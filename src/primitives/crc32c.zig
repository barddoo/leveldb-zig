//! CRC-32C (Castagnoli), used by block and log trailers.
//!
//! The algorithm comes from the standard library: `std.hash.crc.Crc32Iscsi` is
//! CRC-32C (polynomial 0x1edc6f41, reflected input and output, initial/final
//! 0xffffffff). We only add LevelDB's *masking* on top, which rotates the CRC
//! before it is stored so that a CRC computed over data that accidentally
//! contains its own checksum does not trivially pass.

const std = @import("std");

/// Streaming CRC-32C hasher. Use `Hasher.init()`, then `update` with each chunk
/// (including the type byte), then `final()`. This is the documented public API
/// of `std.hash.crc`, so it is stable across std copies.
pub const Hasher = std.hash.crc.Crc32Iscsi;

/// CRC of an entire buffer.
pub fn value(data: []const u8) u32 {
    return Hasher.hash(data);
}

const mask_delta: u32 = 0xa282_ead8;

/// Rotate right 15 and add a constant. Stored in file trailers.
pub fn mask(crc: u32) u32 {
    return std.math.rotl(u32, crc, 17) +% mask_delta;
}

/// Inverse of `mask`.
pub fn unmask(masked: u32) u32 {
    return std.math.rotl(u32, masked -% mask_delta, 15);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "standard vector" {
    // The canonical CRC-32C check value for the ASCII string "123456789".
    try testing.expectEqual(@as(u32, 0xE306_9283), value("123456789"));
    try testing.expectEqual(@as(u32, 0), value(""));
}

test "rfc3720 section B.4" {
    var buf: [32]u8 = undefined;

    @memset(&buf, 0);
    try testing.expectEqual(@as(u32, 0x8a91_36aa), value(&buf));

    @memset(&buf, 0xff);
    try testing.expectEqual(@as(u32, 0x62a8_ab43), value(&buf));

    for (0..32) |i| buf[i] = @intCast(i);
    try testing.expectEqual(@as(u32, 0x46dd_794e), value(&buf));

    for (0..32) |i| buf[i] = @intCast(31 - i);
    try testing.expectEqual(@as(u32, 0x113f_db5c), value(&buf));
}

test "streaming equals one-shot" {
    const a = "the quick brown ";
    const b = "fox jumps over the lazy dog";

    var hasher = Hasher.init();
    hasher.update(a);
    hasher.update(b);

    try testing.expectEqual(value(a ++ b), hasher.final());
}

test "mask/unmask round trip" {
    const crc = value("some data");
    try testing.expectEqual(crc, unmask(mask(crc)));
}
