//! The internal 32-bit hash from `util/hash.{h,cc}`, used by the bloom filter
//! and the LRU cache's handle table.
//!
//! It is a MurmurHash-like function: multiply by a large odd constant, xor the
//! high bits back down, and process four bytes at a time. It is *not*
//! cryptographic and is not meant to be.

const std = @import("std");
const coding = @import("coding.zig");

pub fn hash(data: []const u8, seed: u32) u32 {
    const m: u32 = 0xc6a4_a793;
    const r: u32 = 24;

    var h: u32 = seed ^ (@as(u32, @intCast(data.len)) *% m);
    var p = data;

    while (p.len >= 4) {
        h +%= coding.decodeFixed32(p);
        p = p[4..];
        h *%= m;
        h ^= h >> 16;
    }

    // Handle the 1-3 trailing bytes. The C++ version uses switch fallthrough;
    // this spells each case out for clarity.
    switch (p.len) {
        3 => {
            h +%= @as(u32, p[2]) << 16;
            h +%= @as(u32, p[1]) << 8;
            h +%= p[0];
            h *%= m;
            h ^= h >> r;
        },
        2 => {
            h +%= @as(u32, p[1]) << 8;
            h +%= p[0];
            h *%= m;
            h ^= h >> r;
        },
        1 => {
            h +%= p[0];
            h *%= m;
            h ^= h >> r;
        },
        else => {},
    }
    return h;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "empty input returns the seed" {
    try testing.expectEqual(@as(u32, 0xbc9f1d34), hash("", 0xbc9f1d34));
}

test "golden values from the C++ hash_test" {
    const seed: u32 = 0xbc9f1d34;
    const data1 = [_]u8{0x62};
    const data2 = [_]u8{ 0xc3, 0x97 };
    const data3 = [_]u8{ 0xe2, 0x99, 0xa5 };
    const data4 = [_]u8{ 0xe1, 0x80, 0xb9, 0x32 };
    const data5 = [_]u8{
        0x01, 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00,
        0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x18, 0x28, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };

    try testing.expectEqual(@as(u32, 0xbc9f_1d34), hash("", seed));
    try testing.expectEqual(@as(u32, 0xef13_45c4), hash(&data1, seed));
    try testing.expectEqual(@as(u32, 0x5b66_3814), hash(&data2, seed));
    try testing.expectEqual(@as(u32, 0x323c_078f), hash(&data3, seed));
    try testing.expectEqual(@as(u32, 0xed21_633a), hash(&data4, seed));
    try testing.expectEqual(@as(u32, 0xf333_dabb), hash(&data5, 0x12345678));
}
