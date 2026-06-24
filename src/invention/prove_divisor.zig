//! prove_divisor.zig — the next research step: from CHECK to PROOF.
//!
//! divisor_discover CERTIFIES identities empirically over a finite range [1,N]. That is a strong
//! certificate, but not a proof. This tool PROVES the same identities for an INFINITE class of n —
//! all n whose prime exponents are ≤ K — via a sound three-step reduction:
//!
//!   1. MULTIPLICATIVITY. Both sides are multiplicative arithmetic functions: they are built from
//!      the multiplicative basis {1, id, φ, μ, d, σ}, and a divisor-sum Σ_{d|n} h(d) of a
//!      multiplicative h is itself multiplicative (standard theorem). This is structural — we do
//!      not sample it.
//!   2. PRIME-POWER REDUCTION. Two multiplicative functions that agree on every prime power p^k
//!      agree on every n (multiplicative functions are determined by their prime-power values). So
//!      "∀n: f(n)=g(n)" reduces to "∀ primes p, ∀k: f(p^k)=g(p^k)".
//!   3. POLYNOMIAL IDENTITY. For a fixed k, f(p^k) and g(p^k) are polynomials in p of degree ≤ 2k.
//!      Two polynomials of degree ≤ D agreeing at D+1 distinct points are identical — so checking
//!      f(p^k)=g(p^k) at 2k+2 distinct primes PROVES it for ALL p (it is a proof, not a sample).
//!
//! Therefore: proven-at-k for all primes, for k=0..K  ⟹  PROVEN ∀n with prime exponents ≤ K.
//! (Proving for ALL k as well needs symbolic induction on k — the honest next step.) A FALSE
//! identity is DISPROVEN by an exhibited prime-power counterexample (e.g. Σ_{d|p} d = 1+p ≠ p).
//!
//! No hardcoded answers: the verdict comes from computing both sides at prime powers. The two
//! theorems used (divisor-sum-of-multiplicative is multiplicative; multiplicative ⇒ determined by
//! prime powers) are the sound, handed reduction — the analogue of the "handed verifier".
const std = @import("std");

fn ipow(base: i128, exp: i128) i128 {
    var r: i128 = 1;
    var e = exp;
    while (e > 0) : (e -= 1) r *= base;
    return r;
}
fn phi(n: i128) i128 {
    var result = n;
    var m = n;
    var p: i128 = 2;
    while (p * p <= m) : (p += 1) {
        if (@rem(m, p) == 0) {
            while (@rem(m, p) == 0) m = @divTrunc(m, p);
            result -= @divTrunc(result, p);
        }
    }
    if (m > 1) result -= @divTrunc(result, m);
    return result;
}
fn mu(n: i128) i128 {
    if (n == 1) return 1;
    var m = n;
    var primes: i128 = 0;
    var p: i128 = 2;
    while (p * p <= m) : (p += 1) {
        if (@rem(m, p) == 0) {
            m = @divTrunc(m, p);
            if (@rem(m, p) == 0) return 0; // square factor
            primes += 1;
        }
    }
    if (m > 1) primes += 1;
    return if (@rem(primes, 2) == 0) 1 else -1;
}
fn dcount(n: i128) i128 {
    var count: i128 = 0;
    var d: i128 = 1;
    while (d * d <= n) : (d += 1) {
        if (@rem(n, d) == 0) {
            count += 1;
            if (d != @divTrunc(n, d)) count += 1;
        }
    }
    return count;
}
fn sigma(n: i128) i128 {
    var sum: i128 = 0;
    var d: i128 = 1;
    while (d * d <= n) : (d += 1) {
        if (@rem(n, d) == 0) {
            sum += d;
            const q = @divTrunc(n, d);
            if (d != q) sum += q;
        }
    }
    return sum;
}

// term(d, n/d) summed over the divisors of n; rhs(n) is the claimed closed form.
const Id = struct {
    name: []const u8,
    lhs: *const fn (i128, i128) i128,
    rhs: *const fn (i128) i128,
    expect_provable: bool,
};

fn t_phi(d: i128, q: i128) i128 {
    _ = q;
    return phi(d);
}
fn t_one(d: i128, q: i128) i128 {
    _ = d;
    _ = q;
    return 1;
}
fn t_id(d: i128, q: i128) i128 {
    _ = q;
    return d;
}
fn t_mu(d: i128, q: i128) i128 {
    _ = q;
    return mu(d);
}
fn t_mu_inv(d: i128, q: i128) i128 {
    return mu(d) * q;
}
fn r_n(n: i128) i128 {
    return n;
}
fn r_d(n: i128) i128 {
    return dcount(n);
}
fn r_sigma(n: i128) i128 {
    return sigma(n);
}
fn r_eps(n: i128) i128 {
    return if (n == 1) 1 else 0;
}
fn r_phi(n: i128) i128 {
    return phi(n);
}

const identities = [_]Id{
    .{ .name = "sum_{d|n} phi(d)      == n        (Gauss)", .lhs = t_phi, .rhs = r_n, .expect_provable = true },
    .{ .name = "sum_{d|n} 1           == d(n)     (divisor count)", .lhs = t_one, .rhs = r_d, .expect_provable = true },
    .{ .name = "sum_{d|n} d           == sigma(n) (definition)", .lhs = t_id, .rhs = r_sigma, .expect_provable = true },
    .{ .name = "sum_{d|n} mu(d)       == [n==1]   (Mobius)", .lhs = t_mu, .rhs = r_eps, .expect_provable = true },
    .{ .name = "sum_{d|n} mu(d)*(n/d) == phi(n)   (Mobius inversion)", .lhs = t_mu_inv, .rhs = r_phi, .expect_provable = true },
    .{ .name = "sum_{d|n} d           == n        (FALSE - must disprove)", .lhs = t_id, .rhs = r_n, .expect_provable = false },
};

const Verdict = struct { proven: bool, cex_p: i128 = 0, cex_k: i128 = 0, cex_lhs: i128 = 0, cex_rhs: i128 = 0 };

fn firstPrimes(buf: []i128) void {
    var c: usize = 0;
    var n: i128 = 2;
    while (c < buf.len) : (n += 1) {
        var ok = true;
        var p: i128 = 2;
        while (p * p <= n) : (p += 1) {
            if (@rem(n, p) == 0) {
                ok = false;
                break;
            }
        }
        if (ok) {
            buf[c] = n;
            c += 1;
        }
    }
}

fn proveIdentity(id: Id, K: i128) Verdict {
    var primes: [64]i128 = undefined;
    firstPrimes(&primes);
    var k: i128 = 0;
    while (k <= K) : (k += 1) {
        const pts: usize = @intCast(2 * k + 2); // ≥ (deg ≤ 2k) + 1 distinct primes ⇒ proof ∀p at this k
        var pi: usize = 0;
        while (pi < pts) : (pi += 1) {
            const p = primes[pi];
            const n = ipow(p, k);
            var lhs: i128 = 0;
            var i: i128 = 0;
            while (i <= k) : (i += 1) {
                lhs += id.lhs(ipow(p, i), ipow(p, k - i)); // divisors of p^k are p^0..p^k
            }
            const rhs = id.rhs(n);
            if (lhs != rhs) return .{ .proven = false, .cex_p = p, .cex_k = k, .cex_lhs = lhs, .cex_rhs = rhs };
        }
    }
    return .{ .proven = true };
}

pub fn main() !void {
    const K: i128 = 8;
    const o = std.io.getStdOut().writer();
    try o.print("=== PROVE divisor identities (CHECK -> PROOF) ===\n", .{});
    try o.print("  Method: multiplicative reduction -> prime powers -> polynomial identity at 2k+2 primes.\n", .{});
    try o.print("  A PROVEN verdict holds for ALL n with prime exponents <= {d} (an infinite class), not a range.\n\n", .{K});
    for (identities) |id| {
        const v = proveIdentity(id, K);
        if (v.proven) {
            try o.print("  [PROVEN  forall n, exp<= {d}]  {s}\n", .{ K, id.name });
        } else {
            try o.print("  [DISPROVEN at p^k = {d}^{d}: lhs={d} != rhs={d}]  {s}\n", .{ v.cex_p, v.cex_k, v.cex_lhs, v.cex_rhs, id.name });
        }
    }
    try o.print("\n  Why this is a PROOF, not a check: at each k, both sides are polynomials in p of degree <= 2k;\n", .{});
    try o.print("  agreement at 2k+2 distinct primes is a polynomial identity (holds for ALL p). Multiplicativity\n", .{});
    try o.print("  then lifts prime powers to all n. The finite-range certifier became an infinite-class prover.\n", .{});
    try o.print("  Honest bound: exponents <= {d}; proving ALL k needs symbolic induction on k (next step).\n", .{K});
}

test "prover: true divisor identities PROVEN, the false one DISPROVEN" {
    const K: i128 = 8;
    for (identities) |id| {
        const v = proveIdentity(id, K);
        try std.testing.expectEqual(id.expect_provable, v.proven);
    }
}

test "prover exhibits the right counterexample for the false identity" {
    const v = proveIdentity(identities[5], 8); // Σ_{d|p} d = 1+p, claimed == p
    try std.testing.expect(!v.proven);
    try std.testing.expectEqual(@as(i128, 1), v.cex_k); // first failure at a prime p^1
    try std.testing.expectEqual(v.cex_p + 1, v.cex_lhs); // 1 + p
    try std.testing.expectEqual(v.cex_p, v.cex_rhs); // claimed n = p
}
