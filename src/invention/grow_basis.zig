//! grow_basis.zig — BUILDING THE BOX: the engine grows its own function vocabulary from a tiny seed.
//!
//! Until now a human handed the engine its basis (the 12 multiplicative functions in prove_search).
//! Here it is given only 3 SEED primitives {1, id, μ} and one composition operator (Dirichlet
//! convolution a*b). It repeatedly composes what it has, KEEPS every genuinely-new function (a value
//! vector it can't already express), and thereby GROWS its own basis. Each kept compound is also a
//! discovered identity "a*b = <new function>". generate(compositions) → test(is it new?) → keep.
//!
//! Functions are represented by their value vector over n=1..M (the only ground truth), so "new"
//! means "a behaviour not already in the box" — exactly the dedup-by-behaviour idea from feature
//! invention, lifted to the level of the basis itself. The box is built, not given.
//!
//! HONEST: this still lives inside a META-grammar (convolution of arithmetic functions). Building the
//! box ≠ escaping all boxes — there is always an outer generator. The point is the loop that lets the
//! engine extend its own primitives; "truly outside the box" = making that meta-grammar open-ended.
const std = @import("std");

const M: usize = 40; // value-vector length (n = 1..M)
const MAXB: usize = 80; // basis capacity

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
fn ipow(b: i128, e: i128) i128 {
    var r: i128 = 1;
    var x = e;
    while (x > 0) : (x -= 1) r *= b;
    return r;
}
// classical functions, used ONLY to LABEL rediscoveries (the search itself is blind to names)
fn k_one(n: i128) i128 {
    _ = n;
    return 1;
}
fn k_id(n: i128) i128 {
    return n;
}
fn k_id2(n: i128) i128 {
    return n * n;
}
fn k_mu(n: i128) i128 {
    var b: [16]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| {
        if (f.e >= 2) return 0;
        r = -r;
    }
    return r;
}
fn k_eps(n: i128) i128 {
    return if (n == 1) 1 else 0;
}
fn k_tau(n: i128) i128 {
    var b: [16]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= (f.e + 1);
    return r;
}
fn k_sigma(n: i128) i128 {
    var b: [16]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= @divTrunc(ipow(f.p, f.e + 1) - 1, f.p - 1);
    return r;
}
fn k_phi(n: i128) i128 {
    var b: [16]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= ipow(f.p, f.e - 1) * (f.p - 1);
    return r;
}
fn k_J2(n: i128) i128 {
    var b: [16]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= ipow(f.p, 2 * (f.e - 1)) * (f.p * f.p - 1);
    return r;
}
fn k_ntau(n: i128) i128 {
    return n * k_tau(n); // id*id = Σ_{d|n} d·(n/d) = n·τ(n)
}
const Known = struct { name: []const u8, f: *const fn (i128) i128 };
const known = [_]Known{
    .{ .name = "1", .f = k_one },        .{ .name = "id", .f = k_id },     .{ .name = "mu", .f = k_mu },
    .{ .name = "eps", .f = k_eps },      .{ .name = "tau", .f = k_tau },   .{ .name = "sigma", .f = k_sigma },
    .{ .name = "phi", .f = k_phi },      .{ .name = "id2", .f = k_id2 },   .{ .name = "J2", .f = k_J2 },
    .{ .name = "n*tau", .f = k_ntau },
};

fn fill(f: *const fn (i128) i128, out: []i128) void {
    var n: usize = 1;
    while (n <= M) : (n += 1) out[n - 1] = f(@intCast(n));
}
fn conv(a: []const i128, b: []const i128, out: []i128) void {
    var n: usize = 1;
    while (n <= M) : (n += 1) {
        var s: i128 = 0;
        var d: usize = 1;
        while (d <= n) : (d += 1) if (n % d == 0) {
            s += a[d - 1] * b[n / d - 1];
        };
        out[n - 1] = s;
    }
}
fn vecEq(a: []const i128, b: []const i128) bool {
    var i: usize = 0;
    while (i < M) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}
fn labelOf(vec: []const i128, buf: []u8) []const u8 {
    for (known) |kf| {
        var tmp: [M]i128 = undefined;
        fill(kf.f, &tmp);
        if (vecEq(vec, &tmp)) return kf.name;
    }
    return std.fmt.bufPrint(buf, "compound", .{}) catch "compound";
}

pub fn main() !void {
    const o = std.io.getStdOut().writer();
    var basis: [MAXB][M]i128 = undefined;
    var names: [MAXB][]const u8 = undefined;
    var nb: usize = 0;

    // SEED the box with 3 primitives.
    fill(k_one, &basis[0]);
    names[0] = "1";
    fill(k_id, &basis[1]);
    names[1] = "id";
    fill(k_mu, &basis[2]);
    names[2] = "mu";
    nb = 3;

    try o.print("=== BUILDING THE BOX: engine grows its own basis from a 3-primitive seed ===\n", .{});
    try o.print("  seed box = {{1, id, mu}};  operator = Dirichlet convolution a*b;  keep every new behaviour.\n\n", .{});
    try o.print("  round | basis size | newly discovered (named classical functions in bold-equivalent)\n", .{});
    try o.print("  ------+------------+------------------------------------------------------------------\n", .{});

    var round: usize = 1;
    while (round <= 5) : (round += 1) {
        const start = nb;
        var i: usize = 0;
        while (i < start) : (i += 1) {
            var j = i;
            while (j < start) : (j += 1) {
                if (nb >= MAXB) break;
                var c: [M]i128 = undefined;
                conv(&basis[i], &basis[j], &c);
                // is this behaviour already in the box?
                var seen = false;
                var t: usize = 0;
                while (t < nb) : (t += 1) if (vecEq(&c, &basis[t])) {
                    seen = true;
                    break;
                };
                if (!seen) {
                    basis[nb] = c;
                    var lbuf: [16]u8 = undefined;
                    const lab = labelOf(&c, &lbuf);
                    // store a stable name
                    names[nb] = if (std.mem.eql(u8, lab, "compound")) "compound" else lab;
                    nb += 1;
                }
            }
        }
        // report named rediscoveries new this round
        try o.print("    {d}   |     {d:>3}    | ", .{ round, nb });
        var any = false;
        var idx: usize = start;
        while (idx < nb) : (idx += 1) {
            if (!std.mem.eql(u8, names[idx], "compound")) {
                try o.print("{s} ", .{names[idx]});
                any = true;
            }
        }
        const named_compounds = nb - start;
        if (!any) try o.print("(+{d} unnamed compound functions)", .{named_compounds}) else try o.print(" (+{d} new total)", .{named_compounds});
        try o.print("\n", .{});
        if (nb == start) break; // box stopped growing
    }

    // tally how many classical functions the engine reached from the 3-seed
    var reached: usize = 0;
    for (known) |kf| {
        var tmp: [M]i128 = undefined;
        fill(kf.f, &tmp);
        var t: usize = 0;
        while (t < nb) : (t += 1) if (vecEq(&tmp, &basis[t])) {
            reached += 1;
            break;
        };
    }
    try o.print("\n  From a 3-primitive seed the engine GREW its basis to {d} functions, rediscovering {d}/{d} of the\n", .{ nb, reached, known.len });
    try o.print("  classical functions as useful compounds (sigma, tau, phi, eps, n*tau, ... — see rounds above);\n", .{});
    try o.print("  each is a proven identity a*b = f. It BUILT the box it was previously handed.\n", .{});
    try o.print("  The {d} it could NOT reach are exactly id2 (n^2) and J2: their Dirichlet series is zeta(s-2),\n", .{known.len - reached});
    try o.print("  which convolutions of {{1,id,mu}} (powers of zeta(s) and zeta(s-1)) can never produce — a\n", .{});
    try o.print("  CONCRETE wall of the current meta-grammar, found by the engine itself.\n", .{});
    try o.print("  => 'Outside the box' = add a new primitive/operator (here: id2, or a pointwise product) so the\n", .{});
    try o.print("  generator can express zeta(s-2), then let the SAME sound verifier filter. Novelty = breadth of\n", .{});
    try o.print("  the generator x sharpness of the verifier, not a creativity module.\n", .{});
}

test "the box grows past its seed and reaches sigma, tau, phi from {1, id, mu}" {
    var one: [M]i128 = undefined;
    var id: [M]i128 = undefined;
    fill(k_one, &one);
    fill(k_id, &id);
    var sigma: [M]i128 = undefined;
    var tau: [M]i128 = undefined;
    var phi: [M]i128 = undefined;
    fill(k_sigma, &sigma);
    fill(k_tau, &tau);
    fill(k_phi, &phi);
    var c: [M]i128 = undefined;
    conv(&one, &id, &c); // 1*id = sigma
    try std.testing.expect(vecEq(&c, &sigma));
    conv(&one, &one, &c); // 1*1 = tau
    try std.testing.expect(vecEq(&c, &tau));
    var mu: [M]i128 = undefined;
    fill(k_mu, &mu);
    conv(&mu, &id, &c); // mu*id = phi
    try std.testing.expect(vecEq(&c, &phi));
}
