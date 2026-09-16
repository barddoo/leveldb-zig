//! Builds a table from an internal-key iterator, from `db/builder.{h,cc}`.
//!
//! Used both when flushing a memtable (level 0 output) and when writing
//! compaction output. On success `meta` is filled with the file size and key
//! range; an empty iterator produces no file.

const std = @import("std");
const Allocator = std.mem.Allocator;

const env_mod = @import("env.zig");
const filename = @import("filename.zig");
const version_edit = @import("version_edit.zig");
const FileMetaData = version_edit.FileMetaData;

const table_builder = @import("../table/table_builder.zig");
const TableBuilder = table_builder.TableBuilder;
const iter_mod = @import("../iter/iterator.zig");
const Iterator = iter_mod.Iterator;
const TableCache = @import("table_cache.zig").TableCache;

pub fn buildTable(
    env: env_mod.Env,
    gpa: Allocator,
    dbname: []const u8,
    table_cache: *TableCache,
    options: table_builder.Options,
    iter: Iterator,
    meta: *FileMetaData,
) env_mod.Error!void {
    meta.file_size = 0;
    iter.seekToFirst();

    const fname = try filename.tableFileName(gpa, dbname, meta.number);
    defer gpa.free(fname);

    if (iter.valid()) {
        const file = try env.newWritableFile(gpa, fname);
        defer file.deinit(gpa);

        var builder = try TableBuilder.init(gpa, options, file);
        defer builder.deinit();

        meta.smallest.clearRetainingCapacity();
        try meta.smallest.appendSlice(gpa, iter.key());

        while (iter.valid()) : (iter.next()) {
            meta.largest.clearRetainingCapacity();
            try meta.largest.appendSlice(gpa, iter.key());
            try builder.add(iter.key(), iter.value());
        }

        try builder.finish();
        meta.file_size = builder.fileSize();
        try file.sync();
        try file.close();

        // Reopen and scan to confirm the table is usable.
        const check = try table_cache.newIterator(.{}, meta.number, meta.file_size);
        defer check.deinit(gpa);
        try check.status();
    }

    // Propagate any iterator error, and drop empty files.
    var failed = false;
    iter.status() catch {
        failed = true;
    };
    if (failed or meta.file_size == 0) {
        env.removeFile(fname) catch {};
    }
}
