# Milestones

A record of what was built, in the order it was built, plus the things that are
intentionally left out.

## Done

- **M0 — Scaffolding.** `build.zig`, `build.zig.zon`, public API in `src/lib.zig`,
  CLI in `src/main.zig`, `zig build test`.
- **M1 — Primitives.** Fixed/varint coding, CRC32C, 32-bit hash, Park–Miller RNG,
  bytewise + internal-key comparators. Golden-value tests ported from the C++
  suite.
- **M2 — Memtable.** Bump arena, generic skip list, internal-key format,
  reference-counted memtable, write batches.
- **M3 — WAL.** 32 KiB block framing with fragmentation and CRC verification,
  the `Env` interface, and an in-memory `Env` for tests.
- **M4 — SSTables.** Prefix-compressed blocks with restart points, block
  handles/footer/read-block, table builder and reader, Bloom filter policy and
  filter block. (Block cache deferred; see below.)
- **M5 — Iterators.** Iterator vtable, merging iterator, two-level iterator,
  user-facing DB iterator (version collapsing and tombstones).
- **M6 — Versions & MANIFEST.** Filenames, `VersionEdit` encode/decode,
  `Version`/`VersionSet`/`Compaction`, manifest log and recovery, table cache,
  snapshot list, table builder glue.
- **M7 — DB engine.** Writer queue with group commit, memtable rotation, read
  path, background compaction worker, recovery, garbage collection, snapshots,
  manual compaction.
- **M8 — CLI & docs.** A real `std.Io`-backed filesystem `Env`, a `put/get/del/
  scan/compact` CLI, and these docs.

## Test coverage

- Unit tests colocated with every module (coding, CRC32C, hash, RNG, comparator,
  skiplist, memtable, write batch, log, block, table, Bloom, merger, DB
  iterator, filename, version edit, version set, snapshots).
- End-to-end DB tests: put/get/delete/reopen, iterate across memtable and
  tables (5000 keys, forcing flushes), and delete-survives-compaction-and-reopen.

## Bugs worth remembering

These were found while building and are documented because they are easy to
reintroduce:

1. **`newFileNumber` must post-increment.** Otherwise every file reuses one
   number and overwrites the previous file.
2. **`Builder.saveTo` must honor deletions for added files.** A file added by one
   edit and deleted by a later edit must not be resurrected when replaying a
   MANIFEST.
3. **Copy the current user key in compaction.** A slice into a released block
   dangles; the comparison fails and tombstones stop hiding older values.
4. **`writeLevel0Table` must be symmetric about the mutex** (lock at entry,
   unlock at exit) so it can be called with the lock held or not.
5. **A fresh memtable's arena already owns one 4 KiB block**, so
   `write_buffer_size` must be clamped well above that.
6. **`Get` must release references on every path**, including errors, or
   versions leak and the version set cannot be torn down.

## Not implemented (and why)

- **Block cache.** Reads open a table per use. The `TableCache` API is shaped so
  an LRU can be added without touching callers.
- **Compression.** No Snappy/Zstd. The extension points are marked in
  `table/table_builder.zig` (`writeBlock`), `table/format.zig` (`readBlock`),
  and `table/table.zig`.
- **Repair, dumpfile, C API, benchmarks.** Useful in production, not needed to
  understand the engine.
- **Boundary-input expansion and input growth in compaction.** Avoided by never
  splitting a user key across output files.
- **`reuse_logs` / manifest reuse.** Every open writes a fresh MANIFEST.

## Next steps if you want to keep going

1. Add an LRU block cache and wire it into `Table::BlockReader`.
2. Add a table cache (LRU of open `Table`s keyed by file number).
3. Implement boundary-input expansion and expanded compaction.
4. Add `reuse_logs` and manifest reuse to speed up open.
5. Add Snappy/Zstd behind a build option.
6. Port the randomized model test from `db_test.cc`: run random
   put/delete/get/iterate operations against both the DB and a `std.StringHashMap`
   and compare.
7. Add a fault-injection `Env` wrapper to test crash recovery.
