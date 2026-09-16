//! Atomic batches of updates, ported from `db/write_batch.cc` and
//! `db/write_batch_internal.h`.
//!
//! A `WriteBatch` is a small serialized buffer that is applied to the memtable
//! and appended to the WAL as one unit, so a crash either replays all of it or
//! none of it.
//!
//! Layout of `rep`:
//!
//!     sequence : fixed64   // sequence of the first record
//!     count    : fixed32   // number of records
//!     record*  : (tag, key[, value])...
//!
//! Each record is a one-byte type tag, a length-prefixed key, and — for puts —
//! a length-prefixed value.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const coding = @import("../primitives/coding.zig");
const internal_key = @import("../db/internal_key.zig");
const MemTable = @import("memtable.zig").MemTable;

const ValueType = internal_key.ValueType;
const SequenceNumber = internal_key.SequenceNumber;

/// Bytes of batch header: an 8-byte sequence number plus a 4-byte record count.
pub const header_size = 12;

/// An atomic group of updates.
///
/// The serialized form is:
///
///     sequence : fixed64   // sequence of the first record
///     count    : fixed32   // number of records
///     record*             // tag, key[, value]
///
/// The whole buffer is appended to the WAL as one log record, so replaying a
/// crash either applies all of it or none of it.
pub const WriteBatch = struct {
    /// The serialized bytes. Reused across operations; `clear` keeps capacity.
    rep: ArrayList(u8),
    /// Allocator for `rep`.
    gpa: Allocator,

    /// Create an empty batch (header only). Caller must `deinit`.
    pub fn init(gpa: Allocator) !WriteBatch {
        var rep = ArrayList(u8).empty;
        errdefer rep.deinit(gpa);
        try rep.appendSlice(gpa, &[_]u8{0} ** header_size);
        return .{ .rep = rep, .gpa = gpa };
    }

    /// Free the buffer.
    pub fn deinit(self: *WriteBatch) void {
        self.rep.deinit(self.gpa);
    }

    /// Reset to an empty batch, keeping the allocation.
    pub fn clear(self: *WriteBatch) void {
        self.rep.items.len = header_size;
        @memset(self.rep.items, 0);
    }

    /// Number of bytes in the serialized batch.
    pub fn byteSize(self: *const WriteBatch) usize {
        return self.rep.items.len;
    }

    /// LevelDB's rough "database change size" metric. For this implementation
    /// it is simply the serialized size.
    pub fn approximateSize(self: *const WriteBatch) usize {
        return self.rep.items.len;
    }

    /// The serialized bytes, ready to append to the log.
    pub fn contents(self: *const WriteBatch) []const u8 {
        return self.rep.items;
    }

    /// Number of records in the batch (stored in the header).
    pub fn count(self: *const WriteBatch) u32 {
        return coding.decodeFixed32(self.rep.items[8..12]);
    }

    /// Overwrite the stored record count.
    pub fn setCount(self: *WriteBatch, n: u32) void {
        coding.encodeFixed32(self.rep.items[8..12], n);
    }

    /// Sequence number of the first record (stored in the header).
    pub fn sequence(self: *const WriteBatch) SequenceNumber {
        return coding.decodeFixed64(self.rep.items[0..8]);
    }

    /// Overwrite the stored sequence number. The DB sets this right before
    /// applying the batch, assigning one sequence per record.
    pub fn setSequence(self: *WriteBatch, seq: SequenceNumber) void {
        coding.encodeFixed64(self.rep.items[0..8], seq);
    }

    /// Append a put: tag, length-prefixed key, length-prefixed value.
    pub fn put(self: *WriteBatch, key: []const u8, value: []const u8) !void {
        self.setCount(self.count() + 1);
        try self.rep.append(self.gpa, @intFromEnum(ValueType.value));
        try coding.putLengthPrefixedSlice(self.gpa, &self.rep, key);
        try coding.putLengthPrefixedSlice(self.gpa, &self.rep, value);
    }

    /// Append a delete (tombstone): tag plus length-prefixed key.
    pub fn delete(self: *WriteBatch, key: []const u8) !void {
        self.setCount(self.count() + 1);
        try self.rep.append(self.gpa, @intFromEnum(ValueType.deletion));
        try coding.putLengthPrefixedSlice(self.gpa, &self.rep, key);
    }

    /// Append all of `other`'s records after ours. The sequence number is left
    /// untouched; the caller sets it before applying. Used by group commit.
    pub fn append(self: *WriteBatch, other: *const WriteBatch) !void {
        self.setCount(self.count() + other.count());
        try self.rep.appendSlice(self.gpa, other.rep.items[header_size..]);
    }

    /// A record decoded from the batch. `key`/`value` point into `rep`.
    pub const Record = struct {
        type: ValueType,
        key: []const u8,
        value: []const u8 = "",
    };

    pub const Iterator = struct {
        input: []const u8,
        remaining: u32,

        /// Returns null when exhausted; returns error.Corruption on bad bytes.
        pub fn next(self: *Iterator) !?Record {
            if (self.remaining == 0) return null;
            if (self.input.len < 1) return error.Corruption;
            const tag = self.input[0];
            self.input = self.input[1..];
            const value_type: ValueType = switch (tag) {
                @intFromEnum(ValueType.value) => .value,
                @intFromEnum(ValueType.deletion) => .deletion,
                else => return error.Corruption,
            };
            const key = coding.getLengthPrefixedSlice(&self.input) orelse return error.Corruption;
            var value: []const u8 = "";
            if (value_type == .value) {
                value = coding.getLengthPrefixedSlice(&self.input) orelse return error.Corruption;
            }
            self.remaining -= 1;
            return .{ .type = value_type, .key = key, .value = value };
        }
    };

    pub fn iterator(self: *const WriteBatch) Iterator {
        return .{ .input = self.rep.items[header_size..], .remaining = self.count() };
    }

    /// Apply the batch to `mem`, assigning consecutive sequence numbers
    /// starting at the batch's own sequence.
    pub fn insertInto(self: *const WriteBatch, mem: *MemTable) !void {
        var it = self.iterator();
        var seq = self.sequence();
        while (try it.next()) |rec| {
            switch (rec.type) {
                .value => try mem.add(seq, .value, rec.key, rec.value),
                .deletion => try mem.add(seq, .deletion, rec.key, ""),
            }
            seq += 1;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const comparator = @import("../primitives/comparator.zig");

test "put/delete encoding and iteration" {
    var batch = try WriteBatch.init(testing.allocator);
    defer batch.deinit();

    try batch.put("k1", "v1");
    try batch.delete("k2");
    try batch.put("k3", "v3");
    try testing.expectEqual(@as(u32, 3), batch.count());

    var it = batch.iterator();
    const r1 = (try it.next()).?;
    try testing.expectEqual(ValueType.value, r1.type);
    try testing.expectEqualStrings("k1", r1.key);
    try testing.expectEqualStrings("v1", r1.value);

    const r2 = (try it.next()).?;
    try testing.expectEqual(ValueType.deletion, r2.type);
    try testing.expectEqualStrings("k2", r2.key);

    const r3 = (try it.next()).?;
    try testing.expectEqualStrings("k3", r3.key);
    try testing.expectEqualStrings("v3", r3.value);

    try testing.expect((try it.next()) == null);
}

test "sequence and clear" {
    var batch = try WriteBatch.init(testing.allocator);
    defer batch.deinit();

    batch.setSequence(42);
    try testing.expectEqual(@as(SequenceNumber, 42), batch.sequence());
    try batch.put("a", "b");
    batch.clear();
    try testing.expectEqual(@as(u32, 0), batch.count());
    try testing.expectEqual(@as(SequenceNumber, 0), batch.sequence());
}

test "append concatenates records" {
    var a = try WriteBatch.init(testing.allocator);
    defer a.deinit();
    var b = try WriteBatch.init(testing.allocator);
    defer b.deinit();

    try a.put("a", "1");
    try b.put("b", "2");
    try a.append(&b);
    try testing.expectEqual(@as(u32, 2), a.count());

    var it = a.iterator();
    try testing.expectEqualStrings("a", (try it.next()).?.key);
    try testing.expectEqualStrings("b", (try it.next()).?.key);
}

test "insertInto applies to a memtable" {
    const icmp = internal_key.InternalKeyComparator.init(comparator.bytewise);
    const mem = try MemTable.create(testing.allocator, icmp);
    mem.ref();
    defer mem.unref();

    var batch = try WriteBatch.init(testing.allocator);
    defer batch.deinit();
    batch.setSequence(10);
    try batch.put("x", "10");
    try batch.put("y", "20");

    try batch.insertInto(mem);

    var lk = try internal_key.LookupKey.init(testing.allocator, "x", 100);
    defer lk.deinit(testing.allocator);
    try testing.expectEqualStrings("10", mem.get(&lk).found);

    var lk2 = try internal_key.LookupKey.init(testing.allocator, "y", 100);
    defer lk2.deinit(testing.allocator);
    try testing.expectEqualStrings("20", mem.get(&lk2).found);
}
