//! A simple bump-pointer arena, modeled on `util/arena.{h,cc}`.
//!
//! The memtable allocates every node and every key/value copy from an arena and
//! never frees individually. When the memtable is retired the whole arena is
//! dropped at once. That makes writes cheap: allocation is a pointer bump, and
//! there is no per-object bookkeeping.
//!
//! Layout: memory is handed out of a current 4 KiB block until it is exhausted.
//! Small requests that do not fit start a new block; requests larger than a
//! quarter block get their own dedicated block so a single large value cannot
//! waste most of a block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// Alignment guaranteed by the backing allocator; the skiplist needs pointers.
pub const alignment = @alignOf(usize);

const Block = []align(alignment) u8;

pub const Arena = struct {
    gpa: Allocator,
    blocks: ArrayList(Block) = .empty,
    alloc_ptr: [*]u8 = undefined,
    alloc_bytes_remaining: usize = 0,
    memory_usage: usize = 0,

    pub const block_size = 4096;

    pub fn init(gpa: Allocator) Arena {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Arena) void {
        for (self.blocks.items) |block| self.gpa.free(block);
        self.blocks.deinit(self.gpa);
    }

    /// Approximate bytes of memory owned by this arena.
    pub fn memoryUsage(self: *const Arena) usize {
        return self.memory_usage;
    }

    /// Allocate `bytes` with default alignment.
    pub fn allocate(self: *Arena, bytes: usize) ![]u8 {
        if (bytes <= self.alloc_bytes_remaining) {
            const result = self.alloc_ptr[0..bytes];
            self.alloc_ptr += bytes;
            self.alloc_bytes_remaining -= bytes;
            return result;
        }
        return self.allocateFallback(bytes);
    }

    fn allocateFallback(self: *Arena, bytes: usize) ![]u8 {
        if (bytes > block_size / 4) {
            // Large request: dedicate a block to it so the current block's
            // remaining space is not stranded.
            const block = try self.gpa.alignedAlloc(u8, .of(usize), bytes);
            try self.blocks.append(self.gpa, block);
            self.memory_usage += block.len + @sizeOf(Block);
            return block;
        }

        const block = try self.gpa.alignedAlloc(u8, .of(usize), block_size);
        try self.blocks.append(self.gpa, block);
        self.memory_usage += block.len + @sizeOf(Block);

        self.alloc_ptr = block.ptr;
        self.alloc_bytes_remaining = block.len;

        const result = self.alloc_ptr[0..bytes];
        self.alloc_ptr += bytes;
        self.alloc_bytes_remaining -= bytes;
        return result;
    }

    /// Allocate `bytes` aligned to `align_of` (a power of two, at most
    /// `alignment`). The returned slice's real address is aligned, so callers
    /// may `@alignCast` it.
    pub fn allocateAligned(self: *Arena, bytes: usize, align_of: usize) ![]u8 {
        std.debug.assert(std.math.isPowerOfTwo(align_of));
        std.debug.assert(align_of <= alignment);

        const current = @intFromPtr(self.alloc_ptr);
        const aligned = std.mem.alignForward(usize, current, align_of);
        const slop = aligned - current;

        if (self.alloc_bytes_remaining >= slop + bytes) {
            self.alloc_ptr += slop;
            self.alloc_bytes_remaining -= slop;
            const result = self.alloc_ptr[0..bytes];
            self.alloc_ptr += bytes;
            self.alloc_bytes_remaining -= bytes;
            return result;
        }

        // The current block cannot satisfy an aligned request; start fresh.
        // A new block is `alignment`-aligned, which satisfies `align_of`.
        const block = try self.gpa.alignedAlloc(u8, .of(usize), block_size);
        try self.blocks.append(self.gpa, block);
        self.memory_usage += block.len + @sizeOf(Block);

        self.alloc_ptr = block.ptr;
        self.alloc_bytes_remaining = block.len;

        const result = self.alloc_ptr[0..bytes];
        self.alloc_ptr += bytes;
        self.alloc_bytes_remaining -= bytes;
        return result;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "arena hands out distinct memory" {
    var arena = Arena.init(testing.allocator);
    defer arena.deinit();

    const a = try arena.allocate(100);
    const b = try arena.allocate(100);
    try testing.expect(a.ptr != b.ptr);
    @memset(a, 0xaa);
    @memset(b, 0xbb);
    try testing.expectEqual(@as(u8, 0xaa), a[0]);
    try testing.expectEqual(@as(u8, 0xbb), b[0]);
}

test "arena large allocation and alignment" {
    var arena = Arena.init(testing.allocator);
    defer arena.deinit();

    const big = try arena.allocate(Arena.block_size * 2);
    try testing.expectEqual(Arena.block_size * 2, big.len);

    const aligned = try arena.allocateAligned(24, 8);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 8);
    try testing.expect(arena.memoryUsage() > 0);
}
