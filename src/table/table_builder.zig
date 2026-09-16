//! Builds SSTables, from `table/table_builder.cc`.
//!
//! `add` appends to a data block until it reaches `block_size`, then flushes it
//! and records its handle in the index block. `finish` writes the optional
//! filter block, the metaindex, the index, and the footer.
//!
//! Compression extension point: `writeBlock` is where LevelDB would try Snappy
//! or Zstd and fall back to uncompressed when the result is not at least 12.5%
//! smaller. Here it always writes type 0 (uncompressed).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const coding = @import("../primitives/coding.zig");
const crc32c = @import("../primitives/crc32c.zig");
const comparator = @import("../primitives/comparator.zig");
const env = @import("../db/env.zig");
const WritableFile = env.WritableFile;
const Error = env.Error;

const BlockBuilder = @import("block_builder.zig").BlockBuilder;
const format = @import("format.zig");
const BlockHandle = format.BlockHandle;
const Footer = format.Footer;
const FilterPolicy = @import("filter_policy.zig").FilterPolicy;
const FilterBlockBuilder = @import("filter_block.zig").Builder;

/// Knobs for building a table.
pub const Options = struct {
    /// Target uncompressed size of a data block. A block is flushed once its
    /// estimate reaches this.
    block_size: usize = 4096,
    /// Number of keys between restart points in data blocks.
    block_restart_interval: usize = 16,
    /// Orders keys and supplies separator shortening for the index.
    comparator: comparator.Comparator,
    /// If set, a filter block is written and recorded in the metaindex.
    filter_policy: ?FilterPolicy = null,
};

/// Writes an SSTable.
///
/// `add` appends entries to the current data block. When the block is full it is
/// written to the file and its handle is recorded in the index block. `finish`
/// writes the filter, metaindex, index, and footer.
pub const TableBuilder = struct {
    /// Allocator for block builders and the filter.
    gpa: Allocator,
    /// Configuration captured at construction.
    options: Options,
    /// Destination file. Not owned; the caller closes it.
    file: WritableFile,
    /// Bytes written so far, used for block handles and `fileSize`.
    offset: u64 = 0,
    /// Current data block being filled.
    data_block: BlockBuilder,
    /// Index block: one entry per data block, built incrementally.
    index_block: BlockBuilder,
    /// The last key added, needed to build the next index entry.
    last_key: ArrayList(u8) = .empty,
    /// Total entries added.
    num_entries: u64 = 0,
    /// Set by `finish` or `abandon`; guards against further writes.
    closed: bool = false,
    /// Accumulates Bloom filters, if a policy was configured.
    filter_block: ?FilterBlockBuilder = null,
    /// True when the previous data block was flushed and the next `add` must
    /// first record an index entry for it.
    pending_index_entry: bool = false,
    /// Handle of the most recently flushed data block.
    pending_handle: BlockHandle = .{},

    /// Create a builder writing to `file`.
    pub fn init(gpa: Allocator, options: Options, file: WritableFile) !TableBuilder {
        var data_block = try BlockBuilder.init(gpa, options.block_restart_interval);
        errdefer data_block.deinit();
        // The index block uses a restart interval of 1: every entry is a
        // restart point, so binary search works on every index entry.
        var index_block = try BlockBuilder.init(gpa, 1);
        errdefer index_block.deinit();

        var filter_block: ?FilterBlockBuilder = null;
        if (options.filter_policy) |policy| {
            filter_block = FilterBlockBuilder.init(gpa, policy);
        }

        return .{
            .gpa = gpa,
            .options = options,
            .file = file,
            .data_block = data_block,
            .index_block = index_block,
            .filter_block = filter_block,
        };
    }

    /// Free builder state. Does not close the file.
    pub fn deinit(self: *TableBuilder) void {
        self.data_block.deinit();
        self.index_block.deinit();
        self.last_key.deinit(self.gpa);
        if (self.filter_block) |*fb| fb.deinit();
    }

    /// Number of entries written so far.
    pub fn numEntries(self: *const TableBuilder) u64 {
        return self.num_entries;
    }

    pub fn fileSize(self: *const TableBuilder) u64 {
        return self.offset;
    }

    pub fn add(self: *TableBuilder, key: []const u8, value: []const u8) !void {
        if (self.pending_index_entry) {
            // The previous data block just ended. `last_key` is its final key;
            // `key` is the first key of the new block. Record the separator.
            try self.options.comparator.findShortestSeparator(self.gpa, &self.last_key, key);

            var handle_encoding = ArrayList(u8).empty;
            defer handle_encoding.deinit(self.gpa);
            try self.pending_handle.encodeTo(self.gpa, &handle_encoding);
            try self.index_block.add(self.last_key.items, handle_encoding.items);
            self.pending_index_entry = false;
        }

        if (self.filter_block) |*fb| try fb.addKey(key);

        self.last_key.clearRetainingCapacity();
        try self.last_key.appendSlice(self.gpa, key);
        self.num_entries += 1;
        try self.data_block.add(key, value);

        if (self.data_block.currentSizeEstimate() >= self.options.block_size) {
            try self.flush();
        }
    }

    pub fn flush(self: *TableBuilder) !void {
        if (self.data_block.isEmpty()) return;
        try self.writeBlock(&self.data_block, &self.pending_handle);
        self.pending_index_entry = true;
        try self.file.flush();
        if (self.filter_block) |*fb| try fb.startBlock(self.offset);
    }

    /// Finish the table and write the footer. Does not close the file.
    pub fn finish(self: *TableBuilder) !void {
        try self.flush();

        var metaindex_handle = BlockHandle{};

        if (self.filter_block) |*fb| {
            const filter_bytes = try fb.finish();
            var filter_handle = BlockHandle{};
            try self.writeRawBlock(filter_bytes, 0, &filter_handle);

            var meta_index_block = try BlockBuilder.init(self.gpa, self.options.block_restart_interval);
            defer meta_index_block.deinit();

            var key = ArrayList(u8).empty;
            defer key.deinit(self.gpa);
            try key.appendSlice(self.gpa, "filter.");
            try key.appendSlice(self.gpa, self.options.filter_policy.?.name());

            var handle_encoding = ArrayList(u8).empty;
            defer handle_encoding.deinit(self.gpa);
            try filter_handle.encodeTo(self.gpa, &handle_encoding);

            try meta_index_block.add(key.items, handle_encoding.items);
            try self.writeBlock(&meta_index_block, &metaindex_handle);
        }

        if (self.pending_index_entry) {
            try self.options.comparator.findShortSuccessor(self.gpa, &self.last_key);
            var handle_encoding = ArrayList(u8).empty;
            defer handle_encoding.deinit(self.gpa);
            try self.pending_handle.encodeTo(self.gpa, &handle_encoding);
            try self.index_block.add(self.last_key.items, handle_encoding.items);
            self.pending_index_entry = false;
        }

        var index_handle = BlockHandle{};
        try self.writeBlock(&self.index_block, &index_handle);

        const footer = Footer{
            .metaindex_handle = metaindex_handle,
            .index_handle = index_handle,
        };
        var footer_encoding = ArrayList(u8).empty;
        defer footer_encoding.deinit(self.gpa);
        try footer.encodeTo(self.gpa, &footer_encoding);
        try self.file.append(footer_encoding.items);
        self.offset += footer_encoding.items.len;

        self.closed = true;
    }

    pub fn abandon(self: *TableBuilder) void {
        self.closed = true;
    }

    fn writeBlock(self: *TableBuilder, block: *BlockBuilder, handle: *BlockHandle) !void {
        const raw = block.finish();
        // Compression extension point: try to compress `raw` here and pick a
        // non-zero type only when the result is meaningfully smaller.
        try self.writeRawBlock(raw, 0, handle);
        block.reset();
    }

    fn writeRawBlock(self: *TableBuilder, data: []const u8, compression_type: u8, handle: *BlockHandle) !void {
        handle.offset = self.offset;
        handle.size = data.len;

        try self.file.append(data);

        var trailer: [format.kBlockTrailerSize]u8 = undefined;
        trailer[0] = compression_type;
        // The checksum covers the stored block bytes followed by the type byte.
        var hasher = crc32c.Hasher.init();
        hasher.update(data);
        hasher.update(&[_]u8{compression_type});
        coding.encodeFixed32(trailer[1..5], crc32c.mask(hasher.final()));
        try self.file.append(&trailer);

        self.offset += data.len + format.kBlockTrailerSize;
    }
};
