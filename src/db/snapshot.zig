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

/// An opaque handle to a point in time. Reads with this snapshot see exactly
/// the writes with a sequence number at or below `sequence`, and no later ones.
pub const Snapshot = struct {
    /// The sequence number the snapshot is pinned to.
    sequence: SequenceNumber,
};

/// The set of live snapshots. Compaction consults `oldest` to decide which
/// older versions are safe to drop.
///
/// LevelDB keeps an intrusive sorted list; this port keeps an array and scans
/// it. Snapshots are rare, so the O(n) scan is not worth optimizing away, and
/// the array is much easier to read.
pub const SnapshotList = struct {
    /// Allocator used to create and destroy snapshots.
    gpa: Allocator,
    /// Live snapshots, in creation order. Each is individually heap-allocated
    /// so the pointer handed to the caller stays valid.
    items: ArrayList(*Snapshot) = .empty,

    pub fn init(gpa: Allocator) SnapshotList {
        return .{ .gpa = gpa };
    }

    /// Free every snapshot. The DB calls this at close.
    pub fn deinit(self: *SnapshotList) void {
        for (self.items.items) |s| self.gpa.destroy(s);
        self.items.deinit(self.gpa);
    }

    /// Pin the current sequence and return a handle. The caller must eventually
    /// call `delete` with the same pointer.
    pub fn new(self: *SnapshotList, sequence: SequenceNumber) !*Snapshot {
        const s = try self.gpa.create(Snapshot);
        s.* = .{ .sequence = sequence };
        try self.items.append(self.gpa, s);
        return s;
    }

    /// Release a snapshot created by `new`. Panics if the pointer is unknown,
    /// which means the caller released it twice or from the wrong DB.
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

    /// True if no snapshots are live.
    pub fn isEmpty(self: *const SnapshotList) bool {
        return self.items.items.len == 0;
    }

    /// Smallest sequence number among live snapshots, or null if none. This is
    /// the bound compaction uses when deciding what older data may be dropped.
    pub fn oldest(self: *const SnapshotList) ?SequenceNumber {
        var min: ?SequenceNumber = null;
        for (self.items.items) |s| {
            if (min == null or s.sequence < min.?) min = s.sequence;
        }
        return min;
    }

    /// Largest sequence number among live snapshots, or null if none.
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
