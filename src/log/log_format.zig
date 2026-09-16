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

pub const block_size = 32768;
pub const header_size = 7; // 4-byte crc + 2-byte length + 1-byte type

pub const RecordType = enum(u8) {
    /// Reserved for preallocated files.
    zero = 0,
    full = 1,
    first = 2,
    middle = 3,
    last = 4,
};

pub const max_record_type: u8 = @intFromEnum(RecordType.last);

/// Reader-only pseudo-types, one past the real record types.
pub const eof_type: u8 = max_record_type + 1;
pub const bad_record_type: u8 = max_record_type + 2;
