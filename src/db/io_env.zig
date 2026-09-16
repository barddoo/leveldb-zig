//! A real filesystem `Env` built on `std.Io`.
//!
//! This is the backend the CLI uses. It mirrors `util/env_posix.cc` but stays
//! inside the std.Io abstraction, so the same code works on every target Io
//! supports. Writes are positional (tracked offset) so the log writer's
//! append-and-flush pattern maps directly onto `writePositionalAll`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const env_mod = @import("env.zig");
const Env = env_mod.Env;
const Error = env_mod.Error;

fn toEnvError(e: anyerror) Error {
    return switch (e) {
        error.FileNotFound => error.NotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoError,
    };
}

pub const IoEnv = struct {
    gpa: Allocator,
    io: Io,

    pub fn init(gpa: Allocator, io: Io) !*IoEnv {
        const self = try gpa.create(IoEnv);
        self.* = .{ .gpa = gpa, .io = io };
        return self;
    }

    pub fn deinit(self: *IoEnv) void {
        self.gpa.destroy(self);
    }

    pub fn env(self: *IoEnv) Env {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn fromOpaque(ctx: *anyopaque) *IoEnv {
        return @ptrCast(@alignCast(ctx));
    }
};

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

const WritableHandle = struct {
    io: Io,
    file: Io.File,
    offset: u64 = 0,
    closed: bool = false,
};

const SequentialHandle = struct {
    io: Io,
    file: Io.File,
    pos: u64 = 0,
};

const RandomHandle = struct {
    io: Io,
    file: Io.File,
};

const LockHandle = struct {
    io: Io,
    file: Io.File,
};

// ---------------------------------------------------------------------------
// Vtable
// ---------------------------------------------------------------------------

fn newSequentialFile(ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!env_mod.SequentialFile {
    const e = IoEnv.fromOpaque(ctx);
    const file = Io.Dir.cwd().openFile(e.io, path, .{}) catch |err| return toEnvError(err);
    const handle = gpa.create(SequentialHandle) catch |err| {
        file.close(e.io);
        return err;
    };
    handle.* = .{ .io = e.io, .file = file };
    return .{ .ptr = handle, .vtable = &sequential_vtable };
}

fn seqRead(ctx: *anyopaque, n: usize, scratch: []u8) Error![]const u8 {
    const h: *SequentialHandle = @ptrCast(@alignCast(ctx));
    const want = @min(n, scratch.len);
    const got = h.file.readPositionalAll(h.io, scratch[0..want], h.pos) catch |err| return toEnvError(err);
    h.pos += got;
    return scratch[0..got];
}

fn seqSkip(ctx: *anyopaque, n: u64) Error!void {
    const h: *SequentialHandle = @ptrCast(@alignCast(ctx));
    h.pos += n;
}

fn seqDeinit(ctx: *anyopaque, gpa: Allocator) void {
    const h: *SequentialHandle = @ptrCast(@alignCast(ctx));
    h.file.close(h.io);
    gpa.destroy(h);
}

const sequential_vtable = env_mod.SequentialFile.VTable{
    .read = seqRead,
    .skip = seqSkip,
    .deinit = seqDeinit,
};

fn newRandomAccessFile(ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!env_mod.RandomAccessFile {
    const e = IoEnv.fromOpaque(ctx);
    const file = Io.Dir.cwd().openFile(e.io, path, .{}) catch |err| return toEnvError(err);
    const handle = gpa.create(RandomHandle) catch |err| {
        file.close(e.io);
        return err;
    };
    handle.* = .{ .io = e.io, .file = file };
    return .{ .ptr = handle, .vtable = &random_vtable };
}

fn randRead(ctx: *anyopaque, offset: u64, n: usize, scratch: []u8) Error![]const u8 {
    const h: *RandomHandle = @ptrCast(@alignCast(ctx));
    const want = @min(n, scratch.len);
    const got = h.file.readPositionalAll(h.io, scratch[0..want], offset) catch |err| return toEnvError(err);
    return scratch[0..got];
}

fn randDeinit(ctx: *anyopaque, gpa: Allocator) void {
    const h: *RandomHandle = @ptrCast(@alignCast(ctx));
    h.file.close(h.io);
    gpa.destroy(h);
}

const random_vtable = env_mod.RandomAccessFile.VTable{
    .read = randRead,
    .deinit = randDeinit,
};

fn newWritableFile(ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!env_mod.WritableFile {
    const e = IoEnv.fromOpaque(ctx);
    const file = Io.Dir.cwd().createFile(e.io, path, .{ .truncate = true }) catch |err| return toEnvError(err);
    return makeWritable(gpa, e.io, file, 0);
}

fn newAppendableFile(ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!env_mod.WritableFile {
    const e = IoEnv.fromOpaque(ctx);
    // Create if missing, then measure for the append offset.
    const file = Io.Dir.cwd().createFile(e.io, path, .{ .truncate = false }) catch |err| return toEnvError(err);
    const stat = file.stat(e.io) catch |err| {
        file.close(e.io);
        return toEnvError(err);
    };
    return makeWritable(gpa, e.io, file, stat.size);
}

fn makeWritable(gpa: Allocator, io: Io, file: Io.File, offset: u64) Error!env_mod.WritableFile {
    const handle = gpa.create(WritableHandle) catch |err| {
        file.close(io);
        return err;
    };
    handle.* = .{ .io = io, .file = file, .offset = offset };
    return .{ .ptr = handle, .vtable = &writable_vtable };
}

fn writableAppend(ctx: *anyopaque, data: []const u8) Error!void {
    const h: *WritableHandle = @ptrCast(@alignCast(ctx));
    h.file.writePositionalAll(h.io, data, h.offset) catch |err| return toEnvError(err);
    h.offset += data.len;
}

fn writableFlush(_: *anyopaque) Error!void {}

fn writableSync(ctx: *anyopaque) Error!void {
    const h: *WritableHandle = @ptrCast(@alignCast(ctx));
    h.file.sync(h.io) catch |err| return toEnvError(err);
}

fn writableClose(ctx: *anyopaque) Error!void {
    const h: *WritableHandle = @ptrCast(@alignCast(ctx));
    if (!h.closed) {
        h.file.close(h.io);
        h.closed = true;
    }
}

fn writableDeinit(ctx: *anyopaque, gpa: Allocator) void {
    const h: *WritableHandle = @ptrCast(@alignCast(ctx));
    if (!h.closed) h.file.close(h.io);
    gpa.destroy(h);
}

const writable_vtable = env_mod.WritableFile.VTable{
    .append = writableAppend,
    .flush = writableFlush,
    .sync = writableSync,
    .close = writableClose,
    .deinit = writableDeinit,
};

fn fileExists(ctx: *anyopaque, path: []const u8) bool {
    const e = IoEnv.fromOpaque(ctx);
    Io.Dir.cwd().access(e.io, path, .{}) catch return false;
    return true;
}

fn listDir(ctx: *anyopaque, gpa: Allocator, path: []const u8) Error![][]u8 {
    const e = IoEnv.fromOpaque(ctx);
    var out = ArrayList([]u8).empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }

    var dir = Io.Dir.cwd().openDir(e.io, path, .{ .iterate = true }) catch |err| return toEnvError(err);
    defer dir.close(e.io);

    var it = dir.iterate();
    while (it.next(e.io) catch |err| return toEnvError(err)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        try out.append(gpa, try gpa.dupe(u8, entry.name));
    }
    return out.toOwnedSlice(gpa);
}

fn removeFile(ctx: *anyopaque, path: []const u8) Error!void {
    const e = IoEnv.fromOpaque(ctx);
    Io.Dir.cwd().deleteFile(e.io, path) catch |err| return toEnvError(err);
}

fn createDir(ctx: *anyopaque, path: []const u8) Error!void {
    const e = IoEnv.fromOpaque(ctx);
    Io.Dir.cwd().createDir(e.io, path, .default_dir) catch |err| return toEnvError(err);
}

fn removeDir(ctx: *anyopaque, path: []const u8) Error!void {
    const e = IoEnv.fromOpaque(ctx);
    Io.Dir.cwd().deleteDir(e.io, path) catch |err| return toEnvError(err);
}

fn fileSize(ctx: *anyopaque, path: []const u8) Error!u64 {
    const e = IoEnv.fromOpaque(ctx);
    const stat = Io.Dir.cwd().statFile(e.io, path, .{}) catch |err| return toEnvError(err);
    return stat.size;
}

fn renameFile(ctx: *anyopaque, from: []const u8, to: []const u8) Error!void {
    const e = IoEnv.fromOpaque(ctx);
    const cwd = Io.Dir.cwd();
    cwd.rename(from, cwd, to, e.io) catch |err| return toEnvError(err);
}

fn lockFile(ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!env_mod.FileLock {
    const e = IoEnv.fromOpaque(ctx);
    const file = Io.Dir.cwd().createFile(e.io, path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| return toEnvError(err);
    const handle = gpa.create(LockHandle) catch |err| {
        file.close(e.io);
        return err;
    };
    handle.* = .{ .io = e.io, .file = file };
    return .{ .ptr = handle, .vtable = &lock_vtable };
}

fn unlockFile(_: *anyopaque, lock: env_mod.FileLock, gpa: Allocator) void {
    lock.deinit(gpa);
}

fn lockDeinit(ctx: *anyopaque, gpa: Allocator) void {
    const h: *LockHandle = @ptrCast(@alignCast(ctx));
    h.file.unlock(h.io);
    h.file.close(h.io);
    gpa.destroy(h);
}

const lock_vtable = env_mod.FileLock.VTable{ .deinit = lockDeinit };

fn nowMicros(ctx: *anyopaque) u64 {
    const e = IoEnv.fromOpaque(ctx);
    const us = Io.Clock.now(.real, e.io).toMicroseconds();
    return if (us < 0) 0 else @intCast(us);
}

fn sleepMicros(ctx: *anyopaque, micros: u64) void {
    const e = IoEnv.fromOpaque(ctx);
    Io.sleep(e.io, Io.Duration.fromMicroseconds(@intCast(micros)), .awake) catch {};
}

fn envDeinit(ctx: *anyopaque, gpa: Allocator) void {
    _ = gpa;
    IoEnv.fromOpaque(ctx).deinit();
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
