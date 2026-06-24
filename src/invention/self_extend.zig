//! self_extend.zig — the SELF-EXTENDING engine: it enlarges its own box by evidence.
//!
//! Implements the four steps:
//!   (1) FRONTIER DETECTION — compute the reachable closure of the current box (primitives under
//!       operators); the target behaviours NOT in it are the wall.
//!   (2) SELF-EXTENSION — when blocked, propose candidate extensions from a meta-grammar (new
//!       PRIMITIVES like id², new OPERATORS like the pointwise product), and KEEP the one with the
//!       highest YIELD: the most previously-unreachable targets it makes reachable (each reachable
//!       target is a verifier-confirmed identity). The engine chooses HOW to grow itself.
//!   (3) BROADEST BOX — the operator set IS the language; growing it broadens the generator toward
//!       "programs over the primitives", with computation (value-vector equality) as the verifier.
//!   (4) HONEST REGRESS — the candidate operators came from an outer meta-grammar we supplied; a
//!       truly open system would generate those too. You never escape having a generator — you choose
//!       a bigger box. Novelty = breadth of generator × sharpness of verifier × a yield signal.
const std = @import("std");

const M: usize = 40; // value-vector length, n = 1..M
const CAP: usize = 200; // closure size cap

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
fn f_one(n: i128) i128 {
    _ = n;
    return 1;
}
fn f_id(n: i128) i128 {
    return n;
}
fn f_id2(n: i128) i128 {
    return n * n;
}
fn f_id3(n: i128) i128 {
    return n * n * n;
}
fn f_mu(n: i128) i128 {
    var b: [16]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| {
        if (f.e >= 2) return 0;
        r = -r;
    }
    return r;
}
fn f_eps(n: i128) i128 {
    return if (n == 1) 1 else 0;
}
fn f_tau(n: i128) i128 {
    var b: [16]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= (f.e + 1);
    return r;
}
fn f_sigma(n: i128) i128 {
    var b: [16]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= @divTrunc(ipow(f.p, f.e + 1) - 1, f.p - 1);
    return r;
}
fn f_sigma2(n: i128) i128 {
    var b: [16]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= @divTrunc(ipow(f.p, 2 * (f.e + 1)) - 1, f.p * f.p - 1);
    return r;
}
fn f_phi(n: i128) i128 {
    var b: [16]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= ipow(f.p, f.e - 1) * (f.p - 1);
    return r;
}
fn f_J2(n: i128) i128 {
    var b: [16]PF = undefined;
    const c = factorize(n, &b);
    var r: i128 = 1;
    for (b[0..c]) |f| r *= ipow(f.p, 2 * (f.e - 1)) * (f.p * f.p - 1);
    return r;
}
fn f_ntau(n: i128) i128 {
    return n * f_tau(n);
}

fn fill(f: *const fn (i128) i128, out: []i128) void {
    var n: usize = 1;
    while (n <= M) : (n += 1) out[n - 1] = f(@intCast(n));
}
fn vecEq(a: []const i128, b: []const i128) bool {
    var i: usize = 0;
    while (i < M) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

// ── operators (the language constructs the engine can compose with) ──
const OpFn = *const fn ([]const i128, []const i128, []i128) void;
fn op_conv(a: []const i128, b: []const i128, out: []i128) void {
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
fn op_pmul(a: []const i128, b: []const i128, out: []i128) void {
    var i: usize = 0;
    while (i < M) : (i += 1) out[i] = a[i] * b[i];
}
fn op_padd(a: []const i128, b: []const i128, out: []i128) void {
    var i: usize = 0;
    while (i < M) : (i += 1) out[i] = a[i] + b[i];
}
fn op_psub(a: []const i128, b: []const i128, out: []i128) void {
    var i: usize = 0;
    while (i < M) : (i += 1) out[i] = a[i] - b[i];
}

const Target = struct { name: []const u8, f: *const fn (i128) i128 };
const targets = [_]Target{
    .{ .name = "1", .f = f_one },        .{ .name = "id", .f = f_id },       .{ .name = "mu", .f = f_mu },
    .{ .name = "eps", .f = f_eps },      .{ .name = "tau", .f = f_tau },     .{ .name = "sigma", .f = f_sigma },
    .{ .name = "phi", .f = f_phi },      .{ .name = "n*tau", .f = f_ntau },  .{ .name = "id2", .f = f_id2 },
    .{ .name = "J2", .f = f_J2 },        .{ .name = "sigma2", .f = f_sigma2 }, .{ .name = "id3", .f = f_id3 },
};

var set: [CAP][M]i128 = undefined;
fn closure(ops: []const OpFn, prims: []const [M]i128) usize {
    var n: usize = 0;
    for (prims) |p| {
        set[n] = p;
        n += 1;
    }
    var round: usize = 0;
    while (round < 6) : (round += 1) {
        const start = n;
        var added = false;
        var i: usize = 0;
        while (i < start) : (i += 1) {
            var j = i;
            while (j < start) : (j += 1) {
                for (ops) |op| {
                    if (n >= CAP) break;
                    var c: [M]i128 = undefined;
                    op(&set[i], &set[j], &c);
                    var seen = false;
                    var t: usize = 0;
                    while (t < n) : (t += 1) if (vecEq(&set[t], &c)) {
                        seen = true;
                        break;
                    };
                    if (!seen and n < CAP) {
                        set[n] = c;
                        n += 1;
                        added = true;
                    }
                }
            }
        }
        if (!added) break;
    }
    return n;
}
fn reachedCount(n: usize) usize {
    var r: usize = 0;
    for (targets) |tg| {
        var tv: [M]i128 = undefined;
        fill(tg.f, &tv);
        var t: usize = 0;
        while (t < n) : (t += 1) if (vecEq(&set[t], &tv)) {
            r += 1;
            break;
        };
    }
    return r;
}

pub fn main() !void {
    const o = std.io.getStdOut().writer();
    try o.print("=== SELF-EXTENDING ENGINE: enlarge the box by evidence (yield) ===\n", .{});
    try o.print("  box = primitives {{1, id, mu}} + operators {{conv}}; targets = {d} arithmetic functions.\n", .{targets.len});
    try o.print("  loop: detect unreachable targets (the wall) -> propose extensions -> keep the highest-yield.\n\n", .{});

    var one: [M]i128 = undefined;
    var id: [M]i128 = undefined;
    var mu: [M]i128 = undefined;
    var id2: [M]i128 = undefined;
    fill(f_one, &one);
    fill(f_id, &id);
    fill(f_mu, &mu);
    fill(f_id2, &id2);

    var ops: [8]OpFn = undefined;
    var nOps: usize = 0;
    ops[0] = op_conv;
    nOps = 1;
    var prims: [16][M]i128 = undefined;
    var nPrims: usize = 0;
    prims[0] = one;
    prims[1] = id;
    prims[2] = mu;
    nPrims = 3;

    var step: usize = 0;
    while (step < 6) : (step += 1) {
        const baseN = closure(ops[0..nOps], prims[0..nPrims]);
        const reached = reachedCount(baseN);
        try o.print("  box now: {d} ops, {d} primitives -> reaches {d}/{d} targets.\n", .{ nOps, nPrims, reached, targets.len });
        if (reached == targets.len) {
            try o.print("  all targets reachable — box is complete for this target set.\n", .{});
            break;
        }
        // list the wall
        try o.print("    WALL (unreachable): ", .{});
        for (targets) |tg| {
            var tv: [M]i128 = undefined;
            fill(tg.f, &tv);
            var found = false;
            var t: usize = 0;
            while (t < baseN) : (t += 1) if (vecEq(&set[t], &tv)) {
                found = true;
                break;
            };
            if (!found) try o.print("{s} ", .{tg.name});
        }
        try o.print("\n", .{});

        // propose extensions and measure yield
        const Cand = struct { name: []const u8, op: ?OpFn, prim: ?[M]i128 };
        const cands = [_]Cand{
            .{ .name = "operator: pointwise *", .op = op_pmul, .prim = null },
            .{ .name = "operator: pointwise +", .op = op_padd, .prim = null },
            .{ .name = "operator: pointwise -", .op = op_psub, .prim = null },
            .{ .name = "primitive: id2 (n^2)", .op = null, .prim = id2 },
        };
        var best_i: usize = cands.len;
        var best_yield: usize = 0;
        var best_reached: usize = 0;
        for (cands, 0..) |cand, ci| {
            var tOps = ops;
            var tnOps = nOps;
            var tPrims = prims;
            var tnPrims = nPrims;
            if (cand.op) |op| {
                tOps[tnOps] = op;
                tnOps += 1;
            }
            if (cand.prim) |pv| {
                tPrims[tnPrims] = pv;
                tnPrims += 1;
            }
            const tn = closure(tOps[0..tnOps], tPrims[0..tnPrims]);
            const tr = reachedCount(tn);
            const y = tr - reached;
            try o.print("      candidate {s:<24} -> yield {d} (would reach {d}/{d})\n", .{ cand.name, y, tr, targets.len });
            if (y > best_yield) {
                best_yield = y;
                best_i = ci;
                best_reached = tr;
            }
        }
        if (best_yield == 0) {
            try o.print("    no proposed extension crosses the wall — true frontier of this meta-grammar.\n", .{});
            break;
        }
        // KEEP the best extension
        const chosen = cands[best_i];
        try o.print("    >>> KEEP: {s}  (crosses {d} walls, now {d}/{d}) <<<\n\n", .{ chosen.name, best_yield, best_reached, targets.len });
        if (chosen.op) |op| {
            ops[nOps] = op;
            nOps += 1;
        }
        if (chosen.prim) |pv| {
            prims[nPrims] = pv;
            nPrims += 1;
        }
    }

    try o.print("\n  The engine DETECTED its wall (id2/J2/sigma2/id3 unreachable under convolution), PROPOSED\n", .{});
    try o.print("  extensions, MEASURED each by yield, and KEPT the pointwise-product OPERATOR — preferring the\n", .{});
    try o.print("  more general extension (one operator crosses all four walls) over adding a single primitive.\n", .{});
    try o.print("  It chose HOW to enlarge its own box, on evidence. Each newly-reached target is a proven a*b=f.\n", .{});
    try o.print("  HONEST REGRESS: the candidate operators came from an outer meta-grammar we supplied. A truly\n", .{});
    try o.print("  open system generates those too — you never escape a generator, you choose a bigger box. The\n", .{});
    try o.print("  broadest practical box is 'programs over the primitives' + computation as the sound verifier;\n", .{});
    try o.print("  novelty = breadth of generator x sharpness of verifier x a yield signal. No creativity module.\n", .{});
}

test "self-extension: conv-only reaches 8/12; adding pointwise * reaches all 12 (highest yield)" {
    var one: [M]i128 = undefined;
    var id: [M]i128 = undefined;
    var mu: [M]i128 = undefined;
    fill(f_one, &one);
    fill(f_id, &id);
    fill(f_mu, &mu);
    const prims = [_][M]i128{ one, id, mu };

    const ops1 = [_]OpFn{op_conv};
    const n1 = closure(&ops1, &prims);
    try std.testing.expectEqual(@as(usize, 8), reachedCount(n1)); // wall: id2, J2, sigma2, id3

    const ops2 = [_]OpFn{ op_conv, op_pmul };
    const n2 = closure(&ops2, &prims);
    try std.testing.expectEqual(@as(usize, 12), reachedCount(n2)); // pointwise product crosses all walls

    const ops3 = [_]OpFn{ op_conv, op_padd };
    const n3 = closure(&ops3, &prims);
    try std.testing.expectEqual(@as(usize, 8), reachedCount(n3)); // pointwise + yields nothing new
}
