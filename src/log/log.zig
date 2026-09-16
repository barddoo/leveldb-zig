//! Aggregator for the WAL/MANIFEST log format, plus round-trip tests.

pub const format = @import("log_format.zig");
pub const writer = @import("log_writer.zig");
pub const reader = @import("log_reader.zig");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

const mem_env = @import("../db/mem_env.zig");
const env_mod = @import("../db/env.zig");

const Writer = writer.Writer;
const Reader = reader.Reader;

/// Write `records` to a fresh in-memory file named `/log`, then read them back.
fn roundTrip(records: []const []const u8, scratch_out: *std.ArrayList([]u8)) !void {
    const gpa = testing.allocator;
    const mem = try mem_env.MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();

    {
        const file = try env.newWritableFile(gpa, "/log");
        defer file.deinit(gpa);
        var w = Writer.init(file, 0);
        for (records) |r| try w.addRecord(r);
        try w.sync();
        try file.close();
    }

    const file = try env.newSequentialFile(gpa, "/log");
    defer file.deinit(gpa);
    var r = try Reader.init(gpa, file, null, true, 0);
    defer r.deinit();

    while (try r.readRecord()) |rec| {
        try scratch_out.append(gpa, try gpa.dupe(u8, rec));
    }
}

fn freeRecords(records: *std.ArrayList([]u8)) void {
    for (records.items) |r| testing.allocator.free(r);
    records.deinit(testing.allocator);
}

test "round trip small records" {
    var got = std.ArrayList([]u8).empty;
    defer freeRecords(&got);

    try roundTrip(&.{ "hello", "world", "" }, &got);
    try testing.expectEqual(@as(usize, 3), got.items.len);
    try testing.expectEqualStrings("hello", got.items[0]);
    try testing.expectEqualStrings("world", got.items[1]);
    try testing.expectEqualStrings("", got.items[2]);
}

test "round trip record spanning blocks" {
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, format.block_size * 2 + 123);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);

    var got = std.ArrayList([]u8).empty;
    defer freeRecords(&got);

    try roundTrip(&.{big}, &got);
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqualSlices(u8, big, got.items[0]);
}

test "record exactly one block long" {
    const gpa = testing.allocator;
    const exact = try gpa.alloc(u8, format.block_size);
    defer gpa.free(exact);
    @memset(exact, 0x5a);

    var got = std.ArrayList([]u8).empty;
    defer freeRecords(&got);

    try roundTrip(&.{exact}, &got);
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqualSlices(u8, exact, got.items[0]);
}

test "many records with varying sizes" {
    const gpa = testing.allocator;
    const mem = try mem_env.MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();

    var rnd = @import("../primitives/random.zig").Random.init(99);
    var expected = std.ArrayList([]u8).empty;
    defer freeRecords(&expected);

    {
        const file = try env.newWritableFile(gpa, "/log");
        defer file.deinit(gpa);
        var w = Writer.init(file, 0);
        for (0..200) |_| {
            const len = rnd.uniform(5000);
            const data = try gpa.alloc(u8, len);
            for (data, 0..) |*b, i| b.* = @intCast((i + len) % 256);
            try expected.append(gpa, data);
            try w.addRecord(data);
        }
        try file.close();
    }

    const file = try env.newSequentialFile(gpa, "/log");
    defer file.deinit(gpa);
    var r = try Reader.init(gpa, file, null, true, 0);
    defer r.deinit();

    var idx: usize = 0;
    while (try r.readRecord()) |rec| {
        try testing.expectEqualSlices(u8, expected.items[idx], rec);
        idx += 1;
    }
    try testing.expectEqual(expected.items.len, idx);
}

test "checksum mismatch is reported and skipped" {
    const gpa = testing.allocator;
    const mem = try mem_env.MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();

    // A record of exactly `block_size - header_size` fills the first block as
    // a FULL record, so the second record lands in a fresh block. That lets us
    // show that a corrupt block is dropped while later blocks still read.
    const first = try gpa.alloc(u8, format.block_size - format.header_size);
    defer gpa.free(first);
    @memset(first, 'a');

    {
        const file = try env.newWritableFile(gpa, "/log");
        defer file.deinit(gpa);
        var w = Writer.init(file, 0);
        try w.addRecord(first);
        try w.addRecord("second-record");
        try file.close();
    }

    // Corrupt one payload byte of the first record (payload starts at offset 7).
    const data = try env_mod.readFileAlloc(env, gpa, "/log");
    defer gpa.free(data);
    data[8] ^= 0xff;
    {
        const file = try env.newWritableFile(gpa, "/log");
        defer file.deinit(gpa);
        try file.append(data);
        try file.close();
    }

    const Reporter = struct {
        count: usize = 0,
        fn onCorruption(ctx: *anyopaque, bytes: usize, reason: []const u8) void {
            _ = bytes;
            _ = reason;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
        }
    };
    var rep = Reporter{};

    const file = try env.newSequentialFile(gpa, "/log");
    defer file.deinit(gpa);
    var r = try Reader.init(gpa, file, .{ .ptr = &rep, .corruption_fn = Reporter.onCorruption }, true, 0);
    defer r.deinit();

    // The corrupted record is dropped; the second record still reads cleanly.
    var seen: usize = 0;
    while (try r.readRecord()) |rec| {
        try testing.expectEqualStrings("second-record", rec);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen);
    try testing.expect(rep.count >= 1);
}

test "truncated final record is treated as eof" {
    const gpa = testing.allocator;
    const mem = try mem_env.MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();

    {
        const file = try env.newWritableFile(gpa, "/log");
        defer file.deinit(gpa);
        var w = Writer.init(file, 0);
        try w.addRecord("complete");
        try w.addRecord("will-be-truncated");
        try file.close();
    }

    const full = try env_mod.readFileAlloc(env, gpa, "/log");
    defer gpa.free(full);
    // Cut the file in the middle of the second record's payload.
    const truncated = full[0 .. full.len - 5];
    {
        const file = try env.newWritableFile(gpa, "/log");
        defer file.deinit(gpa);
        try file.append(truncated);
        try file.close();
    }

    const file = try env.newSequentialFile(gpa, "/log");
    defer file.deinit(gpa);
    var r = try Reader.init(gpa, file, null, true, 0);
    defer r.deinit();

    var count: usize = 0;
    while (try r.readRecord()) |rec| {
        try testing.expectEqualStrings("complete", rec);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}
