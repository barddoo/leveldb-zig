//! Reads SSTables, from `table/table.{h,cc}`.
//!
//! `open` decodes the footer, loads the index block, and (if a filter policy is
//! configured) the filter. Iteration is a two-level iterator over the index and
//! data blocks. `internalGet` seeks the index, consults the filter, and scans
//! the target block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const comparator = @import("../primitives/comparator.zig");
const env_mod = @import("../db/env.zig");
const Error = env_mod.Error;

const iter_mod = @import("../iter/iterator.zig");
const Iterator = iter_mod.Iterator;
const IteratorError = iter_mod.IteratorError;
const TwoLevelIterator = @import("../iter/two_level.zig").TwoLevelIterator;

const Block = @import("block.zig").Block;
const format = @import("format.zig");
const BlockHandle = format.BlockHandle;
const Footer = format.Footer;
const ReadOptions = format.ReadOptions;
const FilterPolicy = @import("filter_policy.zig").FilterPolicy;
const FilterBlockReader = @import("filter_block.zig").Reader;

pub const Options = struct {
    comparator: comparator.Comparator,
    filter_policy: ?FilterPolicy = null,
    paranoid_checks: bool = false,
};

pub const Table = struct {
    gpa: Allocator,
    options: Options,
    file: env_mod.RandomAccessFile,
    metaindex_handle: BlockHandle,
    index_block: Block,
    filter: ?FilterBlockReader = null,
    filter_data: ?[]u8 = null,

    /// Takes ownership of `file` on success. On failure the caller still owns it.
    pub fn open(
        gpa: Allocator,
        options: Options,
        file: env_mod.RandomAccessFile,
        file_size: u64,
    ) Error!*Table {
        if (file_size < Footer.encoded_length) return error.Corruption;

        var footer_buf: [Footer.encoded_length]u8 = undefined;
        const n = try file.read(file_size - Footer.encoded_length, Footer.encoded_length, &footer_buf);
        if (n.len != Footer.encoded_length) return error.Corruption;

        var input: []const u8 = n;
        const footer = try Footer.decodeFrom(&input);

        const read_opts = ReadOptions{ .verify_checksums = options.paranoid_checks };
        const index_contents = try format.readBlock(gpa, file, read_opts, footer.index_handle);
        const index_block = Block.init(gpa, index_contents.data);

        const self = try gpa.create(Table);
        self.* = .{
            .gpa = gpa,
            .options = options,
            .file = file,
            .metaindex_handle = footer.metaindex_handle,
            .index_block = index_block,
        };

        try self.readMeta(footer);
        return self;
    }

    pub fn deinit(self: *Table) void {
        self.index_block.deinit();
        if (self.filter_data) |d| self.gpa.free(d);
        self.file.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn newIterator(self: *Table, options: ReadOptions) IteratorError!Iterator {
        const index_iter = try self.index_block.newIterator(self.options.comparator);
        return TwoLevelIterator.create(self.gpa, index_iter, blockReader, self, options);
    }

    /// Seek the index and, if the filter allows it, scan the target block,
    /// invoking `handle_result` on the first entry at or after `key`.
    pub fn internalGet(
        self: *Table,
        gpa: Allocator,
        options: ReadOptions,
        key: []const u8,
        arg: *anyopaque,
        handle_result: *const fn (arg: *anyopaque, ikey: []const u8, value: []const u8) void,
    ) Error!void {
        const iiter = try self.index_block.newIterator(self.options.comparator);
        defer iiter.deinit(gpa);

        iiter.seek(key);
        if (!iiter.valid()) return;

        const handle_value = iiter.value();
        var hinput: []const u8 = handle_value;
        const handle = BlockHandle.decodeFrom(&hinput) catch return;

        if (self.filter) |filter| {
            if (!filter.keyMayMatch(handle.offset, key)) return;
        }

        const block_iter = blockReader(self, gpa, options, handle_value) catch |e| return e;
        defer block_iter.deinit(gpa);

        block_iter.seek(key);
        if (block_iter.valid()) handle_result(arg, block_iter.key(), block_iter.value());
        try block_iter.status();
    }

    pub fn approximateOffsetOf(self: *Table, gpa: Allocator, key: []const u8) u64 {
        const index_iter = self.index_block.newIterator(self.options.comparator) catch {
            return self.metaindex_handle.offset;
        };
        defer index_iter.deinit(gpa);

        index_iter.seek(key);
        if (!index_iter.valid()) return self.metaindex_handle.offset;

        var input: []const u8 = index_iter.value();
        const handle = BlockHandle.decodeFrom(&input) catch return self.metaindex_handle.offset;
        return handle.offset;
    }

    fn readMeta(self: *Table, footer: Footer) Error!void {
        const policy = self.options.filter_policy orelse return;

        const read_opts = ReadOptions{ .verify_checksums = self.options.paranoid_checks };
        const contents = format.readBlock(self.gpa, self.file, read_opts, footer.metaindex_handle) catch return;
        var block = Block.init(self.gpa, contents.data);
        defer block.deinit();

        const it = block.newIterator(comparator.bytewise) catch return;
        defer it.deinit(self.gpa);

        var key = ArrayList(u8).empty;
        defer key.deinit(self.gpa);
        try key.appendSlice(self.gpa, "filter.");
        try key.appendSlice(self.gpa, policy.name());

        it.seek(key.items);
        if (it.valid() and std.mem.eql(u8, it.key(), key.items)) {
            self.readFilter(policy, it.value());
        }
    }

    fn readFilter(self: *Table, policy: FilterPolicy, handle_value: []const u8) void {
        var input: []const u8 = handle_value;
        const handle = BlockHandle.decodeFrom(&input) catch return;

        const read_opts = ReadOptions{ .verify_checksums = self.options.paranoid_checks };
        const contents = format.readBlock(self.gpa, self.file, read_opts, handle) catch return;

        self.filter_data = contents.data;
        self.filter = FilterBlockReader.init(policy, contents.data);
    }
};

// ---------------------------------------------------------------------------
// Block reader: index value -> data block iterator
// ---------------------------------------------------------------------------

fn blockReader(arg: *anyopaque, gpa: Allocator, options: ReadOptions, index_value: []const u8) IteratorError!Iterator {
    const self: *Table = @ptrCast(@alignCast(arg));

    var input: []const u8 = index_value;
    const handle = BlockHandle.decodeFrom(&input) catch {
        return iter_mod.errorIterator(gpa, error.Corruption);
    };

    const contents = format.readBlock(gpa, self.file, options, handle) catch |e| {
        return iter_mod.errorIterator(gpa, e);
    };
    const block = Block.init(gpa, contents.data);

    const inner = block.newIterator(self.options.comparator) catch |e| {
        var b = block;
        b.deinit();
        return e;
    };

    return OwnedBlockIterator.create(gpa, block, inner);
}

/// Wraps a block iterator and owns the block it reads from, so `deinit` frees
/// both. (With a block cache, ownership would move to the cache instead.)
const OwnedBlockIterator = struct {
    gpa: Allocator,
    block: Block,
    inner: Iterator,

    fn create(gpa: Allocator, block: Block, inner: Iterator) !Iterator {
        const self = try gpa.create(OwnedBlockIterator);
        self.* = .{ .gpa = gpa, .block = block, .inner = inner };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ctx: *anyopaque) *OwnedBlockIterator {
        return @ptrCast(@alignCast(ctx));
    }

    fn valid(ctx: *anyopaque) bool {
        return cast(ctx).inner.valid();
    }
    fn key(ctx: *anyopaque) []const u8 {
        return cast(ctx).inner.key();
    }
    fn value(ctx: *anyopaque) []const u8 {
        return cast(ctx).inner.value();
    }
    fn nextFn(ctx: *anyopaque) void {
        cast(ctx).inner.next();
    }
    fn prevFn(ctx: *anyopaque) void {
        cast(ctx).inner.prev();
    }
    fn seekToFirstFn(ctx: *anyopaque) void {
        cast(ctx).inner.seekToFirst();
    }
    fn seekToLastFn(ctx: *anyopaque) void {
        cast(ctx).inner.seekToLast();
    }
    fn seekFn(ctx: *anyopaque, target: []const u8) void {
        cast(ctx).inner.seek(target);
    }
    fn statusFn(ctx: *anyopaque) IteratorError!void {
        return cast(ctx).inner.status();
    }
    fn deinitFn(ctx: *anyopaque, gpa: Allocator) void {
        const self = cast(ctx);
        self.inner.deinit(gpa);
        self.block.deinit();
        gpa.destroy(self);
    }

    const vtable = Iterator.VTable{
        .valid = valid,
        .seekToFirst = seekToFirstFn,
        .seekToLast = seekToLastFn,
        .seek = seekFn,
        .next = nextFn,
        .prev = prevFn,
        .key = key,
        .value = value,
        .status = statusFn,
        .deinit = deinitFn,
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const mem_env = @import("../db/mem_env.zig");
const filter_policy = @import("filter_policy.zig");
const TableBuilder = @import("table_builder.zig").TableBuilder;
const table_builder_mod = @import("table_builder.zig");

fn buildTable(
    gpa: Allocator,
    env: env_mod.Env,
    path: []const u8,
    entries: []const struct { []const u8, []const u8 },
    opts: table_builder_mod.Options,
) !u64 {
    const file = try env.newWritableFile(gpa, path);
    defer file.deinit(gpa);
    var builder = try TableBuilder.init(gpa, opts, file);
    defer builder.deinit();
    for (entries) |e| try builder.add(e[0], e[1]);
    try builder.finish();
    try file.sync();
    try file.close();
    return builder.fileSize();
}

test "table build, iterate, and internalGet" {
    const gpa = testing.allocator;
    const mem = try mem_env.MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();

    const entries = [_]struct { []const u8, []const u8 }{
        .{ "apple", "red" },
        .{ "apricot", "orange" },
        .{ "banana", "yellow" },
        .{ "cherry", "dark red" },
        .{ "date", "brown" },
    };
    const opts = table_builder_mod.Options{ .comparator = comparator.bytewise };
    const size = try buildTable(gpa, env, "/t.sst", &entries, opts);

    const rfile = try env.newRandomAccessFile(gpa, "/t.sst");
    const table = try Table.open(gpa, .{ .comparator = comparator.bytewise }, rfile, size);
    defer table.deinit();

    // Iterate forward.
    const it = try table.newIterator(.{});
    defer it.deinit(gpa);
    it.seekToFirst();
    var i: usize = 0;
    while (it.valid()) : (it.next()) {
        try testing.expectEqualStrings(entries[i][0], it.key());
        try testing.expectEqualStrings(entries[i][1], it.value());
        i += 1;
    }
    try testing.expectEqual(entries.len, i);

    // internalGet through a saver.
    // The saver must copy the value: the block it points into is freed when
    // internalGet returns.
    const Saver = struct {
        key: []const u8,
        value_buf: [64]u8 = undefined,
        value_len: usize = 0,
        found: bool = false,
        fn save(arg: *anyopaque, ikey: []const u8, value: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(arg));
            if (std.mem.eql(u8, ikey, self.key)) {
                self.value_len = @min(value.len, self.value_buf.len);
                @memcpy(self.value_buf[0..self.value_len], value[0..self.value_len]);
                self.found = true;
            }
        }
    };
    var saver = Saver{ .key = "cherry" };
    try table.internalGet(gpa, .{}, "cherry", &saver, Saver.save);
    try testing.expect(saver.found);
    try testing.expectEqualStrings("dark red", saver.value_buf[0..saver.value_len]);

    // A missing key leaves the saver untouched.
    var missing = Saver{ .key = "durian" };
    try table.internalGet(gpa, .{}, "durian", &missing, Saver.save);
    try testing.expect(!missing.found);
}

test "table with bloom filter skips absent keys" {
    const gpa = testing.allocator;
    const mem = try mem_env.MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();

    const policy = try filter_policy.createBloom(gpa, 10);
    defer filter_policy.destroyBloom(gpa, policy);

    var entries: [200]struct { []const u8, []const u8 } = undefined;
    var keys: [200][16]u8 = undefined;
    for (0..200) |i| {
        const k = try std.fmt.bufPrint(&keys[i], "key-{d:0>4}", .{i});
        entries[i] = .{ k, "v" };
    }
    const opts = table_builder_mod.Options{
        .comparator = comparator.bytewise,
        .filter_policy = policy,
    };
    const size = try buildTable(gpa, env, "/t.sst", &entries, opts);

    const rfile = try env.newRandomAccessFile(gpa, "/t.sst");
    const table = try Table.open(gpa, .{
        .comparator = comparator.bytewise,
        .filter_policy = policy,
    }, rfile, size);
    defer table.deinit();

    try testing.expect(table.filter != null);

    const Saver = struct {
        found: bool = false,
        fn save(arg: *anyopaque, ikey: []const u8, value: []const u8) void {
            _ = ikey;
            _ = value;
            const self: *@This() = @ptrCast(@alignCast(arg));
            self.found = true;
        }
    };

    var present = Saver{};
    try table.internalGet(gpa, .{}, "key-0042", &present, Saver.save);
    try testing.expect(present.found);

    var absent = Saver{};
    try table.internalGet(gpa, .{}, "zzz-not-there", &absent, Saver.save);
    try testing.expect(!absent.found);
}

test "table spanning many data blocks" {
    const gpa = testing.allocator;
    const mem = try mem_env.MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();

    const n = 2000;
    var entries = try gpa.alloc(struct { []const u8, []const u8 }, n);
    defer gpa.free(entries);
    const keys = try gpa.alloc([24]u8, n);
    defer gpa.free(keys);
    const vals = try gpa.alloc([64]u8, n);
    defer gpa.free(vals);

    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&keys[i], "key-{d:0>6}", .{i});
        @memset(&vals[i], @intCast('a' + (i % 26)));
        entries[i] = .{ k, &vals[i] };
    }

    const opts = table_builder_mod.Options{ .comparator = comparator.bytewise, .block_size = 1024 };
    const size = try buildTable(gpa, env, "/big.sst", entries, opts);

    const rfile = try env.newRandomAccessFile(gpa, "/big.sst");
    const table = try Table.open(gpa, .{ .comparator = comparator.bytewise }, rfile, size);
    defer table.deinit();

    const it = try table.newIterator(.{});
    defer it.deinit(gpa);

    var count: usize = 0;
    it.seekToFirst();
    while (it.valid()) : (it.next()) count += 1;
    try testing.expectEqual(@as(usize, n), count);

    // Random seeks.
    var rnd = @import("../primitives/random.zig").Random.init(7);
    for (0..200) |_| {
        const i = rnd.uniform(n);
        var kbuf: [24]u8 = undefined;
        const k = try std.fmt.bufPrint(&kbuf, "key-{d:0>6}", .{i});
        it.seek(k);
        try testing.expect(it.valid());
        try testing.expectEqualStrings(k, it.key());
    }
}
