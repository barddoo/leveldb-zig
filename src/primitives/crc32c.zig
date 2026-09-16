//! CRC-32C (Castagnoli) as used by the block and log trailers.
//!
//! This is a straightforward reflected, table-driven implementation. It is not
//! the fastest possible CRC (LevelDB uses a slicing-by-16 software path and an
//! optional hardware instruction), but it is easy to read and produces exactly
//! the same 32-bit values.
//!
//! LevelDB stores a *masked* CRC in files. Masking rotates the CRC so that a
//! CRC computed over data that accidentally contains its own checksum does not
//! trivially pass. Both halves are provided here.

const std = @import("std");

/// Reflected form of the Castagnoli polynomial (0x1EDC6F41 normal order).
const polynomial: u32 = 0x82F6_3B78;

const table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ polynomial;
            } else {
                crc >>= 1;
            }
        }
        t[i] = crc;
    }
    break :blk t;
};

/// Continue an in-progress CRC. Pass 0 to start a fresh computation.
pub fn extend(crc: u32, data: []const u8) u32 {
    var l = crc ^ 0xffff_ffff;
    for (data) |byte| {
        l = (l >> 8) ^ table[@as(u8, @truncate(l)) ^ byte];
    }
    return l ^ 0xffff_ffff;
}

/// CRC of an entire buffer.
pub fn value(data: []const u8) u32 {
    return extend(0, data);
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

test "extend is streaming-equivalent" {
    const a = "the quick brown ";
    const b = "fox jumps over the lazy dog";
    const whole = a ++ b;
    try testing.expectEqual(value(whole), extend(value(a), b));
}

test "mask/unmask round trip" {
    const crc = value("some data");
    try testing.expectEqual(crc, unmask(mask(crc)));
}
