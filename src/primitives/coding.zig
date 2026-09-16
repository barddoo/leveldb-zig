//! Endian-neutral integer coding, ported from `util/coding.{h,cc}`.
//!
//! Two families of encoding are used throughout the storage format:
//!
//!   * **Fixed** integers are little-endian. Used for tags, counts, block
//!     trailers, and the restart array at the end of a block.
//!   * **Varints** are base-128 LEB128: seven payload bits per byte, high bit
//!     set means "another byte follows". Used for lengths, offsets, and file
//!     numbers because most of those values are small.
//!
//! Everything here is deliberately byte-oriented: a value encoded on a
//! big-endian machine is identical to one encoded on a little-endian machine.
//! That property is what makes the on-disk format portable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// A decoded varint plus how many bytes it consumed.
pub const Varint32 = struct { value: u32, len: usize };
pub const Varint64 = struct { value: u64, len: usize };

// ---------------------------------------------------------------------------
// Fixed-width, little-endian
// ---------------------------------------------------------------------------

/// Write a little-endian u32 into `dst[0..4]`. REQUIRES: `dst.len >= 4`.
pub fn encodeFixed32(dst: []u8, value: u32) void {
    dst[0] = @truncate(value);
    dst[1] = @truncate(value >> 8);
    dst[2] = @truncate(value >> 16);
    dst[3] = @truncate(value >> 24);
}

/// Write a little-endian u64 into `dst[0..8]`. REQUIRES: `dst.len >= 8`.
pub fn encodeFixed64(dst: []u8, value: u64) void {
    dst[0] = @truncate(value);
    dst[1] = @truncate(value >> 8);
    dst[2] = @truncate(value >> 16);
    dst[3] = @truncate(value >> 24);
    dst[4] = @truncate(value >> 32);
    dst[5] = @truncate(value >> 40);
    dst[6] = @truncate(value >> 48);
    dst[7] = @truncate(value >> 56);
}

/// Read a little-endian u32 from `src[0..4]`. REQUIRES: `src.len >= 4`.
pub fn decodeFixed32(src: []const u8) u32 {
    return @as(u32, src[0]) |
        (@as(u32, src[1]) << 8) |
        (@as(u32, src[2]) << 16) |
        (@as(u32, src[3]) << 24);
}

/// Read a little-endian u64 from `src[0..8]`. REQUIRES: `src.len >= 8`.
pub fn decodeFixed64(src: []const u8) u64 {
    return @as(u64, src[0]) |
        (@as(u64, src[1]) << 8) |
        (@as(u64, src[2]) << 16) |
        (@as(u64, src[3]) << 24) |
        (@as(u64, src[4]) << 32) |
        (@as(u64, src[5]) << 40) |
        (@as(u64, src[6]) << 48) |
        (@as(u64, src[7]) << 56);
}

// ---------------------------------------------------------------------------
// Varints
// ---------------------------------------------------------------------------

/// Encode `value` as a varint32 into `dst`; returns the number of bytes used.
/// REQUIRES: `dst.len >= varintLength(value)` (max 5).
pub fn encodeVarint32(dst: []u8, value: u32) usize {
    var v = value;
    var i: usize = 0;
    while (v >= 0x80) {
        dst[i] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
        i += 1;
    }
    dst[i] = @truncate(v);
    return i + 1;
}

/// Encode `value` as a varint64 into `dst`; returns the number of bytes used.
/// REQUIRES: `dst.len >= varintLength(value)` (max 10).
pub fn encodeVarint64(dst: []u8, value: u64) usize {
    var v = value;
    var i: usize = 0;
    while (v >= 0x80) {
        dst[i] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
        i += 1;
    }
    dst[i] = @truncate(v);
    return i + 1;
}

/// Decode a varint32 from the start of `src`, or null if it is truncated or
/// would overflow 32 bits.
pub fn decodeVarint32(src: []const u8) ?Varint32 {
    var result: u32 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < src.len and i < 5) : (i += 1) {
        const byte = src[i];
        result |= @as(u32, byte & 0x7f) << @intCast(shift);
        if (byte < 0x80) return .{ .value = result, .len = i + 1 };
        shift += 7;
    }
    return null;
}

/// Decode a varint64 from the start of `src`, or null if truncated/overflow.
pub fn decodeVarint64(src: []const u8) ?Varint64 {
    var result: u64 = 0;
    var shift: u7 = 0;
    var i: usize = 0;
    while (i < src.len and i < 10) : (i += 1) {
        const byte = src[i];
        result |= @as(u64, byte & 0x7f) << @intCast(shift);
        if (byte < 0x80) return .{ .value = result, .len = i + 1 };
        shift += 7;
    }
    return null;
}

/// Number of bytes `value` occupies as a varint64.
pub fn varintLength(value: u64) usize {
    var v = value;
    var n: usize = 1;
    while (v >= 0x80) : (n += 1) v >>= 7;
    return n;
}

// ---------------------------------------------------------------------------
// Appending helpers (used by the block builder and version-edit encoder)
// ---------------------------------------------------------------------------

pub fn putFixed32(gpa: Allocator, list: *ArrayList(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    encodeFixed32(&buf, value);
    try list.appendSlice(gpa, &buf);
}

pub fn putFixed64(gpa: Allocator, list: *ArrayList(u8), value: u64) !void {
    var buf: [8]u8 = undefined;
    encodeFixed64(&buf, value);
    try list.appendSlice(gpa, &buf);
}

pub fn putVarint32(gpa: Allocator, list: *ArrayList(u8), value: u32) !void {
    var buf: [5]u8 = undefined;
    const n = encodeVarint32(&buf, value);
    try list.appendSlice(gpa, buf[0..n]);
}

pub fn putVarint64(gpa: Allocator, list: *ArrayList(u8), value: u64) !void {
    var buf: [10]u8 = undefined;
    const n = encodeVarint64(&buf, value);
    try list.appendSlice(gpa, buf[0..n]);
}

/// Append `len(s)` as a varint followed by the bytes of `s`.
pub fn putLengthPrefixedSlice(gpa: Allocator, list: *ArrayList(u8), s: []const u8) !void {
    try putVarint32(gpa, list, @intCast(s.len));
    try list.appendSlice(gpa, s);
}

/// Read a varint-length-prefixed slice from the front of `input`, advancing it.
pub fn getLengthPrefixedSlice(input: *[]const u8) ?[]const u8 {
    const decoded = decodeVarint32(input.*) orelse return null;
    const rest = input.*[decoded.len..];
    if (rest.len < decoded.value) return null;
    input.* = rest[decoded.value..];
    return rest[0..decoded.value];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "fixed32/fixed64 round trip" {
    var buf: [8]u8 = undefined;
    encodeFixed32(&buf, 0x1234_5678);
    try testing.expectEqual(@as(u32, 0x1234_5678), decodeFixed32(&buf));
    // Little-endian byte order is part of the format.
    try testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, buf[0..4]);

    encodeFixed64(&buf, 0x0102_0304_0506_0708);
    try testing.expectEqual(@as(u64, 0x0102_0304_0506_0708), decodeFixed64(&buf));
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 }, &buf);
}

test "varint32 round trip at boundaries" {
    const values = [_]u32{
        0,           1,           127,         128, 129, 255, 256, 16383, 16384,
        0x0fff_ffff, 0x7fff_ffff, 0xffff_ffff,
    };
    var buf: [5]u8 = undefined;
    for (values) |v| {
        const n = encodeVarint32(&buf, v);
        try testing.expectEqual(varintLength(v), n);
        const d = decodeVarint32(buf[0..n]) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(v, d.value);
        try testing.expectEqual(n, d.len);
    }
}

test "varint64 round trip at boundaries" {
    const values = [_]u64{
        0,           1,           127,                   128,                   16383,                 16384,
        0x7fff_ffff, 0xffff_ffff, 0x0000_0001_0000_0000, 0x7fff_ffff_ffff_ffff, 0xffff_ffff_ffff_ffff,
    };
    var buf: [10]u8 = undefined;
    for (values) |v| {
        const n = encodeVarint64(&buf, v);
        try testing.expectEqual(varintLength(v), n);
        const d = decodeVarint64(buf[0..n]) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(v, d.value);
        try testing.expectEqual(n, d.len);
    }
}

test "varint decode rejects truncation" {
    // 0x80 means "continue", but the buffer ends.
    try testing.expect(decodeVarint32(&.{0x80}) == null);
    try testing.expect(decodeVarint64(&.{0x80}) == null);
    // A full 5-byte varint32 whose continuation bit is still set.
    try testing.expect(decodeVarint32(&.{ 0x80, 0x80, 0x80, 0x80, 0x80 }) == null);
}

test "length-prefixed slice" {
    var list = ArrayList(u8).empty;
    defer list.deinit(testing.allocator);
    try putLengthPrefixedSlice(testing.allocator, &list, "hello");
    try putLengthPrefixedSlice(testing.allocator, &list, "");

    var input: []const u8 = list.items;
    try testing.expectEqualStrings("hello", getLengthPrefixedSlice(&input).?);
    try testing.expectEqualStrings("", getLengthPrefixedSlice(&input).?);
    try testing.expect(input.len == 0);
}

test "length-prefixed slice rejects short buffer" {
    // Says length 5, only 2 bytes follow.
    var input: []const u8 = &.{ 5, 'a', 'b' };
    try testing.expect(getLengthPrefixedSlice(&input) == null);
}
