//! Builds prefix-compressed, restart-addressable blocks, from
//! `table/block_builder.cc`.
//!
//! A block stores sorted key/value pairs. To save space, each key is stored as
//! a delta against the previous key (shared prefix + suffix). Every
//! `restart_interval` entries the full key is written instead; those "restart
//! points" let a reader binary-search the block.
//!
//! Entry:  varint32 shared, varint32 unshared, varint32 value_len, delta, value
//! Trailer: fixed32 restart[0..n], fixed32 n

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const coding = @import("../primitives/coding.zig");

/// Builds one prefix-compressed block.
///
/// Keys must be added in strictly increasing order. The first key at each
/// restart point is stored in full; other keys store only the bytes they do not
/// share with the previous key. The restart offsets are appended at the end so
/// a reader can binary-search.
pub const BlockBuilder = struct {
    /// Allocator for the buffers.
    gpa: Allocator,
    /// Number of entries between restart points (1 means every entry).
    restart_interval: usize,
    /// Encoded entries, growing as keys are added.
    buffer: ArrayList(u8) = .empty,
    /// Offsets of restart points within `buffer`; starts with 0.
    restarts: ArrayList(u32) = .empty,
    /// Entries since the last restart point.
    counter: usize = 0,
    /// Set by `finish`; guards against adding after finishing.
    finished: bool = false,
    /// The previous key, used to compute the shared prefix.
    last_key: ArrayList(u8) = .empty,

    /// Create a builder. `restart_interval` must be at least 1.
    pub fn init(gpa: Allocator, restart_interval: usize) !BlockBuilder {
        std.debug.assert(restart_interval >= 1);
        var restarts = ArrayList(u32).empty;
        errdefer restarts.deinit(gpa);
        try restarts.append(gpa, 0); // first restart is at offset 0
        return .{
            .gpa = gpa,
            .restart_interval = restart_interval,
            .restarts = restarts,
        };
    }

    /// Free the buffers.
    pub fn deinit(self: *BlockBuilder) void {
        self.buffer.deinit(self.gpa);
        self.restarts.deinit(self.gpa);
        self.last_key.deinit(self.gpa);
    }

    /// Start a fresh block, keeping the allocations. Used to reuse one builder
    /// for many blocks.
    pub fn reset(self: *BlockBuilder) void {
        self.buffer.clearRetainingCapacity();
        self.restarts.clearRetainingCapacity();
        self.restarts.appendAssumeCapacity(0);
        self.counter = 0;
        self.finished = false;
        self.last_key.clearRetainingCapacity();
    }

    /// True if no entries have been added since the last `reset`.
    pub fn isEmpty(self: *const BlockBuilder) bool {
        return self.buffer.items.len == 0;
    }

    pub fn currentSizeEstimate(self: *const BlockBuilder) usize {
        return self.buffer.items.len + self.restarts.items.len * 4 + 4;
    }

    /// Append a key/value pair. Keys must arrive in strictly increasing order.
    pub fn add(self: *BlockBuilder, key: []const u8, value: []const u8) !void {
        std.debug.assert(!self.finished);

        var shared: usize = 0;
        if (self.counter < self.restart_interval) {
            const min_len = @min(self.last_key.items.len, key.len);
            while (shared < min_len and self.last_key.items[shared] == key[shared]) : (shared += 1) {}
        } else {
            // Start a new restart point: store the full key.
            try self.restarts.append(self.gpa, @intCast(self.buffer.items.len));
            self.counter = 0;
        }

        const non_shared = key.len - shared;
        try coding.putVarint32(self.gpa, &self.buffer, @intCast(shared));
        try coding.putVarint32(self.gpa, &self.buffer, @intCast(non_shared));
        try coding.putVarint32(self.gpa, &self.buffer, @intCast(value.len));
        try self.buffer.appendSlice(self.gpa, key[shared..]);
        try self.buffer.appendSlice(self.gpa, value);

        self.last_key.items.len = shared;
        try self.last_key.appendSlice(self.gpa, key[shared..]);
        self.counter += 1;
    }

    /// Finish the block and return its bytes. Valid until `reset`/`deinit`.
    pub fn finish(self: *BlockBuilder) []const u8 {
        for (self.restarts.items) |r| {
            coding.putFixed32(self.gpa, &self.buffer, r) catch unreachable;
        }
        coding.putFixed32(self.gpa, &self.buffer, @intCast(self.restarts.items.len)) catch unreachable;
        self.finished = true;
        return self.buffer.items;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Block = @import("block.zig").Block;
const comparator = @import("../primitives/comparator.zig");

test "block builder + reader round trip" {
    var builder = try BlockBuilder.init(testing.allocator, 2);
    defer builder.deinit();

    try builder.add("apple", "red");
    try builder.add("apricot", "orange");
    try builder.add("banana", "yellow");
    try builder.add("cherry", "dark red");
    try builder.add("date", "brown");

    const bytes = builder.finish();
    const block = Block.init(testing.allocator, try testing.allocator.dupe(u8, bytes));
    defer {
        var b = block;
        b.deinit();
    }

    const it = try block.newIterator(comparator.bytewise);
    defer it.deinit(testing.allocator);

    it.seekToFirst();
    const expect_keys = [_][]const u8{ "apple", "apricot", "banana", "cherry", "date" };
    const expect_vals = [_][]const u8{ "red", "orange", "yellow", "dark red", "brown" };
    for (expect_keys, expect_vals) |k, v| {
        try testing.expect(it.valid());
        try testing.expectEqualStrings(k, it.key());
        try testing.expectEqualStrings(v, it.value());
        it.next();
    }
    try testing.expect(!it.valid());
    try it.status();
}

test "block seek and reverse" {
    var builder = try BlockBuilder.init(testing.allocator, 1);
    defer builder.deinit();
    for ([_][]const u8{ "a", "c", "e", "g", "i" }) |k| try builder.add(k, k);

    const bytes = builder.finish();
    const block = Block.init(testing.allocator, try testing.allocator.dupe(u8, bytes));
    defer {
        var b = block;
        b.deinit();
    }
    const it = try block.newIterator(comparator.bytewise);
    defer it.deinit(testing.allocator);

    it.seek("d");
    try testing.expect(it.valid());
    try testing.expectEqualStrings("e", it.key());

    it.seekToLast();
    try testing.expectEqualStrings("i", it.key());

    it.prev();
    try testing.expectEqualStrings("g", it.key());
    it.prev();
    try testing.expectEqualStrings("e", it.key());
}

test "block with restart interval 16" {
    var builder = try BlockBuilder.init(testing.allocator, 16);
    defer builder.deinit();

    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;
    for (0..100) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "key-{d:0>5}", .{i});
        const v = try std.fmt.bufPrint(&val_buf, "val-{d}", .{i});
        try builder.add(k, v);
    }

    const bytes = builder.finish();
    const block = Block.init(testing.allocator, try testing.allocator.dupe(u8, bytes));
    defer {
        var b = block;
        b.deinit();
    }
    const it = try block.newIterator(comparator.bytewise);
    defer it.deinit(testing.allocator);

    var count: usize = 0;
    it.seekToFirst();
    while (it.valid()) : (it.next()) count += 1;
    try testing.expectEqual(@as(usize, 100), count);
}
