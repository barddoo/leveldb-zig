# Architecture: Zig module ↔ LevelDB source

This project is a port, so the fastest way to learn a module is to read it
alongside its C++ original. The table below maps every Zig file to the LevelDB
file(s) it came from.

## Primitives

| Zig | LevelDB | Notes |
|---|---|---|
| `primitives/coding.zig` | `util/coding.{h,cc}` | fixed little-endian + varints |
| `primitives/crc32c.zig` | `util/crc32c.{h,cc}` | table-driven CRC-32C + mask/unmask |
| `primitives/hash.zig` | `util/hash.{h,cc}` | murmur-like 32-bit hash |
| `primitives/random.zig` | `util/random.h` | Park–Miller RNG |
| `primitives/status.zig` | `include/leveldb/status.h`, `util/status.cc` | Zig error set instead of a Status object |
| `primitives/comparator.zig` | `include/leveldb/comparator.h`, `util/comparator.cc` | vtable; bytewise impl |

## Memtable

| Zig | LevelDB |
|---|---|
| `memtable/arena.zig` | `util/arena.{h,cc}` |
| `memtable/skiplist.zig` | `db/skiplist.h` |
| `memtable/memtable.zig` | `db/memtable.{h,cc}` |
| `memtable/write_batch.zig` | `db/write_batch.cc`, `db/write_batch_internal.h` |
| `db/internal_key.zig` | `db/dbformat.{h,cc}` (internal keys, LookupKey, comparators) |

## Log

| Zig | LevelDB |
|---|---|
| `log/log_format.zig` | `db/log_format.h` |
| `log/log_writer.zig` | `db/log_writer.cc` |
| `log/log_reader.zig` | `db/log_reader.cc` |
| `log/log.zig` | aggregator + tests |

## Tables

| Zig | LevelDB |
|---|---|
| `table/block_builder.zig` | `table/block_builder.{h,cc}` |
| `table/block.zig` | `table/block.{h,cc}` |
| `table/format.zig` | `table/format.{h,cc}` (BlockHandle, Footer, ReadBlock) |
| `table/table_builder.zig` | `table/table_builder.cc` |
| `table/table.zig` | `table/table.{h,cc}` |
| `table/filter_policy.zig` | `util/bloom.cc`, `include/leveldb/filter_policy.h` |
| `table/filter_block.zig` | `table/filter_block.{h,cc}` |

## Iterators

| Zig | LevelDB |
|---|---|
| `iter/iterator.zig` | `include/leveldb/iterator.h`, `table/iterator.cc`, `table/iterator_wrapper.h` |
| `iter/merger.zig` | `table/merger.{h,cc}` |
| `iter/two_level.zig` | `table/two_level_iterator.{h,cc}` |
| `iter/db_iter.zig` | `db/db_iter.{h,cc}` |

## DB

| Zig | LevelDB |
|---|---|
| `db/env.zig` | `include/leveldb/env.h` |
| `db/io_env.zig` | `util/env_posix.cc` (reimplemented on `std.Io`) |
| `db/mem_env.zig` | `helpers/memenv/memenv.cc` |
| `db/filename.zig` | `db/filename.{h,cc}` |
| `db/version_edit.zig` | `db/version_edit.{h,cc}` |
| `db/version_set.zig` | `db/version_set.{h,cc}` |
| `db/snapshot.zig` | `db/snapshot.h` |
| `db/table_cache.zig` | `db/table_cache.{h,cc}` |
| `db/builder.zig` | `db/builder.{h,cc}` |
| `db/db_impl.zig` | `db/db_impl.{h,cc}` |
| `main.zig` | `db/leveldbutil.cc` (CLI) |

## Deliberate simplifications

These keep the code readable without changing observable behavior:

- **Versions** are tracked in an array instead of a circular linked list.
- **Table cache** opens a table per use instead of an LRU of open tables. The
  API (`get`, `newIterator`, `evict`) is shaped so a cache can be added later.
- **`Version.addIterators`** opens one table iterator per file; LevelDB uses a
  lazy concatenating iterator to avoid opening files that are never read.
- **Compaction** does not grow its inputs or pull in boundary files. Instead the
  compaction loop never splits a user key across output files, which removes the
  reason boundary files exist.
- **Snapshots** use an array instead of an intrusive list (O(n) `oldest`, but
  snapshots are rare).
- **No compression.** See the marked extension points in `table_builder.zig`,
  `format.zig`, and `table/table.zig`.
- **No repair/dumpfile/C API.** Not needed to understand the engine.

## Things worth studying

- `db/internal_key.zig` — the sequence/type tag and why seeks work.
- `table/block.zig` `seek` — binary search over restart points.
- `iter/merger.zig` — the direction-switching merge trick.
- `iter/db_iter.zig` — collapsing versions and tombstones.
- `db/version_set.zig` — compaction picking and the MANIFEST.
- `db/db_impl.zig` — the writer queue and background worker.
