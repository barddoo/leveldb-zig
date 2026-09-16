//! Filter block construction and lookup, from `table/filter_block.{h,cc}`.
//!
//! One filter is generated per 2 KiB region of the table file, so a lookup maps
//! a data-block offset to its filter with a shift. Layout:
//!
//!     [filter 0]...[filter N-1]
//!     fixed32 offset[0..N-1]
//!     fixed32 offset_of_offset_array
//!     u8      lg(base)   // 11

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const coding = @import("../primitives/coding.zig");
const FilterPolicy = @import("filter_policy.zig").FilterPolicy;

pub const base_lg: u8 = 11;
pub const base: usize = 1 << base_lg; // 2048

pub const Builder = struct {
    gpa: Allocator,
    policy: FilterPolicy,
    keys: ArrayList(u8) = .empty,
    start: ArrayList(usize) = .empty,
    result: ArrayList(u8) = .empty,
    tmp_keys: ArrayList([]const u8) = .empty,
    filter_offsets: ArrayList(usize) = .empty,

    pub fn init(gpa: Allocator, policy: FilterPolicy) Builder {
        return .{ .gpa = gpa, .policy = policy };
    }

    pub fn deinit(self: *Builder) void {
        self.keys.deinit(self.gpa);
        self.start.deinit(self.gpa);
        self.result.deinit(self.gpa);
        self.tmp_keys.deinit(self.gpa);
        self.filter_offsets.deinit(self.gpa);
    }

    /// Call when the table's current offset reaches `block_offset`; emits any
    /// filters for regions that contained no keys.
    pub fn startBlock(self: *Builder, block_offset: u64) !void {
        const filter_index = block_offset / base;
        while (filter_index > self.filter_offsets.items.len) try self.generateFilter();
    }

    pub fn addKey(self: *Builder, key: []const u8) !void {
        try self.start.append(self.gpa, self.keys.items.len);
        try self.keys.appendSlice(self.gpa, key);
    }

    fn generateFilter(self: *Builder) !void {
        const num_keys = self.start.items.len;
        if (num_keys == 0) {
            try self.filter_offsets.append(self.gpa, self.result.items.len);
            return;
        }

        self.tmp_keys.clearRetainingCapacity();
        try self.tmp_keys.ensureTotalCapacity(self.gpa, num_keys);
        for (0..num_keys) |i| {
            const s = self.start.items[i];
            const limit = if (i + 1 < num_keys) self.start.items[i + 1] else self.keys.items.len;
            self.tmp_keys.appendAssumeCapacity(self.keys.items[s..limit]);
        }

        try self.filter_offsets.append(self.gpa, self.result.items.len);
        try self.policy.createFilter(self.gpa, self.tmp_keys.items, &self.result);

        self.start.clearRetainingCapacity();
        self.keys.clearRetainingCapacity();
    }

    /// Finish and return the filter block bytes (owned by the builder).
    pub fn finish(self: *Builder) ![]const u8 {
        if (self.start.items.len > 0) try self.generateFilter();

        const array_offset = self.result.items.len;
        for (self.filter_offsets.items) |off| {
            try coding.putFixed32(self.gpa, &self.result, @intCast(off));
        }
        try coding.putFixed32(self.gpa, &self.result, @intCast(array_offset));
        try self.result.append(self.gpa, base_lg);
        return self.result.items;
    }
};

pub const Reader = struct {
    policy: FilterPolicy,
    data: []const u8,
    offset: []const u8 = &.{},
    num: usize = 0,
    base_lg_: u8 = 0,
    valid: bool = false,

    /// `contents` is borrowed and must outlive the reader.
    pub fn init(policy: FilterPolicy, contents: []const u8) Reader {
        var self = Reader{ .policy = policy, .data = contents };
        const n = contents.len;
        if (n < 5) return self;

        const base_lg_value = contents[n - 1];
        const last_word = coding.decodeFixed32(contents[n - 5 ..][0..4]);
        if (@as(usize, last_word) > n - 5) return self;

        self.base_lg_ = base_lg_value;
        self.offset = contents[last_word..];
        self.num = (n - 5 - last_word) / 4;
        self.valid = true;
        return self;
    }

    /// Returns true if the filter cannot rule out `key` at `block_offset`.
    pub fn keyMayMatch(self: Reader, block_offset: u64, key: []const u8) bool {
        if (!self.valid) return true; // no usable filter: assume it may match

        const index = block_offset >> @as(u6, @intCast(self.base_lg_));
        if (index < self.num) {
            const start = coding.decodeFixed32(self.offset[index * 4 ..][0..4]);
            const limit = coding.decodeFixed32(self.offset[index * 4 + 4 ..][0..4]);
            const data_offset = @intFromPtr(self.offset.ptr) - @intFromPtr(self.data.ptr);

            if (start <= limit and limit <= data_offset) {
                return self.policy.keyMayMatch(key, self.data[start..limit]);
            } else if (start == limit) {
                return false; // empty filter
            }
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const filter_policy = @import("filter_policy.zig");

test "empty filter block" {
    const policy = try filter_policy.createBloom(testing.allocator, 10);
    defer filter_policy.destroyBloom(testing.allocator, policy);

    var builder = Builder.init(testing.allocator, policy);
    defer builder.deinit();

    const bytes = try builder.finish();
    const reader = Reader.init(policy, bytes);
    try testing.expect(reader.valid);
    // With no filters at all the reader cannot rule anything out.
    try testing.expect(reader.keyMayMatch(0, "x"));
}

test "single and multi region filters" {
    const policy = try filter_policy.createBloom(testing.allocator, 10);
    defer filter_policy.destroyBloom(testing.allocator, policy);

    var builder = Builder.init(testing.allocator, policy);
    defer builder.deinit();

    try builder.startBlock(0);
    try builder.addKey("foo");
    try builder.addKey("bar");

    // Jump far ahead so an empty filter is emitted for the gap.
    try builder.startBlock(base * 3);
    try builder.addKey("baz");

    const bytes = try builder.finish();
    const reader = Reader.init(policy, bytes);

    try testing.expect(reader.keyMayMatch(0, "foo"));
    try testing.expect(reader.keyMayMatch(0, "bar"));
    try testing.expect(reader.keyMayMatch(base * 3, "baz"));
    // "foo" was only in region 0.
    try testing.expect(!reader.keyMayMatch(base * 3, "foo"));
}
