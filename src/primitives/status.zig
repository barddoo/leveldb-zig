//! Domain errors shared across the storage engine.
//!
//! LevelDB models results with a `Status` value type (an OK/error code plus an
//! optional message). Zig's error unions are a better fit for control flow, so
//! this module defines the error set and reserves human-readable detail for the
//! `Env`/`Table` boundary where an OS message is genuinely useful.
//!
//! Conventions:
//!   * `error.NotFound`      — key/file not present. Not always a failure.
//!   * `error.Corruption`    — bytes on disk do not match the expected format.
//!   * `error.NotSupported`  — feature or file type not implemented.
//!   * `error.InvalidArgument` — caller passed something malformed.
//!   * `error.IoError`       — the environment failed a read/write/sync.

const std = @import("std");

/// The error set returned by almost every fallible operation in the engine.
///
/// It is deliberately small and closed, so callers can switch on it
/// exhaustively. Allocation failures (`error.OutOfMemory`) and the standard
/// library's `error.Canceled` are *not* members; functions that can fail that
/// way use an inferred error set that includes this one.
pub const Error = error{
    /// The key or file does not exist. Often a normal result, not a failure.
    NotFound,
    /// Bytes on disk do not match the expected format, or a checksum failed.
    Corruption,
    /// The requested feature or file type is not implemented.
    NotSupported,
    /// The caller passed something malformed (bad options, bad range, ...).
    InvalidArgument,
    /// The environment failed a read, write, sync, lock, or similar operation.
    IoError,
};

/// A convenient return type for operations that can only fail with a domain
/// error and otherwise produce nothing.
pub const Result = Error!void;

/// True for the errors callers usually treat as "absent" rather than fatal.
/// Used to turn a `catch` into a "was it missing?" check.
pub fn isNotFound(err: anyerror) bool {
    return err == error.NotFound;
}

/// Human-readable name for logging. `@errorName` already does most of the work;
/// this is a single place to special-case messages later if needed.
pub fn describe(err: anyerror) []const u8 {
    return @errorName(err);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "error classification" {
    try testing.expect(isNotFound(error.NotFound));
    try testing.expect(!isNotFound(error.Corruption));
    try testing.expectEqualStrings("Corruption", describe(error.Corruption));
}
