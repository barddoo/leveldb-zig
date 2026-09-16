//! Internal key format and the internal-key comparator, ported from
//! `db/dbformat.{h,cc}`.
//!
//! # Why internal keys exist
//!
//! A user writes `("name", "alice")`, then `("name", "bob")`, then deletes
//! `"name"`. The engine cannot overwrite the first value — table files are
//! immutable and a memtable entry may be read by an iterator that is still open.
//! So instead of replacing a value, every write becomes a new *version* of the
//! same user key, tagged with a monotonically increasing sequence number:
//!
//!     internal_key := user_key || fixed64(tag)
//!     tag          := (sequence << 8) | type
//!
//! `type` is `value` (a real value) or `deletion` (a tombstone that hides older
//! versions). The user key is stored once per version, unchanged.
//!
//! # The bit layout of a tag
//!
//! A sequence number is 56 bits and the type is 8 bits, packed into one u64:
//!
//!     bit  63                   8   7      0
//!         +----------------------+----------+
//!         |      sequence        |   type   |
//!         +----------------------+----------+
//!           (56 bits, big-endian   (0=del,
//            in the numeric sense)   1=value)
//!
//! Writing the tag as little-endian bytes means a raw `memcmp` of two tags
//! compares sequence first, then type — which is exactly the order we want.
//!
//! # Why sequence numbers sort *descending*
//!
//! Internal keys order by user key ascending, then by tag descending. That means
//! for one user key the *newest* version comes first:
//!
//!     "name" seq 3 (delete)
//!     "name" seq 2 ("bob")
//!     "name" seq 1 ("alice")
//!
//! So a `Get` seeks to `("name", snapshot)` and the very first matching entry is
//! the answer; a `Get` at an old snapshot simply skips entries whose sequence is
//! above it. A tombstone is just a version that means "stop, the key is gone".
//!
//! `LookupKey` is the specialized key used by `Get`: it is a length-prefixed
//! internal key pinned to a snapshot sequence number.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const coding = @import("../primitives/coding.zig");
const comparator = @import("../primitives/comparator.zig");

/// On-disk value types. The numeric values are part of the format.
pub const ValueType = enum(u8) {
    deletion = 0,
    value = 1,
};

/// The type used when constructing a seek key: the highest-numbered type, so a
/// seek to `(user_key, sequence)` lands before any entry at that sequence.
///
/// Concretely: if we seek for `("k", 7)` we build the tag for `("k", 7, value)`.
/// Because ties in the user key are broken by descending tag, that key sorts
/// *before* an existing `("k", 7, value)` and before `("k", 7, deletion)`, and
/// *after* everything at sequence 8 or higher. The seek therefore stops at the
/// first entry that a read at snapshot 7 is allowed to see.
pub const value_type_for_seek: ValueType = .value;

/// A monotonically increasing write order. Higher means "written later".
pub const SequenceNumber = u64;

/// Sequence numbers are 56 bits; the low 8 bits of the tag hold the type.
/// `2^56 - 1` is reserved to mean "infinity" (used in seek keys and internal
/// comparators for "after every real write").
pub const max_sequence_number: SequenceNumber = (1 << 56) - 1;

/// Bytes appended to a user key to make an internal key.
pub const tag_size = 8;

/// An internal key split into its three logical parts. `user_key` borrows from
/// the buffer the key was parsed out of; it is not a copy.
pub const ParsedInternalKey = struct {
    user_key: []const u8,
    sequence: SequenceNumber,
    type: ValueType,
};

/// Pack a sequence number and type into the 8-byte tag.
/// See the bit-layout diagram at the top of the file.
pub fn packSequenceAndType(seq: SequenceNumber, value_type: ValueType) u64 {
    return (seq << 8) | @intFromEnum(value_type);
}

/// Length of an encoded internal key given the user key length.
pub fn encodingLength(user_key_len: usize) usize {
    return user_key_len + tag_size;
}

/// Append `key` (user key + tag) to `dst`.
pub fn appendInternalKey(gpa: Allocator, dst: *ArrayList(u8), key: ParsedInternalKey) !void {
    try dst.appendSlice(gpa, key.user_key);
    var tag: [8]u8 = undefined;
    coding.encodeFixed64(&tag, packSequenceAndType(key.sequence, key.type));
    try dst.appendSlice(gpa, &tag);
}

/// Parse an internal key, returning null if it is too short or the type byte is
/// invalid.
///
/// The tag is the *last* 8 bytes, so `user_key = bytes[0 .. len-8]`. There is no
/// length field: the key's own length tells us where the user key ends.
pub fn parseInternalKey(internal_key: []const u8) ?ParsedInternalKey {
    if (internal_key.len < tag_size) return null;
    const n = internal_key.len;
    const num = coding.decodeFixed64(internal_key[n - tag_size ..]);
    const type_byte: u8 = @truncate(num);
    // A tag whose low byte is neither 0 nor 1 cannot have been written by us,
    // so the entry is corrupt. (This is also the cheapest corruption check we
    // can do without knowing the schema.)
    if (type_byte > @intFromEnum(ValueType.value)) return null;
    return .{
        .user_key = internal_key[0 .. n - tag_size],
        .sequence = num >> 8,
        .type = @enumFromInt(type_byte),
    };
}

/// The user-key portion of an internal key (drops the 8-byte tag).
pub fn extractUserKey(internal_key: []const u8) []const u8 {
    std.debug.assert(internal_key.len >= tag_size);
    return internal_key[0 .. internal_key.len - tag_size];
}

/// The tag (sequence|type) of an internal key.
pub fn extractTag(internal_key: []const u8) u64 {
    std.debug.assert(internal_key.len >= tag_size);
    return coding.decodeFixed64(internal_key[internal_key.len - tag_size ..]);
}

// ---------------------------------------------------------------------------
// InternalKeyComparator
// ---------------------------------------------------------------------------

pub const InternalKeyComparator = struct {
    user: comparator.Comparator,

    pub fn init(user: comparator.Comparator) InternalKeyComparator {
        return .{ .user = user };
    }

    pub fn name(self: InternalKeyComparator) []const u8 {
        _ = self;
        return "leveldb.InternalKeyComparator";
    }

    /// Compare two internal keys: user key ascending, then tag descending.
    ///
    /// This is the single most important ordering rule in the engine. Note the
    /// inversion: for equal user keys, a *larger* tag compares *smaller*, so the
    /// newest write sorts first.
    pub fn compare(self: InternalKeyComparator, a: []const u8, b: []const u8) i32 {
        const r = self.user.compare(extractUserKey(a), extractUserKey(b));
        if (r != 0) return r;
        const anum = extractTag(a);
        const bnum = extractTag(b);
        if (anum > bnum) return -1; // newer write sorts first
        if (anum < bnum) return 1;
        return 0;
    }

    pub fn findShortestSeparator(
        self: InternalKeyComparator,
        gpa: Allocator,
        start: *ArrayList(u8),
        limit: []const u8,
    ) !void {
        const user_start = extractUserKey(start.items);
        const user_limit = extractUserKey(limit);

        var tmp = ArrayList(u8).empty;
        defer tmp.deinit(gpa);
        try tmp.appendSlice(gpa, user_start);

        try self.user.findShortestSeparator(gpa, &tmp, user_limit);

        if (tmp.items.len < user_start.len and self.user.compare(user_start, tmp.items) < 0) {
            var tag: [8]u8 = undefined;
            coding.encodeFixed64(&tag, packSequenceAndType(max_sequence_number, value_type_for_seek));
            try tmp.appendSlice(gpa, &tag);

            start.clearRetainingCapacity();
            try start.appendSlice(gpa, tmp.items);
        }
    }

    pub fn findShortSuccessor(
        self: InternalKeyComparator,
        gpa: Allocator,
        key: *ArrayList(u8),
    ) !void {
        const user_key = extractUserKey(key.items);

        var tmp = ArrayList(u8).empty;
        defer tmp.deinit(gpa);
        try tmp.appendSlice(gpa, user_key);

        try self.user.findShortSuccessor(gpa, &tmp);

        if (tmp.items.len < user_key.len and self.user.compare(user_key, tmp.items) < 0) {
            var tag: [8]u8 = undefined;
            coding.encodeFixed64(&tag, packSequenceAndType(max_sequence_number, value_type_for_seek));
            try tmp.appendSlice(gpa, &tag);

            key.clearRetainingCapacity();
            try key.appendSlice(gpa, tmp.items);
        }
    }

    // -- Adapter to the generic Comparator interface -----------------------
    //
    // Tables and merging iterators are written against `Comparator`, which is a
    // `{ptr, vtable}` pair. An InternalKeyComparator is a concrete struct, so
    // this section exposes it through that interface.
    //
    // The `ctx` helper is the standard trick for vtable callbacks in Zig: the
    // vtable receives an opaque pointer, and we cast it back to the concrete
    // type. The pointer must stay valid for as long as the returned Comparator
    // is used, so callers keep the InternalKeyComparator alive (e.g. as a field
    // of the DB or version set).

    pub fn asComparator(self: *const InternalKeyComparator) comparator.Comparator {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = comparator.Comparator.VTable{
        .compare = vtCompare,
        .name = vtName,
        .findShortestSeparator = vtFindShortestSeparator,
        .findShortSuccessor = vtFindShortSuccessor,
    };

    fn ctx(ptr: *const anyopaque) *const InternalKeyComparator {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtCompare(ptr: *const anyopaque, a: []const u8, b: []const u8) i32 {
        return ctx(ptr).compare(a, b);
    }
    fn vtName(ptr: *const anyopaque) []const u8 {
        return ctx(ptr).name();
    }
    fn vtFindShortestSeparator(
        ptr: *const anyopaque,
        gpa: Allocator,
        start: *ArrayList(u8),
        limit: []const u8,
    ) comparator.Error!void {
        return ctx(ptr).findShortestSeparator(gpa, start, limit);
    }
    fn vtFindShortSuccessor(ptr: *const anyopaque, gpa: Allocator, key: *ArrayList(u8)) comparator.Error!void {
        return ctx(ptr).findShortSuccessor(gpa, key);
    }
};

// ---------------------------------------------------------------------------
// LookupKey
// ---------------------------------------------------------------------------

/// A key for `MemTable.Get`. Encoded as:
///
///     klength  varint32        <- offset 0
///     userkey  char[klength-8] <- kstart
///     tag      fixed64         <- end - 8
///
/// The whole thing is a valid memtable key; the suffix from `kstart` is a valid
/// internal key.
///
/// Why the extra varint length prefix? The memtable's skip list is keyed by a
/// single byte slice, and its comparator needs to find the internal key inside
/// that slice. The prefix makes the internal key self-describing, exactly like
/// the entries the memtable stores (see `memtable.zig`). The skip list can then
/// compare a lookup key against a stored entry without any extra context.
pub const LookupKey = struct {
    buf: ArrayList(u8),
    /// Offset of the user key, i.e. just past the varint length.
    kstart: usize,

    /// Build a lookup key for `user_key` as of `sequence`. Using
    /// `value_type_for_seek` makes the tag the largest possible at that
    /// sequence, so the seek lands on the newest entry the snapshot may see.
    pub fn init(gpa: Allocator, user_key: []const u8, sequence: SequenceNumber) !LookupKey {
        var buf = ArrayList(u8).empty;
        errdefer buf.deinit(gpa);

        // Length of the internal key (user key + tag), as a varint.
        const internal_len = encodingLength(user_key.len);
        try coding.putVarint32(gpa, &buf, @intCast(internal_len));

        const kstart = buf.items.len;
        try buf.appendSlice(gpa, user_key);

        var tag: [8]u8 = undefined;
        coding.encodeFixed64(&tag, packSequenceAndType(sequence, value_type_for_seek));
        try buf.appendSlice(gpa, &tag);

        return .{ .buf = buf, .kstart = kstart };
    }

    pub fn deinit(self: *LookupKey, gpa: Allocator) void {
        self.buf.deinit(gpa);
    }

    /// The key to seek with in the memtable (length-prefixed internal key).
    pub fn memtableKey(self: *const LookupKey) []const u8 {
        return self.buf.items;
    }

    /// The internal key portion (drops the varint length prefix).
    pub fn internalKey(self: *const LookupKey) []const u8 {
        return self.buf.items[self.kstart..];
    }

    /// Just the user key (drops the length prefix and the tag).
    pub fn userKey(self: *const LookupKey) []const u8 {
        return self.buf.items[self.kstart .. self.buf.items.len - tag_size];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "pack and parse round trip" {
    var buf = ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);

    try appendInternalKey(testing.allocator, &buf, .{
        .user_key = "hello",
        .sequence = 12345,
        .type = .value,
    });

    const parsed = parseInternalKey(buf.items).?;
    try testing.expectEqualStrings("hello", parsed.user_key);
    try testing.expectEqual(@as(SequenceNumber, 12345), parsed.sequence);
    try testing.expectEqual(ValueType.value, parsed.type);
    try testing.expectEqualStrings("hello", extractUserKey(buf.items));
}

test "parse rejects short and bad-type keys" {
    try testing.expect(parseInternalKey("abc") == null);
    var buf: [8]u8 = undefined;
    coding.encodeFixed64(&buf, 99); // type 99 is invalid
    try testing.expect(parseInternalKey(&buf) == null);
}

test "internal comparator orders user asc, tag desc" {
    const icmp = InternalKeyComparator.init(comparator.bytewise);

    var a = ArrayList(u8).empty;
    defer a.deinit(testing.allocator);
    try appendInternalKey(testing.allocator, &a, .{ .user_key = "k", .sequence = 5, .type = .value });

    var b = ArrayList(u8).empty;
    defer b.deinit(testing.allocator);
    try appendInternalKey(testing.allocator, &b, .{ .user_key = "k", .sequence = 3, .type = .value });

    // Same user key: higher sequence sorts first.
    try testing.expect(icmp.compare(a.items, b.items) < 0);
    try testing.expect(icmp.compare(b.items, a.items) > 0);

    var c = ArrayList(u8).empty;
    defer c.deinit(testing.allocator);
    try appendInternalKey(testing.allocator, &c, .{ .user_key = "z", .sequence = 100, .type = .value });
    try testing.expect(icmp.compare(a.items, c.items) < 0);
}

test "lookup key layout" {
    var lk = try LookupKey.init(testing.allocator, "abc", 7);
    defer lk.deinit(testing.allocator);

    try testing.expectEqualStrings("abc", lk.userKey());
    try testing.expectEqual(@as(usize, 11), lk.internalKey().len); // 3 + 8
    const parsed = parseInternalKey(lk.internalKey()).?;
    try testing.expectEqual(@as(SequenceNumber, 7), parsed.sequence);
    try testing.expectEqual(ValueType.value, parsed.type);
}

test "shortest separator appends max-sequence tag" {
    const icmp = InternalKeyComparator.init(comparator.bytewise);

    var start = ArrayList(u8).empty;
    defer start.deinit(testing.allocator);
    try appendInternalKey(testing.allocator, &start, .{ .user_key = "abc1xyz", .sequence = 1, .type = .value });

    var limit = ArrayList(u8).empty;
    defer limit.deinit(testing.allocator);
    try appendInternalKey(testing.allocator, &limit, .{ .user_key = "abc9", .sequence = 1, .type = .value });

    try icmp.findShortestSeparator(testing.allocator, &start, limit.items);
    // "abc1xyz" -> "abc2", with the max-sequence seek tag.
    const parsed = parseInternalKey(start.items).?;
    try testing.expectEqualStrings("abc2", parsed.user_key);
    try testing.expectEqual(max_sequence_number, parsed.sequence);
}
