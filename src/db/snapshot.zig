//! Snapshots, from `db/snapshot.h`.
//!
//! A snapshot pins a sequence number; reads at that snapshot ignore later
//! writes, and compaction must not drop entries visible to any live snapshot.
//!
//! The C++ version keeps a circular doubly-linked list so `oldest()` is O(1).
//! Since snapshots are rare, this keeps a small array and scans it — a
//! deliberate simplification that is easier to read.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const internal_key = @import("internal_key.zig");
const SequenceNumber = internal_key.SequenceNumber;

pub const Snapshot = struct {
    sequence: SequenceNumber,
};

pub const SnapshotList = struct {
    gpa: Allocator,
    items: ArrayList(*Snapshot) = .empty,

    pub fn init(gpa: Allocator) SnapshotList {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *SnapshotList) void {
        for (self.items.items) |s| self.gpa.destroy(s);
        self.items.deinit(self.gpa);
    }

    pub fn new(self: *SnapshotList, sequence: SequenceNumber) !*Snapshot {
        const s = try self.gpa.create(Snapshot);
        s.* = .{ .sequence = sequence };
        try self.items.append(self.gpa, s);
        return s;
    }

    pub fn delete(self: *SnapshotList, snapshot: *Snapshot) void {
        for (self.items.items, 0..) |s, i| {
            if (s == snapshot) {
                _ = self.items.swapRemove(i);
                self.gpa.destroy(s);
                return;
            }
        }
        unreachable; // snapshot was not created by this list
    }

    pub fn isEmpty(self: *const SnapshotList) bool {
        return self.items.items.len == 0;
    }

    /// Smallest sequence number among live snapshots, or null if none.
    pub fn oldest(self: *const SnapshotList) ?SequenceNumber {
        var min: ?SequenceNumber = null;
        for (self.items.items) |s| {
            if (min == null or s.sequence < min.?) min = s.sequence;
        }
        return min;
    }

    pub fn newest(self: *const SnapshotList) ?SequenceNumber {
        var max: ?SequenceNumber = null;
        for (self.items.items) |s| {
            if (max == null or s.sequence > max.?) max = s.sequence;
        }
        return max;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "snapshot list oldest/newest" {
    var list = SnapshotList.init(testing.allocator);
    defer list.deinit();

    try testing.expect(list.isEmpty());
    try testing.expect(list.oldest() == null);

    const a = try list.new(10);
    const b = try list.new(5);
    const c = try list.new(20);

    try testing.expectEqual(@as(SequenceNumber, 5), list.oldest().?);
    try testing.expectEqual(@as(SequenceNumber, 20), list.newest().?);

    list.delete(b);
    try testing.expectEqual(@as(SequenceNumber, 10), list.oldest().?);
    list.delete(a);
    list.delete(c);
    try testing.expect(list.isEmpty());
}
