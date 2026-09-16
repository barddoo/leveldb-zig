//! Versions, compaction selection, and the MANIFEST, from
//! `db/version_set.{h,cc}`.
//!
//! A `Version` is an immutable snapshot of which table files exist at each
//! level. `VersionSet` owns the current version, allocates file numbers, and
//! persists changes by appending `VersionEdit` records to the MANIFEST.
//!
//! Compaction picks a level that is over its size budget (or a file whose seek
//! budget ran out), merges the chosen files with the overlapping files one level
//! down, and writes new files one level down.
//!
//! Simplifications vs. C++, all behavior-preserving:
//!   * Versions are tracked in an array instead of a circular list.
//!   * `AddIterators` opens one table iterator per file (no lazy concatenating
//!     iterator); the caller merges them.
//!   * Compaction does not grow its inputs or pull in boundary files; the
//!     compaction loop avoids splitting a user key across output files, which
//!     is what boundary files exist to guard against.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const env_mod = @import("env.zig");
const Error = env_mod.Error;
const internal_key = @import("internal_key.zig");
const version_edit = @import("version_edit.zig");
const FileMetaData = version_edit.FileMetaData;
const VersionEdit = version_edit.VersionEdit;
const filename = @import("filename.zig");
const log = @import("../log/log.zig");
const comparator = @import("../primitives/comparator.zig");
const coding = @import("../primitives/coding.zig");
const iter_mod = @import("../iter/iterator.zig");
const Iterator = iter_mod.Iterator;
const merger = @import("../iter/merger.zig");
const format = @import("../table/format.zig");
const ReadOptions = format.ReadOptions;
const table_builder = @import("../table/table_builder.zig");
const TableCache = @import("table_cache.zig").TableCache;

const InternalKeyComparator = internal_key.InternalKeyComparator;
const SequenceNumber = internal_key.SequenceNumber;

pub const kNumLevels = 7;
pub const kL0_CompactionTrigger = 4;
pub const kL0_SlowdownWritesTrigger = 8;
pub const kL0_StopWritesTrigger = 12;
pub const kMaxMemCompactLevel = 2;

pub const Config = struct {
    max_file_size: usize = 2 << 20,
    internal_comparator: InternalKeyComparator,
    paranoid_checks: bool = false,
};

fn targetFileSize(cfg: Config) u64 {
    return cfg.max_file_size;
}

fn maxGrandParentOverlapBytes(cfg: Config) u64 {
    return 10 * targetFileSize(cfg);
}

fn maxBytesForLevel(level: usize) u64 {
    // Level 1 holds 10 MiB; each subsequent level holds 10x more.
    var result: u64 = 10 * 1024 * 1024;
    var l = level;
    while (l > 1) : (l -= 1) result *= 10;
    return result;
}

fn totalFileSize(files: []const *FileMetaData) u64 {
    var sum: u64 = 0;
    for (files) |f| sum += f.file_size;
    return sum;
}

fn newestFirst(_: void, a: *FileMetaData, b: *FileMetaData) bool {
    return a.number > b.number;
}

fn fileLessThan(icmp: InternalKeyComparator, a: *FileMetaData, b: *FileMetaData) bool {
    const c = icmp.compare(a.smallest.items, b.smallest.items);
    if (c != 0) return c < 0;
    return a.number < b.number;
}

fn afterFile(ucmp: comparator.Comparator, user_key: ?[]const u8, f: *FileMetaData) bool {
    const k = user_key orelse return false;
    return ucmp.compare(k, internal_key.extractUserKey(f.smallest.items)) > 0;
}

fn beforeFile(ucmp: comparator.Comparator, user_key: ?[]const u8, f: *FileMetaData) bool {
    const k = user_key orelse return false;
    return ucmp.compare(k, internal_key.extractUserKey(f.largest.items)) < 0;
}

/// Index of the first file whose largest key is >= `key`.
fn findFile(icmp: InternalKeyComparator, files: []const *FileMetaData, key: []const u8) usize {
    var left: usize = 0;
    var right: usize = files.len;
    while (left < right) {
        const mid = (left + right) / 2;
        if (icmp.compare(files[mid].largest.items, key) < 0) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    return left;
}

fn someFileOverlapsRange(
    gpa: Allocator,
    icmp: InternalKeyComparator,
    disjoint_sorted: bool,
    files: []const *FileMetaData,
    smallest_user: ?[]const u8,
    largest_user: ?[]const u8,
) bool {
    const ucmp = icmp.user;
    if (!disjoint_sorted) {
        for (files) |f| {
            if (afterFile(ucmp, smallest_user, f) or beforeFile(ucmp, largest_user, f)) continue;
            return true;
        }
        return false;
    }

    var index: usize = 0;
    if (smallest_user) |sk| {
        var tmp = ArrayList(u8).empty;
        defer tmp.deinit(gpa);
        tmp.appendSlice(gpa, sk) catch return true;
        var tag: [8]u8 = undefined;
        coding.encodeFixed64(&tag, internal_key.packSequenceAndType(internal_key.max_sequence_number, internal_key.value_type_for_seek));
        tmp.appendSlice(gpa, &tag) catch return true;
        index = findFile(icmp, files, tmp.items);
    }
    if (index >= files.len) return false;
    return !beforeFile(ucmp, largest_user, files[index]);
}

// ---------------------------------------------------------------------------
// Version
// ---------------------------------------------------------------------------

pub const GetStats = struct {
    seek_file: ?*FileMetaData = null,
    seek_file_level: i32 = -1,
};

const GetStateEnum = enum { not_found, found, deleted, corrupt };

pub const Version = struct {
    gpa: Allocator,
    vset: *VersionSet,
    /// One sorted list of files per level. Levels 1..6 are disjoint (no two
    /// files overlap); level 0 may overlap because its files are written by
    /// separate memtable flushes.
    files: [kNumLevels]ArrayList(*FileMetaData) = [_]ArrayList(*FileMetaData){.empty} ** kNumLevels,
    refs: u32 = 0,

    // Compaction bookkeeping, recomputed by `VersionSet.finalize`:
    /// A file whose seek budget ran out and should be compacted.
    file_to_compact: ?*FileMetaData = null,
    file_to_compact_level: i32 = -1,
    /// Highest size-based compaction score and the level it belongs to. A score
    /// >= 1 means that level is over budget.
    compaction_score: f64 = -1,
    compaction_level: i32 = -1,

    pub fn ref(self: *Version) void {
        self.refs += 1;
    }

    /// Drop a reference. When the last one goes, free the file lists and drop a
    /// reference to every file (which may free the file metadata too).
    ///
    /// Callers hold the DB mutex while dropping the final reference, because
    /// this mutates the version set's list of live versions.
    pub fn unref(self: *Version) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs > 0) return;

        const gpa = self.gpa;
        for (&self.files) |*level| {
            for (level.items) |f| unrefFile(gpa, f);
            level.deinit(gpa);
        }
        // Remove from the version set's tracking list.
        const vs = self.vset;
        for (vs.versions.items, 0..) |v, i| {
            if (v == self) {
                _ = vs.versions.swapRemove(i);
                break;
            }
        }
        gpa.destroy(self);
    }

    pub fn numFiles(self: *const Version, level: usize) usize {
        return self.files[level].items.len;
    }

    /// Look up `key` in this version, copying the value into `value`.
    ///
    /// Search order matters: newest data must win.
    ///   1. Level 0 files overlap, so check every file whose range contains the
    ///      key, newest file number first (the newest flush has the newest
    ///      writes).
    ///   2. Levels 1..6 are disjoint, so binary-search for the single file that
    ///      could contain the key.
    /// The first file that yields a match (value *or* tombstone) stops the
    /// search, because newer data always hides older data.
    pub fn get(
        self: *Version,
        options: ReadOptions,
        lkey: *const internal_key.LookupKey,
        value: *ArrayList(u8),
        stats: *GetStats,
    ) Error!void {
        stats.* = .{};
        const ucmp = self.vset.config.internal_comparator.user;
        const user_key = lkey.userKey();
        const internal_key_bytes = lkey.internalKey();

        var state: GetStateEnum = .not_found;
        var last_file_read: ?*FileMetaData = null;
        var last_file_read_level: i32 = 0;
        var corrupt_err: ?Error = null;

        // Level 0: files overlap, so collect every candidate and sort newest
        // first.
        var l0 = ArrayList(*FileMetaData).empty;
        defer l0.deinit(self.gpa);
        for (self.files[0].items) |f| {
            if (ucmp.compare(user_key, internal_key.extractUserKey(f.smallest.items)) >= 0 and
                ucmp.compare(user_key, internal_key.extractUserKey(f.largest.items)) <= 0)
            {
                try l0.append(self.gpa, f);
            }
        }
        std.mem.sort(*FileMetaData, l0.items, {}, newestFirst);

        for (l0.items) |f| {
            if (!self.matchFile(&state, &last_file_read, &last_file_read_level, stats, 0, f, options, internal_key_bytes, user_key, value, &corrupt_err)) break;
        }

        // Levels 1..6: files are disjoint, so one binary search finds the only
        // candidate file.
        var level: usize = 1;
        while (level < kNumLevels and state == .not_found) : (level += 1) {
            const index = findFile(self.vset.config.internal_comparator, self.files[level].items, internal_key_bytes);
            if (index >= self.files[level].items.len) continue;
            const f = self.files[level].items[index];
            // The file's largest key is >= our key, but its smallest may be
            // greater, meaning the key falls in the gap before this file.
            if (ucmp.compare(user_key, internal_key.extractUserKey(f.smallest.items)) < 0) continue;
            if (!self.matchFile(&state, &last_file_read, &last_file_read_level, stats, @intCast(level), f, options, internal_key_bytes, user_key, value, &corrupt_err)) break;
        }

        switch (state) {
            .found => return,
            .deleted, .not_found => return error.NotFound,
            .corrupt => return corrupt_err orelse error.Corruption,
        }
    }

    /// Receives the first matching internal key found in a table. The table
    /// reader calls it with the entry at or after our lookup key; we check that
    /// it is the right user key and record whether it is a value or tombstone.
    const Saver = struct {
        state: *GetStateEnum,
        user_key: []const u8,
        value: *ArrayList(u8),
        ucmp: comparator.Comparator,
        gpa: Allocator,
        err: *?Error,

        fn save(arg: *anyopaque, ikey: []const u8, raw_value: []const u8) void {
            const s: *Saver = @ptrCast(@alignCast(arg));
            const parsed = internal_key.parseInternalKey(ikey) orelse {
                s.state.* = .corrupt;
                return;
            };
            // A different user key means this table has no entry for us (the
            // seek landed past our key); leave the state as not_found so the
            // caller keeps looking in older files.
            if (s.ucmp.compare(parsed.user_key, s.user_key) == 0) {
                if (parsed.type == .value) {
                    s.state.* = .found;
                    // Copy the value: it points into the block, which is freed
                    // when the table read returns.
                    s.value.clearRetainingCapacity();
                    s.value.appendSlice(s.gpa, raw_value) catch {
                        s.state.* = .corrupt;
                        s.err.* = error.OutOfMemory;
                    };
                } else {
                    s.state.* = .deleted;
                }
            }
        }
    };

    /// Read one table and update `state`. Returns true to keep searching older
    /// files, false to stop (found, deleted, or corrupt).
    ///
    /// Side effect: this is where the seek-budget heuristic lives. If a read has
    /// already consulted one file and now needs a second, the *first* file is
    /// blamed, because a good key layout would not have required the extra read.
    fn matchFile(
        self: *Version,
        state: *GetStateEnum,
        last_file_read: *?*FileMetaData,
        last_file_read_level: *i32,
        stats: *GetStats,
        level: u32,
        f: *FileMetaData,
        options: ReadOptions,
        internal_key_bytes: []const u8,
        user_key: []const u8,
        value: *ArrayList(u8),
        corrupt_err: *?Error,
    ) bool {
        // Charge the first file read when a second file is consulted.
        if (stats.seek_file == null and last_file_read.* != null) {
            stats.seek_file = last_file_read.*;
            stats.seek_file_level = last_file_read_level.*;
        }
        last_file_read.* = f;
        last_file_read_level.* = @intCast(level);

        var saver = Saver{
            .state = state,
            .user_key = user_key,
            .value = value,
            .ucmp = self.vset.config.internal_comparator.user,
            .gpa = self.gpa,
            .err = corrupt_err,
        };

        self.vset.table_cache.get(options, f.number, f.file_size, internal_key_bytes, &saver, Saver.save) catch |e| {
            state.* = .corrupt;
            corrupt_err.* = e;
            return false;
        };
        return state.* == .not_found;
    }

    /// Decrement the seek budget of the file charged by the last read. When it
    /// reaches zero, mark the file for a seek-triggered compaction and return
    /// true so the caller can schedule one.
    pub fn updateStats(self: *Version, stats: GetStats) bool {
        if (stats.seek_file) |f| {
            if (f.allowed_seeks > 0) f.allowed_seeks -= 1;
            if (f.allowed_seeks == 0 and self.file_to_compact == null) {
                self.file_to_compact = f;
                self.file_to_compact_level = stats.seek_file_level;
                return true;
            }
        }
        return false;
    }

    /// Called when a read touches `key`. If it spans multiple files, the first
    /// file is charged and may become a compaction candidate.
    pub fn recordReadSample(self: *Version, key: []const u8) bool {
        const ucmp = self.vset.config.internal_comparator.user;
        const user_key = internal_key.extractUserKey(key);

        var matches: usize = 0;
        var first: ?*FileMetaData = null;
        var first_level: i32 = 0;

        for (self.files[0].items) |f| {
            if (ucmp.compare(user_key, internal_key.extractUserKey(f.smallest.items)) >= 0 and
                ucmp.compare(user_key, internal_key.extractUserKey(f.largest.items)) <= 0)
            {
                if (first == null) {
                    first = f;
                    first_level = 0;
                }
                matches += 1;
            }
        }
        for (1..kNumLevels) |level| {
            const index = findFile(self.vset.config.internal_comparator, self.files[level].items, key);
            if (index < self.files[level].items.len) {
                const f = self.files[level].items[index];
                if (ucmp.compare(user_key, internal_key.extractUserKey(f.smallest.items)) >= 0) {
                    if (first == null) {
                        first = f;
                        first_level = @intCast(level);
                    }
                    matches += 1;
                }
            }
        }
        if (matches >= 2) {
            return self.updateStats(.{ .seek_file = first, .seek_file_level = first_level });
        }
        return false;
    }

    /// Append one table iterator per file; the caller merges them.
    pub fn addIterators(self: *Version, options: ReadOptions, list: *ArrayList(Iterator)) !void {
        for (0..kNumLevels) |level| {
            for (self.files[level].items) |f| {
                const it = try self.vset.table_cache.newIterator(options, f.number, f.file_size);
                try list.append(self.gpa, it);
            }
        }
    }

    pub fn overlapInLevel(self: *const Version, level: usize, smallest_user: ?[]const u8, largest_user: ?[]const u8) bool {
        return someFileOverlapsRange(
            self.gpa,
            self.vset.config.internal_comparator,
            level > 0,
            self.files[level].items,
            smallest_user,
            largest_user,
        );
    }

    pub fn getOverlappingInputs(
        self: *const Version,
        level: usize,
        begin: ?[]const u8, // user key
        end: ?[]const u8, // user key
        out: *ArrayList(*FileMetaData),
    ) !void {
        out.clearRetainingCapacity();
        const ucmp = self.vset.config.internal_comparator.user;

        var user_begin: ?[]const u8 = begin;
        var user_end: ?[]const u8 = end;

        var i: usize = 0;
        while (i < self.files[level].items.len) {
            const f = self.files[level].items[i];
            i += 1;
            const file_start = internal_key.extractUserKey(f.smallest.items);
            const file_limit = internal_key.extractUserKey(f.largest.items);

            if (user_begin) |ub| {
                if (ucmp.compare(file_limit, ub) < 0) continue;
            }
            if (user_end) |ue| {
                if (ucmp.compare(file_start, ue) > 0) continue;
            }
            try out.append(self.gpa, f);

            if (level == 0) {
                if (user_begin) |ub| {
                    if (ucmp.compare(file_start, ub) < 0) {
                        user_begin = file_start;
                        out.clearRetainingCapacity();
                        i = 0;
                        continue;
                    }
                }
                if (user_end) |ue| {
                    if (ucmp.compare(file_limit, ue) > 0) {
                        user_end = file_limit;
                        out.clearRetainingCapacity();
                        i = 0;
                        continue;
                    }
                }
            }
        }
    }

    pub fn pickLevelForMemTableOutput(self: *const Version, smallest_user: []const u8, largest_user: []const u8) usize {
        var level: usize = 0;
        if (self.overlapInLevel(0, smallest_user, largest_user)) return 0;

        while (level < kMaxMemCompactLevel) {
            if (self.overlapInLevel(level + 1, smallest_user, largest_user)) break;
            if (level + 2 < kNumLevels) {
                var overlaps = ArrayList(*FileMetaData).empty;
                defer overlaps.deinit(self.gpa);
                self.getOverlappingInputs(level + 2, smallest_user, largest_user, &overlaps) catch break;
                if (totalFileSize(overlaps.items) > maxGrandParentOverlapBytes(self.vset.config)) break;
            }
            level += 1;
        }
        return level;
    }
};

pub fn unrefFile(gpa: Allocator, f: *FileMetaData) void {
    std.debug.assert(f.refs > 0);
    f.refs -= 1;
    if (f.refs == 0) {
        f.deinit(gpa);
        gpa.destroy(f);
    }
}

// ---------------------------------------------------------------------------
// Compaction
// ---------------------------------------------------------------------------

pub const Compaction = struct {
    gpa: Allocator,
    vset: *VersionSet,
    level_: u32,
    max_output_file_size_: u64,
    input_version: *Version,
    edit: VersionEdit,
    inputs: [2][]*FileMetaData = .{ &.{}, &.{} },
    grandparents: []*FileMetaData = &.{},

    inputs_released: bool = false,
    grandparent_index: usize = 0,
    seen_key: bool = false,
    overlapped_bytes: u64 = 0,
    level_ptrs: [kNumLevels]usize = [_]usize{0} ** kNumLevels,

    pub fn create(gpa: Allocator, vset: *VersionSet, level_: u32, input_version: *Version) !*Compaction {
        const c = try gpa.create(Compaction);
        input_version.ref();
        c.* = .{
            .gpa = gpa,
            .vset = vset,
            .level_ = level_,
            .max_output_file_size_ = targetFileSize(vset.config),
            .input_version = input_version,
            .edit = VersionEdit.init(gpa),
        };
        return c;
    }

    pub fn deinit(self: *Compaction) void {
        const gpa = self.gpa;
        for (self.inputs) |s| if (s.len > 0) gpa.free(s);
        if (self.grandparents.len > 0) gpa.free(self.grandparents);
        self.edit.deinit();
        self.releaseInputs();
        gpa.destroy(self);
    }

    pub fn level(self: *const Compaction) u32 {
        return self.level_;
    }
    pub fn numInputFiles(self: *const Compaction, which: usize) usize {
        return self.inputs[which].len;
    }
    pub fn input(self: *const Compaction, which: usize, i: usize) *FileMetaData {
        return self.inputs[which][i];
    }
    pub fn maxOutputFileSize(self: *const Compaction) u64 {
        return self.max_output_file_size_;
    }

    /// A "trivial move" is a compaction whose output would be exactly one of its
    /// inputs. Rather than rewrite the file, we can just relink it into the next
    /// level. This is safe only when the single input is at level > 0 (level 0
    /// files may overlap each other) and when doing so would not overlap too
    /// much of level+2 (the grandparents), which would make a future compaction
    /// expensive.
    pub fn isTrivialMove(self: *const Compaction) bool {
        return self.inputs[0].len == 1 and self.inputs[1].len == 0 and
            totalFileSize(self.grandparents) <= maxGrandParentOverlapBytes(self.vset.config);
    }

    /// Record in `edit` that every input file is being removed.
    pub fn addInputDeletions(self: *Compaction, edit: *VersionEdit) !void {
        for (0..2) |which| {
            for (self.inputs[which]) |f| {
                try edit.removeFile(self.level_ + @as(u32, @intCast(which)), f.number);
            }
        }
    }

    /// True if no file at level+2 or deeper contains `user_key`.
    ///
    /// This decides whether a tombstone can be dropped. A tombstone must be kept
    /// while older data for the same key might still exist in a deeper level; if
    /// nothing is deeper, the tombstone has done its job and can go.
    ///
    /// `level_ptrs[lvl]` is a per-level cursor. Because the compaction walks keys
    /// in ascending order, each level is only ever scanned forward, so this is
    /// O(files) overall rather than O(files) per key.
    pub fn isBaseLevelForKey(self: *Compaction, user_key: []const u8) bool {
        const ucmp = self.vset.config.internal_comparator.user;
        var lvl: usize = @as(usize, self.level_) + 2;
        while (lvl < kNumLevels) : (lvl += 1) {
            const files = self.input_version.files[lvl].items;
            while (self.level_ptrs[lvl] < files.len) {
                const f = files[self.level_ptrs[lvl]];
                // Files are sorted by smallest key. If this file's largest is
                // before our key, skip it.
                if (ucmp.compare(user_key, internal_key.extractUserKey(f.largest.items)) <= 0) {
                    if (ucmp.compare(user_key, internal_key.extractUserKey(f.smallest.items)) >= 0) {
                        return false; // key exists deeper
                    }
                    break; // key falls in the gap before this file
                }
                self.level_ptrs[lvl] += 1;
            }
        }
        return true;
    }

    /// True when the current output file has grown enough to risk overlapping
    /// too much of level+2; the caller should start a new output file.
    ///
    /// This bounds how much of level+2 a future compaction of this output would
    /// have to merge, keeping compaction cost predictable.
    pub fn shouldStopBefore(self: *Compaction, internal_key_bytes: []const u8) bool {
        // Advance past grandparents that end before the current key.
        while (self.grandparent_index < self.grandparents.len and
            self.vset.config.internal_comparator.compare(internal_key_bytes, self.grandparents[self.grandparent_index].largest.items) > 0)
        {
            self.grandparent_index += 1;
        }
        if (self.grandparent_index < self.grandparents.len) {
            // Count the size of each grandparent the output touches, once.
            if (self.seen_key) self.overlapped_bytes += self.grandparents[self.grandparent_index].file_size;
            if (self.overlapped_bytes > maxGrandParentOverlapBytes(self.vset.config)) {
                self.overlapped_bytes = 0;
                return true;
            }
        }
        self.seen_key = true;
        return false;
    }

    /// Drop the reference to the version this compaction reads from. Idempotent,
    /// because it may be called both after a successful compaction and from
    /// `deinit`.
    pub fn releaseInputs(self: *Compaction) void {
        if (!self.inputs_released) {
            self.input_version.unref();
            self.inputs_released = true;
        }
    }
};

// ---------------------------------------------------------------------------
// VersionSet
// ---------------------------------------------------------------------------

pub const VersionSet = struct {
    gpa: Allocator,
    env: env_mod.Env,
    dbname: []const u8,
    config: Config,
    table_cache: *TableCache,
    table_options: table_builder.Options,

    next_file_number: u64 = 2,
    manifest_file_number: u64 = 0,
    last_sequence: SequenceNumber = 0,
    log_number: u64 = 0,
    prev_log_number: u64 = 0,

    compact_pointer: [kNumLevels]ArrayList(u8) = [_]ArrayList(u8){.empty} ** kNumLevels,
    versions: ArrayList(*Version) = .empty,
    current: ?*Version = null,

    descriptor_file: ?env_mod.WritableFile = null,
    descriptor_log: ?log.writer.Writer = null,

    pub fn init(
        gpa: Allocator,
        env: env_mod.Env,
        dbname: []const u8,
        config: Config,
        table_cache: *TableCache,
        table_options: table_builder.Options,
    ) VersionSet {
        return .{
            .gpa = gpa,
            .env = env,
            .dbname = dbname,
            .config = config,
            .table_cache = table_cache,
            .table_options = table_options,
        };
    }

    pub fn deinit(self: *VersionSet) void {
        const gpa = self.gpa;
        if (self.current) |v| v.unref();
        self.current = null;
        std.debug.assert(self.versions.items.len == 0);
        self.versions.deinit(gpa);
        for (&self.compact_pointer) |*cp| cp.deinit(gpa);
        if (self.descriptor_log != null) {
            self.descriptor_file.?.deinit(gpa);
            self.descriptor_log = null;
        }
    }

    pub fn currentVersion(self: *VersionSet) *Version {
        return self.current.?;
    }

    pub fn newFileNumber(self: *VersionSet) u64 {
        const n = self.next_file_number;
        self.next_file_number += 1;
        return n;
    }

    pub fn markFileNumberUsed(self: *VersionSet, number: u64) void {
        // Called after allocating a number to keep it from being reused.
        if (self.next_file_number <= number) self.next_file_number = number + 1;
    }

    pub fn reuseFileNumber(self: *VersionSet, number: u64) void {
        if (self.next_file_number == number + 1) self.next_file_number = number;
    }

    pub fn lastSequence(self: *VersionSet) SequenceNumber {
        return self.last_sequence;
    }
    pub fn setLastSequence(self: *VersionSet, s: SequenceNumber) void {
        std.debug.assert(s >= self.last_sequence);
        self.last_sequence = s;
    }
    pub fn logNumber(self: *VersionSet) u64 {
        return self.log_number;
    }
    pub fn prevLogNumber(self: *VersionSet) u64 {
        return self.prev_log_number;
    }
    pub fn manifestFileNumber(self: *VersionSet) u64 {
        return self.manifest_file_number;
    }
    pub fn numLevelFiles(self: *VersionSet, level: usize) usize {
        return self.currentVersion().files[level].items.len;
    }

    pub fn addLiveFiles(self: *VersionSet, out: *ArrayList(u64)) !void {
        for (self.versions.items) |v| {
            for (&v.files) |*level| {
                for (level.items) |f| try out.append(self.gpa, f.number);
            }
        }
    }

    pub fn needsCompaction(self: *VersionSet) bool {
        const v = self.currentVersion();
        return v.compaction_score >= 1 or v.file_to_compact != null;
    }

    fn createVersion(self: *VersionSet) !*Version {
        const v = try self.gpa.create(Version);
        v.* = .{ .gpa = self.gpa, .vset = self };
        return v;
    }

    fn appendVersion(self: *VersionSet, v: *Version) !void {
        if (self.current) |old| old.unref();
        v.ref();
        try self.versions.append(self.gpa, v);
        self.current = v;
    }

    fn finalize(_: *VersionSet, v: *Version) void {
        var best_level: i32 = -1;
        var best_score: f64 = -1;
        for (0..kNumLevels - 1) |level| {
            var score: f64 = undefined;
            if (level == 0) {
                score = @as(f64, @floatFromInt(v.files[0].items.len)) / kL0_CompactionTrigger;
            } else {
                score = @as(f64, @floatFromInt(totalFileSize(v.files[level].items))) / @as(f64, @floatFromInt(maxBytesForLevel(level)));
            }
            if (score > best_score) {
                best_score = score;
                best_level = @intCast(level);
            }
        }
        v.compaction_level = best_level;
        v.compaction_score = best_score;
    }

    /// Persist `edit` to the MANIFEST and install the resulting version.
    ///
    /// This is the only way the set of live files changes. Ordering matters:
    ///   1. build the new version in memory,
    ///   2. append the edit to the MANIFEST and fsync it,
    ///   3. only then make the new version current.
    /// If we crashed between 2 and 3, recovery would replay the edit and reach
    /// the same state. If we made the version current before the MANIFEST write,
    /// a crash could lose files that reads already depended on.
    ///
    /// The first call also creates the MANIFEST: it writes a snapshot of the
    /// current version, then appends the edit, then atomically points CURRENT at
    /// it. Callers must hold the DB mutex and must not call this concurrently.
    pub fn logAndApply(self: *VersionSet, edit: *VersionEdit) Error!void {
        const gpa = self.gpa;

        // Fill in the bookkeeping fields the edit did not set, so every
        // MANIFEST record carries a complete picture.
        if (!edit.has_log_number) edit.setLogNumber(self.log_number);
        if (!edit.has_prev_log_number) edit.setPrevLogNumber(self.prev_log_number);
        edit.setNextFile(self.next_file_number);
        edit.setLastSequence(self.last_sequence);

        const base = self.currentVersion();
        const v = try self.createVersion();
        errdefer v.unref();

        var builder = Builder.init(self, base);
        defer builder.deinit();
        try builder.apply(edit);
        try builder.saveTo(v);
        self.finalize(v); // recompute compaction scores

        var created_manifest = false;
        if (self.descriptor_log == null) {
            const mf = try filename.descriptorFileName(gpa, self.dbname, self.manifest_file_number);
            defer gpa.free(mf);
            const file = try self.env.newWritableFile(gpa, mf);
            self.descriptor_file = file;
            self.descriptor_log = log.writer.Writer.init(file, 0);
            created_manifest = true;
            try self.writeSnapshot(&self.descriptor_log.?);
        }

        // Append the edit and make it durable before switching versions.
        var record = ArrayList(u8).empty;
        defer record.deinit(gpa);
        try edit.encodeTo(&record);
        try self.descriptor_log.?.addRecord(record.items);
        try self.descriptor_file.?.sync();
        if (created_manifest) {
            // Atomic: write a temp file, sync, rename over CURRENT.
            try filename.setCurrentFile(self.env, gpa, self.dbname, self.manifest_file_number);
        }

        try self.appendVersion(v);
        self.log_number = edit.log_number;
        self.prev_log_number = edit.prev_log_number;
    }

    /// Write the entire current state as a single VersionEdit. A new MANIFEST
    /// starts with this so recovery does not need every historical edit.
    fn writeSnapshot(self: *VersionSet, writer: *log.writer.Writer) Error!void {
        const gpa = self.gpa;
        var edit = VersionEdit.init(gpa);
        defer edit.deinit();

        try edit.setComparatorName(self.config.internal_comparator.name());
        for (self.compact_pointer, 0..) |cp, level| {
            if (cp.items.len > 0) try edit.setCompactPointer(@intCast(level), cp.items);
        }
        const v = self.currentVersion();
        for (&v.files, 0..) |*level_files, level| {
            for (level_files.items) |f| {
                try edit.addFile(@intCast(level), f.number, f.file_size, f.smallest.items, f.largest.items);
            }
        }
        var record = ArrayList(u8).empty;
        defer record.deinit(gpa);
        try edit.encodeTo(&record);
        try writer.addRecord(record.items);
    }

    /// Reconstruct the current version from CURRENT and the MANIFEST.
    ///
    /// The MANIFEST is replayed from the beginning through one Builder, so the
    /// snapshot and every subsequent edit compose into the final version. A few
    /// fields (next file number, log number, last sequence) must have been seen
    /// at least once or the DB is considered corrupt.
    pub fn recover(self: *VersionSet, save_manifest: *bool) Error!void {
        const gpa = self.gpa;

        const current_name = try filename.readCurrentFile(self.env, gpa, self.dbname);
        defer gpa.free(current_name);

        const manifest_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.dbname, current_name });
        defer gpa.free(manifest_path);

        const file = try self.env.newSequentialFile(gpa, manifest_path);
        defer file.deinit(gpa);

        var reader = try log.reader.Reader.init(gpa, file, null, true, 0);
        defer reader.deinit();

        const base = try self.createVersion();
        var builder = Builder.init(self, base);
        defer builder.deinit();

        var have_next_file = false;
        var have_log_number = false;
        var have_last_sequence = false;
        var next_file: u64 = 0;
        var last_seq: SequenceNumber = 0;
        var log_number: u64 = 0;
        var prev_log_number: u64 = 0;

        var edit = VersionEdit.init(gpa);
        defer edit.deinit();

        while (try reader.readRecord()) |record| {
            try edit.decodeFrom(record);
            if (edit.has_comparator and
                !std.mem.eql(u8, edit.comparator.items, self.config.internal_comparator.name()))
            {
                return error.InvalidArgument;
            }
            try builder.apply(&edit);
            if (edit.has_log_number) {
                log_number = edit.log_number;
                have_log_number = true;
            }
            if (edit.has_prev_log_number) prev_log_number = edit.prev_log_number;
            if (edit.has_next_file_number) {
                next_file = edit.next_file_number;
                have_next_file = true;
            }
            if (edit.has_last_sequence) {
                last_seq = edit.last_sequence;
                have_last_sequence = true;
            }
        }

        if (!have_next_file) return error.Corruption;
        if (!have_log_number) return error.Corruption;
        if (!have_last_sequence) return error.Corruption;

        self.markFileNumberUsed(prev_log_number);
        self.markFileNumberUsed(log_number);

        const v = try self.createVersion();
        errdefer v.unref();
        try builder.saveTo(v);
        self.finalize(v);
        try self.appendVersion(v);

        self.manifest_file_number = next_file;
        self.next_file_number = next_file + 1;
        self.last_sequence = last_seq;
        self.log_number = log_number;
        self.prev_log_number = prev_log_number;

        // We always write a fresh MANIFEST after recovery.
        save_manifest.* = true;
    }

    /// Choose a compaction to run, or null if none is needed.
    ///
    /// Two triggers, in priority order:
    ///   * **size** — a level is over its byte budget (`compaction_score >= 1`).
    ///     Files are picked round-robin: the first file that starts after the
    ///     level's last compaction pointer, wrapping around.
    ///   * **seek** — a file's seek budget ran out, meaning reads keep touching
    ///     it and an older file (see `Version.matchFile`).
    ///
    /// Either way, `setupOtherInputs` then adds the overlapping files one level
    /// down, so the compaction merges everything the key range can collide with.
    pub fn pickCompaction(self: *VersionSet) Error!?*Compaction {
        const v = self.currentVersion();
        const size_compaction = v.compaction_score >= 1;
        const seek_compaction = v.file_to_compact != null;

        var level: u32 = 0;
        var c: *Compaction = undefined;

        if (size_compaction) {
            level = @intCast(v.compaction_level);
            c = try Compaction.create(self.gpa, self, level, v);
            errdefer c.deinit();

            // Rotate through the level's key space using compact_pointer.
            const files = v.files[level].items;
            var chosen: ?*FileMetaData = null;
            for (files) |f| {
                if (self.compact_pointer[level].items.len == 0 or
                    self.config.internal_comparator.compare(f.largest.items, self.compact_pointer[level].items) > 0)
                {
                    chosen = f;
                    break;
                }
            }
            if (chosen == null and files.len > 0) chosen = files[0]; // wrap around
            if (chosen == null) {
                c.deinit();
                return null;
            }
            c.inputs[0] = try self.gpa.dupe(*FileMetaData, &.{chosen.?});
        } else if (seek_compaction) {
            level = @intCast(v.file_to_compact_level);
            c = try Compaction.create(self.gpa, self, level, v);
            errdefer c.deinit();
            c.inputs[0] = try self.gpa.dupe(*FileMetaData, &.{v.file_to_compact.?});
        } else {
            return null;
        }

        if (level == 0) {
            // Level 0 files overlap, so a compaction must include every file
            // that shares any key range with the chosen one.
            const range = self.getRange(c.inputs[0]);
            var expanded = ArrayList(*FileMetaData).empty;
            defer expanded.deinit(self.gpa);
            try v.getOverlappingInputs(0, internal_key.extractUserKey(range.smallest), internal_key.extractUserKey(range.largest), &expanded);
            self.gpa.free(c.inputs[0]);
            c.inputs[0] = try self.gpa.dupe(*FileMetaData, expanded.items);
            // Newest first so the merge sees newer files first.
            std.mem.sort(*FileMetaData, c.inputs[0], {}, newestFirst);
        }

        try self.setupOtherInputs(c);
        return c;
    }

    /// Build a compaction over an explicit key range, for `CompactRange`.
    pub fn compactRange(self: *VersionSet, level: u32, begin: ?[]const u8, end: ?[]const u8) Error!?*Compaction {
        const v = self.currentVersion();
        var inputs = ArrayList(*FileMetaData).empty;
        defer inputs.deinit(self.gpa);
        try v.getOverlappingInputs(level, begin, end, &inputs);
        if (inputs.items.len == 0) return null;

        const c = try Compaction.create(self.gpa, self, level, v);
        errdefer c.deinit();
        c.inputs[0] = try self.gpa.dupe(*FileMetaData, inputs.items);
        try self.setupOtherInputs(c);
        return c;
    }

    const Range = struct { smallest: []const u8, largest: []const u8 };

    /// The smallest and largest internal key across `files`.
    fn getRange(self: *VersionSet, files: []*FileMetaData) Range {
        const icmp = self.config.internal_comparator;
        var smallest = files[0].smallest.items;
        var largest = files[0].largest.items;
        for (files[1..]) |f| {
            if (icmp.compare(f.smallest.items, smallest) < 0) smallest = f.smallest.items;
            if (icmp.compare(f.largest.items, largest) > 0) largest = f.largest.items;
        }
        return .{ .smallest = smallest, .largest = largest };
    }

    fn getRange2(self: *VersionSet, a: []*FileMetaData, b: []*FileMetaData) Range {
        const icmp = self.config.internal_comparator;
        var smallest = a[0].smallest.items;
        var largest = a[0].largest.items;
        for (a[1..]) |f| {
            if (icmp.compare(f.smallest.items, smallest) < 0) smallest = f.smallest.items;
            if (icmp.compare(f.largest.items, largest) > 0) largest = f.largest.items;
        }
        for (b) |f| {
            if (icmp.compare(f.smallest.items, smallest) < 0) smallest = f.smallest.items;
            if (icmp.compare(f.largest.items, largest) > 0) largest = f.largest.items;
        }
        return .{ .smallest = smallest, .largest = largest };
    }

    /// Fill in the rest of a compaction after `inputs[0]` is chosen:
    ///   * `inputs[1]` — the files one level down that overlap inputs[0]'s range,
    ///   * `grandparents` — files two levels down in the merged range, used to
    ///     decide when to stop an output file,
    ///   * and advance the level's compaction pointer so the next compaction
    ///     picks a different range (even if this one fails).
    fn setupOtherInputs(self: *VersionSet, c: *Compaction) Error!void {
        const gpa = self.gpa;
        const level: usize = c.level_;
        const v = self.currentVersion();

        const range = self.getRange(c.inputs[0]);

        var inputs1 = ArrayList(*FileMetaData).empty;
        defer inputs1.deinit(gpa);
        try v.getOverlappingInputs(level + 1, internal_key.extractUserKey(range.smallest), internal_key.extractUserKey(range.largest), &inputs1);
        c.inputs[1] = try gpa.dupe(*FileMetaData, inputs1.items);

        const all = self.getRange2(c.inputs[0], c.inputs[1]);

        if (level + 2 < kNumLevels) {
            var gp = ArrayList(*FileMetaData).empty;
            defer gp.deinit(gpa);
            try v.getOverlappingInputs(level + 2, internal_key.extractUserKey(all.smallest), internal_key.extractUserKey(all.largest), &gp);
            c.grandparents = try gpa.dupe(*FileMetaData, gp.items);
        }

        // Update the pointer before the compaction runs, so a failed compaction
        // retries a different range instead of looping on the same one.
        self.compact_pointer[level].clearRetainingCapacity();
        try self.compact_pointer[level].appendSlice(gpa, range.largest);
        try c.edit.setCompactPointer(@intCast(level), range.largest);
    }

    pub fn makeInputIterator(self: *VersionSet, c: *Compaction) Error!Iterator {
        const gpa = self.gpa;
        var list = ArrayList(Iterator).empty;
        defer list.deinit(gpa);

        const read_opts = ReadOptions{
            .verify_checksums = self.config.paranoid_checks,
            .fill_cache = false,
        };

        for (0..2) |which| {
            for (c.inputs[which]) |f| {
                const it = try self.table_cache.newIterator(read_opts, f.number, f.file_size);
                try list.append(gpa, it);
            }
        }

        const children = try list.toOwnedSlice(gpa);
        return merger.create(gpa, self.config.internal_comparator.asComparator(), children);
    }
};

// ---------------------------------------------------------------------------
// VersionSet.Builder
// ---------------------------------------------------------------------------

/// Builds a new immutable `Version` by applying one or more `VersionEdit`s to a
/// base version.
///
/// The builder collects additions and deletions per level, then `saveTo` merges
/// them with the base. This is used in two places:
///   * `logAndApply`, to install a new version after a change, and
///   * `recover`, to replay a MANIFEST from the beginning.
const Builder = struct {
    gpa: Allocator,
    vset: *VersionSet,
    /// The version the edits apply to. Held by reference.
    base: *Version,
    /// File numbers removed, per level.
    deleted: [kNumLevels]ArrayList(u64) = [_]ArrayList(u64){.empty} ** kNumLevels,
    /// New files, per level. Owned by the builder until handed to a version.
    added: [kNumLevels]ArrayList(*FileMetaData) = [_]ArrayList(*FileMetaData){.empty} ** kNumLevels,

    fn init(vset: *VersionSet, base: *Version) Builder {
        base.ref();
        return .{ .gpa = vset.gpa, .vset = vset, .base = base };
    }

    fn deinit(self: *Builder) void {
        for (&self.deleted) |*d| d.deinit(self.gpa);
        for (&self.added) |*a| {
            for (a.items) |f| unrefFile(self.gpa, f);
            a.deinit(self.gpa);
        }
        self.base.unref();
    }

    fn containsNumber(list: []const u64, number: u64) bool {
        for (list) |n| if (n == number) return true;
        return false;
    }

    /// Record one edit's changes. Does not touch the version yet.
    fn apply(self: *Builder, edit: *const VersionEdit) Error!void {
        const gpa = self.gpa;

        for (edit.compact_pointers.items) |cp| {
            const level: usize = cp.level;
            self.vset.compact_pointer[level].clearRetainingCapacity();
            try self.vset.compact_pointer[level].appendSlice(gpa, cp.key.items);
        }
        for (edit.deleted_files.items) |df| {
            try self.deleted[df.level].append(gpa, df.number);
        }
        for (edit.new_files.items) |f| {
            const f_meta = try gpa.create(FileMetaData);
            errdefer gpa.destroy(f_meta);
            f_meta.* = try f.meta.clone(gpa);
            // The builder owns one reference; `saveTo` adds another when the
            // file is placed in the version, and `deinit` drops the builder's.
            f_meta.refs = 1;
            // Seek budget: roughly one seek per 16 KiB, at least 100. When it
            // runs out, the file becomes a compaction candidate.
            f_meta.allowed_seeks = @intCast(@max(f_meta.file_size / 16384, 100));

            // A file added here cancels a deletion of the same number (a
            // compaction can remove an old file and add a new one in one edit,
            // and across edits an add can follow a delete).
            var i: usize = 0;
            while (i < self.deleted[f.level].items.len) {
                if (self.deleted[f.level].items[i] == f_meta.number) {
                    _ = self.deleted[f.level].swapRemove(i);
                } else i += 1;
            }
            try self.added[f.level].append(gpa, f_meta);
        }
    }

    /// Produce the new version `v` from the base plus the applied edits.
    ///
    /// For each level: keep base files that were not deleted, add the new files,
    /// sort by smallest key, and take a reference to each. Levels 1..6 are
    /// disjoint, so the sort produces the order reads expect.
    fn saveTo(self: *Builder, v: *Version) Error!void {
        const gpa = self.gpa;
        const icmp = self.vset.config.internal_comparator;

        for (0..kNumLevels) |level| {
            var merged = ArrayList(*FileMetaData).empty;
            defer merged.deinit(gpa);

            for (self.base.files[level].items) |f| {
                if (!containsNumber(self.deleted[level].items, f.number)) {
                    try merged.append(gpa, f);
                }
            }
            // An added file may have been deleted by a later edit in the same
            // manifest; such a file must not be resurrected.
            for (self.added[level].items) |f| {
                if (!containsNumber(self.deleted[level].items, f.number)) {
                    try merged.append(gpa, f);
                }
            }

            std.mem.sort(*FileMetaData, merged.items, icmp, fileLessThan);

            for (merged.items) |f| {
                f.refs += 1;
                try v.files[level].append(gpa, f);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const mem_env = @import("mem_env.zig");
const table_mod = @import("../table/table.zig");

test "version set recover and logAndApply" {
    const gpa = testing.allocator;
    const mem = try mem_env.MemEnv.init(gpa);
    defer mem.deinit();
    const env = mem.env();
    try env.createDir("db");

    const icmp = InternalKeyComparator.init(comparator.bytewise);
    const cfg = Config{ .internal_comparator = icmp };
    const table_opts = table_builder.Options{ .comparator = icmp.asComparator() };
    const tc_opts = table_mod.Options{ .comparator = icmp.asComparator() };

    // Bootstrap: write MANIFEST-000001 and point CURRENT at it, like DBImpl.NewDB.
    {
        var edit = VersionEdit.init(gpa);
        defer edit.deinit();
        try edit.setComparatorName(icmp.name());
        edit.setLogNumber(0);
        edit.setNextFile(2);
        edit.setLastSequence(0);

        var rec = ArrayList(u8).empty;
        defer rec.deinit(gpa);
        try edit.encodeTo(&rec);

        const mf = try filename.descriptorFileName(gpa, "db", 1);
        defer gpa.free(mf);
        const file = try env.newWritableFile(gpa, mf);
        defer file.deinit(gpa);
        var w = log.writer.Writer.init(file, 0);
        try w.addRecord(rec.items);
        try file.sync();
        try file.close();

        try filename.setCurrentFile(env, gpa, "db", 1);
    }

    var tc = TableCache.init(gpa, env, "db", tc_opts);
    var vs = VersionSet.init(gpa, env, "db", cfg, &tc, table_opts);
    defer vs.deinit();

    var save_manifest = false;
    try vs.recover(&save_manifest);
    try testing.expectEqual(@as(usize, 0), vs.numLevelFiles(0));

    // Add a file; this creates MANIFEST-000002 with a snapshot + the edit.
    var edit = VersionEdit.init(gpa);
    defer edit.deinit();
    try edit.setComparatorName(icmp.name());
    edit.setLogNumber(0);
    edit.setLastSequence(0);
    try edit.addFile(0, 5, 1000, "a-key", "z-key");
    try vs.logAndApply(&edit);

    try testing.expectEqual(@as(usize, 1), vs.numLevelFiles(0));
    try testing.expectEqual(@as(u64, 5), vs.currentVersion().files[0].items[0].number);

    // Recover into a fresh set and confirm the file is present.
    var tc2 = TableCache.init(gpa, env, "db", tc_opts);
    var vs2 = VersionSet.init(gpa, env, "db", cfg, &tc2, table_opts);
    defer vs2.deinit();
    var save2 = false;
    try vs2.recover(&save2);
    try testing.expect(save2);
    try testing.expectEqual(@as(usize, 1), vs2.numLevelFiles(0));
    try testing.expectEqual(@as(u64, 5), vs2.currentVersion().files[0].items[0].number);
}
