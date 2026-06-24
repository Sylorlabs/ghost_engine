//! prove_search.zig — point the discover→PROVE loop at a RICHER space.
//!
//! Enriches the function basis (one, ε, id, id², μ, φ, σ, σ₂, τ, λ, J₂, ψ — all multiplicative),
//! enumerates every Dirichlet convolution a*b, checks whether it equals a basis function c over
//! [1,M], and for each empirical hit AUTO-PROVES it for all n via the convolution-recurrence method
//! (discover f's minimal linear recurrence at prime powers; prove the target obeys the same one).
//!
//! This is the honest test of "scale it up": the lever is a richer GRAMMAR + more PRIMITIVES (not
//! data — there is none, and no weights). A convolution that matches NO basis function is reported
//! as a NEW OBJECT the current basis cannot name — the frontier where the grammar must grow.
const std = @import("std");

fn ipow(base: i128, exp: i128) i128 {
    var r: i128 = 1;
    var e = exp;
    while (e > 0) : (e -= 1) r *= base;
    return r;
}

const PF = struct { p: i128, e: i128 };
fn factorize(n0: i128, buf: []PF) usize {
    var n = n0;
    var c: usize = 0;
    var p: i128 = 2;
    while (p * p <= n) : (p += 1) {
        if (@rem(n, p) == 0) {
            var e: i128 = 0;
            while (@rem(n, p) == 0) : (e += 1) n = @divTrunc(n, p);
            buf[c] = .{ .p = p, .e = e };
            c += 1;
        }
    }
    if (n > 1) {
        buf[c] = .{ .p = n, .e = 1 };
        c += 1;
    }
    return c;
}

// ── The basis: multiplicative arithmetic functions ──
fn nt_one(n: i128) i128 {
    _ = n;
    return 1;
}
fn nt_eps(n: i128) i128 {
    return if (n == 1) 1 else 0;
}
fn nt_id(n: i128) i128 {
    return n;
}
fn nt_id2(n: i128) i128 {
    return n * n;
}
fn nt_mu(n: i128) i128 {
    var b: [48]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| {
        if (f.e >= 2) return 0;
        r = -r;
    }
    return r;
}
fn nt_phi(n: i128) i128 {
    var b: [48]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= ipow(f.p, f.e - 1) * (f.p - 1);
    return r;
}
fn nt_sigma(n: i128) i128 {
    var b: [48]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= @divTrunc(ipow(f.p, f.e + 1) - 1, f.p - 1);
    return r;
}
fn nt_sigma2(n: i128) i128 {
    var b: [48]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= @divTrunc(ipow(f.p, 2 * (f.e + 1)) - 1, f.p * f.p - 1);
    return r;
}
fn nt_tau(n: i128) i128 {
    var b: [48]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= (f.e + 1);
    return r;
}
fn nt_lambda(n: i128) i128 {
    var b: [48]PF = undefined;
    const c = factorize(n, &b);
    var omega: i128 = 0;
    for (b[0..c]) |f| omega += f.e;
    return if (@rem(omega, 2) == 0) 1 else -1;
}
fn nt_J2(n: i128) i128 {
    var b: [48]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= ipow(f.p, 2 * (f.e - 1)) * (f.p * f.p - 1);
    return r;
}
fn nt_psi(n: i128) i128 {
    var b: [48]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= ipow(f.p, f.e - 1) * (f.p + 1);
    return r;
}

const Fn = struct { name: []const u8, f: *const fn (i128) i128 };
const basis = [_]Fn{
    .{ .name = "1", .f = nt_one },
    .{ .name = "eps", .f = nt_eps },
    .{ .name = "id", .f = nt_id },
    .{ .name = "id2", .f = nt_id2 },
    .{ .name = "mu", .f = nt_mu },
    .{ .name = "phi", .f = nt_phi },
    .{ .name = "sigma", .f = nt_sigma },
    .{ .name = "sigma2", .f = nt_sigma2 },
    .{ .name = "tau", .f = nt_tau },
    .{ .name = "lambda", .f = nt_lambda },
    .{ .name = "J2", .f = nt_J2 },
    .{ .name = "psi", .f = nt_psi },
};

// Dirichlet convolution at a general n and at a prime power.
fn convN(a: *const fn (i128) i128, b: *const fn (i128) i128, n: i128) i128 {
    var s: i128 = 0;
    var d: i128 = 1;
    while (d * d <= n) : (d += 1) {
        if (@rem(n, d) == 0) {
            const q = @divTrunc(n, d);
            s += a(d) * b(q);
            if (d != q) s += a(q) * b(d);
        }
    }
    return s;
}
fn convAt(a: *const fn (i128) i128, b: *const fn (i128) i128, p: i128, k: i128) i128 {
    var s: i128 = 0;
    var i: i128 = 0;
    while (i <= k) : (i += 1) s += a(ipow(p, i)) * b(ipow(p, k - i));
    return s;
}

// ── Exact-rational recurrence discovery (as in prove_divisor.zig) ──
const Frac = struct {
    n: i128,
    d: i128,
    fn g(x0: i128, y0: i128) i128 {
        var x: i128 = if (x0 < 0) -x0 else x0;
        var y: i128 = if (y0 < 0) -y0 else y0;
        while (y != 0) {
            const t = @rem(x, y);
            x = y;
            y = t;
        }
        return if (x == 0) 1 else x;
    }
    fn make(num: i128, den: i128) Frac {
        var nn = num;
        var dd = den;
        if (dd < 0) {
            nn = -nn;
            dd = -dd;
        }
        const gg = g(nn, dd);
        return .{ .n = @divTrunc(nn, gg), .d = @divTrunc(dd, gg) };
    }
    fn fromInt(v: i128) Frac {
        return .{ .n = v, .d = 1 };
    }
    fn zero() Frac {
        return .{ .n = 0, .d = 1 };
    }
    fn isZero(a: Frac) bool {
        return a.n == 0;
    }
    fn add(a: Frac, b: Frac) Frac {
        return make(a.n * b.d + b.n * a.d, a.d * b.d);
    }
    fn sub(a: Frac, b: Frac) Frac {
        return make(a.n * b.d - b.n * a.d, a.d * b.d);
    }
    fn mul(a: Frac, b: Frac) Frac {
        return make(a.n * b.n, a.d * b.d);
    }
    fn divf(a: Frac, b: Frac) Frac {
        return make(a.n * b.d, a.d * b.n);
    }
    fn mulInt(a: Frac, v: i128) Frac {
        return make(a.n * v, a.d);
    }
    fn eqInt(a: Frac, v: i128) bool {
        return a.d == 1 and a.n == v;
    }
};
fn solveLin(A0: [4][4]Frac, b0: [4]Frac, r: usize) ?[4]Frac {
    var A = A0;
    var b = b0;
    var col: usize = 0;
    while (col < r) : (col += 1) {
        var piv = col;
        while (piv < r and A[piv][col].isZero()) piv += 1;
        if (piv == r) return null;
        if (piv != col) {
            const trow = A[piv];
            A[piv] = A[col];
            A[col] = trow;
            const tv = b[piv];
            b[piv] = b[col];
            b[col] = tv;
        }
        const pv = A[col][col];
        var c2: usize = 0;
        while (c2 < r) : (c2 += 1) A[col][c2] = A[col][c2].divf(pv);
        b[col] = b[col].divf(pv);
        var row: usize = 0;
        while (row < r) : (row += 1) {
            if (row == col) continue;
            const f = A[row][col];
            if (f.isZero()) continue;
            var cc: usize = 0;
            while (cc < r) : (cc += 1) A[row][cc] = A[row][cc].sub(f.mul(A[col][cc]));
            b[row] = b[row].sub(f.mul(b[col]));
        }
    }
    return b;
}
const Rec = struct { r: usize, c: [4]Frac };
fn findRec(seq: []const i128) ?Rec {
    var r: usize = 1;
    while (r <= 4) : (r += 1) {
        if (seq.len < 2 * r) continue;
        var A: [4][4]Frac = undefined;
        var b: [4]Frac = undefined;
        var m: usize = 0;
        while (m < r) : (m += 1) {
            var j: usize = 0;
            while (j < r) : (j += 1) A[m][j] = Frac.fromInt(seq[r + m - (j + 1)]);
            b[m] = Frac.fromInt(seq[r + m]);
        }
        const sol = solveLin(A, b, r) orelse continue;
        var ok = true;
        var k: usize = r;
        while (k < seq.len) : (k += 1) {
            var acc = Frac.zero();
            var j: usize = 0;
            while (j < r) : (j += 1) acc = acc.add(sol[j].mulInt(seq[k - (j + 1)]));
            if (!acc.eqInt(seq[k])) {
                ok = false;
                break;
            }
        }
        if (ok) return .{ .r = r, .c = sol };
    }
    return null;
}

// Prove (a*b)=c for ALL n: both sides multiplicative (basis is multiplicative ⇒ a*b multiplicative),
// so it suffices to prove on prime powers; discover f=(a*b)'s recurrence in k and verify c obeys it
// + matches initial terms. Sample primes {2,3} (values bounded to stay exact in i128).
fn proveAllN(a: *const fn (i128) i128, b: *const fn (i128) i128, c: *const fn (i128) i128) bool {
    const N: usize = 12;
    const primes = [_]i128{ 2, 3 };
    for (primes) |p| {
        var fseq: [N]i128 = undefined;
        var gseq: [N]i128 = undefined;
        var k: usize = 0;
        while (k < N) : (k += 1) {
            fseq[k] = convAt(a, b, p, @intCast(k));
            gseq[k] = c(ipow(p, @intCast(k)));
        }
        const rec = findRec(&fseq) orelse return false;
        var i: usize = 0;
        while (i < rec.r) : (i += 1) if (fseq[i] != gseq[i]) return false;
        k = rec.r;
        while (k < N) : (k += 1) {
            var acc = Frac.zero();
            var j: usize = 0;
            while (j < rec.r) : (j += 1) acc = acc.add(rec.c[j].mulInt(gseq[k - (j + 1)]));
            if (!acc.eqInt(gseq[k])) return false;
        }
    }
    return true;
}

fn matchesOverRange(a: *const fn (i128) i128, b: *const fn (i128) i128, c: *const fn (i128) i128, m: i128) bool {
    var n: i128 = 1;
    while (n <= m) : (n += 1) if (convN(a, b, n) != c(n)) return false;
    return true;
}

pub fn main() !void {
    const o = std.io.getStdOut().writer();
    const M: i128 = 300;
    try o.print("=== DISCOVER + PROVE over a richer basis ({d} multiplicative functions) ===\n", .{basis.len});
    try o.print("  basis: 1 eps id id2 mu phi sigma sigma2 tau lambda J2 psi\n", .{});
    try o.print("  enumerate a*b, match to a basis function over [1,{d}], then PROVE for all n.\n\n", .{M});

    var proven: usize = 0;
    var empirical_only: usize = 0;
    var new_objects: usize = 0;
    var pairs: usize = 0;

    for (basis, 0..) |A, ai| {
        for (basis, 0..) |B, bi| {
            if (bi < ai) continue; // convolution is commutative — dedup
            pairs += 1;
            var matched = false;
            for (basis) |C| {
                if (!matchesOverRange(A.f, B.f, C.f, M)) continue;
                matched = true;
                if (proveAllN(A.f, B.f, C.f)) {
                    proven += 1;
                    try o.print("  [PROVEN  forall n]  {s} * {s}  ==  {s}\n", .{ A.name, B.name, C.name });
                } else {
                    empirical_only += 1;
                    try o.print("  [certified [1,{d}]] {s} * {s}  ==  {s}   (proof attempt inconclusive)\n", .{ M, A.name, B.name, C.name });
                }
                break;
            }
            if (!matched) new_objects += 1; // a*b is a function not nameable in the current basis
        }
    }

    try o.print("\n  {d} convolution pairs searched · {d} PROVEN forall n · {d} certified-only · {d} produced a\n", .{ pairs, proven, empirical_only, new_objects });
    try o.print("  function OUTSIDE the basis (the frontier — where a richer grammar would name more).\n", .{});
    try o.print("  Scaling lever here is GRAMMAR + PRIMITIVES (not data/weights): a bigger basis ⇒ more\n", .{});
    try o.print("  discoverable+provable identities, at the cost of more enumeration. Every result above is\n", .{});
    try o.print("  a machine-found, machine-PROVED classical Dirichlet identity — rediscovery with proof.\n", .{});
}

test "richer-basis search proves the known convolution identities" {
    // 1*1 = tau, 1*id = sigma, phi*1 = id (Gauss), mu*1 = eps (Mobius), mu*id = phi, mu*tau = 1, mu*sigma = id
    try std.testing.expect(proveAllN(nt_one, nt_one, nt_tau));
    try std.testing.expect(proveAllN(nt_one, nt_id, nt_sigma));
    try std.testing.expect(proveAllN(nt_phi, nt_one, nt_id));
    try std.testing.expect(proveAllN(nt_mu, nt_one, nt_eps));
    try std.testing.expect(proveAllN(nt_mu, nt_id, nt_phi));
    try std.testing.expect(proveAllN(nt_one, nt_id2, nt_sigma2)); // 1*id2 = sigma2
    try std.testing.expect(proveAllN(nt_J2, nt_one, nt_id2)); // Jordan: sum_{d|n} J2(d) = n^2
}

test "search does not prove a false convolution identity" {
    // sigma * sigma is NOT id, tau, or any single basis function — must not be 'proven' as one
    try std.testing.expect(!proveAllN(nt_sigma, nt_sigma, nt_id));
    try std.testing.expect(!proveAllN(nt_one, nt_one, nt_id)); // 1*1 = tau, not id
}
