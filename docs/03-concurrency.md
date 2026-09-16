# Concurrency

The engine is safe for concurrent use by many threads. This document describes
the protocol and the invariants that keep it correct.

## The pieces

- `Io.Mutex` (`mutex`) guards all mutable DB state: the memtables, the log, the
  version set, the writer queue, snapshots, and pending outputs.
- `Io.Condition` (`bg_cv`) wakes the background worker and writers waiting for
  space.
- Each pending `Write` has its own `Writer` with a `Condition` (`cv`).
- `has_imm` and `shutting_down` are atomics so the background worker can check
  them cheaply.
- `Version`, `MemTable`, and `FileMetaData` are reference counted. A reader
  takes references before releasing the mutex and drops them afterwards.

All lock and wait calls use the **uncancelable** variants
(`lockUncancelable`, `waitUncancelable`). A canceled write in the middle of a
DB operation would leave inconsistent state, so cancellation is blocked here.

## Write path and group commit

Only the writer at the head of the queue performs I/O; others may have their
batches folded into the same log append (group commit).

```
Write(batch):
  lock
  append self to writers
  while not done and not at head: wait on my cv
  if done: return status              // folded into another writer's group
  status = MakeRoomForWrite()
  last_sequence = versions.lastSequence()
  last_writer = self
  if ok:
    group = BuildBatchGroup(&last_writer)
    group.setSequence(last_sequence + 1)
    last_sequence += group.count()
    unlock                            // log I/O happens without the lock
    log.addRecord(group)
    if sync: logfile.sync()
    if ok: group.insertInto(mem)
    lock
    versions.setLastSequence(last_sequence)
  pop writers up to last_writer, completing folded-in waiters
  signal new head
  unlock
```

Key invariants:

- A write is acknowledged only after its bytes are in the log (and synced, if
  requested).
- If `logfile.sync()` fails, the log's state is indeterminate. The DB records a
  background error and **all future writes fail** rather than risk corruption.
- `last_sequence` is advanced before the lock is dropped, so sequence numbers
  are assigned in order.

## Memtable rotation

`MakeRoomForWrite` runs with the lock held:

1. If there is a background error, fail.
2. If the active memtable has room, return.
3. If an immutable memtable exists, wait for the worker to flush it.
4. If level 0 has too many files, wait (write stall).
5. Otherwise: create a new log and memtable; the old memtable becomes `imm`;
   notify the worker.

The new log is installed **before** the old memtable becomes immutable, so a
crash can never leave acknowledged writes with no log.

## Background worker

One long-lived worker is started with `io.concurrent`. It loops:

```
lock
while not shutting down and no work: wait on bg_cv
if shutting down: unlock; return
unlock
BackgroundCompaction()          // flush imm first, then pick a compaction
lock
broadcast bg_cv                 // wake writers waiting for space
unlock
```

`BackgroundCompaction`:

- If `imm != null`, flush it to a level-0 table (priority over other work).
- Otherwise pick a compaction (size-triggered preferred, else seek-triggered).
- If it is a trivial move (one file, no overlap), just relink it one level down.
- Otherwise merge inputs into new files one level down, then install the result
  via `LogAndApply` and garbage-collect obsolete files.

If `io.concurrent` is unavailable, or `Options.disable_background_thread` is
set, compaction runs synchronously inside `MakeRoomForWrite` after rotation.
Tests use this mode for determinism.

## Reference counting

- `Version.ref` / `unref`. The current version is held by the version set; a
  reader or compaction takes an extra ref.
- `MemTable.ref` / `unref`. The DB holds the active and immutable memtables;
  an iterator or flush takes an extra ref.
- `FileMetaData.refs`. Each version that lists a file holds a reference.

References are dropped while holding `mutex` (see `DBImpl.releaseRefs`), because
dropping the last reference may free memory and mutate the version list.

## Read path

`Get` takes references to the memtable, immutable memtable, and current version,
then releases the lock and searches them in order. Afterwards it re-acquires the
lock to drop the references and, if a seek budget was exhausted, to schedule a
compaction.

`NewIterator` does the same, wrapping the merged iterator in a `CleanupIterator`
that drops the references when the iterator is destroyed.

## Garbage collection

`RemoveObsoleteFiles` computes the live set (pending compaction outputs plus
every file referenced by any live version), lists the directory, and deletes
everything else. It is skipped entirely after a background error, because the
set of committed versions is no longer known to be consistent.

## A note on the compaction loop

During compaction, the "current user key" is **copied** into an owned buffer,
not kept as a slice into the input iterator. When a child iterator advances past
its block, that block is released and the slice would dangle — which silently
breaks the "same user key" comparison and can resurrect deleted data. LevelDB
copies for the same reason.
