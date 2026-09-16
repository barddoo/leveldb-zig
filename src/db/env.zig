//! The `Env` abstraction, modeled on `include/leveldb/env.h`.
//!
//! The engine never touches the filesystem directly. Instead it goes through
//! this vtable, which buys two things:
//!
//!   * tests can run entirely in memory and simulate failures, and
//!   * the same DB code works on any platform with one small backend.
//!
//! Zig has no inheritance, so each interface is a context pointer plus a table
//! of function pointers. Ownership is explicit: the caller `deinit`s files and
//! frees directory listings.
//!
//! Only the operations the engine actually uses are declared. Adding a new one
//! means adding a field to the vtable and implementing it in each backend.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const status = @import("../primitives/status.zig");

/// Errors any Env operation may return. OS-specific failures are collapsed to
/// `IoError`; the message (if needed) is logged by the backend.
pub const Error = status.Error || Allocator.Error;

// ---------------------------------------------------------------------------
// SequentialFile — read forward, used by log replay and table building
// ---------------------------------------------------------------------------

pub const SequentialFile = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read up to `n` bytes. The returned slice may point into `scratch`.
        /// A short read means end of file.
        read: *const fn (ctx: *anyopaque, n: usize, scratch: []u8) Error![]const u8,
        skip: *const fn (ctx: *anyopaque, n: u64) Error!void,
        deinit: *const fn (ctx: *anyopaque, gpa: Allocator) void,
    };

    pub fn read(self: SequentialFile, n: usize, scratch: []u8) Error![]const u8 {
        return self.vtable.read(self.ptr, n, scratch);
    }
    pub fn skip(self: SequentialFile, n: u64) Error!void {
        return self.vtable.skip(self.ptr, n);
    }
    pub fn deinit(self: SequentialFile, gpa: Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
    }
};

// ---------------------------------------------------------------------------
// RandomAccessFile — positional reads, used by tables
// ---------------------------------------------------------------------------

pub const RandomAccessFile = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read up to `n` bytes at `offset`. The returned slice may point into
        /// `scratch`. A short read means the file ended.
        read: *const fn (ctx: *anyopaque, offset: u64, n: usize, scratch: []u8) Error![]const u8,
        deinit: *const fn (ctx: *anyopaque, gpa: Allocator) void,
    };

    pub fn read(self: RandomAccessFile, offset: u64, n: usize, scratch: []u8) Error![]const u8 {
        return self.vtable.read(self.ptr, offset, n, scratch);
    }
    pub fn deinit(self: RandomAccessFile, gpa: Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
    }
};

// ---------------------------------------------------------------------------
// WritableFile — append-only, used by the WAL and table builder
// ---------------------------------------------------------------------------

pub const WritableFile = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        append: *const fn (ctx: *anyopaque, data: []const u8) Error!void,
        flush: *const fn (ctx: *anyopaque) Error!void,
        /// Durably persist previously appended data.
        sync: *const fn (ctx: *anyopaque) Error!void,
        close: *const fn (ctx: *anyopaque) Error!void,
        deinit: *const fn (ctx: *anyopaque, gpa: Allocator) void,
    };

    pub fn append(self: WritableFile, data: []const u8) Error!void {
        return self.vtable.append(self.ptr, data);
    }
    pub fn flush(self: WritableFile) Error!void {
        return self.vtable.flush(self.ptr);
    }
    pub fn sync(self: WritableFile) Error!void {
        return self.vtable.sync(self.ptr);
    }
    pub fn close(self: WritableFile) Error!void {
        return self.vtable.close(self.ptr);
    }
    pub fn deinit(self: WritableFile, gpa: Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
    }
};

// ---------------------------------------------------------------------------
// FileLock — one process may hold the DB's LOCK at a time
// ---------------------------------------------------------------------------

pub const FileLock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque, gpa: Allocator) void,
    };

    pub fn deinit(self: FileLock, gpa: Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
    }
};

// ---------------------------------------------------------------------------
// Env
// ---------------------------------------------------------------------------

pub const Env = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        newSequentialFile: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!SequentialFile,
        newRandomAccessFile: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!RandomAccessFile,
        newWritableFile: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!WritableFile,
        newAppendableFile: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!WritableFile,

        fileExists: *const fn (ctx: *anyopaque, path: []const u8) bool,
        /// Returns freshly allocated names; free with `freeDirEntries`.
        listDir: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error![][]u8,
        removeFile: *const fn (ctx: *anyopaque, path: []const u8) Error!void,
        createDir: *const fn (ctx: *anyopaque, path: []const u8) Error!void,
        removeDir: *const fn (ctx: *anyopaque, path: []const u8) Error!void,
        fileSize: *const fn (ctx: *anyopaque, path: []const u8) Error!u64,
        rename: *const fn (ctx: *anyopaque, from: []const u8, to: []const u8) Error!void,

        lockFile: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!FileLock,
        unlockFile: *const fn (ctx: *anyopaque, lock: FileLock, gpa: Allocator) void,

        nowMicros: *const fn (ctx: *anyopaque) u64,
        sleepMicros: *const fn (ctx: *anyopaque, micros: u64) void,

        deinit: *const fn (ctx: *anyopaque, gpa: Allocator) void,
    };

    pub fn newSequentialFile(self: Env, gpa: Allocator, path: []const u8) Error!SequentialFile {
        return self.vtable.newSequentialFile(self.ptr, gpa, path);
    }
    pub fn newRandomAccessFile(self: Env, gpa: Allocator, path: []const u8) Error!RandomAccessFile {
        return self.vtable.newRandomAccessFile(self.ptr, gpa, path);
    }
    pub fn newWritableFile(self: Env, gpa: Allocator, path: []const u8) Error!WritableFile {
        return self.vtable.newWritableFile(self.ptr, gpa, path);
    }
    pub fn newAppendableFile(self: Env, gpa: Allocator, path: []const u8) Error!WritableFile {
        return self.vtable.newAppendableFile(self.ptr, gpa, path);
    }
    pub fn fileExists(self: Env, path: []const u8) bool {
        return self.vtable.fileExists(self.ptr, path);
    }
    pub fn listDir(self: Env, gpa: Allocator, path: []const u8) Error![][]u8 {
        return self.vtable.listDir(self.ptr, gpa, path);
    }
    pub fn removeFile(self: Env, path: []const u8) Error!void {
        return self.vtable.removeFile(self.ptr, path);
    }
    pub fn createDir(self: Env, path: []const u8) Error!void {
        return self.vtable.createDir(self.ptr, path);
    }
    pub fn removeDir(self: Env, path: []const u8) Error!void {
        return self.vtable.removeDir(self.ptr, path);
    }
    pub fn fileSize(self: Env, path: []const u8) Error!u64 {
        return self.vtable.fileSize(self.ptr, path);
    }
    pub fn rename(self: Env, from: []const u8, to: []const u8) Error!void {
        return self.vtable.rename(self.ptr, from, to);
    }
    pub fn lockFile(self: Env, gpa: Allocator, path: []const u8) Error!FileLock {
        return self.vtable.lockFile(self.ptr, gpa, path);
    }
    pub fn unlockFile(self: Env, lock: FileLock, gpa: Allocator) void {
        self.vtable.unlockFile(self.ptr, lock, gpa);
    }
    pub fn nowMicros(self: Env) u64 {
        return self.vtable.nowMicros(self.ptr);
    }
    pub fn sleepMicros(self: Env, micros: u64) void {
        self.vtable.sleepMicros(self.ptr, micros);
    }
    pub fn deinit(self: Env, gpa: Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
    }
};

/// Free the names and the outer slice returned by `Env.listDir`.
pub fn freeDirEntries(gpa: Allocator, entries: [][]u8) void {
    for (entries) |e| gpa.free(e);
    gpa.free(entries);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Write `data` to a new file, sync it, and close it. Used for CURRENT and the
/// manifest bootstrap.
pub fn writeStringToFile(env: Env, gpa: Allocator, data: []const u8, path: []const u8) Error!void {
    const file = try env.newWritableFile(gpa, path);
    defer file.deinit(gpa);
    try file.append(data);
    try file.sync();
    try file.close();
}

/// Read an entire file into memory. Caller frees the result.
pub fn readFileAlloc(env: Env, gpa: Allocator, path: []const u8) Error![]u8 {
    const file = try env.newSequentialFile(gpa, path);
    defer file.deinit(gpa);

    var out = ArrayList(u8).empty;
    errdefer out.deinit(gpa);

    var scratch: [8192]u8 = undefined;
    while (true) {
        const chunk = try file.read(scratch.len, &scratch);
        if (chunk.len == 0) break;
        try out.appendSlice(gpa, chunk);
    }
    return out.toOwnedSlice(gpa);
}
