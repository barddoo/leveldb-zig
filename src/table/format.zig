//! Block handles, the table footer, and block reading, from `table/format.{h,cc}`.
//!
//! An SSTable file looks like:
//!
//!     [data block]...[data block]     each followed by a 5-byte trailer
//!     [filter block]                  optional, also trailed
//!     [metaindex block]
//!     [index block]
//!     [footer]                        fixed 48 bytes
//!
//! A `BlockHandle` points at one block: a varint64 offset and varint64 size.
//! The footer names the metaindex and index blocks and ends with a magic number.
//!
//! The per-block trailer is `compression_type (1 byte) || masked_crc32c (4 bytes)`
//! where the CRC covers the block bytes *and* the type byte.
//!
//! Compression extension point: LevelDB's type byte selects Snappy (1) or Zstd
//! (2) and `readBlock` decompresses accordingly. This project stores everything
//! uncompressed (type 0), so the decompress branch is where that logic would go.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const coding = @import("../primitives/coding.zig");
const crc32c = @import("../primitives/crc32c.zig");
const env = @import("../db/env.zig");
const Error = env.Error;

/// Magic number at the end of every table. Chosen as the leading 64 bits of a
/// hash of the LevelDB URL; any wrong value means "this is not a table".
pub const kTableMagicNumber: u64 = 0xdb47_7524_8b80_fb57;
/// Bytes after each block: one compression-type byte plus a 4-byte CRC.
pub const kBlockTrailerSize = 5;

/// A pointer to a block within a table file: where it starts and how long it is
/// (excluding the 5-byte trailer). Encoded as two varint64s.
pub const BlockHandle = struct {
    /// Byte offset of the block from the start of the file.
    offset: u64 = 0,
    /// Number of stored block bytes, not counting the trailer.
    size: u64 = 0,

    /// Worst-case encoded size: two varint64s.
    pub const max_encoded_length = 20; // two varint64s

    /// Append `offset` then `size` as varints.
    pub fn encodeTo(self: BlockHandle, gpa: Allocator, list: *ArrayList(u8)) !void {
        try coding.putVarint64(gpa, list, self.offset);
        try coding.putVarint64(gpa, list, self.size);
    }

    /// Decode a handle from the front of `input`, advancing it. Corruption if
    /// either varint is malformed.
    pub fn decodeFrom(input: *[]const u8) Error!BlockHandle {
        const o = coding.decodeVarint64(input.*) orelse return error.Corruption;
        input.* = input.*[o.len..];
        const s = coding.decodeVarint64(input.*) orelse return error.Corruption;
        input.* = input.*[s.len..];
        return .{ .offset = o.value, .size = s.value };
    }
};

/// The fixed 48-byte trailer at the end of every table. It names the metaindex
/// and index blocks and ends with a magic number, so a table can be recognized
/// and opened without reading anything else.
pub const Footer = struct {
    /// Handle of the metaindex block (maps "filter.<name>" to the filter block).
    metaindex_handle: BlockHandle = .{},
    /// Handle of the index block (maps separator keys to data blocks).
    index_handle: BlockHandle = .{},

    /// Always exactly this many bytes: two handles plus padding and the magic.
    pub const encoded_length = 2 * BlockHandle.max_encoded_length + 8; // 48

    /// Append the footer. The handles are followed by zero padding so the magic
    /// always lands at a fixed offset from the end.
    pub fn encodeTo(self: Footer, gpa: Allocator, list: *ArrayList(u8)) !void {
        const start = list.items.len;
        try self.metaindex_handle.encodeTo(gpa, list);
        try self.index_handle.encodeTo(gpa, list);
        // Zero-pad to the fixed handle region.
        while (list.items.len - start < 2 * BlockHandle.max_encoded_length) {
            try list.append(gpa, 0);
        }
        try coding.putFixed32(gpa, list, @truncate(kTableMagicNumber));
        try coding.putFixed32(gpa, list, @truncate(kTableMagicNumber >> 32));
        std.debug.assert(list.items.len - start == encoded_length);
    }

    /// Decode a footer from the front of `input`, advancing it past the footer.
    /// Verifies the magic number.
    pub fn decodeFrom(input: *[]const u8) Error!Footer {
        if (input.*.len < encoded_length) return error.Corruption;
        const data = input.*;
        const magic = coding.decodeFixed64(data[encoded_length - 8 ..][0..8]);
        if (magic != kTableMagicNumber) return error.Corruption;

        // The handles live in the first 40 bytes; padding fills the rest.
        var p: []const u8 = data[0 .. encoded_length - 8];
        const meta = try BlockHandle.decodeFrom(&p);
        const index = try BlockHandle.decodeFrom(&p);
        input.* = data[encoded_length..];
        return .{ .metaindex_handle = meta, .index_handle = index };
    }
};

/// The bytes of a block, owned by the caller (free with the same allocator).
pub const BlockContents = struct {
    data: []u8,
};

/// Options affecting a block read.
pub const ReadOptions = struct {
    /// Verify the block's CRC. Slower, but catches corruption early.
    verify_checksums: bool = false,
    /// Whether a block read should populate the block cache (unused until a
    /// cache exists).
    fill_cache: bool = true,
};

/// Read, verify, and (eventually) decompress the block at `handle`.
pub fn readBlock(
    gpa: Allocator,
    file: env.RandomAccessFile,
    options: ReadOptions,
    handle: BlockHandle,
) Error!BlockContents {
    const n: usize = @intCast(handle.size);
    const buf = try gpa.alloc(u8, n + kBlockTrailerSize);
    errdefer gpa.free(buf);

    const contents = try file.read(handle.offset, n + kBlockTrailerSize, buf);
    if (contents.len != n + kBlockTrailerSize) return error.Corruption;

    if (options.verify_checksums) {
        const expected = crc32c.unmask(coding.decodeFixed32(buf[n + 1 ..][0..4]));
        const actual = crc32c.value(buf[0 .. n + 1]); // data + type byte
        if (actual != expected) return error.Corruption;
    }

    const compression_type = buf[n];
    switch (compression_type) {
        0 => {
            // Uncompressed: shrink the allocation to just the block data.
            const data = try gpa.realloc(buf, n);
            return .{ .data = data };
        },
        // Compression extension point: decompress Snappy (1) / Zstd (2) here,
        // writing the uncompressed bytes into a new buffer and freeing `buf`.
        else => return error.NotSupported,
    }
}
