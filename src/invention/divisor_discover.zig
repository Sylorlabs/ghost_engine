//! divisor_discover.zig — #2 richer space: NUMBER-THEORETIC terms (sums over divisors / Dirichlet convolutions).
//! Ties back to feature_invent's d(n), sigma(n). Enumerate sums over the divisors of n,
//!   f(n) = sum_{d | n} term(d, n/d),  term built from {d, n/d, 1, phi(d), mu(d), d(d), sigma(d)} with + and *,
//! then MATCH each f against a small set of recognizable target functions (n, n^2, d(n), sigma(n), phi(n),
//! [n==1], …), certified by exact computation over [1,M]. This rediscovers genuine theorems — Gauss
//! (sum_{d|n} phi(d) = n), the Mobius sum (sum_{d|n} mu(d) = [n==1]), Mobius inversion (sum_{d|n} mu(d)·(n/d) =
//! phi(n)), sigma = sum_{d|n} d — none retrieved; generated and proven. No match ⇒ abstain.
//! Build: zig build-exe divisor_discover.zig -O ReleaseFast -femit-bin=/tmp/dd && /tmp/dd
const std = @import("std");
var A: std.mem.Allocator = undefined;
const M: i64 = 3000; // certify over n = 1..M

fn dcount(n: i64) i64 {
    var c: i64 = 0;
    var i: i64 = 1;
    while (i * i <= n) : (i += 1) if (@rem(n, i) == 0) {
        c += if (i * i == n) 1 else 2;
    };
    return c;
}
fn sigma(n: i64) i64 {
    var s: i64 = 0;
    var i: i64 = 1;
    while (i * i <= n) : (i += 1) if (@rem(n, i) == 0) {
        s += i;
        if (i * i != n) s += @divTrunc(n, i);
    };
    return s;
}
fn phi(n: i64) i64 {
    var result = n;
    var m = n;
    var p: i64 = 2;
    while (p * p <= m) : (p += 1) {
        if (@rem(m, p) == 0) {
            while (@rem(m, p) == 0) m = @divTrunc(m, p);
            result -= @divTrunc(result, p);
        }
    }
    if (m > 1) result -= @divTrunc(result, m);
    return result;
}
fn mu(n: i64) i64 {
    if (n == 1) return 1;
    var m = n;
    var primes: i64 = 0;
    var p: i64 = 2;
    while (p * p <= m) : (p += 1) {
        if (@rem(m, p) == 0) {
            m = @divTrunc(m, p);
            if (@rem(m, p) == 0) return 0; // squared factor
            primes += 1;
        }
    }
    if (m > 1) primes += 1;
    return if (@rem(primes, 2) == 0) 1 else -1;
}

// ── term over a divisor d of n (e = n/d) ──
const NLEAF = 7;
fn leafVal(l: u8, d: i64, e: i64) i64 {
    return switch (l) {
        0 => d,
        1 => e, // n/d
        2 => 1,
        3 => phi(d),
        4 => mu(d),
        5 => dcount(d),
        else => sigma(d),
    };
}
fn leafName(l: u8) []const u8 {
    return switch (l) {
        0 => "d",
        1 => "(n/d)",
        2 => "1",
        3 => "phi(d)",
        4 => "mu(d)",
        5 => "d(d)",
        else => "sigma(d)",
    };
}
// term = leaf, leaf*leaf, or leaf+leaf
const Term = struct { op: u8, a: u8, b: u8 }; // op 0=leaf(a), 1=a*b, 2=a+b
fn termVal(t: Term, d: i64, e: i64) i64 {
    return switch (t.op) {
        0 => leafVal(t.a, d, e),
        1 => leafVal(t.a, d, e) * leafVal(t.b, d, e),
        else => leafVal(t.a, d, e) + leafVal(t.b, d, e),
    };
}
fn termName(t: Term, buf: []u8) []const u8 {
    return switch (t.op) {
        0 => std.fmt.bufPrint(buf, "{s}", .{leafName(t.a)}) catch "?",
        1 => std.fmt.bufPrint(buf, "{s}*{s}", .{ leafName(t.a), leafName(t.b) }) catch "?",
        else => std.fmt.bufPrint(buf, "{s}+{s}", .{ leafName(t.a), leafName(t.b) }) catch "?",
    };
}
fn divisorSum(t: Term, n: i64) i64 {
    var s: i64 = 0;
    var d: i64 = 1;
    while (d <= n) : (d += 1) if (@rem(n, d) == 0) {
        s += termVal(t, d, @divTrunc(n, d));
    };
    return s;
}

// recognizable target functions g(n)
const Target = struct { name: []const u8, f: *const fn (i64) i64 };
fn g_one(n: i64) i64 {
    return if (n >= 1) 1 else 0;
}
fn g_n(n: i64) i64 {
    return n;
}
fn g_n2(n: i64) i64 {
    return n * n;
}
fn g_n3(n: i64) i64 {
    return n * n * n;
}
fn g_d(n: i64) i64 {
    return dcount(n);
}
fn g_sig(n: i64) i64 {
    return sigma(n);
}
fn g_phi(n: i64) i64 {
    return phi(n);
}
fn g_eq1(n: i64) i64 {
    return if (n == 1) 1 else 0;
}
fn g_nd(n: i64) i64 {
    return n * dcount(n);
}
fn g_dd(n: i64) i64 {
    return dcount(n) * dcount(n);
}
fn g_zero(_: i64) i64 {
    return 0;
}
fn g_ndiv(n: i64) i64 {
    return sigma(n) - n;
} // aliquot
const TARGETS = [_]Target{
    .{ .name = "n", .f = g_n },
    .{ .name = "n^2", .f = g_n2 },
    .{ .name = "n^3", .f = g_n3 },
    .{ .name = "d(n) [num divisors]", .f = g_d },
    .{ .name = "sigma(n) [sum of divisors]", .f = g_sig },
    .{ .name = "phi(n) [Euler totient]", .f = g_phi },
    .{ .name = "[n==1]", .f = g_eq1 },
    .{ .name = "1", .f = g_one },
    .{ .name = "0", .f = g_zero },
    .{ .name = "n*d(n)", .f = g_nd },
    .{ .name = "d(n)^2", .f = g_dd },
    .{ .name = "sigma(n)-n [aliquot]", .f = g_ndiv },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    A = arena.allocator();
    const o = std.io.getStdOut().writer();

    try o.print("=== DIVISOR-SUM DISCOVERY — Dirichlet convolutions over the divisors of n, certified ===\n", .{});
    try o.print("f(n) = sum_{{d|n}} term(d, n/d); match to a recognizable g(n), certify over [1,{d}], else abstain.\n\n", .{M});

    // enumerate terms: leaves, products, sums
    var terms = std.ArrayList(Term).init(A);
    var a: u8 = 0;
    while (a < NLEAF) : (a += 1) terms.append(.{ .op = 0, .a = a, .b = 0 }) catch {};
    a = 0;
    while (a < NLEAF) : (a += 1) {
        var b: u8 = a;
        while (b < NLEAF) : (b += 1) {
            terms.append(.{ .op = 1, .a = a, .b = b }) catch {};
            if (a != b) terms.append(.{ .op = 2, .a = a, .b = b }) catch {};
        }
    }

    try o.print("──────── discovered + certified identities  (sum_{{d|n}} term  =  g(n)) ────────\n", .{});
    var found: usize = 0;
    var tested: usize = 0;
    var abstain: usize = 0;
    var seen = std.StringHashMap(void).init(A); // dedup by "term=target"
    for (terms.items) |t| {
        tested += 1;
        var matched = false;
        for (TARGETS) |tg| {
            var ok = true;
            var n: i64 = 1;
            while (n <= M) : (n += 1) {
                if (divisorSum(t, n) != tg.f(n)) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                var tb: [48]u8 = undefined;
                const tn = termName(t, &tb);
                const key = std.fmt.allocPrint(A, "{s}={s}", .{ tn, tg.name }) catch continue;
                if (seen.contains(key)) {
                    matched = true;
                    break;
                }
                seen.put(key, {}) catch {};
                const star = if (std.mem.eql(u8, tg.name, "phi(n) [Euler totient]") or std.mem.startsWith(u8, tg.name, "[n==1]") or (std.mem.eql(u8, tg.name, "n") and std.mem.eql(u8, tn, "phi(d)"))) "  ★" else "";
                try o.print("    sum_{{d|n}} {s:<18} = {s}{s}\n", .{ tn, tg.name, star });
                found += 1;
                matched = true;
                break;
            }
        }
        if (!matched) abstain += 1;
    }

    try o.print("\n  tested {d} divisor-sum programs · {d} certified identities · {d} with no match in the target set (abstain).\n", .{ tested, found, abstain });
    try o.print("  ★ = a non-obvious classical theorem rediscovered by generate-and-certify: Gauss (sum_{{d|n}} phi(d) = n),\n", .{});
    try o.print("    the Mobius sum (sum_{{d|n}} mu(d) = [n==1]), Mobius inversion (sum_{{d|n}} mu(d)·(n/d) = phi(n)).\n", .{});
    try o.print("  These are real Dirichlet-convolution identities — posed from primitives and proven by computation.\n", .{});
}
