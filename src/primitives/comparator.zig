//! Key comparators, ported from `util/comparator.{h,cc}` and
//! `include/leveldb/comparator.h`.
//!
//! A `Comparator` defines the total order over user keys. Zig has no
//! inheritance, so the interface is a small vtable: a `*const anyopaque`
//! context plus a table of function pointers. This mirrors the C++ design and
//! keeps room for user-supplied comparators later.
//!
//! Two "advanced" operations let the table builder shrink index keys:
//!   * `findShortestSeparator` may shorten `start` to any key in [start, limit).
//!   * `findShortSuccessor` may shorten `key` to any key >= key.
//! Both are optional: a correct implementation may do nothing at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const status = @import("status.zig");

/// Errors a comparator operation may return (only allocation).
pub const Error = status.Error || Allocator.Error;

pub const Comparator = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        compare: *const fn (ctx: *const anyopaque, a: []const u8, b: []const u8) i32,
        name: *const fn (ctx: *const anyopaque) []const u8,
        findShortestSeparator: *const fn (
            ctx: *const anyopaque,
            gpa: Allocator,
            start: *ArrayList(u8),
            limit: []const u8,
        ) Error!void,
        findShortSuccessor: *const fn (
            ctx: *const anyopaque,
            gpa: Allocator,
            key: *ArrayList(u8),
        ) Error!void,
    };

    /// Three-way compare: <0, 0, >0 for a<b, a==b, a>b.
    pub fn compare(self: Comparator, a: []const u8, b: []const u8) i32 {
        return self.vtable.compare(self.ptr, a, b);
    }

    /// Stable identifier stored in the MANIFEST to detect comparator changes.
    pub fn name(self: Comparator) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn findShortestSeparator(
        self: Comparator,
        gpa: Allocator,
        start: *ArrayList(u8),
        limit: []const u8,
    ) Error!void {
        return self.vtable.findShortestSeparator(self.ptr, gpa, start, limit);
    }

    pub fn findShortSuccessor(self: Comparator, gpa: Allocator, key: *ArrayList(u8)) Error!void {
        return self.vtable.findShortSuccessor(self.ptr, gpa, key);
    }
};

// ---------------------------------------------------------------------------
// Bytewise comparator
// ---------------------------------------------------------------------------

const bytewise_name = "leveldb.BytewiseComparator";

// The bytewise implementation needs no state, but the vtable requires a
// context pointer, so we point at this dummy.
const bytewise_ctx: u8 = 0;

fn bytewiseCompare(_: *const anyopaque, a: []const u8, b: []const u8) i32 {
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn bytewiseName(_: *const anyopaque) []const u8 {
    return bytewise_name;
}

fn bytewiseFindShortestSeparator(
    _: *const anyopaque,
    gpa: Allocator,
    start: *ArrayList(u8),
    limit: []const u8,
) !void {
    _ = gpa;
    const min_len = @min(start.items.len, limit.len);

    var diff: usize = 0;
    while (diff < min_len and start.items[diff] == limit[diff]) : (diff += 1) {}

    if (diff >= min_len) return; // one is a prefix of the other

    const diff_byte = start.items[diff];
    if (diff_byte < 0xff and diff_byte + 1 < limit[diff]) {
        start.items[diff] += 1;
        start.items.len = diff + 1; // truncate
    }
}

fn bytewiseFindShortSuccessor(_: *const anyopaque, gpa: Allocator, key: *ArrayList(u8)) !void {
    _ = gpa;
    for (key.items, 0..) |byte, i| {
        if (byte != 0xff) {
            key.items[i] = byte + 1;
            key.items.len = i + 1; // truncate
            return;
        }
    }
    // All bytes are 0xff; leave the key unchanged.
}

const bytewise_vtable = Comparator.VTable{
    .compare = bytewiseCompare,
    .name = bytewiseName,
    .findShortestSeparator = bytewiseFindShortestSeparator,
    .findShortSuccessor = bytewiseFindShortSuccessor,
};

/// The default lexicographic bytewise comparator.
pub const bytewise: Comparator = .{
    .ptr = @as(*const anyopaque, @ptrCast(&bytewise_ctx)),
    .vtable = &bytewise_vtable,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "bytewise compare" {
    try testing.expect(bytewise.compare("abc", "abd") < 0);
    try testing.expect(bytewise.compare("abc", "abc") == 0);
    try testing.expect(bytewise.compare("abd", "abc") > 0);
    try testing.expect(bytewise.compare("abc", "ab") > 0); // longer sorts after prefix
    try testing.expect(bytewise.compare("", "a") < 0);
    try testing.expectEqualStrings(bytewise_name, bytewise.name());
}

test "findShortestSeparator shrinks when possible" {
    var start = ArrayList(u8).empty;
    defer start.deinit(testing.allocator);
    try start.appendSlice(testing.allocator, "abc1xyz");
    try bytewise.findShortestSeparator(testing.allocator, &start, "abc9");
    // Common prefix "abc", '1' increments to '2' which is still < '9'.
    try testing.expectEqualStrings("abc2", start.items);
}

test "findShortestSeparator leaves prefix cases alone" {
    var start = ArrayList(u8).empty;
    defer start.deinit(testing.allocator);
    try start.appendSlice(testing.allocator, "abc");
    try bytewise.findShortestSeparator(testing.allocator, &start, "abcd");
    try testing.expectEqualStrings("abc", start.items);
}

test "findShortSuccessor" {
    var key = ArrayList(u8).empty;
    defer key.deinit(testing.allocator);
    try key.appendSlice(testing.allocator, "abc");
    try bytewise.findShortSuccessor(testing.allocator, &key);
    try testing.expectEqualStrings("b", key.items);

    // All 0xff: unchanged.
    var ff = ArrayList(u8).empty;
    defer ff.deinit(testing.allocator);
    try ff.appendSlice(testing.allocator, &.{ 0xff, 0xff });
    try bytewise.findShortSuccessor(testing.allocator, &ff);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff }, ff.items);
}
