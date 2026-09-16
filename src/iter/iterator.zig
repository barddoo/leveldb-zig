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

pub const Iterator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        valid: *const fn (ctx: *anyopaque) bool,
        seekToFirst: *const fn (ctx: *anyopaque) void,
        seekToLast: *const fn (ctx: *anyopaque) void,
        seek: *const fn (ctx: *anyopaque, target: []const u8) void,
        next: *const fn (ctx: *anyopaque) void,
        prev: *const fn (ctx: *anyopaque) void,
        key: *const fn (ctx: *anyopaque) []const u8,
        value: *const fn (ctx: *anyopaque) []const u8,
        /// Non-OK if the iterator encountered an error while advancing.
        status: *const fn (ctx: *anyopaque) IteratorError!void,
        deinit: *const fn (ctx: *anyopaque, gpa: Allocator) void,
    };

    pub fn valid(self: Iterator) bool {
        return self.vtable.valid(self.ptr);
    }
    pub fn seekToFirst(self: Iterator) void {
        self.vtable.seekToFirst(self.ptr);
    }
    pub fn seekToLast(self: Iterator) void {
        self.vtable.seekToLast(self.ptr);
    }
    pub fn seek(self: Iterator, target: []const u8) void {
        self.vtable.seek(self.ptr, target);
    }
    pub fn next(self: Iterator) void {
        self.vtable.next(self.ptr);
    }
    pub fn prev(self: Iterator) void {
        self.vtable.prev(self.ptr);
    }
    /// REQUIRES: `valid()`.
    pub fn key(self: Iterator) []const u8 {
        return self.vtable.key(self.ptr);
    }
    /// REQUIRES: `valid()`.
    pub fn value(self: Iterator) []const u8 {
        return self.vtable.value(self.ptr);
    }
    pub fn status(self: Iterator) IteratorError!void {
        return self.vtable.status(self.ptr);
    }
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
