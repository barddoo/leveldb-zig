//! A generic skip list, ported from `db/skiplist.h`.
//!
//! The memtable needs a sorted structure that supports concurrent lock-free
//! reads while a single writer inserts. A skip list gives that: inserts publish
//! nodes with release stores, readers traverse with acquire loads, and nothing
//! is ever deleted.
//!
//! Two deliberate simplifications vs. the C++ version, both for readability:
//!
//!   1. Every node embeds the full `max_height` pointer array rather than
//!      over-allocating exactly its own height. This costs a little memory per
//!      node but removes manual pointer arithmetic.
//!   2. `Key` is a Zig value (for the memtable, a `[]const u8` slice) rather
//!      than a bare `const char*`.
//!
//! `Cmp` must be a type with a method `compare(self, a: Key, b: Key) i32`.

const std = @import("std");
const Arena = @import("arena.zig").Arena;
const Random = @import("../primitives/random.zig").Random;

pub fn SkipList(comptime Key: type, comptime Cmp: type) type {
    return struct {
        const Self = @This();

        pub const max_height = 12;

        const AtomicPtr = std.atomic.Value(?*Node);

        pub const Node = struct {
            key: Key,
            /// How many levels this node participates in. `next[0..height]` are
            /// the live links; the rest are unused.
            height: usize,
            /// Level 0 is a plain linked list of every node. Each higher level
            /// is a sparser "express lane" that skips over many nodes, so a
            /// search can drop down a level whenever it overshoots.
            next: [max_height]AtomicPtr,
        };

        cmp: Cmp,
        arena: *Arena,
        /// Sentinel node with no real key. It is the start of every level, so
        /// searches never need a null check on the left.
        head: *Node,
        /// Current maximum height in the list. Read racily by readers; a stale
        /// value is safe (see `insert`).
        current_max_height: std.atomic.Value(usize),
        rnd: Random,

        pub fn init(cmp: Cmp, arena: *Arena) !Self {
            const head = try newNode(arena, undefined, max_height);
            for (&head.next) |*link| link.* = .init(null);

            return .{
                .cmp = cmp,
                .arena = arena,
                .head = head,
                .current_max_height = .init(1),
                .rnd = Random.init(0xdeadbeef),
            };
        }

        fn newNode(arena: *Arena, key: Key, height: usize) !*Node {
            const mem = try arena.allocateAligned(@sizeOf(Node), @alignOf(Node));
            const node: *Node = @ptrCast(@alignCast(mem.ptr));
            node.key = key;
            node.height = height;
            for (node.next[0..height]) |*link| link.* = .init(null);
            return node;
        }

        /// Insert `key`. REQUIRES: nothing equal to `key` is present.
        ///
        /// The tricky part is publication. A concurrent reader must never see a
        /// half-linked node, so we:
        ///   1. find where the node goes at every level (filling `prev`),
        ///   2. allocate and initialize the node's own links first, and
        ///   3. splice it in with a *release* store, which makes all of the
        ///      node's earlier writes visible to a reader that acquires the
        ///      pointer.
        /// The node's `next` links are stored with relaxed ordering because
        /// nobody can reach the node until step 3 publishes it.
        pub fn insert(self: *Self, key: Key) !void {
            var prev: [max_height]*Node = undefined;
            const existing = self.findGreaterOrEqual(key, &prev);
            std.debug.assert(existing == null or self.cmp.compare(key, existing.?.key) != 0);

            const height = self.randomHeight();
            const old_max = self.current_max_height.load(.monotonic);
            if (height > old_max) {
                for (old_max..height) |i| prev[i] = self.head;
                // It is safe to raise the height without synchronizing with
                // readers: a reader that sees the new height either sees a null
                // pointer from head (drops a level) or the fully published node.
                self.current_max_height.store(height, .monotonic);
            }

            const node = try newNode(self.arena, key, height);
            for (0..height) |i| {
                // Point the new node at its successor...
                node.next[i].store(prev[i].next[i].load(.monotonic), .monotonic);
                // ...then point the predecessor at the new node. This is the
                // release store that publishes the node.
                prev[i].next[i].store(node, .release);
            }
        }

        pub fn contains(self: *const Self, key: Key) bool {
            const node = self.findGreaterOrEqual(key, null);
            if (node) |n| return self.cmp.compare(key, n.key) == 0;
            return false;
        }

        /// Pick a node height. Each level up is taken with probability 1/4, so
        /// ~3/4 of nodes are height 1, ~3/16 are height 2, and so on. This
        /// geometric distribution is what gives a skip list its O(log n)
        /// expected search time with no rebalancing.
        fn randomHeight(self: *Self) usize {
            const branching = 4;
            var height: usize = 1;
            while (height < max_height and self.rnd.oneIn(branching)) : (height += 1) {}
            return height;
        }

        /// Return the first node whose key is >= `key`, or null. If `prev` is
        /// given, fill `prev[level]` with the last node before `key` at each
        /// level up to the current max height.
        ///
        /// The walk: start at the top level. Move right while the next node is
        /// still less than `key`; when the next node is >= `key` (or null),
        /// remember `x` as the predecessor at this level and drop down one
        /// level. Repeat until level 0, where `next` is the answer.
        fn findGreaterOrEqual(self: *const Self, key: Key, prev: ?*[max_height]*Node) ?*Node {
            var x = self.head;
            var level = self.current_max_height.load(.monotonic) - 1;
            while (true) {
                const next = x.next[level].load(.acquire);
                if (next) |n| {
                    if (self.cmp.compare(n.key, key) < 0) {
                        x = n;
                        continue; // keep moving right on this level
                    }
                }
                if (prev) |p| p[level] = x;
                if (level == 0) return next; // next is the first key >= target
                level -= 1;
            }
        }

        /// Return the last node whose key is < `key`; `head` if none.
        fn findLessThan(self: *const Self, key: Key) *Node {
            var x = self.head;
            var level = self.current_max_height.load(.monotonic) - 1;
            while (true) {
                const next = x.next[level].load(.acquire);
                if (next == null or self.cmp.compare(next.?.key, key) >= 0) {
                    if (level == 0) return x;
                    level -= 1;
                } else {
                    x = next.?;
                }
            }
        }

        /// Return the last node in the list; `head` if empty.
        fn findLast(self: *const Self) *Node {
            var x = self.head;
            var level = self.current_max_height.load(.monotonic) - 1;
            while (true) {
                const next = x.next[level].load(.acquire);
                if (next == null) {
                    if (level == 0) return x;
                    level -= 1;
                } else {
                    x = next.?;
                }
            }
        }

        pub const Iterator = struct {
            list: *const Self,
            node: ?*Node = null,

            pub fn valid(self: Iterator) bool {
                return self.node != null;
            }

            pub fn key(self: Iterator) Key {
                std.debug.assert(self.node != null);
                return self.node.?.key;
            }

            pub fn next(self: *Iterator) void {
                std.debug.assert(self.node != null);
                self.node = self.node.?.next[0].load(.acquire);
            }

            pub fn prev(self: *Iterator) void {
                std.debug.assert(self.node != null);
                const n = self.list.findLessThan(self.node.?.key);
                self.node = if (n == self.list.head) null else n;
            }

            pub fn seek(self: *Iterator, target: Key) void {
                self.node = self.list.findGreaterOrEqual(target, null);
            }

            pub fn seekToFirst(self: *Iterator) void {
                self.node = self.list.head.next[0].load(.acquire);
            }

            pub fn seekToLast(self: *Iterator) void {
                const n = self.list.findLast();
                self.node = if (n == self.list.head) null else n;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .list = self };
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const IntCmp = struct {
    pub fn compare(_: IntCmp, a: i32, b: i32) i32 {
        return switch (std.math.order(a, b)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }
};

test "empty list" {
    var arena = Arena.init(testing.allocator);
    defer arena.deinit();
    var list = try SkipList(i32, IntCmp).init(.{}, &arena);

    var it = list.iterator();
    it.seekToFirst();
    try testing.expect(!it.valid());
    try testing.expect(!list.contains(1));
}

test "insert, contains, ordered iteration" {
    var arena = Arena.init(testing.allocator);
    defer arena.deinit();
    var list = try SkipList(i32, IntCmp).init(.{}, &arena);

    var rnd = Random.init(1234);
    var expected = std.ArrayList(i32).empty;
    defer expected.deinit(testing.allocator);

    for (0..500) |_| {
        const v: i32 = @intCast(rnd.uniform(1_000_000));
        if (list.contains(v)) continue;
        try list.insert(v);
        try expected.append(testing.allocator, v);
    }

    std.mem.sort(i32, expected.items, {}, std.sort.asc(i32));

    var it = list.iterator();
    it.seekToFirst();
    var idx: usize = 0;
    while (it.valid()) : (it.next()) {
        try testing.expectEqual(expected.items[idx], it.key());
        idx += 1;
    }
    try testing.expectEqual(expected.items.len, idx);

    for (expected.items) |v| try testing.expect(list.contains(v));
    try testing.expect(!list.contains(-1));
}

test "reverse iteration" {
    var arena = Arena.init(testing.allocator);
    defer arena.deinit();
    var list = try SkipList(i32, IntCmp).init(.{}, &arena);
    for ([_]i32{ 5, 1, 9, 3, 7 }) |v| try list.insert(v);

    var it = list.iterator();
    it.seekToLast();
    var got = std.ArrayList(i32).empty;
    defer got.deinit(testing.allocator);
    while (it.valid()) : (it.prev()) try got.append(testing.allocator, it.key());
    try testing.expectEqualSlices(i32, &.{ 9, 7, 5, 3, 1 }, got.items);
}

test "seek finds first >= target" {
    var arena = Arena.init(testing.allocator);
    defer arena.deinit();
    var list = try SkipList(i32, IntCmp).init(.{}, &arena);
    for ([_]i32{ 10, 20, 30, 40 }) |v| try list.insert(v);

    var it = list.iterator();
    it.seek(25);
    try testing.expect(it.valid());
    try testing.expectEqual(@as(i32, 30), it.key());
}
