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

pub const Error = error{
    NotFound,
    Corruption,
    NotSupported,
    InvalidArgument,
    IoError,
};

/// A common return type for operations that only need domain errors.
pub const Result = Error!void;

/// True for the errors that callers usually treat as "absent" rather than fatal.
pub fn isNotFound(err: anyerror) bool {
    return err == error.NotFound;
}

/// Human-readable name for logging. `@errorName` already does most of the work,
/// but this keeps a single place to special-case messages later.
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
