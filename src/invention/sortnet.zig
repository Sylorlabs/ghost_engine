//! sortnet.zig — point the generate→test→keep loop at a real algorithm-discovery problem with a
//! SOUND exact verifier: minimal SORTING NETWORKS. This is the niche where verified discovery is
//! real (Hillis's evolved sorting networks; DeepMind FunSearch/AlphaTensor live here too) — NOT the
//! famous open AI problems (hallucination/alignment/reasoning), which lack a cheap exact verifier.
//!
//! A sorting network is a fixed sequence of compare-exchange (i,j) ops. The 0-1 PRINCIPLE makes the
//! verifier exact and cheap: a network sorts all inputs iff it sorts all 2^n binary inputs. So:
//!   generate (greedy build + random restarts) → test (sorts all 2^n 0/1 vectors? exact) → keep
//!   (smallest network that sorts). We then COMPARE the engine's sizes to the published optima.
//!
//! HONEST framing up front: optimal sizes for small n are KNOWN (solved), so matching them is
//! VALIDATION, not solving an open problem; the genuinely-open large-n cases are intractable on a
//! laptop. We measure and report the truth.
const std = @import("std");

const Comp = struct { i: u5, j: u5 };
const MAXLEN = 64;

// 0-1 principle: sorts everything iff it sorts all 2^n binary inputs (ascending = 0s in low indices).
fn sortsAll(net: []const Comp, n: u5) bool {
    const lim: u32 = @as(u32, 1) << n;
    var x: u32 = 0;
    while (x < lim) : (x += 1) {
        var b = x;
        for (net) |c| {
            const bi = (b >> c.i) & 1;
            const bj = (b >> c.j) & 1;
            if (bi == 1 and bj == 0) { // out of order (i<j must hold the smaller) → exchange
                b &= ~(@as(u32, 1) << c.i);
                b |= (@as(u32, 1) << c.j);
            }
        }
        // sorted ⇔ bits non-decreasing in index ⇔ b = 1…10…0 = (lim-1) & ~(lim-1 >> p): all 1s on top
        var k: u5 = 0;
        var prev: u32 = 0;
        while (k < n) : (k += 1) {
            const bit = (b >> k) & 1;
            if (bit < prev) return false;
            prev = bit;
        }
    }
    return true;
}
fn unsortedCount(net: []const Comp, n: u5) u32 {
    const lim: u32 = @as(u32, 1) << n;
    var bad: u32 = 0;
    var x: u32 = 0;
    while (x < lim) : (x += 1) {
        var b = x;
        for (net) |c| {
            const bi = (b >> c.i) & 1;
            const bj = (b >> c.j) & 1;
            if (bi == 1 and bj == 0) {
                b &= ~(@as(u32, 1) << c.i);
                b |= (@as(u32, 1) << c.j);
            }
        }
        var k: u5 = 0;
        var prev: u32 = 0;
        var sorted = true;
        while (k < n) : (k += 1) {
            const bit = (b >> k) & 1;
            if (bit < prev) {
                sorted = false;
                break;
            }
            prev = bit;
        }
        if (!sorted) bad += 1;
    }
    return bad;
}

// GENERATE: greedily add the comparator that fixes the most 0/1 inputs (ties broken randomly).
fn greedyBuild(net: *[MAXLEN]Comp, n: u5, rng: std.Random) usize {
    var len: usize = 0;
    while (len < MAXLEN) {
        if (unsortedCount(net[0..len], n) == 0) break;
        var best = Comp{ .i = 0, .j = 1 };
        var bestBad: u32 = std.math.maxInt(u32);
        var bestTies: u32 = 1;
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            var j: u5 = i + 1;
            while (j < n) : (j += 1) {
                net[len] = .{ .i = i, .j = j };
                const bad = unsortedCount(net[0 .. len + 1], n);
                if (bad < bestBad) {
                    bestBad = bad;
                    best = .{ .i = i, .j = j };
                    bestTies = 1;
                } else if (bad == bestBad) {
                    bestTies += 1;
                    if (rng.uintLessThan(u32, bestTies) == 0) best = .{ .i = i, .j = j };
                }
            }
        }
        net[len] = best;
        len += 1;
    }
    return len;
}
// KEEP smaller: drop any comparator whose removal still leaves a valid sorter (repeat to fixpoint).
fn prune(net: *[MAXLEN]Comp, len0: usize, n: u5) usize {
    var len = len0;
    var improved = true;
    while (improved) {
        improved = false;
        var idx: usize = 0;
        while (idx < len) : (idx += 1) {
            var tmp: [MAXLEN]Comp = undefined;
            var t: usize = 0;
            var k: usize = 0;
            while (k < len) : (k += 1) {
                if (k == idx) continue;
                tmp[t] = net[k];
                t += 1;
            }
            if (sortsAll(tmp[0..t], n)) {
                @memcpy(net[0..t], tmp[0..t]);
                len = t;
                improved = true;
                break;
            }
        }
    }
    return len;
}

fn search(n: u5, budget_ms: i64, rng: std.Random) usize {
    var best: usize = MAXLEN;
    const t0 = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - t0 < budget_ms) {
        var net: [MAXLEN]Comp = undefined;
        const len = greedyBuild(&net, n, rng);
        const plen = prune(&net, len, n);
        if (plen < best and sortsAll(net[0..plen], n)) best = plen;
    }
    return best;
}

pub fn main() !void {
    const o = std.io.getStdOut().writer();
    var prng = std.Random.DefaultPrng.init(20260624);
    const rng = prng.random();

    try o.print("=== ALGORITHM DISCOVERY with a SOUND verifier: minimal SORTING NETWORKS ===\n", .{});
    try o.print("  generate (greedy+restart) -> test (sorts all 2^n binary inputs, exact 0-1 principle) -> keep.\n", .{});
    try o.print("  comparing the engine's discovered sizes to the PUBLISHED optima.\n\n", .{});
    try o.print("    n | engine (verified) | known optimal | verdict\n", .{});
    try o.print("  ----+-------------------+---------------+----------------------\n", .{});

    const known = [_]struct { n: u5, opt: usize }{
        .{ .n = 4, .opt = 5 },  .{ .n = 5, .opt = 9 },   .{ .n = 6, .opt = 12 },
        .{ .n = 7, .opt = 16 }, .{ .n = 8, .opt = 19 },  .{ .n = 9, .opt = 25 },
    };
    for (known) |kn| {
        const got = search(kn.n, 700, rng);
        const verdict = if (got == kn.opt) "OPTIMAL (matches)" else if (got < kn.opt) "BELOW KNOWN?! (recheck)" else "above optimal";
        try o.print("    {d} |        {d:>2}         |      {d:>2}       | {s}\n", .{ kn.n, got, kn.opt, verdict });
    }

    try o.print("\n  Read-out: where the engine matches the optimum it's VALIDATION (these are solved); where it's\n", .{});
    try o.print("  above, blind generate+prune simply isn't AlphaTensor-grade search. The point: this is the\n", .{});
    try o.print("  CLASS of AI problem this engine can touch at all — exact verifier + discrete search. The famous\n", .{});
    try o.print("  open problems (hallucination, alignment, reasoning) have NO cheap exact verifier, so this\n", .{});
    try o.print("  paradigm cannot address them — and saying otherwise would be theater, not research.\n", .{});
}

test "verifier is sound: a known 4-input optimal network sorts; a broken one does not" {
    // optimal 5-comparator network for n=4
    const good = [_]Comp{ .{ .i = 0, .j = 1 }, .{ .i = 2, .j = 3 }, .{ .i = 0, .j = 2 }, .{ .i = 1, .j = 3 }, .{ .i = 1, .j = 2 } };
    try std.testing.expect(sortsAll(&good, 4));
    const bad = [_]Comp{ .{ .i = 0, .j = 1 }, .{ .i = 2, .j = 3 } }; // too few — cannot sort
    try std.testing.expect(!sortsAll(&bad, 4));
}
