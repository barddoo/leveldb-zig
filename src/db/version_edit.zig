//! Version edits, from `db/version_edit.{h,cc}`.
//!
//! A `VersionEdit` is a delta describing how the set of live table files
//! changes: files added, files removed, and the current log/sequence numbers.
//! The MANIFEST is simply a log of these deltas; replaying them reconstructs the
//! current version.
//!
//! Wire format: a sequence of `(varint32 tag, payload)` records. Tag values are
//! part of the on-disk format.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const coding = @import("../primitives/coding.zig");
const internal_key = @import("../db/internal_key.zig");
const SequenceNumber = internal_key.SequenceNumber;

// Record tags. These numbers are written to the MANIFEST, so they are part of
// the on-disk format and must never change.
/// Comparator name (length-prefixed string).
pub const kComparator: u32 = 1;
/// Current log file number (varint64).
pub const kLogNumber: u32 = 2;
/// Next file number to allocate (varint64).
pub const kNextFileNumber: u32 = 3;
/// Last used sequence number (varint64).
pub const kLastSequence: u32 = 4;
/// A level's compaction pointer: level (varint32) + internal key.
pub const kCompactPointer: u32 = 5;
/// A deleted file: level (varint32) + file number (varint64).
pub const kDeletedFile: u32 = 6;
/// A new file: level, number, size, smallest key, largest key.
pub const kNewFile: u32 = 7;
/// Previous log file number, kept for old manifests (varint64).
pub const kPrevLogNumber: u32 = 9;

/// Metadata for one table file. Internal keys are owned byte buffers.
pub const FileMetaData = struct {
    /// Reference count. Each `Version` that lists this file holds one.
    refs: u32 = 0,
    /// Seek budget; when it hits zero a seek-triggered compaction is scheduled.
    allowed_seeks: u32 = 1 << 30,
    /// File number; also the `.sst` name.
    number: u64 = 0,
    /// Size in bytes, as recorded when the table was written.
    file_size: u64 = 0,
    /// Smallest internal key in the file (inclusive).
    smallest: ArrayList(u8) = .empty,
    /// Largest internal key in the file (inclusive).
    largest: ArrayList(u8) = .empty,

    /// Free the key buffers. Does not free the struct itself.
    pub fn deinit(self: *FileMetaData, gpa: Allocator) void {
        self.smallest.deinit(gpa);
        self.largest.deinit(gpa);
    }

    /// Deep-copy the metadata, including its key buffers.
    pub fn clone(self: *const FileMetaData, gpa: Allocator) !FileMetaData {
        var m = FileMetaData{
            .refs = self.refs,
            .allowed_seeks = self.allowed_seeks,
            .number = self.number,
            .file_size = self.file_size,
        };
        errdefer m.deinit(gpa);
        try m.smallest.appendSlice(gpa, self.smallest.items);
        try m.largest.appendSlice(gpa, self.largest.items);
        return m;
    }
};

/// A level's "resume point": the next compaction at `level` starts after `key`.
pub const CompactPointer = struct { level: u32, key: ArrayList(u8) = .empty };
/// A file removed from `level`.
pub const DeletedFile = struct { level: u32, number: u64 };
/// A file added at `level`, with its metadata.
pub const NewFile = struct { level: u32, meta: FileMetaData };

/// A delta to the set of live files and the DB's bookkeeping.
///
/// A `VersionEdit` is applied on top of the current `Version` to produce a new
/// one. The MANIFEST is a log of these; recovery replays them in order.
///
/// Scalar fields (log number, sequence, ...) carry `has_*` flags because "not
/// present" and "present and zero" are different: a compaction edit does not
/// mention the sequence number, while the first edit after a fresh open does.
pub const VersionEdit = struct {
    /// Allocator for every buffer in the edit.
    gpa: Allocator,

    /// Comparator name, if this edit sets it.
    comparator: ArrayList(u8) = .empty,
    /// Log file number, if set.
    log_number: u64 = 0,
    /// Previous log file number, if set.
    prev_log_number: u64 = 0,
    /// Next file number, if set.
    next_file_number: u64 = 0,
    /// Last sequence number, if set.
    last_sequence: SequenceNumber = 0,

    /// Presence flags for the scalar fields above.
    has_comparator: bool = false,
    has_log_number: bool = false,
    has_prev_log_number: bool = false,
    has_next_file_number: bool = false,
    has_last_sequence: bool = false,

    /// Updated compaction resume points.
    compact_pointers: ArrayList(CompactPointer) = .empty,
    /// Files removed.
    deleted_files: ArrayList(DeletedFile) = .empty,
    /// Files added.
    new_files: ArrayList(NewFile) = .empty,

    /// Create an empty edit.
    pub fn init(gpa: Allocator) VersionEdit {
        return .{ .gpa = gpa };
    }

    /// Free every owned buffer.
    pub fn deinit(self: *VersionEdit) void {
        const gpa = self.gpa;
        self.comparator.deinit(gpa);
        for (self.compact_pointers.items) |*cp| cp.key.deinit(gpa);
        self.compact_pointers.deinit(gpa);
        self.deleted_files.deinit(gpa);
        for (self.new_files.items) |*nf| nf.meta.deinit(gpa);
        self.new_files.deinit(gpa);
    }

    pub fn clear(self: *VersionEdit) void {
        const gpa = self.gpa;
        self.comparator.clearRetainingCapacity();
        for (self.compact_pointers.items) |*cp| cp.key.deinit(gpa);
        self.compact_pointers.clearRetainingCapacity();
        self.deleted_files.clearRetainingCapacity();
        for (self.new_files.items) |*nf| nf.meta.deinit(gpa);
        self.new_files.clearRetainingCapacity();
        self.has_comparator = false;
        self.has_log_number = false;
        self.has_prev_log_number = false;
        self.has_next_file_number = false;
        self.has_last_sequence = false;
    }

    pub fn setComparatorName(self: *VersionEdit, name: []const u8) !void {
        self.comparator.clearRetainingCapacity();
        try self.comparator.appendSlice(self.gpa, name);
        self.has_comparator = true;
    }

    pub fn setLogNumber(self: *VersionEdit, n: u64) void {
        self.has_log_number = true;
        self.log_number = n;
    }
    pub fn setPrevLogNumber(self: *VersionEdit, n: u64) void {
        self.has_prev_log_number = true;
        self.prev_log_number = n;
    }
    pub fn setNextFile(self: *VersionEdit, n: u64) void {
        self.has_next_file_number = true;
        self.next_file_number = n;
    }
    pub fn setLastSequence(self: *VersionEdit, s: SequenceNumber) void {
        self.has_last_sequence = true;
        self.last_sequence = s;
    }

    pub fn setCompactPointer(self: *VersionEdit, level: u32, key: []const u8) !void {
        var cp = CompactPointer{ .level = level };
        try cp.key.appendSlice(self.gpa, key);
        try self.compact_pointers.append(self.gpa, cp);
    }

    pub fn addFile(
        self: *VersionEdit,
        level: u32,
        number: u64,
        file_size: u64,
        smallest: []const u8,
        largest: []const u8,
    ) !void {
        var meta = FileMetaData{ .number = number, .file_size = file_size };
        errdefer meta.deinit(self.gpa);
        try meta.smallest.appendSlice(self.gpa, smallest);
        try meta.largest.appendSlice(self.gpa, largest);
        try self.new_files.append(self.gpa, .{ .level = level, .meta = meta });
    }

    pub fn removeFile(self: *VersionEdit, level: u32, number: u64) !void {
        try self.deleted_files.append(self.gpa, .{ .level = level, .number = number });
    }

    pub fn encodeTo(self: *const VersionEdit, dst: *ArrayList(u8)) !void {
        const gpa = self.gpa;
        if (self.has_comparator) {
            try coding.putVarint32(gpa, dst, kComparator);
            try coding.putLengthPrefixedSlice(gpa, dst, self.comparator.items);
        }
        if (self.has_log_number) {
            try coding.putVarint32(gpa, dst, kLogNumber);
            try coding.putVarint64(gpa, dst, self.log_number);
        }
        if (self.has_prev_log_number) {
            try coding.putVarint32(gpa, dst, kPrevLogNumber);
            try coding.putVarint64(gpa, dst, self.prev_log_number);
        }
        if (self.has_next_file_number) {
            try coding.putVarint32(gpa, dst, kNextFileNumber);
            try coding.putVarint64(gpa, dst, self.next_file_number);
        }
        if (self.has_last_sequence) {
            try coding.putVarint32(gpa, dst, kLastSequence);
            try coding.putVarint64(gpa, dst, self.last_sequence);
        }
        for (self.compact_pointers.items) |cp| {
            try coding.putVarint32(gpa, dst, kCompactPointer);
            try coding.putVarint32(gpa, dst, cp.level);
            try coding.putLengthPrefixedSlice(gpa, dst, cp.key.items);
        }
        for (self.deleted_files.items) |df| {
            try coding.putVarint32(gpa, dst, kDeletedFile);
            try coding.putVarint32(gpa, dst, df.level);
            try coding.putVarint64(gpa, dst, df.number);
        }
        for (self.new_files.items) |nf| {
            try coding.putVarint32(gpa, dst, kNewFile);
            try coding.putVarint32(gpa, dst, nf.level);
            try coding.putVarint64(gpa, dst, nf.meta.number);
            try coding.putVarint64(gpa, dst, nf.meta.file_size);
            try coding.putLengthPrefixedSlice(gpa, dst, nf.meta.smallest.items);
            try coding.putLengthPrefixedSlice(gpa, dst, nf.meta.largest.items);
        }
    }

    /// Decode `src`, replacing any prior contents.
    pub fn decodeFrom(self: *VersionEdit, src: []const u8) !void {
        self.clear();
        var input = src;

        while (input.len > 0) {
            const tag = coding.decodeVarint32(input) orelse return error.Corruption;
            input = input[tag.len..];
            switch (tag.value) {
                kComparator => {
                    const s = coding.getLengthPrefixedSlice(&input) orelse return error.Corruption;
                    try self.setComparatorName(s);
                },
                kLogNumber => {
                    const d = coding.decodeVarint64(input) orelse return error.Corruption;
                    input = input[d.len..];
                    self.setLogNumber(d.value);
                },
                kPrevLogNumber => {
                    const d = coding.decodeVarint64(input) orelse return error.Corruption;
                    input = input[d.len..];
                    self.setPrevLogNumber(d.value);
                },
                kNextFileNumber => {
                    const d = coding.decodeVarint64(input) orelse return error.Corruption;
                    input = input[d.len..];
                    self.setNextFile(d.value);
                },
                kLastSequence => {
                    const d = coding.decodeVarint64(input) orelse return error.Corruption;
                    input = input[d.len..];
                    self.setLastSequence(d.value);
                },
                kCompactPointer => {
                    const lvl = coding.decodeVarint32(input) orelse return error.Corruption;
                    input = input[lvl.len..];
                    const key = coding.getLengthPrefixedSlice(&input) orelse return error.Corruption;
                    if (lvl.value >= 7) return error.Corruption;
                    try self.setCompactPointer(lvl.value, key);
                },
                kDeletedFile => {
                    const lvl = coding.decodeVarint32(input) orelse return error.Corruption;
                    input = input[lvl.len..];
                    const num = coding.decodeVarint64(input) orelse return error.Corruption;
                    input = input[num.len..];
                    if (lvl.value >= 7) return error.Corruption;
                    try self.removeFile(lvl.value, num.value);
                },
                kNewFile => {
                    const lvl = coding.decodeVarint32(input) orelse return error.Corruption;
                    input = input[lvl.len..];
                    const num = coding.decodeVarint64(input) orelse return error.Corruption;
                    input = input[num.len..];
                    const size = coding.decodeVarint64(input) orelse return error.Corruption;
                    input = input[size.len..];
                    const smallest = coding.getLengthPrefixedSlice(&input) orelse return error.Corruption;
                    const largest = coding.getLengthPrefixedSlice(&input) orelse return error.Corruption;
                    if (lvl.value >= 7) return error.Corruption;
                    try self.addFile(lvl.value, num.value, size.value, smallest, largest);
                },
                else => return error.Corruption,
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "version edit round trip" {
    const gpa = testing.allocator;

    var edit = VersionEdit.init(gpa);
    defer edit.deinit();

    try edit.setComparatorName("leveldb.BytewiseComparator");
    edit.setLogNumber(5);
    edit.setPrevLogNumber(0);
    edit.setNextFile(12);
    edit.setLastSequence(99);
    try edit.setCompactPointer(1, "some-internal-key");
    try edit.removeFile(2, 7);
    try edit.addFile(1, 8, 4096, "small-key", "large-key");

    var encoded = ArrayList(u8).empty;
    defer encoded.deinit(gpa);
    try edit.encodeTo(&encoded);

    var decoded = VersionEdit.init(gpa);
    defer decoded.deinit();
    try decoded.decodeFrom(encoded.items);

    try testing.expect(decoded.has_comparator);
    try testing.expectEqualStrings("leveldb.BytewiseComparator", decoded.comparator.items);
    try testing.expectEqual(@as(u64, 5), decoded.log_number);
    try testing.expectEqual(@as(u64, 12), decoded.next_file_number);
    try testing.expectEqual(@as(SequenceNumber, 99), decoded.last_sequence);
    try testing.expectEqual(@as(usize, 1), decoded.compact_pointers.items.len);
    try testing.expectEqualStrings("some-internal-key", decoded.compact_pointers.items[0].key.items);
    try testing.expectEqual(@as(usize, 1), decoded.deleted_files.items.len);
    try testing.expectEqual(@as(u64, 7), decoded.deleted_files.items[0].number);
    try testing.expectEqual(@as(usize, 1), decoded.new_files.items.len);
    try testing.expectEqualStrings("small-key", decoded.new_files.items[0].meta.smallest.items);
    try testing.expectEqualStrings("large-key", decoded.new_files.items[0].meta.largest.items);
}

test "decode rejects unknown tag" {
    const gpa = testing.allocator;
    var edit = VersionEdit.init(gpa);
    defer edit.deinit();

    // Tag 200 is not defined.
    var bad = ArrayList(u8).empty;
    defer bad.deinit(gpa);
    try coding.putVarint32(gpa, &bad, 200);
    try testing.expectError(error.Corruption, edit.decodeFrom(bad.items));
}
