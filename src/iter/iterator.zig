//! The iterator interface, modeled on `include/leveldb/iterator.h`.
//!
//! Everything the engine reads — a block, a table, a memtable, a merged view of
//! several tables — is exposed through this one vtable. Zig has no inheritance,
//! so an iterator is a context pointer plus a table of functions.
//!
//! Unlike the C++ version, resource cleanup is folded into `deinit` rather than
//! a separate cleanup-function list. A merging iterator deinits its children; a
//! table iterator releases its block-cache handle. This keeps ownership obvious.

const std = @import("std");
const Allocator = std.mem.Allocator;

const status = @import("../primitives/status.zig");
const Error = status.Error;

/// Errors an iterator may surface through `status()`.
pub const IteratorError = status.Error || Allocator.Error;

/// A cursor over a sorted sequence of key/value pairs.
///
/// An iterator is either *valid* (positioned on a pair) or invalid (before the
/// first entry, past the last, or empty). Seek operations move it to the first
/// entry at or after a target; `next`/`prev` step one entry.
///
/// Keys and values are borrowed slices that stay valid only until the iterator
/// is moved. Copy anything you need to keep.
pub const Iterator = struct {
    /// Implementation state. The concrete type differs per iterator.
    ptr: *anyopaque,
    /// The function table.
    vtable: *const VTable,

    /// The operations every iterator provides. This is the interface; concrete
    /// iterators fill in these functions and supply a context pointer.
    pub const VTable = struct {
        /// True if positioned on an entry.
        valid: *const fn (ctx: *anyopaque) bool,
        /// Move to the first entry (invalid if empty).
        seekToFirst: *const fn (ctx: *anyopaque) void,
        /// Move to the last entry (invalid if empty).
        seekToLast: *const fn (ctx: *anyopaque) void,
        /// Move to the first entry >= `target` (invalid if none).
        seek: *const fn (ctx: *anyopaque, target: []const u8) void,
        /// Step forward. REQUIRES: `valid()`.
        next: *const fn (ctx: *anyopaque) void,
        /// Step backward. REQUIRES: `valid()`.
        prev: *const fn (ctx: *anyopaque) void,
        /// Current key. REQUIRES: `valid()`.
        key: *const fn (ctx: *anyopaque) []const u8,
        /// Current value. REQUIRES: `valid()`.
        value: *const fn (ctx: *anyopaque) []const u8,
        /// Non-OK if the iterator hit an error while advancing. The vtable
        /// cannot return errors from `next`, so errors surface here.
        status: *const fn (ctx: *anyopaque) IteratorError!void,
        /// Release the iterator and any resources it owns.
        deinit: *const fn (ctx: *anyopaque, gpa: Allocator) void,
    };

    /// True if positioned on an entry.
    pub fn valid(self: Iterator) bool {
        return self.vtable.valid(self.ptr);
    }
    /// Move to the first entry.
    pub fn seekToFirst(self: Iterator) void {
        self.vtable.seekToFirst(self.ptr);
    }
    /// Move to the last entry.
    pub fn seekToLast(self: Iterator) void {
        self.vtable.seekToLast(self.ptr);
    }
    /// Move to the first entry >= `target`.
    pub fn seek(self: Iterator, target: []const u8) void {
        self.vtable.seek(self.ptr, target);
    }
    /// Step forward. REQUIRES: `valid()`.
    pub fn next(self: Iterator) void {
        self.vtable.next(self.ptr);
    }
    /// Step backward. REQUIRES: `valid()`.
    pub fn prev(self: Iterator) void {
        self.vtable.prev(self.ptr);
    }
    /// Current key. REQUIRES: `valid()`.
    pub fn key(self: Iterator) []const u8 {
        return self.vtable.key(self.ptr);
    }
    /// Current value. REQUIRES: `valid()`.
    pub fn value(self: Iterator) []const u8 {
        return self.vtable.value(self.ptr);
    }
    /// Check for errors accumulated while advancing.
    pub fn status(self: Iterator) IteratorError!void {
        return self.vtable.status(self.ptr);
    }
    /// Destroy the iterator. Safe on an exhausted iterator.
    pub fn deinit(self: Iterator, gpa: Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
    }
};

// ---------------------------------------------------------------------------
// Empty iterator (singleton, no allocation)
// ---------------------------------------------------------------------------

const empty_ctx: u8 = 0;

fn emptyValid(_: *anyopaque) bool {
    return false;
}
fn emptyNoop(_: *anyopaque) void {}
fn emptyKey(_: *anyopaque) []const u8 {
    unreachable;
}
fn emptyStatus(_: *anyopaque) IteratorError!void {}
fn emptyDeinit(_: *anyopaque, gpa: Allocator) void {
    _ = gpa;
}

const empty_vtable = Iterator.VTable{
    .valid = emptyValid,
    .seekToFirst = emptyNoop,
    .seekToLast = emptyNoop,
    .seek = struct {
        fn f(_: *anyopaque, _: []const u8) void {}
    }.f,
    .next = emptyNoop,
    .prev = emptyNoop,
    .key = emptyKey,
    .value = emptyKey,
    .status = emptyStatus,
    .deinit = emptyDeinit,
};

/// An iterator that yields nothing.
pub fn empty() Iterator {
    return .{ .ptr = @ptrCast(@constCast(&empty_ctx)), .vtable = &empty_vtable };
}

// ---------------------------------------------------------------------------
// Error iterator
// ---------------------------------------------------------------------------

const ErrorIterator = struct {
    err: IteratorError,
};

fn errValid(_: *anyopaque) bool {
    return false;
}
fn errNoop(_: *anyopaque) void {}
fn errKey(_: *anyopaque) []const u8 {
    unreachable;
}
fn errStatus(ctx: *anyopaque) IteratorError!void {
    const self: *ErrorIterator = @ptrCast(@alignCast(ctx));
    return self.err;
}
fn errDeinit(ctx: *anyopaque, gpa: Allocator) void {
    gpa.destroy(@as(*ErrorIterator, @ptrCast(@alignCast(ctx))));
}

const err_vtable = Iterator.VTable{
    .valid = errValid,
    .seekToFirst = errNoop,
    .seekToLast = errNoop,
    .seek = struct {
        fn f(_: *anyopaque, _: []const u8) void {}
    }.f,
    .next = errNoop,
    .prev = errNoop,
    .key = errKey,
    .value = errKey,
    .status = errStatus,
    .deinit = errDeinit,
};

/// An iterator that yields nothing and reports `err` from `status()`.
pub fn errorIterator(gpa: Allocator, err: IteratorError) !Iterator {
    const ctx = try gpa.create(ErrorIterator);
    ctx.* = .{ .err = err };
    return .{ .ptr = ctx, .vtable = &err_vtable };
}

// ---------------------------------------------------------------------------
// IteratorWrapper — caches validity and key to avoid repeated virtual calls
// ---------------------------------------------------------------------------

pub const IteratorWrapper = struct {
    iter: ?Iterator = null,
    valid_: bool = false,
    key_: []const u8 = &.{},

    pub fn set(self: *IteratorWrapper, iter: ?Iterator) void {
        self.iter = iter;
        self.update();
    }

    pub fn update(self: *IteratorWrapper) void {
        if (self.iter) |it| {
            self.valid_ = it.valid();
            if (self.valid_) self.key_ = it.key();
        } else {
            self.valid_ = false;
        }
    }

    pub fn valid(self: IteratorWrapper) bool {
        return self.valid_;
    }

    pub fn next(self: *IteratorWrapper) void {
        self.iter.?.next();
        self.update();
    }

    pub fn prev(self: *IteratorWrapper) void {
        self.iter.?.prev();
        self.update();
    }

    pub fn seek(self: *IteratorWrapper, target: []const u8) void {
        self.iter.?.seek(target);
        self.update();
    }

    pub fn seekToFirst(self: *IteratorWrapper) void {
        self.iter.?.seekToFirst();
        self.update();
    }

    pub fn seekToLast(self: *IteratorWrapper) void {
        self.iter.?.seekToLast();
        self.update();
    }

    pub fn key(self: IteratorWrapper) []const u8 {
        return self.key_;
    }

    pub fn value(self: IteratorWrapper) []const u8 {
        return self.iter.?.value();
    }

    pub fn status(self: IteratorWrapper) IteratorError!void {
        if (self.iter) |it| return it.status();
    }

    pub fn deinit(self: *IteratorWrapper, gpa: Allocator) void {
        if (self.iter) |it| it.deinit(gpa);
        self.iter = null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "empty iterator" {
    const it = empty();
    try testing.expect(!it.valid());
    it.seekToFirst();
    try testing.expect(!it.valid());
    it.seek("anything");
    try testing.expect(!it.valid());
    try it.status();
}

test "error iterator" {
    const it = try errorIterator(testing.allocator, error.Corruption);
    defer it.deinit(testing.allocator);
    try testing.expect(!it.valid());
    try testing.expectError(error.Corruption, it.status());
}
