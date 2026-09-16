//! An in-memory `Env`, used by tests and by anyone who wants a throwaway DB.
//!
//! This mirrors `helpers/memenv/memenv.cc`. Files are byte buffers in a hash
//! map; directories are just a set of path prefixes. It makes the entire engine
//! testable without touching disk and without cleanup hazards.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const env_mod = @import("env.zig");
const Env = env_mod.Env;

/// A file's contents. Heap-allocated and referenced by pointer so a writable
/// handle stays valid even if the hash map is resized by a later file creation.
const FileData = struct {
    data: ArrayList(u8) = .empty,
};

/// An `Env` whose files live in memory. Everything is a byte buffer; there is
/// no real filesystem, so tests are fast and leave nothing behind.
pub const MemEnv = struct {
    /// Allocator for all maps, keys, file data, and handles.
    gpa: Allocator,
    /// Open "files", keyed by path. Values are stable pointers (see FileData).
    files: std.StringHashMapUnmanaged(*FileData) = .empty,
    /// Existing "directories". The DB only ever uses one, but the model is
    /// general.
    dirs: std.StringHashMapUnmanaged(void) = .empty,
    /// A fake monotonic clock; advances on each `nowMicros`/`sleepMicros`.
    clock: u64 = 0,

    /// Create an empty environment. Free with `deinit`.
    pub fn init(gpa: Allocator) !*MemEnv {
        const self = try gpa.create(MemEnv);
        self.* = .{ .gpa = gpa };
        return self;
    }

    /// Free every file, directory, and the environment itself.
    pub fn deinit(self: *MemEnv) void {
        const gpa = self.gpa;
        var it = self.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.data.deinit(gpa);
            gpa.destroy(entry.value_ptr.*);
            gpa.free(entry.key_ptr.*);
        }
        self.files.deinit(gpa);

        var dit = self.dirs.iterator();
        while (dit.next()) |entry| gpa.free(entry.key_ptr.*);
        self.dirs.deinit(gpa);

        gpa.destroy(self);
    }

    /// Wrap this environment in the `Env` vtable the engine uses.
    pub fn env(self: *MemEnv) Env {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn fromOpaque(ctx: *anyopaque) *MemEnv {
        return @ptrCast(@alignCast(ctx));
    }

    /// Look up an existing file, or null.
    fn findFile(self: *MemEnv, path: []const u8) ?*FileData {
        return self.files.get(path);
    }

    /// Look up a file, creating an empty one if it does not exist.
    fn ensureFile(self: *MemEnv, path: []const u8) !*FileData {
        if (self.files.get(path)) |f| return f;
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);
        const data = try self.gpa.create(FileData);
        errdefer self.gpa.destroy(data);
        data.* = .{};
        try self.files.put(self.gpa, key, data);
        return data;
    }
};

// ---------------------------------------------------------------------------
// File handles
// ---------------------------------------------------------------------------

const WritableHandle = struct {
    mem: *MemEnv,
    file: *FileData,
};

const SequentialHandle = struct {
    mem: *MemEnv,
    file: *FileData,
    pos: usize = 0,
};

const RandomHandle = struct {
    mem: *MemEnv,
    file: *FileData,
};

const LockHandle = struct {};

// ---------------------------------------------------------------------------
// Vtable implementations
// ---------------------------------------------------------------------------

fn newSequentialFile(ctx: *anyopaque, gpa: Allocator, path: []const u8) env_mod.Error!env_mod.SequentialFile {
    const mem = MemEnv.fromOpaque(ctx);
    const file = mem.findFile(path) orelse return error.NotFound;
    const handle = try gpa.create(SequentialHandle);
    handle.* = .{ .mem = mem, .file = file };
    return .{ .ptr = handle, .vtable = &sequential_vtable };
}

fn seqRead(ctx: *anyopaque, n: usize, scratch: []u8) env_mod.Error![]const u8 {
    const handle: *SequentialHandle = @ptrCast(@alignCast(ctx));
    const remaining = handle.file.data.items.len - handle.pos;
    const take = @min(n, @min(scratch.len, remaining));
    @memcpy(scratch[0..take], handle.file.data.items[handle.pos..][0..take]);
    handle.pos += take;
    return scratch[0..take];
}

fn seqSkip(ctx: *anyopaque, n: u64) env_mod.Error!void {
    const handle: *SequentialHandle = @ptrCast(@alignCast(ctx));
    const len = handle.file.data.items.len;
    handle.pos = @min(len, handle.pos + @as(usize, @intCast(n)));
}

fn seqDeinit(ctx: *anyopaque, gpa: Allocator) void {
    gpa.destroy(@as(*SequentialHandle, @ptrCast(@alignCast(ctx))));
}

const sequential_vtable = env_mod.SequentialFile.VTable{
    .read = seqRead,
    .skip = seqSkip,
    .deinit = seqDeinit,
};

fn newRandomAccessFile(ctx: *anyopaque, gpa: Allocator, path: []const u8) env_mod.Error!env_mod.RandomAccessFile {
    const mem = MemEnv.fromOpaque(ctx);
    const file = mem.findFile(path) orelse return error.NotFound;
    const handle = try gpa.create(RandomHandle);
    handle.* = .{ .mem = mem, .file = file };
    return .{ .ptr = handle, .vtable = &random_vtable };
}

fn randRead(ctx: *anyopaque, offset: u64, n: usize, scratch: []u8) env_mod.Error![]const u8 {
    const handle: *RandomHandle = @ptrCast(@alignCast(ctx));
    const len = handle.file.data.items.len;
    const off: usize = @intCast(offset);
    if (off >= len) return scratch[0..0];
    const take = @min(n, @min(scratch.len, len - off));
    @memcpy(scratch[0..take], handle.file.data.items[off..][0..take]);
    return scratch[0..take];
}

fn randDeinit(ctx: *anyopaque, gpa: Allocator) void {
    gpa.destroy(@as(*RandomHandle, @ptrCast(@alignCast(ctx))));
}

const random_vtable = env_mod.RandomAccessFile.VTable{
    .read = randRead,
    .deinit = randDeinit,
};

fn newWritableFile(ctx: *anyopaque, gpa: Allocator, path: []const u8) env_mod.Error!env_mod.WritableFile {
    const mem = MemEnv.fromOpaque(ctx);
    // Truncate any existing file.
    if (mem.files.get(path)) |f| {
        f.data.clearRetainingCapacity();
        return makeWritable(gpa, mem, f);
    }
    const file = try mem.ensureFile(path);
    return makeWritable(gpa, mem, file);
}

fn newAppendableFile(ctx: *anyopaque, gpa: Allocator, path: []const u8) env_mod.Error!env_mod.WritableFile {
    const mem = MemEnv.fromOpaque(ctx);
    const file = try mem.ensureFile(path);
    return makeWritable(gpa, mem, file);
}

fn makeWritable(gpa: Allocator, mem: *MemEnv, file: *FileData) env_mod.Error!env_mod.WritableFile {
    const handle = try gpa.create(WritableHandle);
    handle.* = .{ .mem = mem, .file = file };
    return .{ .ptr = handle, .vtable = &writable_vtable };
}

fn writableAppend(ctx: *anyopaque, data: []const u8) env_mod.Error!void {
    const handle: *WritableHandle = @ptrCast(@alignCast(ctx));
    try handle.file.data.appendSlice(handle.mem.gpa, data);
}

fn writableNoop(_: *anyopaque) env_mod.Error!void {}

fn writableDeinit(ctx: *anyopaque, gpa: Allocator) void {
    gpa.destroy(@as(*WritableHandle, @ptrCast(@alignCast(ctx))));
}

const writable_vtable = env_mod.WritableFile.VTable{
    .append = writableAppend,
    .flush = writableNoop,
    .sync = writableNoop,
    .close = writableNoop,
    .deinit = writableDeinit,
};

fn fileExists(ctx: *anyopaque, path: []const u8) bool {
    return MemEnv.fromOpaque(ctx).files.contains(path);
}

fn relativeBasename(prefix: []const u8, full: []const u8) ?[]const u8 {
    var rest = full;
    if (prefix.len > 0) {
        if (!std.mem.startsWith(u8, full, prefix)) return null;
        rest = full[prefix.len..];
        if (rest.len == 0 or rest[0] != '/') return null;
        rest = rest[1..];
    }
    if (rest.len == 0) return null;
    if (std.mem.indexOfScalar(u8, rest, '/') != null) return null;
    return rest;
}

fn listDir(ctx: *anyopaque, gpa: Allocator, path: []const u8) env_mod.Error![][]u8 {
    const mem = MemEnv.fromOpaque(ctx);
    var out = ArrayList([]u8).empty;
    errdefer {
        for (out.items) |e| gpa.free(e);
        out.deinit(gpa);
    }

    const prefix = if (std.mem.eql(u8, path, ".")) "" else path;

    var it = mem.files.iterator();
    while (it.next()) |entry| {
        if (relativeBasename(prefix, entry.key_ptr.*)) |base| {
            try out.append(gpa, try gpa.dupe(u8, base));
        }
    }
    var dit = mem.dirs.iterator();
    while (dit.next()) |entry| {
        if (relativeBasename(prefix, entry.key_ptr.*)) |base| {
            try out.append(gpa, try gpa.dupe(u8, base));
        }
    }
    return out.toOwnedSlice(gpa);
}

fn removeFile(ctx: *anyopaque, path: []const u8) env_mod.Error!void {
    const mem = MemEnv.fromOpaque(ctx);
    const kv = mem.files.fetchRemove(path) orelse return error.NotFound;
    kv.value.data.deinit(mem.gpa);
    mem.gpa.destroy(kv.value);
    mem.gpa.free(kv.key);
}

fn createDir(ctx: *anyopaque, path: []const u8) env_mod.Error!void {
    const mem = MemEnv.fromOpaque(ctx);
    if (mem.dirs.contains(path)) return;
    const key = try mem.gpa.dupe(u8, path);
    errdefer mem.gpa.free(key);
    try mem.dirs.put(mem.gpa, key, {});
}

fn removeDir(ctx: *anyopaque, path: []const u8) env_mod.Error!void {
    const mem = MemEnv.fromOpaque(ctx);
    const kv = mem.dirs.fetchRemove(path) orelse return error.NotFound;
    mem.gpa.free(kv.key);
}

fn fileSize(ctx: *anyopaque, path: []const u8) env_mod.Error!u64 {
    const mem = MemEnv.fromOpaque(ctx);
    const file = mem.findFile(path) orelse return error.NotFound;
    return file.data.items.len;
}

fn renameFile(ctx: *anyopaque, from: []const u8, to: []const u8) env_mod.Error!void {
    const mem = MemEnv.fromOpaque(ctx);
    const file = mem.findFile(from) orelse return error.NotFound;
    const kv = mem.files.fetchRemove(from).?;
    // If `to` exists, drop its old contents.
    if (mem.files.fetchRemove(to)) |old| {
        old.value.data.deinit(mem.gpa);
        mem.gpa.destroy(old.value);
        mem.gpa.free(old.key);
    }
    const key = try mem.gpa.dupe(u8, to);
    errdefer mem.gpa.free(key);
    try mem.files.put(mem.gpa, key, file);
    mem.gpa.free(kv.key);
}

fn lockFile(ctx: *anyopaque, gpa: Allocator, path: []const u8) env_mod.Error!env_mod.FileLock {
    _ = ctx;
    _ = path;
    const handle = try gpa.create(LockHandle);
    handle.* = .{};
    return .{ .ptr = handle, .vtable = &lock_vtable };
}

fn unlockFile(ctx: *anyopaque, lock: env_mod.FileLock, gpa: Allocator) void {
    _ = ctx;
    lock.deinit(gpa);
}

fn lockDeinit(ctx: *anyopaque, gpa: Allocator) void {
    gpa.destroy(@as(*LockHandle, @ptrCast(@alignCast(ctx))));
}

const lock_vtable = env_mod.FileLock.VTable{ .deinit = lockDeinit };

fn nowMicros(ctx: *anyopaque) u64 {
    const mem = MemEnv.fromOpaque(ctx);
    mem.clock += 1000;
    return mem.clock;
}

fn sleepMicros(ctx: *anyopaque, micros: u64) void {
    const mem = MemEnv.fromOpaque(ctx);
    mem.clock += micros;
}

fn envDeinit(ctx: *anyopaque, gpa: Allocator) void {
    _ = gpa;
    MemEnv.fromOpaque(ctx).deinit();
}

const vtable = env_mod.Env.VTable{
    .newSequentialFile = newSequentialFile,
    .newRandomAccessFile = newRandomAccessFile,
    .newWritableFile = newWritableFile,
    .newAppendableFile = newAppendableFile,
    .fileExists = fileExists,
    .listDir = listDir,
    .removeFile = removeFile,
    .createDir = createDir,
    .removeDir = removeDir,
    .fileSize = fileSize,
    .rename = renameFile,
    .lockFile = lockFile,
    .unlockFile = unlockFile,
    .nowMicros = nowMicros,
    .sleepMicros = sleepMicros,
    .deinit = envDeinit,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "write, read, size, list, remove" {
    const mem = try MemEnv.init(testing.allocator);
    defer mem.deinit();
    const env = mem.env();

    try env.createDir("/db");
    try env_mod.writeStringToFile(env, testing.allocator, "hello world", "/db/a.txt");
    try testing.expect(env.fileExists("/db/a.txt"));
    try testing.expectEqual(@as(u64, 11), try env.fileSize("/db/a.txt"));

    const contents = try env_mod.readFileAlloc(env, testing.allocator, "/db/a.txt");
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("hello world", contents);

    const entries = try env.listDir(testing.allocator, "/db");
    defer env_mod.freeDirEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("a.txt", entries[0]);

    try env.removeFile("/db/a.txt");
    try testing.expect(!env.fileExists("/db/a.txt"));
}

test "appendable file appends" {
    const mem = try MemEnv.init(testing.allocator);
    defer mem.deinit();
    const env = mem.env();

    const f1 = try env.newWritableFile(testing.allocator, "/f");
    defer f1.deinit(testing.allocator);
    try f1.append("abc");
    try f1.close();

    const f2 = try env.newAppendableFile(testing.allocator, "/f");
    defer f2.deinit(testing.allocator);
    try f2.append("def");

    const contents = try env_mod.readFileAlloc(env, testing.allocator, "/f");
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("abcdef", contents);
}

test "random access reads at offset" {
    const mem = try MemEnv.init(testing.allocator);
    defer mem.deinit();
    const env = mem.env();
    try env_mod.writeStringToFile(env, testing.allocator, "0123456789", "/f");

    const file = try env.newRandomAccessFile(testing.allocator, "/f");
    defer file.deinit(testing.allocator);

    var scratch: [4]u8 = undefined;
    try testing.expectEqualStrings("3456", try file.read(3, 4, &scratch));
    try testing.expectEqualStrings("89", try file.read(8, 4, &scratch));
}

test "rename and missing file" {
    const mem = try MemEnv.init(testing.allocator);
    defer mem.deinit();
    const env = mem.env();
    try env_mod.writeStringToFile(env, testing.allocator, "x", "/a");
    try env.rename("/a", "/b");
    try testing.expect(!env.fileExists("/a"));
    try testing.expect(env.fileExists("/b"));
    try testing.expectError(error.NotFound, env.fileSize("/missing"));
}
