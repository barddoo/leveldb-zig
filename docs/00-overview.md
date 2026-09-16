# Overview

This is a small LSM-tree storage engine. If you have used LevelDB or RocksDB,
the shape will be familiar; if not, this document explains how the pieces fit
and suggests a reading order.

## The one-sentence version

Writes are appended to a log and an in-memory sorted buffer; when the buffer
fills it becomes an immutable sorted file; a background worker merges those
files across levels to keep reads fast and reclaim space.

## Data flow

```
                 put/delete
                     |
                     v
              +--------------+        +------------------+
              |  WriteBatch  | -----> |  WAL (log file)  |   (durable)
              +--------------+        +------------------+
                     |
                     v
              +--------------+
              |   MemTable   |  (arena + skip list, sorted by internal key)
              +--------------+
                     |  full
                     v
              +--------------+        +------------------+
              |  Immutable   | -----> |  SSTable (L0)    |
              |  MemTable    |        +------------------+
              +--------------+
                                          |  background compaction
                                          v
                              L0 -> L1 -> L2 -> ... -> L6
                              (each level ~10x larger than the last)

  Get(key):
    memtable -> immutable memtable -> level 0 (newest first) -> levels 1..6
```

## The three big ideas

1. **Internal keys.** A user key is stored many times, each version tagged with
   a sequence number and a value/deletion type. Sorting by user key ascending
   and sequence descending means a seek lands on the newest visible version.
   This is what makes `Get` cheap and tombstones possible.

2. **Immutable sorted files.** Once a table is written it is never modified.
   That makes caching and concurrency simple: readers never see a file change
   under them, and compaction writes new files and atomically swaps them in.

3. **Versions and a manifest.** The set of live files is an immutable `Version`.
   Changes are deltas (`VersionEdit`) appended to the MANIFEST, which is just a
   log. Recovery replays it to reconstruct the current version.

## Reading order

1. `src/primitives/coding.zig` — how numbers become bytes.
2. `src/memtable/skiplist.zig` and `memtable.zig` — the write buffer.
3. `src/log/log_writer.zig` / `log_reader.zig` — the WAL format.
4. `src/table/block_builder.zig` / `block.zig` — prefix-compressed blocks.
5. `src/table/table_builder.zig` / `table.zig` — SSTable layout.
6. `src/iter/iterator.zig`, `merger.zig`, `db_iter.zig` — merging versions.
7. `src/db/version_set.zig` — versions, compaction selection, MANIFEST.
8. `src/db/db_impl.zig` — the engine: write path, read path, background worker.

Each file has a header comment explaining the algorithm and pointing at the
original LevelDB file it was ported from.
