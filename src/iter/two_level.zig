//! A two-level iterator, from `table/two_level_iterator.cc`.
//!
//! An index iterator yields block handles; for each handle a block function
//! produces a data iterator over that block. This is how a table is scanned:
//! the index block points at data blocks, which are opened lazily.
//!
//! The same pattern also concatenates the non-overlapping files of a level.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const iter_mod = @import("iterator.zig");
const Iterator = iter_mod.Iterator;
const IteratorWrapper = iter_mod.IteratorWrapper;
const IteratorError = iter_mod.IteratorError;
const ReadOptions = @import("../table/format.zig").ReadOptions;

/// Produces a data iterator for the block named by an index entry. `arg` is
/// the caller's context (for a table, the `*Table`).
pub const BlockFunction = *const fn (
    arg: *anyopaque,
    gpa: Allocator,
    options: ReadOptions,
    index_value: []const u8,
) IteratorError!Iterator;

/// An iterator over an index whose entries point at blocks.
///
/// The index iterator yields `(separator_key, block_handle)` pairs. Whenever the
/// index moves, `block_function` opens the named block and gives us a data
/// iterator over it. Because both levels are sorted and non-overlapping, walking
/// the data iterator and stepping the index when it is exhausted yields the
/// blocks in order — exactly what a table scan needs.
pub const TwoLevelIterator = struct {
    /// Allocator for the data iterators and the cached handle.
    gpa: Allocator,
    /// Opens a block given an index value.
    block_function: BlockFunction,
    /// Passed through to `block_function`.
    arg: *anyopaque,
    /// Read options for block reads.
    options: ReadOptions,
    /// Iterator over the index entries.
    index_iter: IteratorWrapper = .{},
    /// Iterator over the current data block (null before the first seek).
    data_iter: IteratorWrapper = .{},
    /// Copy of the index value for the currently open block, so we can tell
    /// whether the index moved to a *different* block or just re-seeked within
    /// the same one.
    data_block_handle: ArrayList(u8) = .empty,
    /// First error seen; surfaced by `status()`.
    err: ?IteratorError = null,

    /// Build a two-level iterator. Takes ownership of `index_iter`.
    pub fn create(
        gpa: Allocator,
        index_iter: Iterator,
        block_function: BlockFunction,
        arg: *anyopaque,
        options: ReadOptions,
    ) !Iterator {
        const self = try gpa.create(TwoLevelIterator);
        self.* = .{
            .gpa = gpa,
            .block_function = block_function,
            .arg = arg,
            .options = options,
        };
        self.index_iter.set(index_iter);
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ctx: *anyopaque) *TwoLevelIterator {
        return @ptrCast(@alignCast(ctx));
    }

    /// Remember the first error; later errors are dropped.
    fn saveError(self: *TwoLevelIterator, err: IteratorError) void {
        if (self.err == null) self.err = err;
    }

    /// Replace the data iterator, releasing the old one and salvaging its
    /// status first.
    fn setDataIterator(self: *TwoLevelIterator, new_iter: ?Iterator) void {
        if (self.data_iter.iter) |old| {
            old.status() catch |e| self.saveError(e);
            old.deinit(self.gpa);
        }
        self.data_iter.set(new_iter);
    }

    /// Open the block the index currently points at, unless it is already open.
    fn initDataBlock(self: *TwoLevelIterator) void {
        if (!self.index_iter.valid()) {
            self.setDataIterator(null);
            return;
        }
        const handle = self.index_iter.value();
        if (self.data_iter.iter != null and std.mem.eql(u8, self.data_block_handle.items, handle)) {
            return; // already positioned on this block
        }
        self.data_block_handle.clearRetainingCapacity();
        self.data_block_handle.appendSlice(self.gpa, handle) catch {
            self.saveError(error.OutOfMemory);
            self.setDataIterator(null);
            return;
        };
        const new_iter = self.block_function(self.arg, self.gpa, self.options, handle) catch |e| {
            self.saveError(e);
            self.setDataIterator(null);
            return;
        };
        self.setDataIterator(new_iter);
    }

    fn skipEmptyDataBlocksForward(self: *TwoLevelIterator) void {
        while (!self.data_iter.valid()) {
            if (!self.index_iter.valid()) {
                self.setDataIterator(null);
                return;
            }
            self.index_iter.next();
            self.initDataBlock();
            if (self.data_iter.iter != null) self.data_iter.seekToFirst();
        }
    }

    fn skipEmptyDataBlocksBackward(self: *TwoLevelIterator) void {
        while (!self.data_iter.valid()) {
            if (!self.index_iter.valid()) {
                self.setDataIterator(null);
                return;
            }
            self.index_iter.prev();
            self.initDataBlock();
            if (self.data_iter.iter != null) self.data_iter.seekToLast();
        }
    }

    fn valid(ctx: *anyopaque) bool {
        return cast(ctx).data_iter.valid();
    }
    fn key(ctx: *anyopaque) []const u8 {
        return cast(ctx).data_iter.key();
    }
    fn value(ctx: *anyopaque) []const u8 {
        return cast(ctx).data_iter.value();
    }
    fn nextFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        std.debug.assert(self.data_iter.valid());
        self.data_iter.next();
        self.skipEmptyDataBlocksForward();
    }
    fn prevFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        std.debug.assert(self.data_iter.valid());
        self.data_iter.prev();
        self.skipEmptyDataBlocksBackward();
    }
    fn seekToFirstFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.index_iter.seekToFirst();
        self.initDataBlock();
        if (self.data_iter.iter != null) self.data_iter.seekToFirst();
        self.skipEmptyDataBlocksForward();
    }
    fn seekToLastFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.index_iter.seekToLast();
        self.initDataBlock();
        if (self.data_iter.iter != null) self.data_iter.seekToLast();
        self.skipEmptyDataBlocksBackward();
    }
    fn seekFn(ctx: *anyopaque, target: []const u8) void {
        const self = cast(ctx);
        self.index_iter.seek(target);
        self.initDataBlock();
        if (self.data_iter.iter != null) self.data_iter.seek(target);
        self.skipEmptyDataBlocksForward();
    }
    fn statusFn(ctx: *anyopaque) IteratorError!void {
        const self = cast(ctx);
        try self.index_iter.status();
        if (self.data_iter.iter) |it| try it.status();
        if (self.err) |e| return e;
    }
    fn deinitFn(ctx: *anyopaque, gpa: Allocator) void {
        const self = cast(ctx);
        self.index_iter.deinit(gpa);
        self.data_iter.deinit(gpa);
        self.data_block_handle.deinit(gpa);
        gpa.destroy(self);
    }

    const vtable = Iterator.VTable{
        .valid = valid,
        .seekToFirst = seekToFirstFn,
        .seekToLast = seekToLastFn,
        .seek = seekFn,
        .next = nextFn,
        .prev = prevFn,
        .key = key,
        .value = value,
        .status = statusFn,
        .deinit = deinitFn,
    };
};
