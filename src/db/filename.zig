//! Database file naming and parsing, from `db/filename.{h,cc}`.
//!
//! All files live in one directory. The names are:
//!
//!     %06d.log        write-ahead log
//!     %06d.sst        sorted table
//!     MANIFEST-%06d   descriptor (a log of VersionEdits)
//!     CURRENT         text file naming the live MANIFEST
//!     LOCK            held for the lifetime of an open DB
//!     %06d.dbtmp      temporary file used when installing CURRENT
//!     LOG, LOG.old    informational logs
//!
//! `CURRENT` is installed atomically: write a temp file, sync it, rename.

const std = @import("std");
const Allocator = std.mem.Allocator;

const env_mod = @import("env.zig");
const Env = env_mod.Env;

pub const FileType = enum {
    log,
    lock,
    table,
    descriptor,
    current,
    temp,
    info_log,
};

pub fn logFileName(gpa: Allocator, dbname: []const u8, number: u64) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{d:0>6}.log", .{ dbname, number });
}

pub fn tableFileName(gpa: Allocator, dbname: []const u8, number: u64) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{d:0>6}.sst", .{ dbname, number });
}

pub fn descriptorFileName(gpa: Allocator, dbname: []const u8, number: u64) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/MANIFEST-{d:0>6}", .{ dbname, number });
}

pub fn currentFileName(gpa: Allocator, dbname: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/CURRENT", .{dbname});
}

pub fn lockFileName(gpa: Allocator, dbname: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/LOCK", .{dbname});
}

pub fn tempFileName(gpa: Allocator, dbname: []const u8, number: u64) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{d:0>6}.dbtmp", .{ dbname, number });
}

pub fn infoLogFileName(gpa: Allocator, dbname: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/LOG", .{dbname});
}

pub fn oldInfoLogFileName(gpa: Allocator, dbname: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/LOG.old", .{dbname});
}

pub const Parsed = struct {
    number: u64,
    type: FileType,
};

/// Parse a base file name (no directory). Returns null if unrecognized.
pub fn parseFileName(name: []const u8) ?Parsed {
    if (std.mem.eql(u8, name, "CURRENT")) return .{ .number = 0, .type = .current };
    if (std.mem.eql(u8, name, "LOCK")) return .{ .number = 0, .type = .lock };
    if (std.mem.eql(u8, name, "LOG")) return .{ .number = 0, .type = .info_log };
    if (std.mem.eql(u8, name, "LOG.old")) return .{ .number = 0, .type = .info_log };

    if (std.mem.startsWith(u8, name, "MANIFEST-")) {
        const rest = name["MANIFEST-".len..];
        const num = consumeDecimal(rest) orelse return null;
        if (num.consumed != rest.len) return null;
        return .{ .number = num.value, .type = .descriptor };
    }

    const num = consumeDecimal(name) orelse return null;
    if (num.consumed == 0) return null;
    const suffix = name[num.consumed..];

    if (std.mem.eql(u8, suffix, ".log")) return .{ .number = num.value, .type = .log };
    if (std.mem.eql(u8, suffix, ".sst")) return .{ .number = num.value, .type = .table };
    if (std.mem.eql(u8, suffix, ".dbtmp")) return .{ .number = num.value, .type = .temp };
    return null;
}

const Decimal = struct { value: u64, consumed: usize };

/// Parse leading decimal digits, locale-independent and overflow-checked.
fn consumeDecimal(s: []const u8) ?Decimal {
    var value: u64 = 0;
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        const digit: u64 = s[i] - '0';
        if (value > (std.math.maxInt(u64) - digit) / 10) return null; // overflow
        value = value * 10 + digit;
    }
    return .{ .value = value, .consumed = i };
}

/// Atomically point CURRENT at `manifest_number`'s MANIFEST file.
pub fn setCurrentFile(
    env: Env,
    gpa: Allocator,
    dbname: []const u8,
    manifest_number: u64,
) !void {
    const tmp = try tempFileName(gpa, dbname, manifest_number);
    defer gpa.free(tmp);
    const current = try currentFileName(gpa, dbname);
    defer gpa.free(current);

    var buf: [64]u8 = undefined;
    const contents = std.fmt.bufPrint(&buf, "MANIFEST-{d:0>6}\n", .{manifest_number}) catch return error.IoError;

    try env_mod.writeStringToFile(env, gpa, contents, tmp);
    try env.rename(tmp, current);
}

/// Read CURRENT and return the MANIFEST base name (caller frees).
pub fn readCurrentFile(env: Env, gpa: Allocator, dbname: []const u8) ![]u8 {
    const current = try currentFileName(gpa, dbname);
    defer gpa.free(current);

    const contents = try env_mod.readFileAlloc(env, gpa, current);
    errdefer gpa.free(contents);

    if (contents.len == 0 or contents[contents.len - 1] != '\n') {
        gpa.free(contents);
        return error.Corruption;
    }
    // Drop the trailing newline.
    const name = try gpa.dupe(u8, contents[0 .. contents.len - 1]);
    gpa.free(contents);
    return name;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "constructors" {
    const gpa = testing.allocator;

    const t = try tableFileName(gpa, "db", 12);
    defer gpa.free(t);
    try testing.expectEqualStrings("db/000012.sst", t);

    const l = try logFileName(gpa, "db", 7);
    defer gpa.free(l);
    try testing.expectEqualStrings("db/000007.log", l);

    const d = try descriptorFileName(gpa, "db", 3);
    defer gpa.free(d);
    try testing.expectEqualStrings("db/MANIFEST-000003", d);
}

test "parseFileName" {
    try testing.expectEqual(FileType.current, parseFileName("CURRENT").?.type);
    try testing.expectEqual(FileType.lock, parseFileName("LOCK").?.type);
    try testing.expectEqual(FileType.info_log, parseFileName("LOG").?.type);
    try testing.expectEqual(FileType.info_log, parseFileName("LOG.old").?.type);

    const m = parseFileName("MANIFEST-000123").?;
    try testing.expectEqual(FileType.descriptor, m.type);
    try testing.expectEqual(@as(u64, 123), m.number);

    const t = parseFileName("000045.sst").?;
    try testing.expectEqual(FileType.table, t.type);
    try testing.expectEqual(@as(u64, 45), t.number);

    const l = parseFileName("000045.log").?;
    try testing.expectEqual(FileType.log, l.type);

    try testing.expect(parseFileName("garbage") == null);
    try testing.expect(parseFileName("000045.txt") == null);
    try testing.expect(parseFileName("MANIFEST-xyz") == null);
}

test "consumeDecimal overflow" {
    try testing.expect(consumeDecimal("999999999999999999999") == null);
}

test "setCurrentFile and readCurrentFile" {
    const gpa = testing.allocator;
    const mem = try @import("mem_env.zig").MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();

    try env.createDir("db");
    try setCurrentFile(env, gpa, "db", 42);

    const name = try readCurrentFile(env, gpa, "db");
    defer gpa.free(name);
    try testing.expectEqualStrings("MANIFEST-000042", name);
}
