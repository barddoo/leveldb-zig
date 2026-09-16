//! Write-ahead log reader, ported from `db/log_reader.cc`.
//!
//! `readRecord` reassembles logical records from physical fragments, verifying
//! checksums when requested and reporting corruption through a `Reporter`. It
//! returns `null` at end of file.
//!
//! The returned slice is only valid until the next call: a FULL record points
//! into the reader's block buffer, and a fragmented record points into the
//! reader's scratch buffer. Callers parse or copy it immediately.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const coding = @import("../primitives/coding.zig");
const crc32c = @import("../primitives/crc32c.zig");
const log_format = @import("log_format.zig");
const env = @import("../db/env.zig");
const SequentialFile = env.SequentialFile;
const Error = env.Error;

/// Receives corruption reports. Optional; pass null to ignore.
pub const Reporter = struct {
    ptr: *anyopaque,
    corruption_fn: *const fn (ctx: *anyopaque, bytes: usize, reason: []const u8) void,

    pub fn corruption(self: Reporter, bytes: usize, reason: []const u8) void {
        self.corruption_fn(self.ptr, bytes, reason);
    }
};

const Physical = union(enum) {
    full: []const u8,
    first: []const u8,
    middle: []const u8,
    last: []const u8,
    eof,
    bad,
};

pub const Reader = struct {
    gpa: Allocator,
    file: SequentialFile,
    reporter: ?Reporter,
    verify_checksums: bool,
    backing: []u8,
    buffer: []const u8 = &.{},
    scratch: ArrayList(u8) = .empty,
    eof: bool = false,
    last_record_offset: u64 = 0,
    end_of_buffer_offset: u64 = 0,
    initial_offset: u64 = 0,
    resyncing: bool = false,

    pub fn init(
        gpa: Allocator,
        file: SequentialFile,
        reporter: ?Reporter,
        verify_checksums: bool,
        initial_offset: u64,
    ) !Reader {
        const backing = try gpa.alloc(u8, log_format.block_size);
        return .{
            .gpa = gpa,
            .file = file,
            .reporter = reporter,
            .verify_checksums = verify_checksums,
            .backing = backing,
            .initial_offset = initial_offset,
            .resyncing = initial_offset > 0,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.gpa.free(self.backing);
        self.scratch.deinit(self.gpa);
    }

    pub fn lastRecordOffset(self: *const Reader) u64 {
        return self.last_record_offset;
    }

    /// Read the next logical record, or null at end of file.
    pub fn readRecord(self: *Reader) Error!?[]const u8 {
        if (self.last_record_offset < self.initial_offset) {
            if (!try self.skipToInitialBlock()) return null;
        }

        self.scratch.clearRetainingCapacity();
        var in_fragmented_record = false;
        var prospective_record_offset: u64 = 0;

        while (true) {
            const physical = try self.readPhysicalRecord();

            const fragment: []const u8 = switch (physical) {
                .full => |d| d,
                .first => |d| d,
                .middle => |d| d,
                .last => |d| d,
                .eof, .bad => &.{},
            };

            const consumed = self.buffer.len + log_format.header_size + fragment.len;
            const physical_record_offset = if (self.end_of_buffer_offset >= consumed)
                self.end_of_buffer_offset - consumed
            else
                0;

            if (self.resyncing) {
                switch (physical) {
                    .middle => continue,
                    .last => {
                        self.resyncing = false;
                        continue;
                    },
                    else => self.resyncing = false,
                }
            }

            switch (physical) {
                .full => |d| {
                    if (in_fragmented_record and self.scratch.items.len != 0) {
                        self.reportCorruption(self.scratch.items.len, "partial record without end(1)");
                    }
                    prospective_record_offset = physical_record_offset;
                    self.scratch.clearRetainingCapacity();
                    self.last_record_offset = prospective_record_offset;
                    return d;
                },
                .first => |d| {
                    if (in_fragmented_record and self.scratch.items.len != 0) {
                        self.reportCorruption(self.scratch.items.len, "partial record without end(2)");
                    }
                    prospective_record_offset = physical_record_offset;
                    self.scratch.clearRetainingCapacity();
                    try self.scratch.appendSlice(self.gpa, d);
                    in_fragmented_record = true;
                },
                .middle => |d| {
                    if (!in_fragmented_record) {
                        self.reportCorruption(d.len, "missing start of fragmented record(1)");
                    } else {
                        try self.scratch.appendSlice(self.gpa, d);
                    }
                },
                .last => |d| {
                    if (!in_fragmented_record) {
                        self.reportCorruption(d.len, "missing start of fragmented record(2)");
                    } else {
                        try self.scratch.appendSlice(self.gpa, d);
                        self.last_record_offset = prospective_record_offset;
                        return self.scratch.items;
                    }
                },
                .eof => {
                    // A writer that died mid-record leaves a partial logical
                    // record; drop it silently rather than call it corruption.
                    if (in_fragmented_record) self.scratch.clearRetainingCapacity();
                    return null;
                },
                .bad => {
                    if (in_fragmented_record) {
                        self.reportCorruption(self.scratch.items.len, "error in middle of record");
                        in_fragmented_record = false;
                        self.scratch.clearRetainingCapacity();
                    }
                },
            }
        }
    }

    fn skipToInitialBlock(self: *Reader) Error!bool {
        const offset_in_block: usize = @intCast(self.initial_offset % log_format.block_size);
        var block_start: u64 = self.initial_offset - offset_in_block;

        // Do not start inside a block trailer.
        if (offset_in_block > log_format.block_size - 6) {
            block_start += log_format.block_size;
        }
        self.end_of_buffer_offset = block_start;

        if (block_start > 0) {
            self.file.skip(block_start) catch |err| {
                self.reportDrop(block_start, "initial offset skip failed");
                return err;
            };
        }
        return true;
    }

    fn readPhysicalRecord(self: *Reader) Error!Physical {
        while (true) {
            if (self.buffer.len < log_format.header_size) {
                if (!self.eof) {
                    self.buffer = &.{};
                    const chunk = self.file.read(log_format.block_size, self.backing) catch |err| {
                        self.buffer = &.{};
                        self.reportDrop(log_format.block_size, "read error");
                        self.eof = true;
                        return err;
                    };
                    self.end_of_buffer_offset += chunk.len;
                    self.buffer = chunk;
                    if (chunk.len < log_format.block_size) self.eof = true;
                    continue;
                } else {
                    self.buffer = &.{};
                    return .eof;
                }
            }

            const header = self.buffer;
            const length: u32 = @as(u32, header[4]) | (@as(u32, header[5]) << 8);
            const record_type = header[6];

            if (log_format.header_size + @as(usize, length) > self.buffer.len) {
                const drop_size = self.buffer.len;
                self.buffer = &.{};
                if (!self.eof) {
                    self.reportCorruption(drop_size, "bad record length");
                    return .bad;
                }
                // Writer died mid-record; treat as clean EOF.
                return .eof;
            }

            if (record_type == @intFromEnum(log_format.RecordType.zero) and length == 0) {
                // Preallocated zero region; skip without reporting.
                self.buffer = self.buffer[log_format.header_size..];
                return .bad;
            }

            if (self.verify_checksums) {
                const expected = crc32c.unmask(coding.decodeFixed32(header[0..4]));
                const actual = crc32c.value(header[6..][0 .. 1 + @as(usize, length)]);
                if (actual != expected) {
                    const drop_size = self.buffer.len;
                    self.buffer = &.{};
                    self.reportCorruption(drop_size, "checksum mismatch");
                    return .bad;
                }
            }

            self.buffer = self.buffer[log_format.header_size + length ..];

            // Skip physical records that started before the initial offset.
            const consumed = self.end_of_buffer_offset - self.buffer.len -
                log_format.header_size - length;
            if (consumed < self.initial_offset) return .bad;

            const data = header[log_format.header_size..][0..length];
            return switch (record_type) {
                @intFromEnum(log_format.RecordType.full) => .{ .full = data },
                @intFromEnum(log_format.RecordType.first) => .{ .first = data },
                @intFromEnum(log_format.RecordType.middle) => .{ .middle = data },
                @intFromEnum(log_format.RecordType.last) => .{ .last = data },
                else => .bad,
            };
        }
    }

    fn reportCorruption(self: *Reader, bytes: usize, reason: []const u8) void {
        self.reportDrop(bytes, reason);
    }

    fn reportDrop(self: *Reader, bytes: usize, reason: []const u8) void {
        const r = self.reporter orelse return;
        if (self.end_of_buffer_offset >= self.buffer.len + bytes and
            self.end_of_buffer_offset - self.buffer.len - bytes >= self.initial_offset)
        {
            r.corruption(bytes, reason);
        }
    }
};
