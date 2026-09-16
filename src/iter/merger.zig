//! Merging iterator, from `table/merger.cc`.
//!
//! Combines N sorted child iterators into one sorted stream. No duplicate
//! suppression happens here — that is the DB iterator's job. Ties are broken by
//! child order: the earliest child wins going forward and the latest wins going
//! backward, which is what makes level-0 files (newest first) behave correctly.
//!
//! Direction changes reposition the non-current children, the classic trick
//! that lets one structure serve both `Next` and `Prev`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const comparator = @import("../primitives/comparator.zig");
const iter_mod = @import("iterator.zig");
const Iterator = iter_mod.Iterator;
const IteratorWrapper = iter_mod.IteratorWrapper;
const IteratorError = iter_mod.IteratorError;

const Direction = enum { forward, reverse };

/// Combine `children` into one iterator. Takes ownership of every child.
pub fn create(gpa: Allocator, cmp: comparator.Comparator, children: []Iterator) !Iterator {
    // On success this takes ownership of both the child iterators and the
    // `children` array. On failure the caller keeps ownership of both.
    if (children.len == 0) {
        gpa.free(children);
        return iter_mod.empty();
    }
    if (children.len == 1) {
        const only = children[0];
        gpa.free(children);
        return only;
    }

    const wrappers = try gpa.alloc(IteratorWrapper, children.len);
    errdefer gpa.free(wrappers);
    for (children, 0..) |child, i| {
        wrappers[i] = .{};
        wrappers[i].set(child);
    }

    const self = try gpa.create(MergingIterator);
    self.* = .{
        .gpa = gpa,
        .cmp = cmp,
        .children = wrappers,
        .current = &wrappers[0],
        .direction = .forward,
    };
    gpa.free(children);
    return .{ .ptr = self, .vtable = &MergingIterator.vtable };
}

const MergingIterator = struct {
    gpa: Allocator,
    cmp: comparator.Comparator,
    children: []IteratorWrapper,
    current: *IteratorWrapper,
    direction: Direction,

    fn cast(ctx: *anyopaque) *MergingIterator {
        return @ptrCast(@alignCast(ctx));
    }

    /// Pick the child with the smallest key as the current one.
    ///
    /// Ties are broken by child order: the *earliest* child wins because we only
    /// replace `smallest` on a strictly-smaller key. This matters for level 0,
    /// where files overlap and the caller passes them newest-first, so a newer
    /// version of a key wins over an older one.
    fn findSmallest(self: *MergingIterator) void {
        var smallest = &self.children[0];
        for (self.children[1..]) |*child| {
            if (child.valid()) {
                if (!smallest.valid() or self.cmp.compare(child.key(), smallest.key()) < 0) {
                    smallest = child;
                }
            }
        }
        self.current = smallest;
    }

    /// Pick the child with the largest key. Ties go to the *latest* child
    /// (strictly-greater comparison), the mirror of `findSmallest`.
    fn findLargest(self: *MergingIterator) void {
        var largest = &self.children[0];
        for (self.children[1..]) |*child| {
            if (child.valid()) {
                if (!largest.valid() or self.cmp.compare(child.key(), largest.key()) > 0) {
                    largest = child;
                }
            }
        }
        self.current = largest;
    }

    fn valid(ctx: *anyopaque) bool {
        return cast(ctx).current.valid();
    }
    fn key(ctx: *anyopaque) []const u8 {
        const self = cast(ctx);
        std.debug.assert(self.current.valid());
        return self.current.key();
    }
    fn value(ctx: *anyopaque) []const u8 {
        const self = cast(ctx);
        std.debug.assert(self.current.valid());
        return self.current.value();
    }

    /// Advance the merged stream forward by one entry.
    ///
    /// The hard case is when we were previously going backward: the other
    /// children were left positioned at or before the current key, so they are
    /// not necessarily pointing at the next candidate. Before stepping, we
    /// re-seek every other child to the current key and, if it lands exactly on
    /// it, step past it. After that all children are strictly after the current
    /// key and `findSmallest` works again.
    fn nextFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        std.debug.assert(self.current.valid());

        if (self.direction != .forward) {
            for (self.children) |*child| {
                if (child != self.current) {
                    child.seek(self.current.key());
                    if (child.valid() and self.cmp.compare(self.current.key(), child.key()) == 0) {
                        child.next();
                    }
                }
            }
            self.direction = .forward;
        }

        self.current.next();
        self.findSmallest();
    }

    /// Advance the merged stream backward by one entry. Mirror image of `next`:
    /// reposition the other children to be strictly before the current key.
    fn prevFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        std.debug.assert(self.current.valid());

        if (self.direction != .reverse) {
            for (self.children) |*child| {
                if (child != self.current) {
                    child.seek(self.current.key());
                    if (child.valid()) {
                        // If the child landed on the current key, step back so
                        // it is strictly before it.
                        if (self.cmp.compare(self.current.key(), child.key()) > 0) child.prev();
                    } else {
                        // The child has no key >= current, so its last entry is
                        // the closest one before.
                        child.seekToLast();
                    }
                }
            }
            self.direction = .reverse;
        }

        self.current.prev();
        self.findLargest();
    }

    fn seekFn(ctx: *anyopaque, target: []const u8) void {
        const self = cast(ctx);
        for (self.children) |*child| child.seek(target);
        self.findSmallest();
        self.direction = .forward;
    }

    fn seekToFirstFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        for (self.children) |*child| child.seekToFirst();
        self.findSmallest();
        self.direction = .forward;
    }

    fn seekToLastFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        for (self.children) |*child| child.seekToLast();
        self.findLargest();
        self.direction = .reverse;
    }

    fn statusFn(ctx: *anyopaque) IteratorError!void {
        const self = cast(ctx);
        for (self.children) |*child| try child.status();
    }

    fn deinitFn(ctx: *anyopaque, gpa: Allocator) void {
        const self = cast(ctx);
        for (self.children) |*child| child.deinit(gpa);
        gpa.free(self.children);
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A tiny in-memory iterator over a fixed list of key/value pairs, used to test
/// the merger without depending on the table or memtable layers.
const ArrayIterator = struct {
    entries: []const [2][]const u8,
    index: usize = 0,
    pos: usize = 0,

    fn create(gpa: Allocator, entries: []const [2][]const u8) !Iterator {
        const self = try gpa.create(ArrayIterator);
        self.* = .{ .entries = entries, .index = 0 };
        return .{ .ptr = self, .vtable = &ArrayIterator.vtable };
    }
    fn cast(ctx: *anyopaque) *ArrayIterator {
        return @ptrCast(@alignCast(ctx));
    }
    fn valid(ctx: *anyopaque) bool {
        return cast(ctx).index < cast(ctx).entries.len;
    }
    fn key(ctx: *anyopaque) []const u8 {
        return cast(ctx).entries[cast(ctx).index][0];
    }
    fn value(ctx: *anyopaque) []const u8 {
        return cast(ctx).entries[cast(ctx).index][1];
    }
    fn nextFn(ctx: *anyopaque) void {
        cast(ctx).index += 1;
    }
    fn prevFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        if (self.index > 0) self.index -= 1 else self.index = self.entries.len;
    }
    fn seekToFirstFn(ctx: *anyopaque) void {
        cast(ctx).index = 0;
    }
    fn seekToLastFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.index = if (self.entries.len == 0) 0 else self.entries.len - 1;
    }
    fn seekFn(ctx: *anyopaque, target: []const u8) void {
        const self = cast(ctx);
        self.index = self.entries.len;
        for (self.entries, 0..) |e, i| {
            if (std.mem.order(u8, e[0], target) != .lt) {
                self.index = i;
                return;
            }
        }
    }
    fn statusFn(_: *anyopaque) IteratorError!void {}
    fn deinitFn(ctx: *anyopaque, gpa: Allocator) void {
        gpa.destroy(cast(ctx));
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

test "merger interleaves sorted children" {
    const gpa = testing.allocator;
    const a = [_][2][]const u8{ .{ "a", "1" }, .{ "c", "3" }, .{ "e", "5" } };
    const b = [_][2][]const u8{ .{ "b", "2" }, .{ "d", "4" }, .{ "f", "6" } };

    const children = try gpa.alloc(Iterator, 2);
    children[0] = try ArrayIterator.create(gpa, &a);
    children[1] = try ArrayIterator.create(gpa, &b);
    const it = try create(gpa, comparator.bytewise, children);
    defer it.deinit(gpa);

    it.seekToFirst();
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(gpa);
    while (it.valid()) : (it.next()) try keys.append(gpa, it.key());

    try testing.expectEqual(@as(usize, 6), keys.items.len);
    try testing.expectEqualStrings("a", keys.items[0]);
    try testing.expectEqualStrings("b", keys.items[1]);
    try testing.expectEqualStrings("c", keys.items[2]);
    try testing.expectEqualStrings("d", keys.items[3]);
    try testing.expectEqualStrings("e", keys.items[4]);
    try testing.expectEqualStrings("f", keys.items[5]);
}

test "merger reverse iteration" {
    const gpa = testing.allocator;
    const a = [_][2][]const u8{ .{ "a", "1" }, .{ "c", "3" } };
    const b = [_][2][]const u8{ .{ "b", "2" }, .{ "d", "4" } };

    const children = try gpa.alloc(Iterator, 2);
    children[0] = try ArrayIterator.create(gpa, &a);
    children[1] = try ArrayIterator.create(gpa, &b);
    const it = try create(gpa, comparator.bytewise, children);
    defer it.deinit(gpa);

    it.seekToLast();
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(gpa);
    while (it.valid()) : (it.prev()) try keys.append(gpa, it.key());

    try testing.expectEqual(@as(usize, 4), keys.items.len);
    try testing.expectEqualStrings("d", keys.items[0]);
    try testing.expectEqualStrings("c", keys.items[1]);
    try testing.expectEqualStrings("b", keys.items[2]);
    try testing.expectEqualStrings("a", keys.items[3]);
}
