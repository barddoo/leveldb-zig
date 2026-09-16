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

/// A file that can only be read forward, one chunk at a time. Used for log
/// replay and for building tables from a stream.
pub const SequentialFile = struct {
    /// Implementation state (a `*Handle` in each backend).
    ptr: *anyopaque,
    /// The function table; every `SequentialFile` shares its shape.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read up to `n` bytes. The returned slice may point into `scratch`,
        /// so `scratch` must stay alive while the result is used. A short read
        /// means end of file.
        read: *const fn (ctx: *anyopaque, n: usize, scratch: []u8) Error![]const u8,
        /// Advance without reading. Skipping past EOF is not an error.
        skip: *const fn (ctx: *anyopaque, n: u64) Error!void,
        /// Close and free the implementation state.
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

/// A file that supports reading at arbitrary offsets. Reads are stateless, so
/// one instance may be used from several threads.
pub const RandomAccessFile = struct {
    /// Implementation state.
    ptr: *anyopaque,
    /// The function table.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read up to `n` bytes at `offset`. The returned slice may point into
        /// `scratch`. A short read means the file ended.
        read: *const fn (ctx: *anyopaque, offset: u64, n: usize, scratch: []u8) Error![]const u8,
        /// Close and free the implementation state.
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

/// An append-only file. Callers may append many small fragments; the
/// implementation is responsible for buffering.
pub const WritableFile = struct {
    /// Implementation state.
    ptr: *anyopaque,
    /// The function table.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Append bytes at the current end of the file.
        append: *const fn (ctx: *anyopaque, data: []const u8) Error!void,
        /// Push buffered bytes to the OS. Not necessarily durable.
        flush: *const fn (ctx: *anyopaque) Error!void,
        /// Durably persist previously appended data.
        sync: *const fn (ctx: *anyopaque) Error!void,
        /// Finish the file. After this, `deinit` releases resources.
        close: *const fn (ctx: *anyopaque) Error!void,
        /// Free the implementation state (closing first if still open).
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

/// An exclusive advisory lock on the DB directory. Held for the lifetime of an
/// open DB so two processes cannot open it at once.
pub const FileLock = struct {
    /// Implementation state.
    ptr: *anyopaque,
    /// The function table.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Release the lock and free the implementation state.
        deinit: *const fn (ctx: *anyopaque, gpa: Allocator) void,
    };

    pub fn deinit(self: FileLock, gpa: Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
    }
};

// ---------------------------------------------------------------------------
// Env
// ---------------------------------------------------------------------------

/// The filesystem/OS abstraction the engine talks to. Every backend (real disk,
/// in-memory, fault injection) implements this one vtable, so the DB code is
/// identical across all of them.
///
/// All paths are interpreted by the backend. The real backend uses paths
/// relative to the process working directory; the in-memory backend uses them
/// as keys.
pub const Env = struct {
    /// Implementation state.
    ptr: *anyopaque,
    /// The function table.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Open an existing file for forward reading. `error.NotFound` if absent.
        newSequentialFile: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!SequentialFile,
        /// Open an existing file for positional reading.
        newRandomAccessFile: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!RandomAccessFile,
        /// Create or truncate a file for writing.
        newWritableFile: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!WritableFile,
        /// Open for appending, creating the file if it does not exist.
        newAppendableFile: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!WritableFile,

        /// True if the path exists (file or directory).
        fileExists: *const fn (ctx: *anyopaque, path: []const u8) bool,
        /// List a directory's immediate children. Returns freshly allocated
        /// names; free with `freeDirEntries`.
        listDir: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error![][]u8,
        /// Delete a file.
        removeFile: *const fn (ctx: *anyopaque, path: []const u8) Error!void,
        /// Create a directory. Existing directories are not an error.
        createDir: *const fn (ctx: *anyopaque, path: []const u8) Error!void,
        /// Delete an empty directory.
        removeDir: *const fn (ctx: *anyopaque, path: []const u8) Error!void,
        /// Size of a file in bytes.
        fileSize: *const fn (ctx: *anyopaque, path: []const u8) Error!u64,
        /// Rename/replace `from` with `to`.
        rename: *const fn (ctx: *anyopaque, from: []const u8, to: []const u8) Error!void,

        /// Acquire an exclusive lock on a file, creating it if needed.
        lockFile: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) Error!FileLock,
        /// Release a lock. Takes `gpa` so the handle can be freed.
        unlockFile: *const fn (ctx: *anyopaque, lock: FileLock, gpa: Allocator) void,

        /// Monotonic-ish microseconds; only differences are meaningful.
        nowMicros: *const fn (ctx: *anyopaque) u64,
        /// Sleep. Used to throttle writers under back-pressure.
        sleepMicros: *const fn (ctx: *anyopaque, micros: u64) void,

        /// Release backend resources.
        deinit: *const fn (ctx: *anyopaque, gpa: Allocator) void,
    };

    /// Open an existing file for forward reading.
    pub fn newSequentialFile(self: Env, gpa: Allocator, path: []const u8) Error!SequentialFile {
        return self.vtable.newSequentialFile(self.ptr, gpa, path);
    }
    /// Open an existing file for positional reading.
    pub fn newRandomAccessFile(self: Env, gpa: Allocator, path: []const u8) Error!RandomAccessFile {
        return self.vtable.newRandomAccessFile(self.ptr, gpa, path);
    }
    /// Create or truncate a file for writing.
    pub fn newWritableFile(self: Env, gpa: Allocator, path: []const u8) Error!WritableFile {
        return self.vtable.newWritableFile(self.ptr, gpa, path);
    }
    /// Open a file for appending, creating it if needed.
    pub fn newAppendableFile(self: Env, gpa: Allocator, path: []const u8) Error!WritableFile {
        return self.vtable.newAppendableFile(self.ptr, gpa, path);
    }
    /// True if the path exists.
    pub fn fileExists(self: Env, path: []const u8) bool {
        return self.vtable.fileExists(self.ptr, path);
    }
    /// List a directory. Free the result with `freeDirEntries`.
    pub fn listDir(self: Env, gpa: Allocator, path: []const u8) Error![][]u8 {
        return self.vtable.listDir(self.ptr, gpa, path);
    }
    /// Delete a file.
    pub fn removeFile(self: Env, path: []const u8) Error!void {
        return self.vtable.removeFile(self.ptr, path);
    }
    /// Create a directory (existing directories are fine).
    pub fn createDir(self: Env, path: []const u8) Error!void {
        return self.vtable.createDir(self.ptr, path);
    }
    /// Delete an empty directory.
    pub fn removeDir(self: Env, path: []const u8) Error!void {
        return self.vtable.removeDir(self.ptr, path);
    }
    /// Size of a file in bytes.
    pub fn fileSize(self: Env, path: []const u8) Error!u64 {
        return self.vtable.fileSize(self.ptr, path);
    }
    /// Rename/replace `from` with `to`.
    pub fn rename(self: Env, from: []const u8, to: []const u8) Error!void {
        return self.vtable.rename(self.ptr, from, to);
    }
    /// Acquire the exclusive lock on a file.
    pub fn lockFile(self: Env, gpa: Allocator, path: []const u8) Error!FileLock {
        return self.vtable.lockFile(self.ptr, gpa, path);
    }
    /// Release a lock acquired with `lockFile`.
    pub fn unlockFile(self: Env, lock: FileLock, gpa: Allocator) void {
        self.vtable.unlockFile(self.ptr, lock, gpa);
    }
    /// Microseconds from an arbitrary fixed point.
    pub fn nowMicros(self: Env) u64 {
        return self.vtable.nowMicros(self.ptr);
    }
    /// Sleep for `micros` microseconds.
    pub fn sleepMicros(self: Env, micros: u64) void {
        self.vtable.sleepMicros(self.ptr, micros);
    }
    /// Release backend resources.
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
