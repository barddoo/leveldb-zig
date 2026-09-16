# On-disk format

All integers are little-endian. Variable-length integers ("varints") are LEB128:
seven payload bits per byte, high bit set means another byte follows.

## Internal keys

Every entry in the engine is keyed by an *internal key*:

```
internal_key := user_key || fixed64(tag)
tag          := (sequence << 8) | type
type         := 0 (deletion) | 1 (value)
```

Sequence numbers are 56 bits (`max = 2^56 - 1`). Internal keys sort by user key
ascending and, for equal user keys, by tag *descending*. That means a seek to
`(user_key, sequence, value_type)` lands on the newest version at or below the
snapshot.

## WAL / MANIFEST records

Both the write-ahead log and the MANIFEST use the same record framing. The file
is a sequence of 32 KiB blocks; each block holds records:

```
crc32c   fixed32   // masked CRC of (type || data)
length   fixed16
type     u8        // 1 FULL, 2 FIRST, 3 MIDDLE, 4 LAST
data     length bytes
```

A record never starts in the last 6 bytes of a block; the leftover is a
zero-filled trailer. Records larger than the remaining space are split into
FIRST / MIDDLE* / LAST fragments.

The MANIFEST stores `VersionEdit` records (see below) in this framing.

## Block

Blocks are used for table data, indexes, and metaindexes. Keys are
prefix-compressed against the previous key. Every `restart_interval` entries
the full key is stored (a "restart point") so a reader can binary-search.

```
entry:
  varint32 shared          // bytes shared with the previous key
  varint32 unshared        // bytes of new key
  varint32 value_length
  byte[unshared] key_delta
  byte[value_length] value

block:
  entry[0] ... entry[N-1]
  fixed32 restart[0..R-1]  // offsets from block start
  fixed32 R
```

Data and metaindex blocks use `restart_interval = 16`; index blocks use `1`.

## Block trailer

Every stored block is followed by a 5-byte trailer:

```
u8      compression_type   // 0 = none (this project)
fixed32 Mask(crc32c(block_bytes || type))
```

`Mask(c) = rotl(c, 17) + 0xa282ead8`. This is where a codec would go.

## Table file

```
[data block 1] [trailer]
[data block 2] [trailer]
...
[filter block] [trailer]        // optional, if a filter policy is set
[metaindex block] [trailer]
[index block] [trailer]
[Footer]                        // fixed 48 bytes
```

- **Index block**: one entry per data block. Key is the last key of the block
  (shortened with `FindShortestSeparator`), value is a `BlockHandle`.
- **Filter block**: one Bloom filter per 2 KiB region of the file.
- **Metaindex block**: maps `"filter." + policy_name` to the filter's
  `BlockHandle`.
- **BlockHandle**: `varint64 offset || varint64 size` (the size excludes the
  5-byte trailer).
- **Footer** (exactly 48 bytes):

```
metaindex_handle  BlockHandle
index_handle      BlockHandle
padding           zeros to byte 40
fixed32 magic_lo  0x8b80fb57
fixed32 magic_hi  0xdb477524     // magic = 0xdb4775248b80fb57
```

## Bloom filter

```
bit_array  ceil(max(64, n*bits_per_key)/8) bytes
k          u8        // probes, clamp [1,30], default bits_per_key=10 -> k=7
```

Hash seed `0xbc9f1d34`; double hashing with `delta = rotl(h, 15)`. Name stored
in the metaindex is `leveldb.BuiltinBloomFilter2`.

## Files

```
%06d.log        write-ahead log
%06d.sst        sorted table
MANIFEST-%06d   descriptor: a log of VersionEdit records
CURRENT         text file naming the live MANIFEST
LOCK            held for the lifetime of an open DB
%06d.dbtmp      temporary used when installing CURRENT
LOG, LOG.old    informational logs
```

`CURRENT` is installed atomically: write a temp file, sync, rename.

## VersionEdit

A delta describing version changes, encoded as `(varint32 tag, payload)`:

| tag | name | payload |
|---|---|---|
| 1 | comparator | length-prefixed name |
| 2 | log number | varint64 |
| 3 | next file number | varint64 |
| 4 | last sequence | varint64 |
| 5 | compact pointer | varint32 level, length-prefixed internal key |
| 6 | deleted file | varint32 level, varint64 number |
| 7 | new file | varint32 level, varint64 number, varint64 size, LP smallest, LP largest |
| 9 | prev log number | varint64 |

## Compaction drop rules

While merging, an entry is dropped if either holds:

- **Rule A** — a newer entry for the same user key already passed
  (`last_sequence_for_key <= smallest_snapshot`).
- **Rule B** — it is a deletion tombstone at or below the smallest snapshot and
  no file at a level deeper than the output contains that user key
  (`IsBaseLevelForKey`).

Both rules are snapshot-safe: they never drop data still visible to a live
snapshot.
