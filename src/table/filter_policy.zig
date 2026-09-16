//! Filter policies and the built-in Bloom filter, from `util/bloom.cc` and
//! `include/leveldb/filter_policy.h`.
//!
//! A filter policy summarizes a set of keys into a compact filter. The table
//! stores one filter per 2 KiB region of the file; a read consults the filter
//! before touching disk, skipping the read when the key is definitely absent.
//!
//! Bloom filter layout: `bit_array (bytes) || k (1 byte)`, where
//! `bytes = ceil(max(64, n*bits_per_key)/8)` and `k` probes are derived from a
//! double hash (`h` and a rotate-right-17 delta).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const hash = @import("../primitives/hash.zig");
const status = @import("../primitives/status.zig");

/// Errors a filter operation may return (only allocation).
pub const Error = status.Error || Allocator.Error;

pub const FilterPolicy = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ctx: *const anyopaque) []const u8,
        /// Append a filter summarizing `keys` to `dst`.
        createFilter: *const fn (
            ctx: *const anyopaque,
            gpa: Allocator,
            keys: []const []const u8,
            dst: *ArrayList(u8),
        ) Error!void,
        keyMayMatch: *const fn (ctx: *const anyopaque, key: []const u8, filter: []const u8) bool,
    };

    pub fn name(self: FilterPolicy) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn createFilter(self: FilterPolicy, gpa: Allocator, keys: []const []const u8, dst: *ArrayList(u8)) Error!void {
        return self.vtable.createFilter(self.ptr, gpa, keys, dst);
    }

    pub fn keyMayMatch(self: FilterPolicy, key: []const u8, filter: []const u8) bool {
        return self.vtable.keyMayMatch(self.ptr, key, filter);
    }
};

pub const bloom_name = "leveldb.BuiltinBloomFilter2";

const Bloom = struct {
    bits_per_key: usize,
    k: usize,

    fn policy(self: *const Bloom) FilterPolicy {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn ctx(ptr: *const anyopaque) *const Bloom {
        return @ptrCast(@alignCast(ptr));
    }

    fn nameFn(_: *const anyopaque) []const u8 {
        return bloom_name;
    }

    fn createFilterFn(
        ptr: *const anyopaque,
        gpa: Allocator,
        keys: []const []const u8,
        dst: *ArrayList(u8),
    ) Error!void {
        const self = ctx(ptr);

        var bits = keys.len * self.bits_per_key;
        if (bits < 64) bits = 64;
        const bytes = (bits + 7) / 8;
        bits = bytes * 8;

        const start = dst.items.len;
        try dst.appendNTimes(gpa, 0, bytes);
        try dst.append(gpa, @intCast(self.k));

        for (keys) |key| {
            var h = hash.hash(key, 0xbc9f1d34);
            const delta = (h >> 17) | (h << 15);
            var j: usize = 0;
            while (j < self.k) : (j += 1) {
                const bitpos = h % bits;
                dst.items[start + bitpos / 8] |= @as(u8, 1) << @intCast(bitpos % 8);
                h +%= delta;
            }
        }
    }

    fn keyMayMatchFn(ptr: *const anyopaque, key: []const u8, filter: []const u8) bool {
        _ = ctx(ptr);
        if (filter.len < 2) return false;
        const bits = (filter.len - 1) * 8;
        const k = filter[filter.len - 1];
        if (k > 30) {
            // Reserved for future encodings; be conservative.
            return true;
        }

        var h = hash.hash(key, 0xbc9f1d34);
        const delta = (h >> 17) | (h << 15);
        var j: usize = 0;
        while (j < k) : (j += 1) {
            const bitpos = h % bits;
            if (filter[bitpos / 8] & (@as(u8, 1) << @intCast(bitpos % 8)) == 0) return false;
            h +%= delta;
        }
        return true;
    }

    const vtable = FilterPolicy.VTable{
        .name = nameFn,
        .createFilter = createFilterFn,
        .keyMayMatch = keyMayMatchFn,
    };
};

/// Create a Bloom filter policy with ~`bits_per_key` bits per key (10 is a
/// good default, giving ~1% false positives). Caller frees with `destroyBloom`.
pub fn createBloom(gpa: Allocator, bits_per_key: usize) !FilterPolicy {
    const self = try gpa.create(Bloom);
    var k = (bits_per_key * 69) / 100; // ln(2) ~= 0.69
    if (k < 1) k = 1;
    if (k > 30) k = 30;
    self.* = .{ .bits_per_key = bits_per_key, .k = k };
    return self.policy();
}

pub fn destroyBloom(gpa: Allocator, policy: FilterPolicy) void {
    const p: *anyopaque = @constCast(policy.ptr);
    const self: *Bloom = @ptrCast(@alignCast(p));
    gpa.destroy(self);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "bloom: all inserted keys match" {
    const policy = try createBloom(testing.allocator, 10);
    defer destroyBloom(testing.allocator, policy);

    var filter = ArrayList(u8).empty;
    defer filter.deinit(testing.allocator);

    const keys = [_][]const u8{ "apple", "banana", "cherry", "date", "elderberry" };
    try policy.createFilter(testing.allocator, &keys, &filter);

    for (keys) |k| try testing.expect(policy.keyMayMatch(k, filter.items));
}

test "bloom: false positive rate stays low" {
    const policy = try createBloom(testing.allocator, 10);
    defer destroyBloom(testing.allocator, policy);

    var filter = ArrayList(u8).empty;
    defer filter.deinit(testing.allocator);

    const n = 1000;
    const keys = try testing.allocator.alloc([]const u8, n);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    for (keys, 0..) |*slot, i| {
        slot.* = try std.fmt.allocPrint(testing.allocator, "key-{d}", .{i});
    }
    try policy.createFilter(testing.allocator, keys, &filter);

    for (keys) |k| try testing.expect(policy.keyMayMatch(k, filter.items));

    var false_positives: usize = 0;
    for (0..1000) |i| {
        const probe = try std.fmt.allocPrint(testing.allocator, "absent-{d}", .{i});
        defer testing.allocator.free(probe);
        if (policy.keyMayMatch(probe, filter.items)) false_positives += 1;
    }
    // With 10 bits/key the rate is ~1%; allow generous slack for small n.
    try testing.expect(false_positives <= 50);
}

test "bloom: empty filter matches nothing" {
    const policy = try createBloom(testing.allocator, 10);
    defer destroyBloom(testing.allocator, policy);
    try testing.expect(!policy.keyMayMatch("anything", &.{}));
}
