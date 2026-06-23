//! rune_forge.zig — certified discoveries as RUNES in ghost_engine's runes/shards/sigil system, with NO VSA and
//! NO XOR. A rune here is NOT a hypervector: its identity is the EXACT canonical form of a fact (content-addressed),
//! matched by structural EQUALITY — not fuzzy Hamming resonance over XOR-bound vectors. It rides the existing
//! triad.RuneRank ladder (noise → emerging → … → verified): a discovery enters as `emerging` (a labelled
//! conjecture) and is promoted to `verified` only when our SOUND verifier certifies it by exact computation; a
//! single counterexample demotes it to `noise` (refuted). Verified runes persist as a shard. This is the invention
//! engine's generate→certify→keep expressed natively in the runes/shards/sigil system — our system mixed in, no VSA.
//! Build: zig build (installs ghost_rune_forge) ; run: ./zig-out/bin/ghost_rune_forge
const std = @import("std");
const ghost = @import("ghost_core");
const RuneRank = ghost.triad.RuneRank; // the existing rune ladder — reused, not reinvented (VSA-free enum)

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
// returns null if the statement holds for all n in [1,N]; otherwise the first counterexample n
fn certify(s: Stmt) ?u64 {
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

// ── the rune: identity is the EXACT canonical statement (content-addressed), not a hypervector ──
const CertifiedRune = struct {
    canonical: []const u8,
    id: u64, // content hash of `canonical` — EXACT identity (equality match, never Hamming similarity)
    rank: RuneRank,
    certificate: []const u8,
};
fn runeId(canonical: []const u8) u64 {
    return std.hash.Wyhash.hash(0xC0FFEE, canonical); // content addressing, not VSA binding
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const A = gpa.allocator();
    const o = std.io.getStdOut().writer();

    try o.print("=== RUNE FORGE — certified discoveries as runes (rank ladder + shards), no VSA, no XOR ===\n", .{});
    try o.print("identity = exact canonical form (content-addressed); rank promoted by our SOUND verifier, not resonance.\n\n", .{});

    const Cand = struct { canonical: []const u8, stmt: Stmt };
    const cands = [_]Cand{
        .{ .canonical = "sum_{d|n} phi(d) == n", .stmt = .gauss_phi },
        .{ .canonical = "sum_{d|n} mu(d) == [n==1]", .stmt = .mobius_sum },
        .{ .canonical = "sum_{d|n} d == n", .stmt = .sum_divisors_eq_n }, // false: that's sigma(n)
        .{ .canonical = "sum_{d|n} 1 == d(n)", .stmt = .count_divisors },
    };

    var store = std.ArrayList(CertifiedRune).init(A);
    defer store.deinit();
    var seen = std.AutoHashMap(u64, void).init(A); // EXACT dedup (by content id), not fuzzy
    defer seen.deinit();

    try o.print("── lifecycle: enter as `emerging` (conjecture) → SOUND verifier → promote/demote on the rune ladder ──\n", .{});
    for (cands) |c| {
        const id = runeId(c.canonical);
        if (seen.contains(id)) continue; // exact identity: same canonical ⇒ same rune (no duplicate slot)
        seen.put(id, {}) catch {};
        // every rune is born a labelled conjecture
        var rank: RuneRank = .emerging;
        var cert: []const u8 = "conjecture (unverified)";
        const counter = certify(c.stmt);
        if (counter) |cx| {
            rank = .noise; // refuted by a counterexample — demoted, will be pruned (negative knowledge)
            cert = std.fmt.allocPrint(A, "REFUTED: counterexample at n={d}", .{cx}) catch "REFUTED";
        } else {
            rank = .verified; // certified by exact computation over the whole range — promoted to the top of the ladder
            cert = std.fmt.allocPrint(A, "certified by computation over [1,{d}]", .{N}) catch "certified";
        }
        store.append(.{ .canonical = c.canonical, .id = id, .rank = rank, .certificate = cert }) catch {};
        try o.print("    [{s:<9}] {s:<30} id={X:0>16}  ({s})\n", .{ rank.label(), c.canonical, id, cert });
    }

    // ── persist VERIFIED runes as a shard (the shards system; plain structured records, no hypervectors) ──
    std.fs.cwd().makePath(".ghost/runes") catch {};
    const shard_path = ".ghost/runes/certified.runes";
    {
        var f = try std.fs.cwd().createFile(shard_path, .{});
        defer f.close();
        const w = f.writer();
        try w.print("# ghost rune shard — certified knowledge atoms (exact, non-VSA)\n", .{});
        for (store.items) |r| {
            if (r.rank != .verified) continue; // only verified runes are committed to the shard (keep)
            try w.print("{s}\t{X:0>16}\t{s}\t{s}\n", .{ r.rank.label(), r.id, r.canonical, r.certificate });
        }
    }
    var verified: usize = 0;
    for (store.items) |r| {
        if (r.rank == .verified) verified += 1;
    }
    try o.print("\n── persisted {d} verified runes to shard {s} (refuted/conjecture runes are NOT committed) ──\n", .{ verified, shard_path });

    // ── retrieval is EXACT (content-addressed), not fuzzy resonance ──
    try o.print("\n── retrieval by EXACT canonical key (structural equality, not Hamming similarity) ──\n", .{});
    const queries = [_][]const u8{ "sum_{d|n} phi(d) == n", "sum_{d|n} phi(d) == n+1" };
    for (queries) |q| {
        const qid = runeId(q);
        var hit: ?CertifiedRune = null;
        for (store.items) |r| {
            if (r.id == qid and std.mem.eql(u8, r.canonical, q)) hit = r;
        }
        if (hit) |r| {
            try o.print("    query \"{s}\" → FOUND  [{s}]  (exact id match)\n", .{ q, r.rank.label() });
        } else {
            try o.print("    query \"{s}\" → none  (a near-miss does NOT resonate — exact, not fuzzy)\n", .{q});
        }
    }

    try o.print("\n  Runes/shards/sigil system, our certify→keep mixed in: a rune is a certified knowledge atom whose\n", .{});
    try o.print("  identity is its exact canonical form (content-addressed), promoted up the triad.RuneRank ladder by a\n", .{});
    try o.print("  sound computational verifier — no hypervectors, no XOR bind, no Hamming resonance. Verified runes are\n", .{});
    try o.print("  committed to a shard; the sigil VM can `scan`/`lock` them by exact id (symbolic layer kept intact).\n", .{});
}
