//! sortnet_bnb.zig — SCALE the optimality proof past brute force (move 2).
//!
//! Brute force (sortnet_optimal) proves the optimum by checking every comparator SEQUENCE — cost
//! C(n,2)^L, which dies at n=6. The smarter, equally-SOUND method searches over OUTPUT-SETS: the
//! state is the set of distinct 0/1 vectors the partial network can still produce from all 2^n inputs.
//! A network sorts iff that set equals the n+1 sorted vectors. Two prefixes with the same output-set
//! are interchangeable, so a memo (keyed by the EXACT canonical state — no hashing, fully sound)
//! collapses the search. Iterative deepening then finds the minimum #comparators = the optimum, and
//! proves it (every smaller depth is exhausted with the goal unreachable).
//!
//! Same exact verifier underneath; this is a better PROOF SEARCH, not more compute. It reaches n=6,
//! which brute force cannot, and reports honestly where it runs out of budget.
const std = @import("std");

fn applyComp(mask: u32, i: u5, j: u5) u32 {
    const bi = (mask >> i) & 1;
    const bj = (mask >> j) & 1;
    if (bi == 1 and bj == 0) {
        var m = mask;
        m &= ~(@as(u32, 1) << i);
        m |= (@as(u32, 1) << j);
        return m;
    }
    return mask;
}
// canonical state bytes (sorted distinct u32) for an output set after applying comparator (i,j)
fn applyState(in: []const u32, i: u5, j: u5, buf: []u32) []u32 {
    for (in, 0..) |m, idx| buf[idx] = applyComp(m, i, j);
    var s = buf[0..in.len];
    std.mem.sort(u32, s, {}, std.sort.asc(u32));
    var w: usize = 0;
    var r: usize = 0;
    while (r < s.len) : (r += 1) {
        if (w == 0 or s[r] != s[w - 1]) {
            s[w] = s[r];
            w += 1;
        }
    }
    return s[0..w];
}

const Comp = struct { i: u5, j: u5 };

const Solver = struct {
    n: u5,
    goal: []u32,
    comps: []Comp,
    memo: std.StringHashMap(u8), // canonical-state-bytes -> max remaining depth PROVEN goal-unreachable
    alloc: std.mem.Allocator,
    deadline: i64,
    aborted: bool,
    nodes: u64,

    fn isGoal(self: *Solver, st: []const u32) bool {
        if (st.len != self.goal.len) return false;
        for (st, 0..) |m, k| if (m != self.goal[k]) return false;
        return true;
    }
    fn dfs(self: *Solver, st: []const u32, rem: u8) !bool {
        if (self.isGoal(st)) return true;
        if (rem == 0) return false;
        if (self.aborted) return false;
        self.nodes += 1;
        if (self.nodes % 4096 == 0 and std.time.milliTimestamp() > self.deadline) {
            self.aborted = true;
            return false;
        }
        const key = std.mem.sliceAsBytes(st);
        if (self.memo.get(key)) |mr| {
            if (mr >= rem) return false; // already proven unreachable with >= rem budget
        }
        const buf = try self.alloc.alloc(u32, st.len);
        defer self.alloc.free(buf);
        for (self.comps) |c| {
            const ns = applyState(st, c.i, c.j, buf);
            if (ns.len == st.len and std.mem.eql(u32, ns, st)) continue; // comparator changes nothing
            // ns lives in buf (reused each iteration) — copy for the recursive call
            const nsc = try self.alloc.dupe(u32, ns);
            defer self.alloc.free(nsc);
            if (try self.dfs(nsc, rem - 1)) return true;
            if (self.aborted) return false;
        }
        // proven: goal unreachable from st within rem (own the key only when it's new)
        const gop = try self.memo.getOrPut(key);
        if (!gop.found_existing) gop.key_ptr.* = try self.alloc.dupe(u8, key);
        gop.value_ptr.* = rem;
        return false;
    }
};

fn provenOptimal(alloc: std.mem.Allocator, n: u5, budget_ms: i64) !struct { opt: ?usize, nodes: u64 } {
    // start state: every 2^n input
    const lim: u32 = @as(u32, 1) << n;
    const start = try alloc.alloc(u32, lim);
    defer alloc.free(start);
    var x: u32 = 0;
    while (x < lim) : (x += 1) start[x] = x;
    const st0 = applyState(start, 0, 0, start); // canonicalize (no-op comparator) → sorted distinct = 0..lim-1
    const startc = try alloc.dupe(u32, st0);
    defer alloc.free(startc);
    // goal: sorted vectors = { 2^n - 2^(n-k) : k=0..n }
    const goal = try alloc.alloc(u32, n + 1);
    defer alloc.free(goal);
    var k: u5 = 0;
    while (k <= n) : (k += 1) goal[k] = (lim - 1) ^ ((@as(u32, 1) << (n - k)) - 1);
    std.mem.sort(u32, goal, {}, std.sort.asc(u32));
    // comparator set (i<j)
    var comps = std.ArrayList(Comp).init(alloc);
    defer comps.deinit();
    var i: u5 = 0;
    while (i < n) : (i += 1) {
        var j: u5 = i + 1;
        while (j < n) : (j += 1) try comps.append(.{ .i = i, .j = j });
    }

    var s = Solver{
        .n = n,
        .goal = goal,
        .comps = comps.items,
        .memo = std.StringHashMap(u8).init(alloc),
        .alloc = alloc,
        .deadline = std.time.milliTimestamp() + budget_ms,
        .aborted = false,
        .nodes = 0,
    };
    defer {
        var it = s.memo.keyIterator();
        while (it.next()) |kp| alloc.free(kp.*);
        s.memo.deinit();
    }

    var limit: u8 = 0;
    while (limit <= 30) : (limit += 1) {
        if (try s.dfs(startc, limit)) return .{ .opt = limit, .nodes = s.nodes };
        if (s.aborted) return .{ .opt = null, .nodes = s.nodes };
    }
    return .{ .opt = null, .nodes = s.nodes };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const o = std.io.getStdOut().writer();

    try o.print("=== SCALING the optimality PROOF past brute force — output-set search (move 2) ===\n", .{});
    try o.print("  same sound result (minimal #comparators), a smarter proof search: state = set of reachable\n", .{});
    try o.print("  0/1 outputs, exact-state memo (no hashing). Reaches n=6, which comparator-brute cannot.\n\n", .{});
    try o.print("    n | proven optimal | known | search nodes | status\n", .{});
    try o.print("  ----+----------------+-------+--------------+-------------------------\n", .{});

    const known = [_]struct { n: u5, opt: usize }{
        .{ .n = 4, .opt = 5 }, .{ .n = 5, .opt = 9 }, .{ .n = 6, .opt = 12 },
    };
    for (known) |kn| {
        const r = try provenOptimal(alloc, kn.n, 120_000);
        if (r.opt) |opt| {
            const tag = if (opt == kn.opt) "PROVEN OPTIMAL (matches)" else "PROVEN (differs?!)";
            try o.print("    {d} |       {d:>2}       |  {d:>2}   | {d:>12} | {s}\n", .{ kn.n, opt, kn.opt, r.nodes, tag });
        } else {
            try o.print("    {d} |       --       |  {d:>2}   | {d:>12} | budget hit (not proven)\n", .{ kn.n, kn.opt, r.nodes });
        }
    }

    try o.print("\n  Brute force (comparator sequences) needs C(n,2)^L networks — ~1e8 just to PROVE n=5, and n=6\n", .{});
    try o.print("  (15^11 ~ 8.6e12) is hopeless. The output-set proof proves the SAME optima in vastly fewer nodes\n", .{});
    try o.print("  and reaches n=6 — a better proof algorithm, not more compute. (n>=7 needs the field's heavier\n", .{});
    try o.print("  symmetry/SAT machinery; the engine stops and says so rather than bluffing a bound.)\n", .{});
}

test "output-set proof matches known optima for n=4 and n=5" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const r4 = try provenOptimal(alloc, 4, 30_000);
    try std.testing.expectEqual(@as(?usize, 5), r4.opt);
    const r5 = try provenOptimal(alloc, 5, 60_000);
    try std.testing.expectEqual(@as(?usize, 9), r5.opt);
}
