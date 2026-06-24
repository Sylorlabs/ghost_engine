//! labs_theory.zig — give the engine real DOMAIN THEORY and chase a record on LABS.
//!
//! Blind search (labs_smart.zig) plateaued at F≈5.6 for L=101. Records come from THEORY, not brute
//! force. Two classical LABS levers, same sound verifier (exact energy) throughout:
//!
//!   (1) SKEW-SYMMETRY (odd L=2m+1): require s_{m+i} = (-1)^i · s_{m-i}. Then every odd-lag
//!       autocorrelation is identically 0, and the sequence is fixed by its first m+1 entries — so
//!       the search space drops from 2^L to 2^m (√). This lets us EXHAUSTIVELY prove the best
//!       skew-symmetric sequence far past the L≈22 reach of generic exhaustive search.
//!   (2) LEGENDRE CONSTRUCTION (prime p): s_i = (i|p), the quadratic-residue character (Euler's
//!       criterion) — the same multiplicative arithmetic the engine proves identities about. The
//!       rotation-optimized Legendre sequence has asymptotic merit factor → 6, with ZERO search.
//!
//! Honest expectation up front: this should crush blind search and reach the "good construction"
//! tier (F~6), but the best-known LABS merit factors near L=100 are ~8-9 from enormous specialized
//! search — we are very unlikely to beat that. We measure, and report the truth.
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
fn randSeq(s: []i8, rng: std.Random) void {
    for (s) |*x| x.* = if (rng.boolean()) 1 else -1;
}

// BASELINE: generic time-boxed multi-restart steepest descent (full energy), for comparison.
fn genericSearch(s: []i8, budget_ms: i64, rng: std.Random) i64 {
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
                const e = energyFull(s);
                s[j] = -s[j];
                if (e < bE) {
                    bE = e;
                    bj = j;
                }
            }
            if (bE >= curE) break;
            s[bj] = -s[bj];
            curE = bE;
        }
        if (curE < best) best = curE;
    }
    return best;
}

// ── Domain theory (1): skew-symmetry ──
fn buildSkew(free: []const i8, s: []i8) void {
    const L = s.len;
    const m = (L - 1) / 2;
    var i: usize = 0;
    while (i <= m) : (i += 1) s[i] = free[i];
    i = 1;
    while (i <= m) : (i += 1) {
        const sign: i8 = if (i % 2 == 1) -1 else 1;
        s[m + i] = sign * s[m - i];
    }
}
fn skewSearch(L: usize, budget_ms: i64, rng: std.Random, a: std.mem.Allocator) !i64 {
    const m = (L - 1) / 2;
    const free = try a.alloc(i8, m + 1);
    defer a.free(free);
    const s = try a.alloc(i8, L);
    defer a.free(s);
    var best: i64 = std.math.maxInt(i64);
    const t0 = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - t0 < budget_ms) {
        randSeq(free, rng);
        free[0] = 1;
        buildSkew(free, s);
        var curE = energyFull(s);
        while (true) {
            var bj: usize = 0;
            var bE = curE;
            var j: usize = 0;
            while (j < m + 1) : (j += 1) {
                free[j] = -free[j];
                buildSkew(free, s);
                const e = energyFull(s);
                free[j] = -free[j];
                if (e < bE) {
                    bE = e;
                    bj = j;
                }
            }
            if (bE >= curE) break;
            free[bj] = -free[bj];
            buildSkew(free, s);
            curE = bE;
        }
        if (curE < best) best = curE;
    }
    return best;
}
fn skewExhaustive(L: usize, a: std.mem.Allocator) !i64 {
    const m = (L - 1) / 2;
    const free = try a.alloc(i8, m + 1);
    defer a.free(free);
    const s = try a.alloc(i8, L);
    defer a.free(s);
    free[0] = 1; // negation symmetry
    var best: i64 = std.math.maxInt(i64);
    const lim: u64 = @as(u64, 1) << @intCast(m);
    var g: u64 = 0;
    while (g < lim) : (g += 1) {
        var b: usize = 0;
        while (b < m) : (b += 1) free[1 + b] = if ((g >> @intCast(b)) & 1 == 1) 1 else -1;
        buildSkew(free, s);
        const e = energyFull(s);
        if (e < best) best = e;
    }
    return best;
}

// ── Domain theory (2): Legendre / quadratic-residue construction ──
fn legendre(i: i64, p: i64) i8 {
    var x = @mod(i, p);
    if (x == 0) return 1; // s_0 := +1 (standard convention)
    var r: i64 = 1;
    var e: i64 = @divTrunc(p - 1, 2);
    while (e > 0) {
        if (e & 1 == 1) r = @mod(r * x, p);
        x = @mod(x * x, p);
        e >>= 1;
    }
    return if (r == 1) 1 else -1; // Euler's criterion: x^((p-1)/2) ≡ ±1
}
fn legendreBest(p: usize, a: std.mem.Allocator) !i64 {
    const base = try a.alloc(i8, p);
    defer a.free(base);
    const rot = try a.alloc(i8, p);
    defer a.free(rot);
    var i: usize = 0;
    while (i < p) : (i += 1) base[i] = legendre(@intCast(i), @intCast(p));
    var best: i64 = std.math.maxInt(i64);
    var r: usize = 0;
    while (r < p) : (r += 1) { // optimize the cyclic rotation (rotated-Legendre construction)
        i = 0;
        while (i < p) : (i += 1) rot[i] = base[(i + r) % p];
        const e = energyFull(rot);
        if (e < best) best = e;
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

    try o.print("=== LABS with REAL DOMAIN THEORY — chasing a record ===\n", .{});
    try o.print("  merit factor F = L^2/(2E), higher better. Same exact-energy verifier throughout.\n", .{});
    try o.print("  blind = generic steepest descent; skew = skew-symmetric search (odd lags vanish, 2^m space);\n", .{});
    try o.print("  Legendre = quadratic-residue construction, rotation-optimized, NO search.\n\n", .{});
    try o.print("    L  | blind  | skew(search) | Legendre(construct) | skew-EXHAUSTIVE (proven best skew)\n", .{});
    try o.print("  -----+--------+--------------+---------------------+----------------------------------\n", .{});

    const lengths = [_]usize{ 41, 59, 101 };
    const budget_ms: i64 = 500;
    for (lengths) |L| {
        const s = try a.alloc(i8, L);
        defer a.free(s);
        const eBlind = genericSearch(s, budget_ms, rng);
        const eSkew = try skewSearch(L, budget_ms, rng, a);
        const eLeg = try legendreBest(L, a); // all our L are prime
        var exh_buf: [40]u8 = undefined;
        var exh: []const u8 = "      — (L too large)             ";
        if (L <= 41) {
            const eExh = try skewExhaustive(L, a);
            exh = try std.fmt.bufPrint(&exh_buf, "F={d:.2}  (PROVEN best skew)", .{merit(L, eExh)});
        }
        try o.print("  {d:>4} | F={d:>4.2} |  F={d:>5.2}    |   F={d:>5.2}           | {s}\n", .{ L, merit(L, eBlind), merit(L, eSkew), merit(L, eLeg), exh });
    }

    try o.print("\n  Honest read-out: domain theory should beat blind search by a wide margin and land in the\n", .{});
    try o.print("  'good construction' tier (F~6). Best-known LABS merit factors near L=100 are ~8-9 from\n", .{});
    try o.print("  decades of specialized parallel search — so we expect to CLOSE THE GAP, not set a record.\n", .{});
    try o.print("  Every number above is a CERTIFIED merit factor (exact energy of an explicit sequence), and\n", .{});
    try o.print("  the skew-EXHAUSTIVE column is a PROVEN optimum over the skew-symmetric family.\n", .{});
}

test "legendre symbol via Euler's criterion (p=7: QRs are 1,2,4)" {
    try std.testing.expectEqual(@as(i8, 1), legendre(1, 7));
    try std.testing.expectEqual(@as(i8, 1), legendre(2, 7));
    try std.testing.expectEqual(@as(i8, -1), legendre(3, 7));
    try std.testing.expectEqual(@as(i8, 1), legendre(4, 7));
    try std.testing.expectEqual(@as(i8, -1), legendre(5, 7));
    try std.testing.expectEqual(@as(i8, -1), legendre(6, 7));
}

test "skew-symmetric construction kills all odd-lag autocorrelations" {
    var prng = std.Random.DefaultPrng.init(99);
    const rng = prng.random();
    const L = 21;
    const m = (L - 1) / 2;
    var free: [m + 1]i8 = undefined;
    var s: [L]i8 = undefined;
    for (&free) |*x| x.* = if (rng.boolean()) 1 else -1;
    buildSkew(&free, &s);
    var k: usize = 1;
    while (k < L) : (k += 2) { // odd lags
        var c: i64 = 0;
        var i: usize = 0;
        while (i + k < L) : (i += 1) c += @as(i64, s[i]) * @as(i64, s[i + k]);
        try std.testing.expectEqual(@as(i64, 0), c);
    }
}
