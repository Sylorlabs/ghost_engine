//! rune_forge.zig — the certified-knowledge engine running on the EXACT rune lattice + sigil (organs swapped).
//! Discoveries are forged into runes whose identity is their exact canonical form; the SOUND verifier certifies
//! them (promote to `verified`) or refutes them (`noise`); the sigil verbs scan/lock/etch operate by exact
//! structural match — no HyperVector, no Hamming resonance, no XOR bind. generate→certify→keep, native to the
//! runes/shards/sigil framework, on the substrate its proof gates were built for.
//! Build: zig build (installs ghost_rune_forge) ; run: ./zig-out/bin/ghost_rune_forge
const std = @import("std");
const lat = @import("exact_lattice.zig");

const N: u64 = 4000; // certify each statement over [1, N] (the sound verifier)

// ── sound verifiers: exact arithmetic, no hypervectors, no XOR bind ──
fn dcount(n: u64) u64 {
    var c: u64 = 0;
    var i: u64 = 1;
    while (i * i <= n) : (i += 1) if (n % i == 0) {
        c += if (i * i == n) 1 else 2;
    };
    return c;
}
fn phi(n: u64) u64 {
    var r = n;
    var m = n;
    var p: u64 = 2;
    while (p * p <= m) : (p += 1) if (m % p == 0) {
        while (m % p == 0) m /= p;
        r -= r / p;
    };
    if (m > 1) r -= r / m;
    return r;
}
fn mobius(n: u64) i64 {
    if (n == 1) return 1;
    var m = n;
    var primes: u64 = 0;
    var p: u64 = 2;
    while (p * p <= m) : (p += 1) if (m % p == 0) {
        m /= p;
        if (m % p == 0) return 0;
        primes += 1;
    };
    if (m > 1) primes += 1;
    return if (primes % 2 == 0) 1 else -1;
}
const Stmt = enum { gauss_phi, mobius_sum, sum_divisors_eq_n, count_divisors };
fn certify(s: Stmt) ?u64 { // null if it holds over [1,N]; else the first counterexample
    var n: u64 = 1;
    while (n <= N) : (n += 1) {
        var lhs: i64 = 0;
        var d: u64 = 1;
        while (d <= n) : (d += 1) if (n % d == 0) {
            lhs += switch (s) {
                .gauss_phi => @as(i64, @intCast(phi(d))),
                .mobius_sum => mobius(d),
                .sum_divisors_eq_n => @as(i64, @intCast(d)),
                .count_divisors => 1,
            };
        };
        const rhs: i64 = switch (s) {
            .gauss_phi => @intCast(n),
            .mobius_sum => if (n == 1) 1 else 0,
            .sum_divisors_eq_n => @intCast(n),
            .count_divisors => @intCast(dcount(n)),
        };
        if (lhs != rhs) return n;
    }
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const A = gpa.allocator();
    const o = std.io.getStdOut().writer();

    try o.print("=== RUNE FORGE on the EXACT lattice + sigil (organs swapped: no VSA, no XOR) ===\n", .{});
    try o.print("rune identity = exact canonical form; rank promoted by the SOUND verifier; sigil scan/lock by equality.\n\n", .{});

    var lattice = lat.ExactLattice.init(A);
    defer lattice.deinit();

    const Cand = struct { canonical: []const u8, stmt: Stmt };
    const cands = [_]Cand{
        .{ .canonical = "sum_{d|n} phi(d) == n", .stmt = .gauss_phi },
        .{ .canonical = "sum_{d|n} mu(d) == [n==1]", .stmt = .mobius_sum },
        .{ .canonical = "sum_{d|n} d == n", .stmt = .sum_divisors_eq_n }, // false: that's sigma(n)
        .{ .canonical = "sum_{d|n} 1 == d(n)", .stmt = .count_divisors },
    };

    // forge: every candidate enters the lattice via sigil ETCH; the sound verifier sets its rank on the ladder
    try o.print("── ETCH (forge): conjecture → SOUND verifier → rank on the ladder ──\n", .{});
    for (cands) |c| {
        const counter = certify(c.stmt);
        const rank: lat.RuneRank = if (counter == null) .verified else .noise;
        const cert: []const u8 = if (counter) |cx|
            std.fmt.allocPrint(A, "REFUTED: counterexample n={d}", .{cx}) catch "REFUTED"
        else
            std.fmt.allocPrint(A, "certified over [1,{d}]", .{N}) catch "certified";
        _ = try lattice.etch(c.canonical, rank, cert);
        try o.print("    etch [{s:<9}] {s:<28} ({s})\n", .{ rank.label(), c.canonical, cert });
    }

    // sigil LOCK: pin every verified rune (top of the ladder made permanent)
    try o.print("\n── LOCK: pin verified runes (cannot be pruned) ──\n", .{});
    for (cands) |c| {
        if (lattice.lock(c.canonical)) try o.print("    locked  {s}\n", .{c.canonical});
    }

    // PRUNE: clear refuted (noise) runes — definite, no decay/TTL needed
    const dropped = lattice.pruneNoise();
    try o.print("\n── PRUNE: dropped {d} refuted (noise) rune(s) — refutation is definite ──\n", .{dropped});

    // sigil SCAN: EXACT retrieval — a near-miss does not resonate
    try o.print("\n── SCAN: exact retrieval (structural equality, not resonance) ──\n", .{});
    const queries = [_][]const u8{ "sum_{d|n} phi(d) == n", "sum_{d|n} phi(d) == n+1", "sum_{d|n} d == n" };
    for (queries) |q| {
        if (lattice.scan(q)) |r| {
            try o.print("    scan \"{s}\" → HIT  [{s}{s}]\n", .{ q, r.rank.label(), if (r.locked) ", LOCKED" else "" });
        } else {
            try o.print("    scan \"{s}\" → miss  (exact: a near-variant or pruned rune does not resonate)\n", .{q});
        }
    }

    // persist as a shard
    const shard = ".ghost/runes/certified.runes";
    const n = try lattice.persistShard(shard);
    try o.print("\n── persisted {d} verified runes to shard {s} ──\n", .{ n, shard });

    try o.print("\n  The rune lattice and sigil now run EXACT: content-addressed identity, equality match, sound-verifier\n", .{});
    try o.print("  promotion, definite pruning — no HyperVector, no Hamming, no XOR. The framework's bones (rank ladder,\n", .{});
    try o.print("  shards, sigil verbs) on the substrate they were built for.\n", .{});
}
