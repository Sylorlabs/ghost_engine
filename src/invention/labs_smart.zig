//! labs_smart.zig — #3 smarter search × #4 open target, as a BEFORE/AFTER on the SAME problem.
//!
//! LABS (Low-Autocorrelation Binary Sequences): minimize E(s)=Σ_{k=1}^{L-1} C_k², C_k=Σ_i s_i s_{i+k};
//! merit factor F = L²/(2E), higher is better. The optimal F is UNKNOWN for L beyond ~66 — a genuine
//! open problem. Same sound verifier throughout (exact energy), so any improvement is real.
//!
//!   BEFORE — naive multi-restart steepest descent: each candidate flip recomputes energy in O(L²).
//!   AFTER  — smart: keep the autocorrelation array C[] and compute a flip's ΔE in O(L) (≈L× more
//!            search per second), plus TABU to walk through local minima instead of only restarting.
//!   PROVEN — for small L, Gray-code EXHAUSTIVE search (incremental energy) certifies the true optimum.
//!
//! Equal wall-clock budget per length, so the gap is the effect of the smarter search itself.
const std = @import("std");

fn energyFull(s: []const i8) i64 {
    const L = s.len;
    var e: i64 = 0;
    var k: usize = 1;
    while (k < L) : (k += 1) {
        var c: i64 = 0;
        var i: usize = 0;
        while (i + k < L) : (i += 1) c += @as(i64, s[i]) * @as(i64, s[i + k]);
        e += c * c;
    }
    return e;
}
fn merit(L: usize, e: i64) f64 {
    if (e <= 0) return std.math.inf(f64);
    return @as(f64, @floatFromInt(L * L)) / (2.0 * @as(f64, @floatFromInt(e)));
}

// Maintain C[k] = Σ_i s_i s_{i+k}.  Flipping s[j] changes C[k] by -2·s[j]·(s[j-k]+s[j+k]).
fn initC(s: []const i8, C: []i64) void {
    const L = s.len;
    var k: usize = 1;
    while (k < L) : (k += 1) {
        var c: i64 = 0;
        var i: usize = 0;
        while (i + k < L) : (i += 1) c += @as(i64, s[i]) * @as(i64, s[i + k]);
        C[k] = c;
    }
}
fn flipDeltaE(s: []const i8, C: []const i64, j: usize) i64 {
    const L = s.len;
    var dE: i64 = 0;
    var k: usize = 1;
    while (k < L) : (k += 1) {
        var nb: i64 = 0;
        if (j >= k) nb += s[j - k];
        if (j + k < L) nb += s[j + k];
        const dCk = -2 * @as(i64, s[j]) * nb;
        const Ck = C[k];
        dE += (Ck + dCk) * (Ck + dCk) - Ck * Ck;
    }
    return dE;
}
fn applyFlip(s: []i8, C: []i64, j: usize) void {
    const L = s.len;
    var k: usize = 1;
    while (k < L) : (k += 1) {
        var nb: i64 = 0;
        if (j >= k) nb += s[j - k];
        if (j + k < L) nb += s[j + k];
        C[k] += -2 * @as(i64, s[j]) * nb;
    }
    s[j] = -s[j];
}

fn randSeq(s: []i8, rng: std.Random) void {
    for (s) |*x| x.* = if (rng.boolean()) 1 else -1;
}

// BEFORE: naive multi-restart steepest descent, recomputing full energy for every candidate flip.
fn naiveSearch(s: []i8, budget_ms: i64, rng: std.Random) i64 {
    const L = s.len;
    var best: i64 = std.math.maxInt(i64);
    const t0 = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - t0 < budget_ms) {
        randSeq(s, rng);
        var curE = energyFull(s);
        while (true) {
            var bj: usize = 0;
            var bE = curE;
            var j: usize = 0;
            while (j < L) : (j += 1) {
                s[j] = -s[j];
                const e = energyFull(s); // O(L²) per candidate — the naive cost
                s[j] = -s[j];
                if (e < bE) {
                    bE = e;
                    bj = j;
                }
            }
            if (bE >= curE) break; // local minimum
            s[bj] = -s[bj];
            curE = bE;
        }
        if (curE < best) best = curE;
    }
    return best;
}

// AFTER: smart search — incremental ΔE (O(L)) + tabu walk through local minima.
fn smartSearch(s: []i8, C: []i64, tabu: []i64, budget_ms: i64, rng: std.Random) i64 {
    const L = s.len;
    var best: i64 = std.math.maxInt(i64);
    const tenure: i64 = @intCast(L / 4 + 2);
    const t0 = std.time.milliTimestamp();
    var iter: i64 = 0;
    while (std.time.milliTimestamp() - t0 < budget_ms) {
        randSeq(s, rng);
        initC(s, C);
        var curE: i64 = 0;
        for (C[1..L]) |c| curE += c * c;
        for (tabu) |*t| t.* = -1_000_000;
        var since_improve: i64 = 0;
        while (since_improve < @as(i64, @intCast(8 * L))) {
            iter += 1;
            // pick the flip with the best ΔE that is not tabu (aspiration: allow tabu if it beats global best)
            var bj: usize = 0;
            var bDelta: i64 = std.math.maxInt(i64);
            var found = false;
            var j: usize = 0;
            while (j < L) : (j += 1) {
                const d = flipDeltaE(s, C, j); // O(L) per candidate — the smart cost
                const is_tabu = tabu[j] > iter;
                const aspires = curE + d < best;
                if ((!is_tabu or aspires) and d < bDelta) {
                    bDelta = d;
                    bj = j;
                    found = true;
                }
            }
            if (!found) break;
            applyFlip(s, C, bj);
            curE += bDelta;
            tabu[bj] = iter + tenure;
            if (curE < best) {
                best = curE;
                since_improve = 0;
            } else since_improve += 1;
        }
    }
    return best;
}

// PROVEN: Gray-code exhaustive over the 2^(L-1) sequences with s[0] fixed (energy is negation-invariant).
fn exhaustiveOptimal(s: []i8, C: []i64) i64 {
    const L = s.len;
    for (s) |*x| x.* = 1;
    initC(s, C);
    var E: i64 = 0;
    for (C[1..L]) |c| E += c * c;
    var best = E;
    const lim: u64 = @as(u64, 1) << @intCast(L - 1);
    var g: u64 = 1;
    while (g < lim) : (g += 1) {
        const p: usize = 1 + @ctz(g); // free bits are s[1..L-1]
        E += flipDeltaE(s, C, p);
        applyFlip(s, C, p);
        if (E < best) best = E;
    }
    return best;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const o = std.io.getStdOut().writer();
    var prng = std.Random.DefaultPrng.init(0x1ABE15EED);
    const rng = prng.random();

    try o.print("=== LABS: smarter search (#3) on an OPEN problem (#4) — BEFORE / AFTER ===\n", .{});
    try o.print("  merit factor F = L^2/(2E), higher is better; optimal F unknown for L > ~66 (open).\n", .{});
    try o.print("  before = naive steepest descent (energy O(L^2)/flip); after = incremental O(L)/flip + tabu.\n", .{});
    try o.print("  equal time budget per length, fixed seed.\n\n", .{});
    try o.print("    L  |  F_before  F_after  | F_proven (exhaustive) | regime\n", .{});
    try o.print("  -----+---------------------+-----------------------+---------------------------\n", .{});

    const lengths = [_]usize{ 13, 20, 27, 40, 60, 73, 101 };
    const budget_ms: i64 = 350;
    for (lengths) |L| {
        const s = try a.alloc(i8, L);
        defer a.free(s);
        const s2 = try a.alloc(i8, L);
        defer a.free(s2);
        const C = try a.alloc(i64, L);
        defer a.free(C);
        const tabu = try a.alloc(i64, L);
        defer a.free(tabu);

        const eBefore = naiveSearch(s, budget_ms, rng);
        const eAfter = smartSearch(s2, C, tabu, budget_ms, rng);

        var proven_str: [24]u8 = undefined;
        var proven_slice: []const u8 = "        —           ";
        if (L <= 22) {
            const eOpt = exhaustiveOptimal(s, C);
            proven_slice = try std.fmt.bufPrint(&proven_str, "F={d:.2}  (PROVEN opt)", .{merit(L, eOpt)});
        }
        const regime = if (L > 66) "OPEN — certified artifact" else if (L <= 22) "small — optimum provable" else "mid — optimum unknown to us";
        try o.print("  {d:>4} |   F={d:>5.2}  F={d:>5.2} | {s:<21} | {s}\n", .{ L, merit(L, eBefore), merit(L, eAfter), proven_slice, regime });
    }

    try o.print("\n  Reading it: 'after' (smart) should match 'proven' where we exhaust (it reaches the true optimum),\n", .{});
    try o.print("  and beat 'before' at the open lengths — same time, smarter search. Honest SOTA: the best known\n", .{});
    try o.print("  LABS constructions reach F ~ 6-9 for large L (and the conjectured asymptotic optimum is ~12.3);\n", .{});
    try o.print("  our large-L results are CERTIFIED good sequences, not records. The point here is the before/after\n", .{});
    try o.print("  effect of search quality on the identical, soundly-verified open problem.\n", .{});
}

test "incremental energy delta agrees with full recompute" {
    var prng = std.Random.DefaultPrng.init(12345);
    const rng = prng.random();
    const L = 17;
    var s: [L]i8 = undefined;
    var C: [L]i64 = undefined;
    for (&s) |*x| x.* = if (rng.boolean()) 1 else -1;
    initC(&s, &C);
    var j: usize = 0;
    while (j < L) : (j += 1) {
        const e0 = energyFull(&s);
        const d = flipDeltaE(&s, &C, j);
        applyFlip(&s, &C, j);
        const e1 = energyFull(&s);
        try std.testing.expectEqual(e1, e0 + d); // ΔE is exact
        applyFlip(&s, &C, j); // restore
    }
}

test "exhaustive finds the Barker-13 optimum (E=6, F=14.08)" {
    const L = 13;
    var s: [L]i8 = undefined;
    var C: [L]i64 = undefined;
    const eOpt = exhaustiveOptimal(&s, &C);
    try std.testing.expectEqual(@as(i64, 6), eOpt); // Barker-13: E=6 ⇒ F = 169/12 ≈ 14.08
}
