//! Shared constants for the write-ahead log and MANIFEST, from
//! `db/log_format.h` and `doc/log_format.md`.
//!
//! The log is a sequence of 32 KiB blocks. Each block holds records:
//!
//!     checksum : fixed32 (little-endian)
//!     length   : fixed16 (little-endian)
//!     type     : u8 (FULL/FIRST/MIDDLE/LAST)
//!     data     : length bytes
//!
//! Records larger than the remaining space are split across blocks: FIRST,
//! then zero or more MIDDLE, then LAST. A record never starts in the final six
//! bytes of a block; the leftover is zero-filled trailer.

/// The log is divided into blocks of this size. A record never spans a block
/// boundary; oversized records are fragmented instead.
pub const block_size = 32768;
/// Bytes of framing before each record's payload: 4-byte CRC, 2-byte length,
/// 1-byte type.
pub const header_size = 7; // 4-byte crc + 2-byte length + 1-byte type

/// How a physical record relates to a logical record.
pub const RecordType = enum(u8) {
    /// Reserved for preallocated files; readers skip these.
    zero = 0,
    /// The whole logical record fits in this one physical record.
    full = 1,
    /// First fragment of a logical record split across blocks.
    first = 2,
    /// A middle fragment.
    middle = 3,
    /// Final fragment.
    last = 4,
};

/// Highest real record type. Values above this are reader-only pseudo-types.
pub const max_record_type: u8 = @intFromEnum(RecordType.last);

/// Reader-only pseudo-types, one past the real record types. `readRecord`
/// returns EOF/bad as internal markers, never as on-disk values.
pub const eof_type: u8 = max_record_type + 1;
pub const bad_record_type: u8 = max_record_type + 2;
