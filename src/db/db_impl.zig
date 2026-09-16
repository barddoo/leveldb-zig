//! The DB engine, from `db/db_impl.{h,cc}`.
//!
//! This ties everything together:
//!   * writes go to a write-ahead log and then to a memtable,
//!   * a full memtable becomes immutable and is flushed to a level-0 table,
//!   * a background worker compacts levels that exceed their budget,
//!   * reads check the memtable, then the immutable memtable, then the tables,
//!   * open replays the log and rebuilds state from the MANIFEST.
//!
//! Concurrency uses `std.Io`: a `Mutex` guards all mutable DB state, and a
//! `Condition` wakes the background worker. A single writer at the head of a
//! queue performs the log append; others wait their turn (group commit).
//!
//! Cancellation is deliberately avoided: every lock/wait uses the uncancelable
//! variants, because a canceled write in the middle of a DB operation would
//! leave inconsistent state.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const comparator = @import("../primitives/comparator.zig");
const internal_key = @import("internal_key.zig");
const env_mod = @import("env.zig");
const Error = env_mod.Error;
const filename = @import("filename.zig");
const memtable_mod = @import("../memtable/memtable.zig");
const MemTable = memtable_mod.MemTable;
const write_batch_mod = @import("../memtable/write_batch.zig");
const WriteBatch = write_batch_mod.WriteBatch;
const version_edit = @import("version_edit.zig");
const VersionEdit = version_edit.VersionEdit;
const FileMetaData = version_edit.FileMetaData;
const version_set = @import("version_set.zig");
const VersionSet = version_set.VersionSet;
const Compaction = version_set.Compaction;
const Version = version_set.Version;
const Config = version_set.Config;
const snapshot_mod = @import("snapshot.zig");
const SnapshotList = snapshot_mod.SnapshotList;
const Snapshot = snapshot_mod.Snapshot;
const TableCache = @import("table_cache.zig").TableCache;
const table_builder = @import("../table/table_builder.zig");
const filter_policy = @import("../table/filter_policy.zig");
const format = @import("../table/format.zig");
const iter_mod = @import("../iter/iterator.zig");
const Iterator = iter_mod.Iterator;
const merger = @import("../iter/merger.zig");
const db_iter = @import("../iter/db_iter.zig");
const log = @import("../log/log.zig");
const builder = @import("builder.zig");

const InternalKeyComparator = internal_key.InternalKeyComparator;
const SequenceNumber = internal_key.SequenceNumber;

// ---------------------------------------------------------------------------
// Public options
// ---------------------------------------------------------------------------

pub const Options = struct {
    create_if_missing: bool = false,
    error_if_exists: bool = false,
    paranoid_checks: bool = false,

    write_buffer_size: usize = 4 * 1024 * 1024,
    max_open_files: usize = 1000,
    block_size: usize = 4 * 1024,
    block_restart_interval: usize = 16,
    max_file_size: usize = 2 * 1024 * 1024,

    /// If set, a Bloom filter with this many bits per key is used.
    filter_bits_per_key: ?usize = null,

    /// User key comparator. Must be identical across opens of the same DB.
    comparator: comparator.Comparator = comparator.bytewise,

    /// Run compaction synchronously instead of on a background thread. Useful
    /// for tests and embedded use where thread scheduling is undesirable.
    disable_background_thread: bool = false,

    // Compression is intentionally not implemented. The table builder marks the
    // extension point where a codec would be selected.
};

pub const WriteOptions = struct {
    /// If true, sync the log before the write is acknowledged.
    sync: bool = false,
};

pub const ReadOptions = struct {
    verify_checksums: bool = false,
    fill_cache: bool = true,
    snapshot: ?*Snapshot = null,
};

// ---------------------------------------------------------------------------
// DB (public handle)
// ---------------------------------------------------------------------------

pub const DB = struct {
    impl: *DBImpl,

    pub fn open(
        gpa: Allocator,
        io: Io,
        env: env_mod.Env,
        options: Options,
        dbname: []const u8,
    ) Error!*DB {
        const impl = try DBImpl.create(gpa, io, env, options, dbname);
        errdefer impl.destroy();
        try impl.open();
        const self = try gpa.create(DB);
        self.* = .{ .impl = impl };
        return self;
    }

    pub fn close(self: *DB) void {
        const gpa = self.impl.gpa;
        self.impl.close();
        self.impl.destroy();
        gpa.destroy(self);
    }

    pub fn put(self: *DB, key: []const u8, value: []const u8, opts: WriteOptions) Error!void {
        var batch = try WriteBatch.init(self.impl.gpa);
        defer batch.deinit();
        try batch.put(key, value);
        try self.impl.write(&batch, opts);
    }

    pub fn delete(self: *DB, key: []const u8, opts: WriteOptions) Error!void {
        var batch = try WriteBatch.init(self.impl.gpa);
        defer batch.deinit();
        try batch.delete(key);
        try self.impl.write(&batch, opts);
    }

    pub fn write(self: *DB, batch: *WriteBatch, opts: WriteOptions) Error!void {
        return self.impl.write(batch, opts);
    }

    /// Fill `out` with the value for `key`; returns error.NotFound if absent.
    pub fn get(self: *DB, key: []const u8, opts: ReadOptions, out: *ArrayList(u8)) Error!void {
        return self.impl.get(key, opts, out);
    }

    pub fn newIterator(self: *DB, opts: ReadOptions) Error!Iterator {
        return self.impl.newIterator(opts);
    }

    pub fn getSnapshot(self: *DB) Error!*Snapshot {
        return self.impl.getSnapshot();
    }

    pub fn releaseSnapshot(self: *DB, snapshot: *Snapshot) void {
        self.impl.releaseSnapshot(snapshot);
    }

    pub fn compactRange(self: *DB, begin: ?[]const u8, end: ?[]const u8) Error!void {
        return self.impl.compactRange(begin, end);
    }
};

// ---------------------------------------------------------------------------
// Writer (one per pending Write call)
// ---------------------------------------------------------------------------

pub const Writer = struct {
    status: ?Error = null,
    batch: ?*WriteBatch = null,
    sync: bool = false,
    done: bool = false,
    cv: Io.Condition = .init,
};

// ---------------------------------------------------------------------------
// DBImpl
// ---------------------------------------------------------------------------

pub const DBImpl = struct {
    gpa: Allocator,
    io: Io,
    env: env_mod.Env,
    dbname: []u8,
    options: Options,
    internal_comparator: InternalKeyComparator,
    filter_policy_owned: ?filter_policy.FilterPolicy = null,
    table_options: table_builder.Options = undefined,
    table_cache: TableCache = undefined,
    versions: VersionSet = undefined,
    opened: bool = false,

    db_lock: ?env_mod.FileLock = null,
    mutex: Io.Mutex = .init,
    bg_cv: Io.Condition = .init,

    mem: ?*MemTable = null,
    imm: ?*MemTable = null,
    has_imm: std.atomic.Value(bool) = .init(false),

    logfile: ?env_mod.WritableFile = null,
    logfile_number: u64 = 0,
    log_writer: ?log.writer.Writer = null,

    writers: ArrayList(*Writer) = .empty,
    tmp_batch: ?*WriteBatch = null,
    snapshots: SnapshotList,

    pending_outputs: ArrayList(u64) = .empty,
    bg_error: ?Error = null,
    shutting_down: std.atomic.Value(bool) = .init(false),
    bg_future: ?Io.Future(void) = null,
    bg_scheduled: bool = false,
    single_threaded_fallback: bool = false,

    seed: u32 = 0,

    pub fn create(
        gpa: Allocator,
        io: Io,
        env: env_mod.Env,
        options: Options,
        dbname: []const u8,
    ) Error!*DBImpl {
        const self = try gpa.create(DBImpl);
        errdefer gpa.destroy(self);

        const name_copy = try gpa.dupe(u8, dbname);
        errdefer gpa.free(name_copy);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .env = env,
            .dbname = name_copy,
            .options = options,
            .internal_comparator = InternalKeyComparator.init(options.comparator),
            .snapshots = SnapshotList.init(gpa),
        };

        const tmp = try gpa.create(WriteBatch);
        errdefer gpa.destroy(tmp);
        tmp.* = try WriteBatch.init(gpa);
        self.tmp_batch = tmp;
        return self;
    }

    pub fn destroy(self: *DBImpl) void {
        const gpa = self.gpa;
        if (self.opened) self.versions.deinit();
        if (self.mem) |m| m.unref();
        if (self.imm) |m| m.unref();
        if (self.tmp_batch) |b| {
            b.deinit();
            gpa.destroy(b);
        }
        self.writers.deinit(gpa);
        self.pending_outputs.deinit(gpa);
        self.snapshots.deinit();
        if (self.filter_policy_owned) |p| filter_policy.destroyBloom(gpa, p);
        gpa.free(self.dbname);
        gpa.destroy(self);
    }

    pub fn open(self: *DBImpl) Error!void {
        const gpa = self.gpa;

        // A memtable's arena allocates in 4 KiB blocks, so the write buffer
        // must be comfortably larger than one block. Clamp like LevelDB does.
        self.options.write_buffer_size = std.math.clamp(
            self.options.write_buffer_size,
            64 * 1024,
            1 << 30,
        );
        const options = self.options;

        if (options.filter_bits_per_key) |bits| {
            self.filter_policy_owned = try filter_policy.createBloom(gpa, bits);
        }
        self.table_options = .{
            .block_size = options.block_size,
            .block_restart_interval = options.block_restart_interval,
            .comparator = self.internal_comparator.asComparator(),
            .filter_policy = self.filter_policy_owned,
        };
        self.table_cache = TableCache.init(gpa, self.env, self.dbname, .{
            .comparator = self.internal_comparator.asComparator(),
            .filter_policy = self.filter_policy_owned,
            .paranoid_checks = options.paranoid_checks,
        });
        self.versions = VersionSet.init(gpa, self.env, self.dbname, .{
            .max_file_size = options.max_file_size,
            .internal_comparator = self.internal_comparator,
            .paranoid_checks = options.paranoid_checks,
        }, &self.table_cache, self.table_options);
        self.opened = true;

        self.env.createDir(self.dbname) catch {};
        {
            const lock_name = try filename.lockFileName(gpa, self.dbname);
            defer gpa.free(lock_name);
            self.db_lock = try self.env.lockFile(gpa, lock_name);
        }

        var save_manifest = false;
        var edit = VersionEdit.init(gpa);
        defer edit.deinit();

        try self.recover(&edit, &save_manifest);

        if (self.mem == null) {
            const new_log_number = self.versions.newFileNumber();
            try self.newLogFile(new_log_number);
            edit.setLogNumber(new_log_number);
        }
        if (save_manifest) {
            edit.setPrevLogNumber(0);
            edit.setLogNumber(self.logfile_number);
            try self.versions.logAndApply(&edit);
        }

        self.mutex.lockUncancelable(self.io);
        self.removeObsoleteFiles();
        self.mutex.unlock(self.io);

        self.startBackgroundWorker();
    }

    pub fn close(self: *DBImpl) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        self.shutting_down.store(true, .release);
        self.bg_cv.broadcast(io);
        self.mutex.unlock(io);

        if (self.bg_future) |*f| {
            _ = f.await(io);
            self.bg_future = null;
        }

        if (self.log_writer) |*lw| lw.flush() catch {};
        if (self.logfile) |f| {
            f.close() catch {};
            f.deinit(self.gpa);
            self.logfile = null;
            self.log_writer = null;
        }
        if (self.db_lock) |lock| {
            self.env.unlockFile(lock, self.gpa);
            self.db_lock = null;
        }
    }

    // -- file / log helpers ------------------------------------------------

    fn newLogFile(self: *DBImpl, number: u64) Error!void {
        const gpa = self.gpa;
        const fname = try filename.logFileName(gpa, self.dbname, number);
        defer gpa.free(fname);

        const file = try self.env.newWritableFile(gpa, fname);
        if (self.logfile) |old| {
            old.close() catch {};
            old.deinit(gpa);
        }
        self.logfile = file;
        self.logfile_number = number;
        self.log_writer = log.writer.Writer.init(file, 0);

        const mem = try MemTable.create(gpa, self.internal_comparator);
        mem.ref();
        self.mem = mem;
    }

    /// Must be called with the mutex held.
    fn removeObsoleteFiles(self: *DBImpl) void {
        if (self.bg_error != null) return;
        const gpa = self.gpa;
        const io = self.io;

        var live = ArrayList(u64).empty;
        defer live.deinit(gpa);
        live.appendSlice(gpa, self.pending_outputs.items) catch return;
        self.versions.addLiveFiles(&live) catch return;

        const entries = self.env.listDir(gpa, self.dbname) catch return;

        self.mutex.unlock(io);
        for (entries) |name| {
            const parsed = filename.parseFileName(name) orelse continue;
            const keep = switch (parsed.type) {
                .log => parsed.number >= self.versions.logNumber() or parsed.number == self.versions.prevLogNumber(),
                .descriptor => parsed.number >= self.versions.manifestFileNumber(),
                .table => blk: {
                    for (live.items) |n| if (n == parsed.number) break :blk true;
                    self.table_cache.evict(parsed.number);
                    break :blk false;
                },
                .temp => blk: {
                    for (live.items) |n| if (n == parsed.number) break :blk true;
                    break :blk false;
                },
                .current, .lock, .info_log => true,
            };
            if (!keep) {
                const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.dbname, name }) catch continue;
                defer gpa.free(path);
                self.env.removeFile(path) catch {};
            }
        }
        env_mod.freeDirEntries(gpa, entries);
        self.mutex.lockUncancelable(io);
    }

    // -- recovery ----------------------------------------------------------

    /// Bring the DB back to a consistent state at open.
    ///
    /// Steps:
    ///   1. create the directory and take the LOCK,
    ///   2. if CURRENT is missing, create a fresh DB (or fail, depending on
    ///      `create_if_missing`),
    ///   3. replay the MANIFEST to rebuild the set of live files,
    ///   4. replay every log file that is not already reflected in the MANIFEST
    ///      (its writes were not yet flushed to a table),
    ///   5. record the highest sequence seen so new writes continue after it.
    ///
    /// `edit` collects the level-0 tables produced by log replay; the caller
    /// persists them with one `logAndApply`.
    fn recover(self: *DBImpl, edit: *VersionEdit, save_manifest: *bool) Error!void {
        const gpa = self.gpa;

        const current = try filename.currentFileName(gpa, self.dbname);
        defer gpa.free(current);

        if (!self.env.fileExists(current)) {
            if (!self.options.create_if_missing) return error.InvalidArgument;
            try self.newDB();
        } else if (self.options.error_if_exists) {
            return error.InvalidArgument;
        }

        try self.versions.recover(save_manifest);

        // The MANIFEST tells us which log file is current and which one it
        // replaced. Any log with a number at or above `min_log`, or equal to
        // `prev_log`, may hold writes not yet in a table.
        const min_log = self.versions.logNumber();
        const prev_log = self.versions.prevLogNumber();

        // Sanity check: every table the MANIFEST references must exist on disk.
        var expected = ArrayList(u64).empty;
        defer expected.deinit(gpa);
        try self.versions.addLiveFiles(&expected);

        const entries = try self.env.listDir(gpa, self.dbname);
        defer env_mod.freeDirEntries(gpa, entries);

        var logs = ArrayList(u64).empty;
        defer logs.deinit(gpa);

        for (entries) |name| {
            const parsed = filename.parseFileName(name) orelse continue;
            if (parsed.type == .table or parsed.type == .log or parsed.type == .temp) {
                for (expected.items, 0..) |n, i| {
                    if (n == parsed.number) {
                        _ = expected.swapRemove(i);
                        break;
                    }
                }
            }
            if (parsed.type == .log and (parsed.number >= min_log or parsed.number == prev_log)) {
                try logs.append(gpa, parsed.number);
            }
        }

        // Replay oldest log first so sequence numbers stay ordered.
        std.mem.sort(u64, logs.items, {}, std.sort.asc(u64));

        var max_sequence: SequenceNumber = 0;
        for (logs.items) |log_number| {
            try self.recoverLogFile(log_number, edit, &max_sequence);
            // The previous incarnation may not have recorded this log in the
            // MANIFEST, so make sure its number is never reused.
            self.versions.markFileNumberUsed(log_number);
        }

        if (self.versions.lastSequence() < max_sequence) {
            self.versions.setLastSequence(max_sequence);
        }
    }

    /// Replay one log file: read its write batches into a memtable and flush
    /// full memtables to level-0 tables, recording each in `edit`.
    fn recoverLogFile(
        self: *DBImpl,
        log_number: u64,
        edit: *VersionEdit,
        max_sequence: *SequenceNumber,
    ) Error!void {
        const gpa = self.gpa;
        const fname = try filename.logFileName(gpa, self.dbname, log_number);
        defer gpa.free(fname);

        const file = self.env.newSequentialFile(gpa, fname) catch |e| {
            if (e == error.NotFound) return;
            return e;
        };
        defer file.deinit(gpa);

        // Checksums are always verified during recovery, even when
        // paranoid_checks is off, so a corrupt record cannot inject a bogus
        // sequence number into the DB.
        var reader = try log.reader.Reader.init(gpa, file, null, true, 0);
        defer reader.deinit();

        var mem: ?*MemTable = null;
        defer if (mem) |m| m.unref();

        while (try reader.readRecord()) |record| {
            if (record.len < write_batch_mod.header_size) continue;

            // The record is exactly the bytes of a WriteBatch, so wrap it and
            // apply it.
            var batch = try WriteBatch.init(gpa);
            defer batch.deinit();
            batch.rep.clearRetainingCapacity();
            try batch.rep.appendSlice(gpa, record);

            if (mem == null) {
                mem = try MemTable.create(gpa, self.internal_comparator);
                mem.?.ref();
            }
            try batch.insertInto(mem.?);

            // Track the highest sequence so the DB resumes after it.
            const batch_end = batch.sequence() + batch.count();
            if (batch_end > max_sequence.*) max_sequence.* = batch_end - 1;

            // Flush when the recovered memtable gets large, so a huge log does
            // not have to fit in memory all at once.
            if (mem.?.approximateMemoryUsage() > self.options.write_buffer_size) {
                var meta = FileMetaData{ .number = self.versions.newFileNumber() };
                defer meta.deinit(gpa);
                try self.writeLevel0Table(mem.?, edit, null, &meta);
                mem.?.unref();
                mem = null;
            }
        }

        // Flush whatever is left.
        if (mem) |m| {
            var meta = FileMetaData{ .number = self.versions.newFileNumber() };
            defer meta.deinit(gpa);
            try self.writeLevel0Table(m, edit, null, &meta);
            mem.?.unref();
            mem = null;
        }
    }

    fn newDB(self: *DBImpl) Error!void {
        const gpa = self.gpa;
        var edit = VersionEdit.init(gpa);
        defer edit.deinit();

        try edit.setComparatorName(self.internal_comparator.name());
        edit.setLogNumber(0);
        edit.setNextFile(2);
        edit.setLastSequence(0);

        var record = ArrayList(u8).empty;
        defer record.deinit(gpa);
        try edit.encodeTo(&record);

        const mf = try filename.descriptorFileName(gpa, self.dbname, 1);
        defer gpa.free(mf);
        const file = try self.env.newWritableFile(gpa, mf);
        defer file.deinit(gpa);
        var writer = log.writer.Writer.init(file, 0);
        try writer.addRecord(record.items);
        try file.sync();
        try file.close();

        try filename.setCurrentFile(self.env, gpa, self.dbname, 1);
    }

    // -- write path --------------------------------------------------------

    /// Ensure the active memtable has room for a write, rotating it if not.
    /// Must be called with the mutex held.
    ///
    /// This is also where write back-pressure lives. If level 0 is getting
    /// crowded we slow writers down; if it is critically full we stop them until
    /// the background worker catches up. Both cases wait on `bg_cv`, which the
    /// worker broadcasts when it finishes.
    fn makeRoomForWrite(self: *DBImpl, force_in: bool) Error!void {
        const io = self.io;
        var force = force_in;
        var allow_delay = !force;
        while (true) {
            if (self.bg_error) |e| return e;

            // Soft limit: add a tiny delay to throttle the writer.
            if (allow_delay and self.versions.numLevelFiles(0) >= version_set.kL0_SlowdownWritesTrigger) {
                self.mutex.unlock(io);
                self.env.sleepMicros(1000);
                self.mutex.lockUncancelable(io);
                allow_delay = false;
                continue;
            }

            if (!force and self.mem.?.approximateMemoryUsage() <= self.options.write_buffer_size) {
                return; // room available
            }

            // An immutable memtable is still waiting to be flushed: wait.
            if (self.imm != null) {
                self.bg_cv.waitUncancelable(io, &self.mutex);
                continue;
            }

            // Hard limit: level 0 is critically full, so stop writes entirely.
            if (self.versions.numLevelFiles(0) >= version_set.kL0_StopWritesTrigger) {
                self.bg_cv.waitUncancelable(io, &self.mutex);
                continue;
            }

            // Rotate: install a new log and memtable, retire the old memtable.
            //
            // Ordering matters: the new log file must exist *before* the old
            // memtable becomes immutable, or a crash could leave acknowledged
            // writes with no log to recover them from.
            const new_log_number = self.versions.newFileNumber();
            const fname = try filename.logFileName(self.gpa, self.dbname, new_log_number);
            defer self.gpa.free(fname);

            const lfile = self.env.newWritableFile(self.gpa, fname) catch |e| {
                self.versions.reuseFileNumber(new_log_number);
                return e;
            };

            if (self.logfile) |old| {
                old.close() catch {};
                old.deinit(self.gpa);
            }
            self.logfile = lfile;
            self.logfile_number = new_log_number;
            self.log_writer = log.writer.Writer.init(lfile, 0);

            // The old memtable becomes immutable; the worker will flush it.
            self.imm = self.mem;
            self.has_imm.store(true, .release);
            const new_mem = try MemTable.create(self.gpa, self.internal_comparator);
            new_mem.ref();
            self.mem = new_mem;
            force = false;

            self.maybeScheduleCompaction();
            if (self.single_threaded_fallback) {
                // No worker: flush the immutable memtable right here.
                try self.compactMemTable();
            }
        }
    }

    /// Apply a batch atomically.
    ///
    /// Writers form a queue. Only the writer at the head does I/O; the others
    /// wait on their own condition variable. When the head runs, it may merge
    /// several waiting batches into one log append (group commit), which turns
    /// N fsyncs into one under load.
    ///
    /// The mutex is released while appending to the log and inserting into the
    /// memtable, so other threads can read. Correctness relies on the head
    /// writer staying the head for the whole operation.
    pub fn write(self: *DBImpl, batch: *WriteBatch, opts: WriteOptions) Error!void {
        const io = self.io;
        var w = Writer{ .batch = batch, .sync = opts.sync };

        self.mutex.lockUncancelable(io);
        self.writers.append(self.gpa, &w) catch |e| {
            self.mutex.unlock(io);
            return e;
        };
        // Wait until we are the head writer, or until someone else completes us
        // by folding our batch into their group.
        while (!w.done and self.writers.items[0] != &w) {
            w.cv.waitUncancelable(io, &self.mutex);
        }
        if (w.done) {
            self.mutex.unlock(io);
            if (w.status) |e| return e;
            return;
        }

        // We are the head writer and hold the mutex.
        var status: ?Error = null;
        self.makeRoomForWrite(false) catch |e| {
            status = e;
        };
        var last_sequence = self.versions.lastSequence();
        var last_writer: *Writer = &w;

        if (status == null) {
            // Pick up any batches that arrived while we were waiting. Sequence
            // numbers are assigned here, before the lock is dropped, so writes
            // are ordered by the log.
            const write_batch = try self.buildBatchGroup(&last_writer);
            write_batch.setSequence(last_sequence + 1);
            last_sequence += write_batch.count();

            self.mutex.unlock(io);

            // Log first, then memtable. A write is only durable once the log
            // append (and optional fsync) succeeds.
            var log_ok = self.log_writer != null;
            if (self.log_writer) |*lw| {
                lw.addRecord(write_batch.contents()) catch {
                    log_ok = false;
                };
                if (log_ok and opts.sync) {
                    self.logfile.?.sync() catch {
                        log_ok = false;
                    };
                }
            }

            if (log_ok) {
                write_batch.insertInto(self.mem.?) catch |e| {
                    status = e;
                };
            }

            self.mutex.lockUncancelable(io);

            if (!log_ok) {
                // The log's contents are now unknown; refuse all future writes
                // rather than risk returning data that was never persisted.
                self.recordBackgroundError(error.IoError);
                status = error.IoError;
            }
            if (write_batch == self.tmp_batch.?) self.tmp_batch.?.clear();
            self.versions.setLastSequence(last_sequence);
        }

        // Wake everyone whose batch we just wrote (all of them share our
        // status), then wake the new head.
        while (true) {
            const ready = self.writers.items[0];
            _ = self.writers.orderedRemove(0);
            if (ready != &w) {
                ready.status = status;
                ready.done = true;
                ready.cv.signal(io);
            }
            if (ready == last_writer) break;
        }
        if (self.writers.items.len > 0) {
            self.writers.items[0].cv.signal(io);
        }
        self.mutex.unlock(io);

        if (status) |e| return e;
    }

    /// Collect the head writer's batch plus as many following batches as fit.
    /// Must be called with the mutex held.
    ///
    /// Rules: never merge a sync write behind a non-sync write (it would lose
    /// its durability guarantee), and cap the group at ~1 MiB. The first batch
    /// is only copied into `tmp_batch` once a second batch joins, so the common
    /// single-writer case allocates nothing.
    fn buildBatchGroup(self: *DBImpl, last_writer: **Writer) Error!*WriteBatch {
        const first = self.writers.items[0];
        var result: *WriteBatch = first.batch.?;
        var size = first.batch.?.byteSize();

        var max_size: usize = 1 << 20;
        if (size <= (128 << 10)) max_size = size + (128 << 10);

        var i: usize = 1;
        while (i < self.writers.items.len) : (i += 1) {
            const w = self.writers.items[i];
            if (w.sync and !first.sync) break;
            if (w.batch) |b| {
                const bsize = b.byteSize();
                if (result == first.batch.?) {
                    if (size + bsize > max_size) break;
                    self.tmp_batch.?.clear();
                    try self.tmp_batch.?.append(first.batch.?);
                    result = self.tmp_batch.?;
                }
                try result.append(b);
                size += bsize;
                if (size > max_size) break;
            }
            last_writer.* = w;
        }
        return result;
    }

    // -- read path ---------------------------------------------------------

    pub fn get(self: *DBImpl, key: []const u8, opts: ReadOptions, out: *ArrayList(u8)) Error!void {
        const gpa = self.gpa;
        const io = self.io;

        self.mutex.lockUncancelable(io);
        const snapshot_seq = if (opts.snapshot) |s| s.sequence else self.versions.lastSequence();
        const mem = self.mem.?;
        mem.ref();
        const imm = self.imm;
        if (imm) |m| m.ref();
        const version = self.versions.currentVersion();
        version.ref();
        self.mutex.unlock(io);

        // Every path below funnels into `result`, so the references taken above
        // are always released, even on error.
        var result: Error!void = {};

        var lkey = internal_key.LookupKey.init(gpa, key, snapshot_seq) catch |e| {
            self.releaseRefs(mem, imm, version);
            return e;
        };
        defer lkey.deinit(gpa);

        switch (mem.get(&lkey)) {
            .found => |v| {
                out.clearRetainingCapacity();
                out.appendSlice(gpa, v) catch |e| {
                    result = e;
                };
            },
            .deleted => result = error.NotFound,
            .not_found => {
                var handled = false;
                if (imm) |m| {
                    switch (m.get(&lkey)) {
                        .found => |v| {
                            out.clearRetainingCapacity();
                            out.appendSlice(gpa, v) catch |e| {
                                result = e;
                            };
                            handled = true;
                        },
                        .deleted => {
                            result = error.NotFound;
                            handled = true;
                        },
                        .not_found => {},
                    }
                }
                if (!handled) {
                    var stats = version_set.GetStats{};
                    version.get(.{ .verify_checksums = opts.verify_checksums }, &lkey, out, &stats) catch |e| {
                        result = e;
                    };
                    self.mutex.lockUncancelable(io);
                    if (version.updateStats(stats)) self.maybeScheduleCompaction();
                    self.mutex.unlock(io);
                }
            },
        }
        self.releaseRefs(mem, imm, version);
        return result;
    }

    fn releaseRefs(self: *DBImpl, mem: *MemTable, imm: ?*MemTable, version: *Version) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        version.unref();
        if (imm) |m| m.unref();
        mem.unref();
        self.mutex.unlock(io);
    }

    pub fn newIterator(self: *DBImpl, opts: ReadOptions) Error!Iterator {
        const gpa = self.gpa;
        const io = self.io;

        self.mutex.lockUncancelable(io);
        const mem = self.mem.?;
        mem.ref();
        const imm = self.imm;
        if (imm) |m| m.ref();
        const version = self.versions.currentVersion();
        version.ref();
        const latest_snapshot = self.versions.lastSequence();
        const seq = if (opts.snapshot) |s| s.sequence else latest_snapshot;
        self.seed +%= 1;
        const seed = self.seed;
        self.mutex.unlock(io);

        const children = self.collectChildren(gpa, mem, imm, version, opts) catch |e| {
            self.releaseRefs(mem, imm, version);
            return e;
        };

        const merged = merger.create(gpa, self.internal_comparator.asComparator(), children) catch |e| {
            for (children) |it| it.deinit(gpa);
            gpa.free(children);
            self.releaseRefs(mem, imm, version);
            return e;
        };

        const inner = db_iter.create(gpa, self.internal_comparator.user, merged, seq, seed, null) catch |e| {
            merged.deinit(gpa);
            self.releaseRefs(mem, imm, version);
            return e;
        };

        return CleanupIterator.create(gpa, self, inner, mem, imm, version) catch |e| {
            inner.deinit(gpa);
            self.releaseRefs(mem, imm, version);
            return e;
        };
    }

    fn collectChildren(
        self: *DBImpl,
        gpa: Allocator,
        mem: *MemTable,
        imm: ?*MemTable,
        version: *Version,
        opts: ReadOptions,
    ) Error![]Iterator {
        _ = self;
        var list = ArrayList(Iterator).empty;
        errdefer {
            for (list.items) |it| it.deinit(gpa);
            list.deinit(gpa);
        }
        try list.append(gpa, try mem.asIterator(gpa));
        if (imm) |m| try list.append(gpa, try m.asIterator(gpa));
        try version.addIterators(.{
            .verify_checksums = opts.verify_checksums,
            .fill_cache = opts.fill_cache,
        }, &list);
        return list.toOwnedSlice(gpa);
    }

    pub fn getSnapshot(self: *DBImpl) Error!*Snapshot {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return try self.snapshots.new(self.versions.lastSequence());
    }

    pub fn releaseSnapshot(self: *DBImpl, snapshot: *Snapshot) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.snapshots.delete(snapshot);
    }

    // -- compaction --------------------------------------------------------

    fn maybeScheduleCompaction(self: *DBImpl) void {
        if (self.shutting_down.load(.acquire)) return;
        if (self.bg_error != null) return;
        if (self.single_threaded_fallback) return;
        self.bg_cv.signal(self.io);
    }

    fn needsBackgroundWork(self: *DBImpl) bool {
        return self.imm != null or self.versions.needsCompaction();
    }

    fn startBackgroundWorker(self: *DBImpl) void {
        if (self.options.disable_background_thread) {
            self.single_threaded_fallback = true;
            return;
        }
        self.bg_future = self.io.concurrent(backgroundWorker, .{self}) catch {
            self.single_threaded_fallback = true;
            return;
        };
    }

    fn backgroundWorker(self: *DBImpl) void {
        const io = self.io;
        while (true) {
            self.mutex.lockUncancelable(io);
            while (!self.shutting_down.load(.acquire) and !self.needsBackgroundWork()) {
                self.bg_cv.waitUncancelable(io, &self.mutex);
            }
            if (self.shutting_down.load(.acquire)) {
                self.mutex.unlock(io);
                return;
            }
            self.bg_scheduled = true;
            self.mutex.unlock(io);

            self.backgroundCompaction();

            self.mutex.lockUncancelable(io);
            self.bg_scheduled = false;
            self.bg_cv.broadcast(io);
            self.mutex.unlock(io);
        }
    }

    fn backgroundCompaction(self: *DBImpl) void {
        if (self.imm != null) {
            self.mutex.lockUncancelable(self.io);
            self.compactMemTable() catch |e| self.recordBackgroundError(e);
            self.mutex.unlock(self.io);
            return;
        }

        const c = self.versions.pickCompaction() catch |e| {
            self.recordBackgroundError(e);
            return;
        };
        const compaction = c orelse return;

        if (compaction.isTrivialMove()) {
            const f = compaction.input(0, 0);
            compaction.addInputDeletions(&compaction.edit) catch |e| {
                compaction.deinit();
                self.recordBackgroundError(e);
                return;
            };
            compaction.edit.addFile(
                compaction.level() + 1,
                f.number,
                f.file_size,
                f.smallest.items,
                f.largest.items,
            ) catch |e| {
                compaction.deinit();
                self.recordBackgroundError(e);
                return;
            };
            self.mutex.lockUncancelable(self.io);
            self.versions.logAndApply(&compaction.edit) catch |e| {
                self.mutex.unlock(self.io);
                compaction.deinit();
                self.recordBackgroundError(e);
                return;
            };
            self.mutex.unlock(self.io);
            compaction.deinit();
            return;
        }

        self.doCompactionWork(compaction) catch |e| self.recordBackgroundError(e);
        compaction.deinit();

        self.mutex.lockUncancelable(self.io);
        self.removeObsoleteFiles();
        self.mutex.unlock(self.io);
    }

    /// Must be called with the mutex held.
    fn compactMemTable(self: *DBImpl) Error!void {
        std.debug.assert(self.imm != null);
        const gpa = self.gpa;
        const mem = self.imm.?;

        const base = self.versions.currentVersion();
        base.ref();
        defer base.unref();

        var edit = VersionEdit.init(gpa);
        defer edit.deinit();

        var meta = FileMetaData{ .number = self.versions.newFileNumber() };
        defer meta.deinit(gpa);

        self.mutex.unlock(self.io);
        const build_result = self.writeLevel0Table(mem, &edit, base, &meta);
        self.mutex.lockUncancelable(self.io);
        try build_result;

        if (self.shutting_down.load(.acquire)) return error.IoError;

        edit.setPrevLogNumber(0);
        edit.setLogNumber(self.logfile_number);
        try self.versions.logAndApply(&edit);

        mem.unref();
        self.imm = null;
        self.has_imm.store(false, .release);
        self.removeObsoleteFiles();
    }

    /// Acquires the mutex itself and releases it before returning, so callers
    /// may invoke it with or without the lock held (like the C++ version).
    fn writeLevel0Table(
        self: *DBImpl,
        mem: *MemTable,
        edit: *VersionEdit,
        base: ?*Version,
        meta: *FileMetaData,
    ) Error!void {
        const gpa = self.gpa;
        const io = self.io;

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        try self.pending_outputs.append(gpa, meta.number);

        const iter = try mem.asIterator(gpa);
        defer iter.deinit(gpa);

        self.mutex.unlock(io);
        const result = builder.buildTable(
            self.env,
            gpa,
            self.dbname,
            &self.table_cache,
            self.table_options,
            iter,
            meta,
        );
        self.mutex.lockUncancelable(io);

        for (self.pending_outputs.items, 0..) |n, i| {
            if (n == meta.number) {
                _ = self.pending_outputs.swapRemove(i);
                break;
            }
        }

        try result;

        if (meta.file_size > 0) {
            const level: u32 = if (base) |b|
                @intCast(b.pickLevelForMemTableOutput(
                    internal_key.extractUserKey(meta.smallest.items),
                    internal_key.extractUserKey(meta.largest.items),
                ))
            else
                0;
            try edit.addFile(level, meta.number, meta.file_size, meta.smallest.items, meta.largest.items);
        }
    }

    const Output = struct {
        number: u64 = 0,
        file_size: u64 = 0,
        smallest: ArrayList(u8) = .empty,
        largest: ArrayList(u8) = .empty,
        fn deinit(self: *Output, gpa: Allocator) void {
            self.smallest.deinit(gpa);
            self.largest.deinit(gpa);
        }
    };

    const CompactionState = struct {
        outputs: ArrayList(Output) = .empty,
        file: ?env_mod.WritableFile = null,
        builder: ?table_builder.TableBuilder = null,

        fn deinit(self: *CompactionState, gpa: Allocator) void {
            for (self.outputs.items) |*o| o.deinit(gpa);
            self.outputs.deinit(gpa);
            if (self.builder) |*b| b.deinit();
            if (self.file) |f| f.deinit(gpa);
        }
    };

    fn openCompactionOutputFile(self: *DBImpl, compact: *CompactionState) Error!void {
        const gpa = self.gpa;
        const io = self.io;

        self.mutex.lockUncancelable(io);
        const number = self.versions.newFileNumber();
        self.pending_outputs.append(gpa, number) catch |e| {
            self.mutex.unlock(io);
            return e;
        };
        self.mutex.unlock(io);

        const fname = try filename.tableFileName(gpa, self.dbname, number);
        defer gpa.free(fname);
        const file = try self.env.newWritableFile(gpa, fname);

        compact.file = file;
        compact.builder = try table_builder.TableBuilder.init(gpa, self.table_options, file);
        try compact.outputs.append(gpa, .{ .number = number });
    }

    fn finishCompactionOutputFile(self: *DBImpl, compact: *CompactionState) Error!void {
        const gpa = self.gpa;
        const io = self.io;
        std.debug.assert(compact.builder != null);

        const out = &compact.outputs.items[compact.outputs.items.len - 1];
        try compact.builder.?.finish();
        out.file_size = compact.builder.?.fileSize();
        compact.builder.?.deinit();
        compact.builder = null;

        try compact.file.?.sync();
        try compact.file.?.close();
        compact.file.?.deinit(gpa);
        compact.file = null;

        self.mutex.lockUncancelable(io);
        for (self.pending_outputs.items, 0..) |n, i| {
            if (n == out.number) {
                _ = self.pending_outputs.swapRemove(i);
                break;
            }
        }
        self.mutex.unlock(io);
    }

    /// Merge a compaction's inputs into new files one level down.
    ///
    /// The inputs are already sorted and merged by `makeInputIterator`, so this
    /// is a single ascending pass. For each entry it decides whether the entry
    /// is still needed (see the drop rules below) and, if so, appends it to the
    /// current output file, starting a new file when the current one is large
    /// enough or would overlap too much of the next level.
    fn doCompactionWork(self: *DBImpl, c: *Compaction) Error!void {
        const gpa = self.gpa;
        const io = self.io;
        const ucmp = self.internal_comparator.user;

        // The oldest snapshot that must still be able to read. Entries at or
        // below this sequence may be dropped when a newer entry supersedes them;
        // anything above it is newer than every reader and must be preserved.
        const smallest_snapshot = if (self.snapshots.isEmpty())
            self.versions.lastSequence()
        else
            self.snapshots.oldest().?;

        const input = try self.versions.makeInputIterator(c);
        defer input.deinit(gpa);

        var compact = CompactionState{};
        defer compact.deinit(gpa);

        // Own the current user key: the slice returned by the input iterator can
        // be invalidated when its block is released on advance.
        var current_user_key = ArrayList(u8).empty;
        defer current_user_key.deinit(gpa);
        var has_current_user_key = false;
        var last_sequence_for_key: SequenceNumber = internal_key.max_sequence_number;

        input.seekToFirst();
        while (input.valid()) {
            if (self.shutting_down.load(.acquire)) return error.IoError;

            if (self.imm != null) {
                self.mutex.lockUncancelable(io);
                if (self.imm != null) self.compactMemTable() catch {};
                self.mutex.unlock(io);
            }

            const ikey = input.key();
            const parsed = internal_key.parseInternalKey(ikey);

            const user_key = if (parsed) |p| p.user_key else &.{};
            const user_key_changed = parsed == null or !has_current_user_key or
                ucmp.compare(user_key, current_user_key.items) != 0;

            if (user_key_changed and parsed != null) {
                current_user_key.clearRetainingCapacity();
                try current_user_key.appendSlice(gpa, user_key);
                has_current_user_key = true;
                last_sequence_for_key = internal_key.max_sequence_number;
            }

            // Only split output files between user keys, so a key's versions
            // never straddle two files.
            if (compact.builder != null and user_key_changed and c.shouldStopBefore(ikey)) {
                try self.finishCompactionOutputFile(&compact);
            }

            // Decide whether this entry is still needed. Two rules:
            //
            //   A. If we have already passed a newer version of the same user
            //      key at or below the smallest snapshot, this older version is
            //      hidden from every reader and can go.
            //   B. A tombstone can go once it is at or below the smallest
            //      snapshot and nothing in a deeper level could still be hidden
            //      by it (`isBaseLevelForKey`). If deeper data exists, the
            //      tombstone must stay to keep hiding it.
            //
            // Both rules are snapshot-safe: they never drop something a live
            // snapshot still needs.
            var drop = false;
            if (parsed) |p| {
                // Rule A: a newer entry for this key hides this one.
                if (last_sequence_for_key <= smallest_snapshot) drop = true;
                // Rule B: a tombstone below the snapshot and above any deeper data.
                if (p.type == .deletion and p.sequence <= smallest_snapshot and c.isBaseLevelForKey(p.user_key)) {
                    drop = true;
                }
                last_sequence_for_key = p.sequence;
            }

            if (!drop) {
                if (compact.builder == null) {
                    try self.openCompactionOutputFile(&compact);
                    const out = &compact.outputs.items[compact.outputs.items.len - 1];
                    out.smallest.clearRetainingCapacity();
                    try out.smallest.appendSlice(gpa, ikey);
                }
                const out = &compact.outputs.items[compact.outputs.items.len - 1];
                out.largest.clearRetainingCapacity();
                try out.largest.appendSlice(gpa, ikey);
                try compact.builder.?.add(ikey, input.value());
                if (compact.builder.?.fileSize() >= c.maxOutputFileSize()) {
                    try self.finishCompactionOutputFile(&compact);
                }
            }

            input.next();
        }

        if (compact.builder != null) try self.finishCompactionOutputFile(&compact);

        if (self.shutting_down.load(.acquire)) return error.IoError;

        try c.addInputDeletions(&c.edit);
        for (compact.outputs.items) |out| {
            try c.edit.addFile(c.level() + 1, out.number, out.file_size, out.smallest.items, out.largest.items);
        }

        self.mutex.lockUncancelable(io);
        self.versions.logAndApply(&c.edit) catch |e| {
            self.mutex.unlock(io);
            return e;
        };
        self.mutex.unlock(io);
    }

    /// Compact an explicit key range (or the whole DB when both are null),
    /// synchronously. Used by the public `CompactRange` and the CLI.
    ///
    /// It pushes files down one level at a time, from level 0 to the last, so a
    /// key ends up as deep as its range allows. This is a simple full-compaction
    /// strategy rather than LevelDB's background scheduling.
    pub fn compactRange(self: *DBImpl, begin: ?[]const u8, end: ?[]const u8) Error!void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // Wait for any in-flight memtable flush to finish.
        while (self.imm != null) {
            self.bg_cv.waitUncancelable(io, &self.mutex);
        }

        var level: u32 = 0;
        while (level + 1 < version_set.kNumLevels) : (level += 1) {
            // Repeat until this level has no more files in range. `guard` is a
            // safety net against a pathological loop.
            var guard: usize = 0;
            while (guard < 1000) : (guard += 1) {
                const c = try self.versions.compactRange(level, begin, end);
                const compaction = c orelse break;
                // Do the I/O without the lock so writers are not blocked.
                self.mutex.unlock(io);
                self.doCompactionWork(compaction) catch |e| {
                    self.mutex.lockUncancelable(io);
                    compaction.deinit();
                    return e;
                };
                self.mutex.lockUncancelable(io);
                compaction.deinit();
                self.removeObsoleteFiles();
            }
        }
    }

    fn recordBackgroundError(self: *DBImpl, err: Error) void {
        if (self.bg_error == null) {
            self.bg_error = err;
            self.bg_cv.broadcast(self.io);
        }
    }
};

// ---------------------------------------------------------------------------
// CleanupIterator: owns table/memtable/version references for an iterator
// ---------------------------------------------------------------------------

const CleanupIterator = struct {
    gpa: Allocator,
    db: *DBImpl,
    inner: Iterator,
    mem: *MemTable,
    imm: ?*MemTable,
    version: *Version,

    fn create(
        gpa: Allocator,
        db: *DBImpl,
        inner: Iterator,
        mem: *MemTable,
        imm: ?*MemTable,
        version: *Version,
    ) !Iterator {
        const self = try gpa.create(CleanupIterator);
        self.* = .{ .gpa = gpa, .db = db, .inner = inner, .mem = mem, .imm = imm, .version = version };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ctx: *anyopaque) *CleanupIterator {
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
    fn statusFn(ctx: *anyopaque) iter_mod.IteratorError!void {
        return cast(ctx).inner.status();
    }
    fn deinitFn(ctx: *anyopaque, gpa: Allocator) void {
        const self = cast(ctx);
        self.inner.deinit(gpa);
        self.db.releaseRefs(self.mem, self.imm, self.version);
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
const mem_env = @import("mem_env.zig");

fn openTestDb(gpa: Allocator, env: env_mod.Env, name: []const u8, opts: Options) !*DBImpl {
    const impl = try DBImpl.create(gpa, testing.io, env, opts, name);
    errdefer impl.destroy();
    try impl.open();
    return impl;
}

fn putKey(impl: *DBImpl, key: []const u8, val: []const u8) !void {
    var batch = try WriteBatch.init(impl.gpa);
    defer batch.deinit();
    try batch.put(key, val);
    try impl.write(&batch, .{});
}

fn delKey(impl: *DBImpl, key: []const u8) !void {
    var batch = try WriteBatch.init(impl.gpa);
    defer batch.deinit();
    try batch.delete(key);
    try impl.write(&batch, .{});
}

test "db put, get, delete, reopen" {
    const gpa = testing.allocator;
    const mem = try mem_env.MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();

    const opts = Options{ .create_if_missing = true, .write_buffer_size = 64 * 1024, .disable_background_thread = true };

    var value = ArrayList(u8).empty;
    defer value.deinit(gpa);

    {
        const impl = try openTestDb(gpa, env, "db", opts);
        defer impl.destroy();
        try putKey(impl, "alpha", "one");
        try putKey(impl, "beta", "two");

        try impl.get("alpha", .{}, &value);
        try testing.expectEqualStrings("one", value.items);

        try delKey(impl, "alpha");
        try testing.expectError(error.NotFound, impl.get("alpha", .{}, &value));

        impl.close();
    }

    {
        const impl = try openTestDb(gpa, env, "db", opts);
        defer impl.destroy();
        try impl.get("beta", .{}, &value);
        try testing.expectEqualStrings("two", value.items);
        try testing.expectError(error.NotFound, impl.get("alpha", .{}, &value));
        impl.close();
    }
}

test "db iterator merges memtable and tables" {
    const gpa = testing.allocator;
    const mem = try mem_env.MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();

    const opts = Options{ .create_if_missing = true, .write_buffer_size = 64 * 1024, .disable_background_thread = true };

    const impl = try openTestDb(gpa, env, "db", opts);
    defer impl.destroy();

    var kb: [16]u8 = undefined;
    var vb: [16]u8 = undefined;
    for (0..5000) |i| {
        const k = try std.fmt.bufPrint(&kb, "key-{d:0>4}", .{i});
        const v = try std.fmt.bufPrint(&vb, "val-{d}", .{i});
        try putKey(impl, k, v);
    }

    const it = try impl.newIterator(.{});
    defer it.deinit(gpa);

    var count: usize = 0;
    it.seekToFirst();
    while (it.valid()) : (it.next()) count += 1;
    try testing.expectEqual(@as(usize, 5000), count);

    it.seekToLast();
    var reverse_count: usize = 0;
    while (it.valid()) : (it.prev()) reverse_count += 1;
    try testing.expectEqual(@as(usize, 5000), reverse_count);

    impl.close();
}

test "delete survives compaction and reopen" {
    const gpa = testing.allocator;
    const mem = try mem_env.MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();

    const opts = Options{
        .create_if_missing = true,
        .write_buffer_size = 64 * 1024,
        .disable_background_thread = true,
    };

    var value = ArrayList(u8).empty;
    defer value.deinit(gpa);

    {
        const impl = try openTestDb(gpa, env, "db", opts);
        defer impl.destroy();
        try putKey(impl, "keep", "1");
        try putKey(impl, "drop", "2");
        try delKey(impl, "drop");
        try impl.compactRange(null, null);
        try testing.expectError(error.NotFound, impl.get("drop", .{}, &value));
        try impl.get("keep", .{}, &value);
        try testing.expectEqualStrings("1", value.items);
        impl.close();
    }

    {
        const impl = try openTestDb(gpa, env, "db", opts);
        defer impl.destroy();
        try testing.expectError(error.NotFound, impl.get("drop", .{}, &value));
        try impl.get("keep", .{}, &value);
        try testing.expectEqualStrings("1", value.items);
        impl.close();
    }
}
