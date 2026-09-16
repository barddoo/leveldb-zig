//! Park-Miller "minimal standard" pseudo-random number generator, ported from
//! `util/random.h`.
//!
//! LevelDB uses this in two places where reproducibility matters more than
//! statistical quality:
//!   * choosing skip-list node heights, and
//!   * deciding when to sample a read for compaction scoring.
//!
//! It is deliberately a tiny, seedable LCG so tests can be deterministic.

const std = @import("std");

const A: u64 = 16807;
const M: u64 = 2147483647; // 2^31 - 1

pub const Random = struct {
    seed: u32,

    pub fn init(seed: u32) Random {
        var s = seed & 0x7fff_ffff;
        if (s == 0 or s == M) s = 1;
        return .{ .seed = s };
    }

    /// Advance the generator and return the next value in [1, 2^31 - 2].
    pub fn next(self: *Random) u32 {
        const product: u64 = @as(u64, self.seed) * A;
        var s: u64 = (product >> 31) + (product & M);
        if (s > M) s -= M;
        self.seed = @intCast(s);
        return self.seed;
    }

    /// Uniform value in [0, n).
    pub fn uniform(self: *Random, n: u32) u32 {
        return self.next() % n;
    }

    /// True with probability 1/n.
    pub fn oneIn(self: *Random, n: u32) bool {
        return self.uniform(n) == 0;
    }

    /// Skewed toward small values: returns a value in [1, 1<<max_log].
    pub fn skewed(self: *Random, max_log: u32) u32 {
        const log = self.uniform(max_log + 1);
        return self.uniform(@as(u32, 1) << @intCast(log));
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "seed normalization" {
    try testing.expectEqual(@as(u32, 1), Random.init(0).seed);
    try testing.expectEqual(@as(u32, 1), Random.init(2147483647).seed);
    try testing.expectEqual(@as(u32, 1), Random.init(0x8000_0001).seed);
}

test "deterministic sequence" {
    var a = Random.init(42);
    var b = Random.init(42);
    for (0..100) |_| {
        try testing.expectEqual(a.next(), b.next());
    }
}

test "uniform stays in range" {
    var r = Random.init(7);
    for (0..1000) |_| {
        try testing.expect(r.uniform(10) < 10);
    }
}
