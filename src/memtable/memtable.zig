//! The in-memory write buffer, ported from `db/memtable.{h,cc}`.
//!
//! Every write is appended here (and to the WAL) before it is acknowledged. A
//! memtable is an arena-backed skip list keyed by *internal keys*. Each entry is
//! one contiguous arena allocation:
//!
//!     key_size   varint32   // length of the internal key
//!     key bytes  char[]     // internal key: user_key || tag
//!     value_size varint32
//!     value      char[]
//!
//! Keeping the key and value adjacent in one buffer means a lookup that finds
//! the key has already found the value, with no second indirection.
//!
//! Memtables are reference counted. The DB holds one reference for the active
//! memtable and one for the immutable memtable being flushed; the background
//! compaction thread holds another while it builds a table.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Arena = @import("arena.zig").Arena;
const SkipList = @import("skiplist.zig").SkipList;
const coding = @import("../primitives/coding.zig");
const internal_key = @import("../db/internal_key.zig");
const iter_mod = @import("../iter/iterator.zig");

const ValueType = internal_key.ValueType;
const SequenceNumber = internal_key.SequenceNumber;

/// Decode the length-prefixed internal key at the start of a memtable entry.
fn entryInternalKey(entry: []const u8) []const u8 {
    const dec = coding.decodeVarint32(entry) orelse return &.{};
    return entry[dec.len..][0..dec.value];
}

/// The skip list comparator: compare the internal-key portions of two entries.
pub const KeyComparator = struct {
    icmp: internal_key.InternalKeyComparator,

    pub fn compare(self: KeyComparator, a: []const u8, b: []const u8) i32 {
        return self.icmp.compare(entryInternalKey(a), entryInternalKey(b));
    }
};

const Table = SkipList([]const u8, KeyComparator);

pub const MemTable = struct {
    gpa: Allocator,
    arena: Arena,
    icmp: internal_key.InternalKeyComparator,
    refs: u32,
    table: Table,

    /// Allocate and initialize a memtable. Its initial refcount is zero; the
    /// caller must `ref()` it.
    pub fn create(gpa: Allocator, icmp: internal_key.InternalKeyComparator) !*MemTable {
        const self = try gpa.create(MemTable);
        errdefer gpa.destroy(self);

        self.gpa = gpa;
        self.arena = Arena.init(gpa);
        errdefer self.arena.deinit();
        self.icmp = icmp;
        self.refs = 0;
        self.table = try Table.init(.{ .icmp = icmp }, &self.arena);
        return self;
    }

    fn destroy(self: *MemTable) void {
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn ref(self: *MemTable) void {
        self.refs += 1;
    }

    pub fn unref(self: *MemTable) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) self.destroy();
    }

    pub fn approximateMemoryUsage(self: *const MemTable) usize {
        return self.arena.memoryUsage();
    }

    /// Add a mapping at the given sequence number and type.
    pub fn add(
        self: *MemTable,
        seq: SequenceNumber,
        value_type: ValueType,
        key: []const u8,
        value: []const u8,
    ) !void {
        const internal_key_size = key.len + internal_key.tag_size;
        const val_size = value.len;
        const encoded_len = coding.varintLength(internal_key_size) + internal_key_size +
            coding.varintLength(val_size) + val_size;

        const buf = try self.arena.allocate(encoded_len);
        var p: usize = 0;
        p += coding.encodeVarint32(buf[p..], @intCast(internal_key_size));
        @memcpy(buf[p..][0..key.len], key);
        p += key.len;
        coding.encodeFixed64(buf[p..], internal_key.packSequenceAndType(seq, value_type));
        p += internal_key.tag_size;
        p += coding.encodeVarint32(buf[p..], @intCast(val_size));
        @memcpy(buf[p..][0..val_size], value);
        std.debug.assert(p + val_size == encoded_len);

        try self.table.insert(buf[0..encoded_len]);
    }

    pub const GetResult = union(enum) {
        found: []const u8,
        deleted,
        not_found,
    };

    /// Look up `key` at the snapshot encoded in the lookup key.
    pub fn get(self: *const MemTable, key: *const internal_key.LookupKey) GetResult {
        var it = self.table.iterator();
        it.seek(key.memtableKey());
        if (!it.valid()) return .not_found;

        const entry = it.key();
        const dec = coding.decodeVarint32(entry) orelse return .not_found;
        const key_length = dec.value;
        const ikey = entry[dec.len..][0..key_length];

        const user = internal_key.extractUserKey(ikey);
        if (self.icmp.user.compare(user, key.userKey()) != 0) return .not_found;

        const tag = internal_key.extractTag(ikey);
        const value_type: ValueType = @enumFromInt(@as(u8, @truncate(tag)));
        switch (value_type) {
            .value => {
                const vlen = coding.decodeVarint32(entry[dec.len + key_length ..]) orelse return .not_found;
                const vstart = dec.len + key_length + vlen.len;
                return .{ .found = entry[vstart..][0..vlen.value] };
            },
            .deletion => return .deleted,
        }
    }

    /// An iterator over the memtable's internal keys and values.
    pub const Iterator = struct {
        inner: Table.Iterator,
        scratch: ArrayList(u8),
        gpa: Allocator,

        pub fn valid(self: Iterator) bool {
            return self.inner.valid();
        }

        pub fn deinit(self: *Iterator) void {
            self.scratch.deinit(self.gpa);
        }

        pub fn key(self: Iterator) []const u8 {
            return entryInternalKey(self.inner.key());
        }

        pub fn value(self: Iterator) []const u8 {
            const entry = self.inner.key();
            const dec = coding.decodeVarint32(entry).?;
            const vstart = dec.len + dec.value;
            const vlen = coding.decodeVarint32(entry[vstart..]).?;
            return entry[vstart + vlen.len ..][0..vlen.value];
        }

        pub fn next(self: *Iterator) void {
            self.inner.next();
        }

        pub fn prev(self: *Iterator) void {
            self.inner.prev();
        }

        pub fn seekToFirst(self: *Iterator) void {
            self.inner.seekToFirst();
        }

        pub fn seekToLast(self: *Iterator) void {
            self.inner.seekToLast();
        }

        /// Seek to the first entry at or after `target` (an internal key).
        pub fn seek(self: *Iterator, target: []const u8) !void {
            self.scratch.clearRetainingCapacity();
            try coding.putVarint32(self.gpa, &self.scratch, @intCast(target.len));
            try self.scratch.appendSlice(self.gpa, target);
            self.inner.seek(self.scratch.items);
        }
    };

    pub fn iterator(self: *const MemTable, gpa: Allocator) Iterator {
        return .{
            .inner = self.table.iterator(),
            .scratch = .empty,
            .gpa = gpa,
        };
    }

    // -- Adapter to the generic iter.Iterator interface --------------------
    //
    // The DB iterator and merging iterator are written against the vtable; this
    // exposes the memtable through it.

    const AsIterator = struct {
        inner: Iterator,
    };

    pub fn asIterator(self: *const MemTable, gpa: Allocator) !iter_mod.Iterator {
        const holder = try gpa.create(AsIterator);
        holder.* = .{ .inner = self.iterator(gpa) };
        return .{ .ptr = holder, .vtable = &as_vtable };
    }

    fn asCast(ctx: *anyopaque) *AsIterator {
        return @ptrCast(@alignCast(ctx));
    }
    fn asValid(ctx: *anyopaque) bool {
        return asCast(ctx).inner.valid();
    }
    fn asKey(ctx: *anyopaque) []const u8 {
        return asCast(ctx).inner.key();
    }
    fn asValue(ctx: *anyopaque) []const u8 {
        return asCast(ctx).inner.value();
    }
    fn asNext(ctx: *anyopaque) void {
        asCast(ctx).inner.next();
    }
    fn asPrev(ctx: *anyopaque) void {
        asCast(ctx).inner.prev();
    }
    fn asSeekToFirst(ctx: *anyopaque) void {
        asCast(ctx).inner.seekToFirst();
    }
    fn asSeekToLast(ctx: *anyopaque) void {
        asCast(ctx).inner.seekToLast();
    }
    fn asSeek(ctx: *anyopaque, target: []const u8) void {
        asCast(ctx).inner.seek(target) catch {};
    }
    fn asStatus(_: *anyopaque) iter_mod.IteratorError!void {}
    fn asDeinit(ctx: *anyopaque, gpa: Allocator) void {
        const holder = asCast(ctx);
        holder.inner.deinit();
        gpa.destroy(holder);
    }

    const as_vtable = iter_mod.Iterator.VTable{
        .valid = asValid,
        .seekToFirst = asSeekToFirst,
        .seekToLast = asSeekToLast,
        .seek = asSeek,
        .next = asNext,
        .prev = asPrev,
        .key = asKey,
        .value = asValue,
        .status = asStatus,
        .deinit = asDeinit,
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const comparator = @import("../primitives/comparator.zig");

fn makeMemTable(gpa: Allocator) !*MemTable {
    const icmp = internal_key.InternalKeyComparator.init(comparator.bytewise);
    const mem = try MemTable.create(gpa, icmp);
    mem.ref();
    return mem;
}

test "add and get" {
    const mem = try makeMemTable(testing.allocator);
    defer mem.unref();

    try mem.add(1, .value, "alpha", "one");
    try mem.add(2, .value, "beta", "two");

    var lk = try internal_key.LookupKey.init(testing.allocator, "alpha", 100);
    defer lk.deinit(testing.allocator);
    try testing.expectEqualStrings("one", mem.get(&lk).found);

    var lk2 = try internal_key.LookupKey.init(testing.allocator, "beta", 100);
    defer lk2.deinit(testing.allocator);
    try testing.expectEqualStrings("two", mem.get(&lk2).found);

    var lk3 = try internal_key.LookupKey.init(testing.allocator, "missing", 100);
    defer lk3.deinit(testing.allocator);
    try testing.expect(mem.get(&lk3) == .not_found);
}

test "newest version wins and tombstones hide" {
    const mem = try makeMemTable(testing.allocator);
    defer mem.unref();

    try mem.add(1, .value, "k", "old");
    try mem.add(5, .value, "k", "new");

    // Snapshot at 3 sees the old value; snapshot at 10 sees the new one.
    var at3 = try internal_key.LookupKey.init(testing.allocator, "k", 3);
    defer at3.deinit(testing.allocator);
    try testing.expectEqualStrings("old", mem.get(&at3).found);

    var at10 = try internal_key.LookupKey.init(testing.allocator, "k", 10);
    defer at10.deinit(testing.allocator);
    try testing.expectEqualStrings("new", mem.get(&at10).found);

    // A later tombstone hides the value from a fresh snapshot.
    try mem.add(20, .deletion, "k", "");
    var at100 = try internal_key.LookupKey.init(testing.allocator, "k", 100);
    defer at100.deinit(testing.allocator);
    try testing.expect(mem.get(&at100) == .deleted);
}

test "iterator yields sorted internal keys" {
    const mem = try makeMemTable(testing.allocator);
    defer mem.unref();

    try mem.add(1, .value, "c", "3");
    try mem.add(1, .value, "a", "1");
    try mem.add(1, .value, "b", "2");

    var it = mem.iterator(testing.allocator);
    defer it.deinit();
    it.seekToFirst();
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(testing.allocator);
    while (it.valid()) : (it.next()) {
        try keys.append(testing.allocator, internal_key.extractUserKey(it.key()));
    }
    try testing.expectEqual(@as(usize, 3), keys.items.len);
    try testing.expectEqualStrings("a", keys.items[0]);
    try testing.expectEqualStrings("b", keys.items[1]);
    try testing.expectEqualStrings("c", keys.items[2]);
}
