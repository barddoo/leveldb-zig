//! leveldb-zig — a from-scratch, learning-oriented LSM storage engine.
//!
//! This is the public entry point. The implementation is organized bottom-up:
//!
//!   primitives/  byte coding, checksums, hashing, comparators
//!   memtable/    in-memory write buffer (arena + skip list)
//!   log/         the write-ahead log and MANIFEST record framing
//!   table/       sorted string tables (SSTables) and the block cache
//!   iter/        the iterator interface plus merge/two-level/db iterators
//!   db/          versions, manifest, compaction, and the DB engine itself
//!
//! See docs/01-architecture.md for how each Zig module maps onto the original
//! C++ files.

const std = @import("std");

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------
pub const coding = @import("primitives/coding.zig");
pub const crc32c = @import("primitives/crc32c.zig");
pub const hash = @import("primitives/hash.zig");
pub const random = @import("primitives/random.zig");
pub const status = @import("primitives/status.zig");
pub const comparator = @import("primitives/comparator.zig");

// ---------------------------------------------------------------------------
// Memtable
// ---------------------------------------------------------------------------
pub const arena = @import("memtable/arena.zig");
pub const skiplist = @import("memtable/skiplist.zig");
pub const memtable = @import("memtable/memtable.zig");
pub const write_batch = @import("memtable/write_batch.zig");

// ---------------------------------------------------------------------------
// DB format
// ---------------------------------------------------------------------------
pub const internal_key = @import("db/internal_key.zig");
pub const env = @import("db/env.zig");
pub const mem_env = @import("db/mem_env.zig");
pub const filename = @import("db/filename.zig");
pub const version_edit = @import("db/version_edit.zig");
pub const snapshot = @import("db/snapshot.zig");
pub const table_cache = @import("db/table_cache.zig");
pub const builder = @import("db/builder.zig");
pub const version_set = @import("db/version_set.zig");
pub const db_impl = @import("db/db_impl.zig");
pub const io_env = @import("db/io_env.zig");

// Public API aliases
pub const DB = db_impl.DB;
pub const Options = db_impl.Options;
pub const WriteOptions = db_impl.WriteOptions;
pub const ReadOptions = db_impl.ReadOptions;

// ---------------------------------------------------------------------------
// Write-ahead log
// ---------------------------------------------------------------------------
pub const log = @import("log/log.zig");

// ---------------------------------------------------------------------------
// Iterators
// ---------------------------------------------------------------------------
pub const iterator = @import("iter/iterator.zig");
pub const two_level = @import("iter/two_level.zig");
pub const merger = @import("iter/merger.zig");
pub const db_iter = @import("iter/db_iter.zig");

// ---------------------------------------------------------------------------
// Tables (SSTables)
// ---------------------------------------------------------------------------
pub const block_builder = @import("table/block_builder.zig");
pub const block = @import("table/block.zig");
pub const filter_policy = @import("table/filter_policy.zig");
pub const filter_block = @import("table/filter_block.zig");
pub const format = @import("table/format.zig");
pub const table_builder = @import("table/table_builder.zig");
pub const table = @import("table/table.zig");

test {
    // Referencing the modules here makes `zig build test` run the colocated
    // `test` blocks in every file reachable from the public API.
    _ = coding;
    _ = crc32c;
    _ = hash;
    _ = random;
    _ = status;
    _ = comparator;
    _ = arena;
    _ = skiplist;
    _ = memtable;
    _ = write_batch;
    _ = internal_key;
    _ = env;
    _ = mem_env;
    _ = filename;
    _ = version_edit;
    _ = snapshot;
    _ = table_cache;
    _ = builder;
    _ = version_set;
    _ = db_impl;
    _ = io_env;
    _ = log;
    _ = iterator;
    _ = two_level;
    _ = merger;
    _ = db_iter;
    _ = block_builder;
    _ = block;
    _ = filter_policy;
    _ = filter_block;
    _ = format;
    _ = table_builder;
    _ = table;
}
