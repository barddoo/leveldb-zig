//! Write-ahead log writer, ported from `db/log_writer.cc`.
//!
//! `addRecord` splits the payload into physical records that fit the 32 KiB
//! block size and appends them through the `WritableFile` interface. The writer
//! does not own the file; the caller closes it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const coding = @import("../primitives/coding.zig");
const crc32c = @import("../primitives/crc32c.zig");
const log_format = @import("log_format.zig");
const WritableFile = @import("../db/env.zig").WritableFile;
const Error = @import("../db/env.zig").Error;

/// Appends logical records to a log file.
///
/// A logical record may be split across several physical records so it never
/// crosses a block boundary. The writer tracks how far into the current block
/// it has written, so it can pad the trailer and start a fresh block when only
/// a few bytes remain.
pub const Writer = struct {
    /// Destination file. Not owned; the caller closes it.
    dest: WritableFile,
    /// Bytes already written into the current 32 KiB block. Always less than
    /// `block_size`; reset to 0 at each block boundary.
    block_offset: usize,

    /// Create a writer. `dest_length` is the current file size, so appending to
    /// an existing file resumes at the right block offset.
    pub fn init(dest: WritableFile, dest_length: u64) Writer {
        return .{
            .dest = dest,
            .block_offset = @intCast(dest_length % log_format.block_size),
        };
    }

    /// Durably persist everything appended so far.
    pub fn sync(self: *Writer) Error!void {
        try self.dest.sync();
    }

    /// Push buffered bytes to the OS (not necessarily durable).
    pub fn flush(self: *Writer) Error!void {
        try self.dest.flush();
    }

    /// Append one logical record, fragmenting it across blocks as needed.
    pub fn addRecord(self: *Writer, data: []const u8) Error!void {
        var ptr = data;
        var begin = true;

        // Loop at least once so an empty record still emits a FULL record.
        while (true) {
            // If fewer than a header's worth of bytes remain in the block, pad
            // the rest with zeros and move to a fresh block. A record never
            // starts inside the final 7 bytes.
            const leftover = log_format.block_size - self.block_offset;
            if (leftover < log_format.header_size) {
                if (leftover > 0) {
                    const zeros = [_]u8{0} ** log_format.header_size;
                    try self.dest.append(zeros[0..leftover]);
                }
                self.block_offset = 0;
            }

            // How much of the record fits after this block's header.
            const avail = log_format.block_size - self.block_offset - log_format.header_size;
            const fragment_length = @min(ptr.len, avail);
            const end = ptr.len == fragment_length;

            // FIRST/MIDDLE/LAST/FULL is determined by whether this fragment is
            // the start and/or end of the logical record.
            const record_type: log_format.RecordType = if (begin and end)
                .full
            else if (begin)
                .first
            else if (end)
                .last
            else
                .middle;

            try self.emitPhysicalRecord(record_type, ptr[0..fragment_length]);
            ptr = ptr[fragment_length..];
            begin = false;

            if (ptr.len == 0) break;
        }
    }

    /// Write one physical record: header (crc, length, type) then payload.
    fn emitPhysicalRecord(self: *Writer, record_type: log_format.RecordType, data: []const u8) Error!void {
        std.debug.assert(data.len <= 0xffff);
        std.debug.assert(self.block_offset + log_format.header_size + data.len <= log_format.block_size);

        var header: [log_format.header_size]u8 = undefined;
        // The checksum covers the type byte followed by the payload.
        var hasher = crc32c.Hasher.init();
        hasher.update(&[_]u8{@intFromEnum(record_type)});
        hasher.update(data);
        const crc = crc32c.mask(hasher.final());
        coding.encodeFixed32(header[0..4], crc);
        header[4] = @truncate(data.len);
        header[5] = @truncate(data.len >> 8);
        header[6] = @intFromEnum(record_type);

        try self.dest.append(&header);
        try self.dest.append(data);
        // Flush after each record so a reader always sees whole records.
        try self.dest.flush();

        self.block_offset += log_format.header_size + data.len;
    }
};
