//! Reads the blocks produced by `block_builder.zig`, from `table/block.cc`.
//!
//! `Block` owns the block bytes and validates the restart array. `Block.newIterator`
//! returns an `iter.Iterator` that decodes entries lazily and supports binary
//! search via the restart points.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const coding = @import("../primitives/coding.zig");
const comparator = @import("../primitives/comparator.zig");
const iter_mod = @import("../iter/iterator.zig");
const Iterator = iter_mod.Iterator;
const IteratorError = iter_mod.IteratorError;

pub const Block = struct {
    gpa: Allocator,
    data: []u8,
    valid: bool,
    restart_offset: usize,
    num_restarts: usize,

    /// Takes ownership of `data` (which must be heap allocated with `gpa`).
    pub fn init(gpa: Allocator, data: []u8) Block {
        var self = Block{
            .gpa = gpa,
            .data = data,
            .valid = false,
            .restart_offset = 0,
            .num_restarts = 0,
        };
        if (data.len < 4) return self;
        const n = coding.decodeFixed32(data[data.len - 4 ..]);
        const max_allowed = (data.len - 4) / 4;
        if (n > max_allowed) return self;
        self.num_restarts = n;
        self.restart_offset = data.len - (1 + @as(usize, n)) * 4;
        self.valid = true;
        return self;
    }

    pub fn deinit(self: *Block) void {
        self.gpa.free(self.data);
    }

    pub fn newIterator(self: *const Block, cmp: comparator.Comparator) IteratorError!Iterator {
        if (!self.valid) return iter_mod.errorIterator(self.gpa, error.Corruption);
        if (self.num_restarts == 0) return iter_mod.empty();
        return BlockIterator.create(self.gpa, cmp, self.data, self.restart_offset, self.num_restarts);
    }
};

const DecodedEntry = struct {
    shared: u32,
    non_shared: u32,
    value_length: u32,
    key_delta: []const u8,
};

/// Decode one entry from `p` (bounded to the data region). Returns null on
/// malformed input.
///
/// An entry is three varints followed by the key delta and the value:
///
///     varint32 shared       // how many bytes of the previous key to reuse
///     varint32 non_shared   // how many new key bytes follow
///     varint32 value_length
///     byte[non_shared] key_delta
///     byte[value_length] value
///
/// Most entries have all three lengths under 128, so the common case is just
/// three single bytes. The `(shared | non_shared | value_length) < 128` test
/// detects that without decoding, and avoids three function calls on the hot
/// path.
fn decodeEntry(p: []const u8) ?DecodedEntry {
    if (p.len < 3) return null;

    var shared: u32 = p[0];
    var non_shared: u32 = p[1];
    var value_length: u32 = p[2];
    var pos: usize = 0;

    if ((shared | non_shared | value_length) < 128) {
        pos = 3; // fast path: three one-byte varints
    } else {
        const d1 = coding.decodeVarint32(p) orelse return null;
        shared = d1.value;
        pos += d1.len;
        const d2 = coding.decodeVarint32(p[pos..]) orelse return null;
        non_shared = d2.value;
        pos += d2.len;
        const d3 = coding.decodeVarint32(p[pos..]) orelse return null;
        value_length = d3.value;
        pos += d3.len;
    }

    // Bounds check before slicing: a corrupt length must not read past the
    // block (and must not overflow the subtraction).
    if (p.len - pos < @as(usize, non_shared) + value_length) return null;
    return .{
        .shared = shared,
        .non_shared = non_shared,
        .value_length = value_length,
        .key_delta = p[pos..][0..non_shared],
    };
}

const BlockIterator = struct {
    gpa: Allocator,
    cmp: comparator.Comparator,
    data: []const u8,
    restarts: usize, // offset of restart array
    num_restarts: usize,

    // Position is tracked as a byte offset into `data`. `current >= restarts`
    // is the "invalid / past the end" marker: it means the cursor has run into
    // the restart array, which is where the entries stop.
    current: usize,
    /// Which restart block `current` falls in. Advanced lazily in
    /// `parseNextKey` so `prev()` can find the right restart point to back up to.
    restart_index: usize,
    /// The current key, reconstructed from a restart point plus deltas. Reused
    /// between entries so we do not allocate per key.
    key_buf: ArrayList(u8) = .empty,
    /// The current value, a slice directly into `data` (no copy).
    value_slice: []const u8 = &.{},
    err: ?IteratorError = null,

    fn create(
        gpa: Allocator,
        cmp: comparator.Comparator,
        data: []const u8,
        restarts: usize,
        num_restarts: usize,
    ) !Iterator {
        std.debug.assert(num_restarts > 0);
        const self = try gpa.create(BlockIterator);
        self.* = .{
            .gpa = gpa,
            .cmp = cmp,
            .data = data,
            .restarts = restarts,
            .num_restarts = num_restarts,
            .current = restarts,
            .restart_index = num_restarts,
        };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ctx: *anyopaque) *BlockIterator {
        return @ptrCast(@alignCast(ctx));
    }

    fn valid(ctx: *anyopaque) bool {
        return cast(ctx).current < cast(ctx).restarts;
    }

    fn key(ctx: *anyopaque) []const u8 {
        const self = cast(ctx);
        std.debug.assert(self.current < self.restarts);
        return self.key_buf.items;
    }

    fn value(ctx: *anyopaque) []const u8 {
        const self = cast(ctx);
        std.debug.assert(self.current < self.restarts);
        return self.value_slice;
    }

    fn statusFn(ctx: *anyopaque) IteratorError!void {
        const self = cast(ctx);
        if (self.err) |e| return e;
    }

    /// Offset in `data` just past the current value. Because `value_slice`
    /// points into `data`, pointer subtraction recovers the offset. After
    /// `seekToRestartPoint` the value is an empty slice at the entry's start, so
    /// this returns the entry's start — which is exactly what `parseNextKey`
    /// wants.
    fn nextEntryOffset(self: *const BlockIterator) usize {
        return @intFromPtr(self.value_slice.ptr) - @intFromPtr(self.data.ptr) + self.value_slice.len;
    }

    fn getRestartPoint(self: *const BlockIterator, index: usize) usize {
        std.debug.assert(index < self.num_restarts);
        return coding.decodeFixed32(self.data[self.restarts + index * 4 ..]);
    }

    /// Move to a restart point. The key is cleared; the value is set to a
    /// zero-length slice *at* that offset so the next `parseNextKey` starts
    /// there. Restart entries always store the full key (`shared == 0`).
    fn seekToRestartPoint(self: *BlockIterator, index: usize) void {
        self.key_buf.clearRetainingCapacity();
        self.restart_index = index;
        const offset = self.getRestartPoint(index);
        self.value_slice = self.data[offset..offset];
    }

    fn corruptionError(self: *BlockIterator) void {
        self.current = self.restarts;
        self.restart_index = self.num_restarts;
        self.err = error.Corruption;
        self.key_buf.clearRetainingCapacity();
        self.value_slice = &.{};
    }

    /// Decode the entry at `current` and advance the cursor over it.
    ///
    /// Because keys are prefix-compressed, the entry only stores the *delta*
    /// from the previous key. We therefore keep `key_buf` holding the previous
    /// key, truncate it to `shared` bytes, and append the delta to reconstruct
    /// the new key.
    fn parseNextKey(self: *BlockIterator) bool {
        self.current = self.nextEntryOffset();
        if (self.current >= self.restarts) {
            self.current = self.restarts;
            self.restart_index = self.num_restarts;
            return false;
        }

        const p = self.data[self.current..self.restarts];
        const dec = decodeEntry(p) orelse {
            self.corruptionError();
            return false;
        };
        if (self.key_buf.items.len < dec.shared) {
            self.corruptionError();
            return false;
        }

        self.key_buf.items.len = dec.shared; // keep the shared prefix...
        self.key_buf.appendSlice(self.gpa, dec.key_delta) catch {
            // Out of memory: mark invalid and record the error. The vtable
            // cannot return an error, so callers learn about it via `status()`.
            self.err = error.OutOfMemory;
            self.current = self.restarts;
            return false;
        };
        // The value immediately follows the key delta in `data`, so the value
        // is just a slice; no copy is made.
        self.value_slice = dec.key_delta.ptr[dec.key_delta.len..][0..dec.value_length];

        // Advance `restart_index` so it points at the restart block that
        // contains `current`. (The scan is monotone because callers move
        // forward.)
        while (self.restart_index + 1 < self.num_restarts and
            self.getRestartPoint(self.restart_index + 1) < self.current)
        {
            self.restart_index += 1;
        }
        return true;
    }

    fn seekToFirstFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.seekToRestartPoint(0);
        _ = self.parseNextKey();
    }

    fn seekToLastFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.seekToRestartPoint(self.num_restarts - 1);
        // Walk forward from the last restart point to the final entry.
        while (self.parseNextKey() and self.nextEntryOffset() < self.restarts) {}
    }

    /// Seek to the first key >= `target`.
    ///
    /// Two phases:
    ///   1. Binary-search the *restart array* for the last restart point whose
    ///      key is < `target`. Restart keys are full keys, so they can be
    ///      compared directly.
    ///   2. Linear-scan entries from there until the key is >= `target`. This
    ///      phase is short: at most `restart_interval` entries.
    ///
    /// If the iterator is already positioned and `target` is ahead of it, the
    /// binary search is narrowed to start from the current restart block.
    fn seekFn(ctx: *anyopaque, target: []const u8) void {
        const self = cast(ctx);

        var left: usize = 0;
        var right: usize = self.num_restarts - 1;
        var current_key_compare: i32 = 0;

        if (self.current < self.restarts) {
            current_key_compare = self.cmp.compare(self.key_buf.items, target);
            if (current_key_compare < 0) {
                left = self.restart_index; // target is ahead; skip earlier blocks
            } else if (current_key_compare > 0) {
                right = self.restart_index; // target is behind; ignore later blocks
            } else {
                return; // already at target
            }
        }

        while (left < right) {
            const mid = (left + right + 1) / 2;
            const region_offset = self.getRestartPoint(mid);
            const p = self.data[region_offset..self.restarts];
            const dec = decodeEntry(p) orelse {
                self.corruptionError();
                return;
            };
            // At a restart point the whole key is stored, so `shared` must be 0.
            if (dec.shared != 0) {
                self.corruptionError();
                return;
            }
            if (self.cmp.compare(dec.key_delta, target) < 0) {
                left = mid;
            } else {
                right = mid - 1;
            }
        }

        // If the answer is in the current restart block and ahead of us, we can
        // keep the reconstructed key and skip re-seeking to the block start.
        const skip_seek = left == self.restart_index and current_key_compare < 0;
        if (!skip_seek) self.seekToRestartPoint(left);

        while (true) {
            if (!self.parseNextKey()) return; // ran off the end
            if (self.cmp.compare(self.key_buf.items, target) >= 0) return;
        }
    }

    fn nextFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        std.debug.assert(self.current < self.restarts);
        _ = self.parseNextKey();
    }

    /// Step backward one entry.
    ///
    /// Blocks have no back-pointers, so `prev` is implemented by: back up to a
    /// restart point strictly before the current entry, then walk forward until
    /// the *next* entry would pass where we started.
    fn prevFn(ctx: *anyopaque) void {
        const self = cast(ctx);
        std.debug.assert(self.current < self.restarts);

        const original = self.current;
        while (self.getRestartPoint(self.restart_index) >= original) {
            if (self.restart_index == 0) {
                // No restart point before us: we were at the first entry.
                self.current = self.restarts;
                self.restart_index = self.num_restarts;
                return;
            }
            self.restart_index -= 1;
        }

        self.seekToRestartPoint(self.restart_index);
        while (self.parseNextKey() and self.nextEntryOffset() < original) {}
    }

    fn deinitFn(ctx: *anyopaque, gpa: Allocator) void {
        const self = cast(ctx);
        self.key_buf.deinit(gpa);
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
