//! `leveldb-zig` command line interface.
//!
//! A thin shell over the library, useful for poking at a database by hand:
//!
//!     leveldb-zig put  <db> <key> <value>
//!     leveldb-zig get  <db> <key>
//!     leveldb-zig del  <db> <key>
//!     leveldb-zig scan <db>
//!     leveldb-zig compact <db>
//!     leveldb-zig help

const std = @import("std");
const leveldb = @import("leveldb");
const DB = leveldb.DB;
const IoEnv = leveldb.io_env.IoEnv;

/// Entry point. Parses `<command> <db> [args...]`, opens the DB against the
/// real filesystem, and dispatches. `sync = true` is used for writes so the CLI
/// is durable by default (a human expects a `put` to survive).
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // `init.minimal.args` holds the raw argv; skip argv[0] (the program name).
    var args = init.minimal.args.iterate();
    _ = args.next(); // argv[0]

    const command = args.next() orelse return usage(io);
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        return usage(io);
    }

    const dbpath = args.next() orelse {
        try stderr(io, "missing <db> path\n");
        return usage(io);
    };

    // The CLI always talks to real files, so use the std.Io-backed Env.
    const ioenv = try IoEnv.init(gpa, io);
    defer ioenv.deinit();

    const db = DB.open(gpa, io, ioenv.env(), .{ .create_if_missing = true }, dbpath) catch |err| {
        try stderr(io, "failed to open database\n");
        return err;
    };
    defer db.close();

    if (std.mem.eql(u8, command, "put")) {
        const key = args.next() orelse {
            try stderr(io, "put: missing <key> <value>\n");
            return;
        };
        const value = args.next() orelse {
            try stderr(io, "put: missing <key> <value>\n");
            return;
        };
        try db.put(key, value, .{ .sync = true });
    } else if (std.mem.eql(u8, command, "get")) {
        const key = args.next() orelse {
            try stderr(io, "get: missing <key>\n");
            return;
        };
        var out = std.ArrayList(u8).empty;
        defer out.deinit(gpa);
        db.get(key, .{}, &out) catch |err| switch (err) {
            error.NotFound => {
                try stderr(io, "not found\n");
                return;
            },
            else => return err,
        };
        try stdoutLine(io, out.items);
    } else if (std.mem.eql(u8, command, "del")) {
        const key = args.next() orelse {
            try stderr(io, "del: missing <key>\n");
            return;
        };
        try db.delete(key, .{ .sync = true });
    } else if (std.mem.eql(u8, command, "scan")) {
        const it = try db.newIterator(.{});
        defer it.deinit(gpa);
        it.seekToFirst();
        while (it.valid()) : (it.next()) {
            const line = try std.fmt.allocPrint(gpa, "{s} => {s}\n", .{ it.key(), it.value() });
            defer gpa.free(line);
            try stdoutLine(io, line);
        }
        try it.status();
    } else if (std.mem.eql(u8, command, "compact")) {
        try db.compactRange(null, null);
        try stderr(io, "compaction complete\n");
    } else {
        try stderr(io, "unknown command\n");
        try usage(io);
    }
}

fn stdoutLine(io: std.Io, data: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, data);
}

fn stderr(io: std.Io, data: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, data);
}

fn usage(io: std.Io) !void {
    try stderr(io,
        \\leveldb-zig — a learning-oriented LSM storage engine
        \\
        \\Usage: leveldb-zig <command> <db> [args]
        \\
        \\Commands:
        \\  put <db> <key> <value>   store a value
        \\  get <db> <key>           print a value
        \\  del <db> <key>           delete a key
        \\  scan <db>                print all key/value pairs in order
        \\  compact <db>             compact the whole database
        \\  help                     show this message
        \\
    );
}
