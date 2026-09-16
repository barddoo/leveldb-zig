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
    /// Opaque context for the implementation (ignored by stateless comparators).
    ptr: *const anyopaque,
    /// The function table. Every Comparator shares the same shape.
    vtable: *const VTable,

    /// The operations a comparator must provide. This is the "interface"; an
    /// implementation supplies these functions and a context pointer.
    pub const VTable = struct {
        /// Three-way compare. Must be a total order.
        compare: *const fn (ctx: *const anyopaque, a: []const u8, b: []const u8) i32,
        /// A stable name; stored in the MANIFEST so a comparator mismatch is
        /// detected rather than silently corrupting the ordering.
        name: *const fn (ctx: *const anyopaque) []const u8,
        /// Optionally shorten `start` to a shorter key that is still in
        /// `[start, limit)`. Used to shrink index keys.
        findShortestSeparator: *const fn (
            ctx: *const anyopaque,
            gpa: Allocator,
            start: *ArrayList(u8),
            limit: []const u8,
        ) Error!void,
        /// Optionally shorten `key` to a shorter key that is still >= `key`.
        /// Used for the last index entry.
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

    /// Shorten `start` toward `limit`. `start` is an in/out buffer; a no-op
    /// implementation is valid.
    pub fn findShortestSeparator(
        self: Comparator,
        gpa: Allocator,
        start: *ArrayList(u8),
        limit: []const u8,
    ) Error!void {
        return self.vtable.findShortestSeparator(self.ptr, gpa, start, limit);
    }

    /// Shorten `key`. `key` is an in/out buffer; a no-op implementation is valid.
    pub fn findShortSuccessor(self: Comparator, gpa: Allocator, key: *ArrayList(u8)) Error!void {
        return self.vtable.findShortSuccessor(self.ptr, gpa, key);
    }
};

// ---------------------------------------------------------------------------
// Bytewise comparator
// ---------------------------------------------------------------------------

/// Name stored in the MANIFEST. Never change it for an existing comparator.
const bytewise_name = "leveldb.BytewiseComparator";

// The bytewise implementation needs no state, but the vtable requires a
// context pointer, so we point at this dummy.
const bytewise_ctx: u8 = 0;

/// Lexicographic comparison of the raw bytes, shorter-is-smaller on a tie.
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

/// Shorten `start` by finding the first byte where it differs from `limit` and
/// bumping it. For example `"abc1xyz"` with limit `"abc9"` becomes `"abc2"`.
/// If one key is a prefix of the other, or the next byte cannot be bumped while
/// staying below `limit`, the key is left unchanged.
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
    // Only shorten if the bumped byte is still strictly below `limit`'s byte;
    // otherwise the result could equal or exceed `limit`.
    if (diff_byte < 0xff and diff_byte + 1 < limit[diff]) {
        start.items[diff] += 1;
        start.items.len = diff + 1; // truncate
    }
}

/// Shorten `key` by bumping its first non-0xff byte. For example `"abc"`
/// becomes `"b"`. All-0xff keys cannot be shortened and are left alone.
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

/// The default lexicographic bytewise comparator. Stateless, so a single
/// instance is shared by the whole process.
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
