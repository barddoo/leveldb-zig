//! Opening tables by file number, from `db/table_cache.{h,cc}`.
//!
//! LevelDB caches open tables in an LRU. This port opens a table per use and
//! closes it after, which is simpler and correct. The `evict` hook and the API
//! shape are kept so a cache can be added later without touching callers.
//!
//! A `newIterator` result owns its table: the iterator wrapper closes the table
//! when it is deinited, so the data stays valid for the iterator's lifetime.

const std = @import("std");
const Allocator = std.mem.Allocator;

const env_mod = @import("env.zig");
const filename = @import("filename.zig");
const table_mod = @import("../table/table.zig");
const format = @import("../table/format.zig");
const iter_mod = @import("../iter/iterator.zig");
const Iterator = iter_mod.Iterator;
const IteratorError = iter_mod.IteratorError;

pub const TableCache = struct {
    /// Allocator for file handles and tables.
    gpa: Allocator,
    /// Environment used to open table files.
    env: env_mod.Env,
    /// Directory containing the DB. Borrowed; owned by the DB.
    dbname: []const u8,
    /// Options passed to every opened table.
    table_options: table_mod.Options,

    pub fn init(gpa: Allocator, env: env_mod.Env, dbname: []const u8, options: table_mod.Options) TableCache {
        return .{ .gpa = gpa, .env = env, .dbname = dbname, .table_options = options };
    }

    /// Open the table file for `number`. Caller owns the returned table and
    /// must `deinit` it.
    fn openTable(self: *TableCache, number: u64, file_size: u64) env_mod.Error!*table_mod.Table {
        const fname = try filename.tableFileName(self.gpa, self.dbname, number);
        defer self.gpa.free(fname);

        const file = try self.env.newRandomAccessFile(self.gpa, fname);
        errdefer file.deinit(self.gpa);

        return table_mod.Table.open(self.gpa, self.table_options, file, file_size);
    }

    /// Look up `key` in the table for `number`, invoking `handle_result` with
    /// the first entry at or after it. The table is closed before returning.
    pub fn get(
        self: *TableCache,
        options: format.ReadOptions,
        number: u64,
        file_size: u64,
        key: []const u8,
        arg: *anyopaque,
        handle_result: *const fn (arg: *anyopaque, ikey: []const u8, value: []const u8) void,
    ) env_mod.Error!void {
        const table = try self.openTable(number, file_size);
        defer table.deinit();
        try table.internalGet(self.gpa, options, key, arg, handle_result);
    }

    /// Return an iterator over the table for `number`. The iterator owns the
    /// open table, so the data stays valid until the iterator is deinited.
    pub fn newIterator(
        self: *TableCache,
        options: format.ReadOptions,
        number: u64,
        file_size: u64,
    ) env_mod.Error!Iterator {
        const table = try self.openTable(number, file_size);
        const inner = table.newIterator(options) catch |e| {
            table.deinit();
            return e;
        };
        return OwnedTableIterator.create(self.gpa, table, inner);
    }

    /// No-op without a cache; kept for API compatibility.
    pub fn evict(self: *TableCache, number: u64) void {
        _ = self;
        _ = number;
    }
};

/// Owns a table and an iterator over it, closing the table on deinit.
const OwnedTableIterator = struct {
    gpa: Allocator,
    table: *table_mod.Table,
    inner: Iterator,

    fn create(gpa: Allocator, table: *table_mod.Table, inner: Iterator) !Iterator {
        const self = try gpa.create(OwnedTableIterator);
        self.* = .{ .gpa = gpa, .table = table, .inner = inner };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ctx: *anyopaque) *OwnedTableIterator {
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
        self.table.deinit();
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
