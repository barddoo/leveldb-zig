# leveldb-zig (For learning purposes only)

A from-scratch, learning-oriented LSM storage engine in Zig 0.16, closely
modeled on Google's [LevelDB](https://github.com/google/leveldb).

The goal is understanding, not bit-for-bit compatibility. Every subsystem is
written to be read: the algorithms, the on-disk formats, and the concurrency
protocol are all documented in the source and in [`docs/`](docs/).

## What it does

- **Write-ahead log** — every write is appended to a log before it is acked, so
  a crash never loses an acknowledged write.
- **Memtable** — an arena-backed skip list holds recent writes in sorted order.
- **SSTables** — full memtables are flushed to sorted, immutable table files
  with prefix-compressed blocks and optional Bloom filters.
- **Leveled compaction** — a background worker merges levels that exceed their
  size budget and drops overwritten values and obsolete tombstones.
- **Versions & MANIFEST** — the set of live files is tracked by immutable
  versions and persisted as a log of deltas (the MANIFEST).
- **Recovery** — on open, the MANIFEST is replayed and the WAL is re-applied.
- **Snapshots** — reads can pin a sequence number and ignore later writes.

Compression is deliberately not implemented; the table builder marks the exact
place where a codec (Snappy/Zstd) would slot in.

## Build and run

Requires Zig 0.16.0.

```sh
zig build                      # build the library and CLI
zig build test                 # run all unit and integration tests
zig build run -- help          # CLI help

# Try it:
./zig-out/bin/leveldb-zig put  /tmp/mydb hello world
./zig-out/bin/leveldb-zig get  /tmp/mydb hello
./zig-out/bin/leveldb-zig scan /tmp/mydb
./zig-out/bin/leveldb-zig compact /tmp/mydb
```

## Using the library

```zig
const std = @import("std");
const leveldb = @import("leveldb");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const ioenv = try leveldb.io_env.IoEnv.init(gpa, io);
    defer ioenv.deinit();

    const db = try leveldb.DB.open(gpa, io, ioenv.env(), .{
        .create_if_missing = true,
    }, "/tmp/mydb");
    defer db.close();

    try db.put("greeting", "hello", .{});
    try db.delete("greeting", .{});

    var value = std.ArrayList(u8).empty;
    defer value.deinit(gpa);
    db.get("greeting", .{}, &value) catch |err| switch (err) {
        error.NotFound => std.debug.print("absent\n", .{}),
        else => return err,
    };
}
```

## Layout

```
src/
  primitives/   byte coding, CRC32C, hashing, RNG, comparators
  memtable/     arena, skip list, memtable, write batch
  log/          WAL / MANIFEST record framing
  table/        blocks, SSTable builder/reader, Bloom filters, table cache
  iter/         iterator vtable, merge, two-level, DB iterator
  db/           env, filenames, versions, MANIFEST, compaction, DB engine
tests/          end-to-end integration tests
docs/           architecture, format, concurrency, milestones
```

Start with [`docs/00-overview.md`](docs/00-overview.md), then follow the reading
order it suggests.
