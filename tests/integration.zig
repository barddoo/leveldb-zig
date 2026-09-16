//! Integration tests exercise the engine through its public API.
//!
//! Unit tests live beside each module under `src/`. These tests go through
//! `leveldb.DB` the way an application would, using the in-memory environment.

const std = @import("std");
const leveldb = @import("leveldb");

const testing = std.testing;

test "end-to-end put/get/iterate/delete across a flush" {
    const gpa = testing.allocator;
    const mem = try leveldb.mem_env.MemEnv.init(gpa);
    defer mem.deinit();

    const db = try leveldb.DB.open(gpa, testing.io, mem.env(), .{
        .create_if_missing = true,
        .write_buffer_size = 64 * 1024,
        .disable_background_thread = true,
    }, "db");
    defer db.close();

    // Write enough to force at least one memtable flush to an SSTable.
    var kb: [24]u8 = undefined;
    var vb: [24]u8 = undefined;
    for (0..4000) |i| {
        const k = try std.fmt.bufPrint(&kb, "key-{d:0>6}", .{i});
        const v = try std.fmt.bufPrint(&vb, "value-{d}", .{i});
        try db.put(k, v, .{});
    }

    // Point reads.
    var out = std.ArrayList(u8).empty;
    defer out.deinit(gpa);
    try db.get("key-000042", .{}, &out);
    try testing.expectEqualStrings("value-42", out.items);

    // Full forward iteration.
    const it = try db.newIterator(.{});
    defer it.deinit(gpa);
    var count: usize = 0;
    it.seekToFirst();
    while (it.valid()) : (it.next()) count += 1;
    try testing.expectEqual(@as(usize, 4000), count);
    try it.status();

    // A snapshot taken now keeps seeing the pre-delete state.
    const snap = try db.getSnapshot();
    defer db.releaseSnapshot(snap);

    // Delete a key and confirm it disappears for fresh reads.
    try db.delete("key-000042", .{});
    try testing.expectError(error.NotFound, db.get("key-000042", .{}, &out));

    // The snapshot still sees the old value.
    try db.get("key-000042", .{ .snapshot = snap }, &out);
    try testing.expectEqualStrings("value-42", out.items);
}

test "reopen recovers data from the write-ahead log" {
    const gpa = testing.allocator;
    const mem = try leveldb.mem_env.MemEnv.init(gpa);
    defer mem.deinit();

    const opts = leveldb.Options{
        .create_if_missing = true,
        .write_buffer_size = 64 * 1024,
        .disable_background_thread = true,
    };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(gpa);

    {
        const db = try leveldb.DB.open(gpa, testing.io, mem.env(), opts, "db");
        defer db.close();
        try db.put("a", "1", .{});
        try db.put("b", "2", .{});
        try db.delete("a", .{});
    }

    {
        const db = try leveldb.DB.open(gpa, testing.io, mem.env(), opts, "db");
        defer db.close();
        try db.get("b", .{}, &out);
        try testing.expectEqualStrings("2", out.items);
        try testing.expectError(error.NotFound, db.get("a", .{}, &out));
    }
}
