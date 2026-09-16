//! The user-facing DB iterator, from `db/db_iter.cc`.
//!
//! The internal representation holds many versions of the same user key, each
//! tagged with a sequence number and a value/deletion type. This iterator
//! collapses them into one visible entry per user key:
//!
//!   * entries with `sequence > snapshot` are invisible,
//!   * a tombstone hides all older versions of that key,
//!   * the newest visible value is yielded.
//!
//! # Why forward and reverse are separate code paths
//!
//! The internal iterator can only be in one place at a time, and the two
//! directions need it in different places:
//!
//!   * **Forward** — the internal iterator sits *on* the entry being returned.
//!     `key()` is `ExtractUserKey(iter.key())` and `value()` is `iter.value()`.
//!   * **Reverse** — the internal iterator sits *just before* all versions of
//!     the returned key. The returned key and value are cached in `saved_key`
//!     and `saved_value`, because the internal iterator has already moved past
//!     them.
//!
//! When you call `next()` while going backward (or `prev()` while going
//! forward), the iterator must be repositioned before the normal scanning code
//! can run. That is why `next` and `prev` both have a "switch directions"
//! preamble.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const comparator = @import("../primitives/comparator.zig");
const random = @import("../primitives/random.zig");
const internal_key = @import("../db/internal_key.zig");
const coding = @import("../primitives/coding.zig");
const iter_mod = @import("iterator.zig");
const Iterator = iter_mod.Iterator;
const IteratorError = iter_mod.IteratorError;

const ValueType = internal_key.ValueType;
const SequenceNumber = internal_key.SequenceNumber;
const ParsedInternalKey = internal_key.ParsedInternalKey;

/// Approximate read interval that triggers a compaction-sample callback.
pub const read_bytes_period: usize = 1048576;

/// Optional hook the DB installs to notice reads that span many files, which is
/// a signal that a key should be compacted. Unused by default.
pub const ReadSample = struct {
    ptr: *anyopaque,
    record_fn: *const fn (ctx: *anyopaque, key: []const u8) void,
};

const Direction = enum { forward, reverse };

/// Wrap `internal_iter` so it yields user keys, hiding versions above
/// `sequence` and suppressing tombstoned keys. Takes ownership of `internal_iter`.
pub fn create(
    gpa: Allocator,
    user_cmp: comparator.Comparator,
    internal_iter: Iterator,
    sequence: SequenceNumber,
    seed: u32,
    read_sample: ?ReadSample,
) !Iterator {
    const self = try gpa.create(DBIter);
    self.* = .{
        .gpa = gpa,
        .user_cmp = user_cmp,
        .iter = internal_iter,
        .sequence = sequence,
        .rnd = random.Random.init(seed),
        .read_sample = read_sample,
    };
    self.bytes_until_read_sampling = self.randomCompactionPeriod();
    return .{ .ptr = self, .vtable = &DBIter.vtable };
}

const DBIter = struct {
    gpa: Allocator,
    user_cmp: comparator.Comparator,
    iter: Iterator,
    /// The snapshot this iterator reads at. Entries with a higher sequence are
    /// invisible.
    sequence: SequenceNumber,

    /// When `direction == .reverse`, the user key and value currently being
    /// returned. In the forward direction `saved_key` is also used as scratch:
    /// it holds the key we must skip past while scanning.
    saved_key: ArrayList(u8) = .empty,
    saved_value: ArrayList(u8) = .empty,
    direction: Direction = .forward,
    valid: bool = false,
    err: ?IteratorError = null,

    rnd: random.Random,
    bytes_until_read_sampling: usize = 0,
    read_sample: ?ReadSample = null,

    fn cast(ctx: *anyopaque) *DBIter {
        return @ptrCast(@alignCast(ctx));
    }

    fn randomCompactionPeriod(self: *DBIter) usize {
        return self.rnd.uniform(2 * read_bytes_period);
    }

    /// Drop `saved_value`'s buffer if it has grown large; otherwise just clear
    /// it. This keeps a single huge value from being retained forever.
    fn clearSavedValue(self: *DBIter) void {
        if (self.saved_value.capacity > 1048576) {
            self.saved_value.deinit(self.gpa);
            self.saved_value = .empty;
        } else {
            self.saved_value.clearRetainingCapacity();
        }
    }

    fn saveKey(self: *DBIter, key: []const u8) void {
        self.saved_key.clearRetainingCapacity();
        self.saved_key.appendSlice(self.gpa, key) catch {
            self.err = error.OutOfMemory;
        };
    }

    /// Parse the internal key at the current position, sampling reads.
    ///
    /// Read sampling is a cheap heuristic: every ~1 MiB of bytes read, tell the
    /// DB which key was read so it can notice hot keys that span many files and
    /// schedule a compaction. It has no effect on the result.
    fn parseKey(self: *DBIter) ?ParsedInternalKey {
        const k = self.iter.key();
        const bytes_read = k.len + self.iter.value().len;

        while (self.bytes_until_read_sampling < bytes_read) {
            self.bytes_until_read_sampling += self.randomCompactionPeriod();
            if (self.read_sample) |rs| rs.record_fn(rs.ptr, k);
        }
        self.bytes_until_read_sampling -= bytes_read;

        return internal_key.parseInternalKey(k) orelse {
            self.err = error.Corruption;
            return null;
        };
    }

    /// Advance the internal iterator to the next visible value, in the forward
    /// direction. Leaves `valid` set and the iterator positioned on the entry.
    ///
    /// `skipping` starts true when the caller already knows the current key must
    /// be skipped (for example `next()` just consumed it). `saved_key` holds the
    /// key to skip. The loop:
    ///
    ///   * ignores entries above the snapshot,
    ///   * on a tombstone, records that this user key is dead and keeps skipping
    ///     any older versions of it,
    ///   * on a value, stops unless it is an older version of a skipped key.
    fn findNextUserEntry(self: *DBIter, skipping_in: bool) void {
        var skipping = skipping_in;
        while (self.iter.valid()) {
            const ikey = self.parseKey() orelse {
                self.iter.next();
                continue;
            };
            if (ikey.sequence <= self.sequence) {
                switch (ikey.type) {
                    .deletion => {
                        // Everything older for this key is hidden.
                        self.saveKey(ikey.user_key);
                        skipping = true;
                    },
                    .value => {
                        // `<= 0` because versions are ordered newest-first, so
                        // an older version of the skipped key compares <= it.
                        if (skipping and self.user_cmp.compare(ikey.user_key, self.saved_key.items) <= 0) {
                            // Hidden by an earlier entry.
                        } else {
                            self.valid = true;
                            self.saved_key.clearRetainingCapacity();
                            return;
                        }
                    },
                }
            }
            self.iter.next();
        }
        self.saved_key.clearRetainingCapacity();
        self.valid = false;
    }

    /// Scan backward to the previous visible value, caching it in `saved_key`
    /// and `saved_value`.
    ///
    /// Because the internal iterator walks backward over versions newest-first
    /// in the forward sense, going backward means visiting *oldest first* for a
    /// given user key. So we accumulate: keep the last value seen for the
    /// current key, and stop once we cross into a strictly smaller user key
    /// after having found a live value.
    fn findPrevUserEntry(self: *DBIter) void {
        // `value_type` tracks the newest version seen so far for the key we are
        // currently accumulating. It starts as `deletion` so the first entry is
        // always accepted.
        var value_type: ValueType = .deletion;
        if (self.iter.valid()) {
            while (true) {
                if (self.parseKey()) |ikey| {
                    if (ikey.sequence <= self.sequence) {
                        // If we already have a live value and the user key got
                        // smaller, we have moved past the key we want.
                        if (value_type != .deletion and
                            self.user_cmp.compare(ikey.user_key, self.saved_key.items) < 0)
                        {
                            break;
                        }
                        value_type = ikey.type;
                        if (value_type == .deletion) {
                            // Newest version for this key is a tombstone: the
                            // key is not visible. Clear the cache.
                            self.saved_key.clearRetainingCapacity();
                            self.clearSavedValue();
                        } else {
                            const raw_value = self.iter.value();
                            self.saveKey(ikey.user_key);
                            self.saved_value.clearRetainingCapacity();
                            self.saved_value.appendSlice(self.gpa, raw_value) catch {
                                self.err = error.OutOfMemory;
                            };
                        }
                    }
                }
                self.iter.prev();
                if (!self.iter.valid()) break;
            }
        }

        if (value_type == .deletion) {
            // No live value for the key we ended on: the iterator is exhausted.
            self.valid = false;
            self.saved_key.clearRetainingCapacity();
            self.clearSavedValue();
            self.direction = .forward;
        } else {
            self.valid = true;
        }
    }

    fn validFn(ctx: *anyopaque) bool {
        return cast(ctx).valid;
    }

    fn keyFn(ctx: *anyopaque) []const u8 {
        const self = cast(ctx);
        std.debug.assert(self.valid);
        return if (self.direction == .forward)
            internal_key.extractUserKey(self.iter.key())
        else
            self.saved_key.items;
    }

    fn valueFn(ctx: *anyopaque) []const u8 {
        const self = cast(ctx);
        std.debug.assert(self.valid);
        return if (self.direction == .forward) self.iter.value() else self.saved_value.items;
    }

    fn statusFn(ctx: *anyopaque) IteratorError!void {
        const self = cast(ctx);
        if (self.err) |e| return e;
        return self.iter.status();
    }

    /// Move forward to the next visible user key.
    fn nextFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        std.debug.assert(self.valid);

        if (self.direction == .reverse) {
            // Switching from reverse to forward. In reverse mode `iter` sits
            // just before this key's versions, and `saved_key` holds the key we
            // are leaving. Step into the range of this key's versions and let
            // the forward scan skip them via `saved_key`.
            self.direction = .forward;
            if (!self.iter.valid()) {
                self.iter.seekToFirst();
            } else {
                self.iter.next();
            }
            if (!self.iter.valid()) {
                self.valid = false;
                self.saved_key.clearRetainingCapacity();
                return;
            }
            // saved_key already holds the key to skip.
        } else {
            // Normal forward step: remember the key we are on so the scan skips
            // any remaining versions of it, then advance past the current entry.
            self.saveKey(internal_key.extractUserKey(self.iter.key()));
            self.iter.next();
            if (!self.iter.valid()) {
                self.valid = false;
                self.saved_key.clearRetainingCapacity();
                return;
            }
        }
        self.findNextUserEntry(true);
    }

    fn prevFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        std.debug.assert(self.valid);

        if (self.direction == .forward) {
            // Switching from forward to reverse. `iter` is sitting on the entry
            // we just returned, so walk backward until the user key changes.
            // That leaves `iter` just before all versions of the *previous*
            // key, which is the invariant reverse mode needs.
            self.saveKey(internal_key.extractUserKey(self.iter.key()));
            while (true) {
                self.iter.prev();
                if (!self.iter.valid()) {
                    self.valid = false;
                    self.saved_key.clearRetainingCapacity();
                    self.clearSavedValue();
                    return;
                }
                if (self.user_cmp.compare(internal_key.extractUserKey(self.iter.key()), self.saved_key.items) < 0) {
                    break;
                }
            }
            self.direction = .reverse;
        }
        self.findPrevUserEntry();
    }

    /// Seek to the first visible user key >= `target`.
    ///
    /// Builds an internal key `(target, snapshot, value_type_for_seek)` and
    /// seeks the internal iterator with it, then runs the forward scan to skip
    /// invisible versions and tombstones.
    fn seekFn(ctx: *anyopaque, target: []const u8) void {
        const self = cast(ctx);
        self.direction = .forward;
        self.clearSavedValue();
        self.saved_key.clearRetainingCapacity();

        // saved_key := internal_key(target, sequence, value_type_for_seek)
        self.saved_key.appendSlice(self.gpa, target) catch {
            self.err = error.OutOfMemory;
            self.valid = false;
            return;
        };
        var tag: [8]u8 = undefined;
        coding.encodeFixed64(&tag, internal_key.packSequenceAndType(self.sequence, internal_key.value_type_for_seek));
        self.saved_key.appendSlice(self.gpa, &tag) catch {
            self.err = error.OutOfMemory;
            self.valid = false;
            return;
        };

        self.iter.seek(self.saved_key.items);
        if (self.iter.valid()) {
            self.findNextUserEntry(false);
        } else {
            self.valid = false;
        }
    }

    fn seekToFirstFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.direction = .forward;
        self.clearSavedValue();
        self.iter.seekToFirst();
        if (self.iter.valid()) {
            self.findNextUserEntry(false);
        } else {
            self.valid = false;
        }
    }

    fn seekToLastFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.direction = .reverse;
        self.clearSavedValue();
        self.iter.seekToLast();
        self.findPrevUserEntry();
    }

    fn deinitFn(ctx: *anyopaque, gpa: Allocator) void {
        const self = cast(ctx);
        self.iter.deinit(gpa);
        self.saved_key.deinit(gpa);
        self.saved_value.deinit(gpa);
        gpa.destroy(self);
    }

    const vtable = Iterator.VTable{
        .valid = validFn,
        .seekToFirst = seekToFirstFn,
        .seekToLast = seekToLastFn,
        .seek = seekFn,
        .next = nextFn,
        .prev = prevFn,
        .key = keyFn,
        .value = valueFn,
        .status = statusFn,
        .deinit = deinitFn,
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const MemTable = @import("../memtable/memtable.zig").MemTable;

fn collect(it: Iterator, gpa: Allocator) !std.ArrayList([]u8) {
    var out = std.ArrayList([]u8).empty;
    it.seekToFirst();
    while (it.valid()) : (it.next()) {
        try out.append(gpa, try gpa.dupe(u8, it.key()));
    }
    return out;
}

fn freeCollected(gpa: Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |s| gpa.free(s);
    list.deinit(gpa);
}

test "db iter hides older versions and tombstones" {
    const gpa = testing.allocator;
    const icmp = internal_key.InternalKeyComparator.init(comparator.bytewise);
    const mem = try MemTable.create(gpa, icmp);
    mem.ref();
    defer mem.unref();

    try mem.add(1, .value, "a", "a1");
    try mem.add(2, .value, "a", "a2");
    try mem.add(3, .deletion, "a", "");
    try mem.add(1, .value, "b", "b1");
    try mem.add(1, .value, "c", "c1");
    try mem.add(2, .deletion, "c", "");
    try mem.add(1, .value, "d", "d1");

    // Snapshot 100 sees the newest state: a and c are deleted.
    {
        const internal = try mem.asIterator(gpa);
        const it = try create(gpa, comparator.bytewise, internal, 100, 0, null);
        defer it.deinit(gpa);

        var got = try collect(it, gpa);
        defer freeCollected(gpa, &got);
        try testing.expectEqual(@as(usize, 2), got.items.len);
        try testing.expectEqualStrings("b", got.items[0]);
        try testing.expectEqualStrings("d", got.items[1]);
    }

    // Snapshot 1 sees only the original values.
    {
        const internal = try mem.asIterator(gpa);
        const it = try create(gpa, comparator.bytewise, internal, 1, 0, null);
        defer it.deinit(gpa);

        var got = try collect(it, gpa);
        defer freeCollected(gpa, &got);
        try testing.expectEqual(@as(usize, 4), got.items.len);
        try testing.expectEqualStrings("a", got.items[0]);
        try testing.expectEqualStrings("d", got.items[3]);
    }

    // Snapshot 2 sees a2 and c deleted.
    {
        const internal = try mem.asIterator(gpa);
        const it = try create(gpa, comparator.bytewise, internal, 2, 0, null);
        defer it.deinit(gpa);

        var got = try collect(it, gpa);
        defer freeCollected(gpa, &got);
        try testing.expectEqual(@as(usize, 3), got.items.len);
        try testing.expectEqualStrings("a", got.items[0]);
        try testing.expectEqualStrings("b", got.items[1]);
        try testing.expectEqualStrings("d", got.items[2]);
    }
}

test "db iter forward and reverse agree" {
    const gpa = testing.allocator;
    const icmp = internal_key.InternalKeyComparator.init(comparator.bytewise);
    const mem = try MemTable.create(gpa, icmp);
    mem.ref();
    defer mem.unref();

    for ([_][]const u8{ "apple", "banana", "cherry", "date" }) |k| {
        try mem.add(1, .value, k, k);
    }

    const internal = try mem.asIterator(gpa);
    const it = try create(gpa, comparator.bytewise, internal, 10, 0, null);
    defer it.deinit(gpa);

    it.seekToLast();
    var reverse = std.ArrayList([]u8).empty;
    defer freeCollected(gpa, &reverse);
    while (it.valid()) : (it.prev()) {
        try reverse.append(gpa, try gpa.dupe(u8, it.key()));
    }
    try testing.expectEqual(@as(usize, 4), reverse.items.len);
    try testing.expectEqualStrings("date", reverse.items[0]);
    try testing.expectEqualStrings("apple", reverse.items[3]);
}
