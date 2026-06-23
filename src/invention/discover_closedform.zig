//! discover_closedform.zig — the RICHER generator: programs with CONTROL FLOW (loops + branches), against a
//! sound verifier. An expression-only generator cannot even POSE an iteratively-defined sequence; this one
//! generates loop/branch programs a(n), then DISCOVERS a closed-form polynomial for each via finite differences
//! (exact, sound) and CERTIFIES it by reproducing a(n) over [1,M] from the recovered formula. Where no polynomial
//! closed form of bounded degree exists (factorial grows too fast; parity-dependent sums are only
//! quasi-polynomial) it HONESTLY abstains — a sound verifier never fakes a proof. This is the step from
//! rediscovering known theorems toward proposing new ones: the generator reaches functions expressions can't, and
//! the certifier discovers + proves their closed forms or refuses.
//! Build: zig build-exe discover_closedform.zig -O ReleaseFast -femit-bin=/tmp/cf && /tmp/cf
const std = @import("std");
const M: i128 = 200; // certify the recovered formula over n = 1..M
const DMAX: usize = 6; // search for polynomial closed forms up to this degree

// ───────────────────────── richer program space: loop + branch sequences a(n) ─────────────────────────
const Seq = struct { id: u8, name: []const u8, control: []const u8 };
const SEQS = [_]Seq{
    .{ .id = 0, .name = "sum_{i=1..n} i", .control = "loop" },
    .{ .id = 1, .name = "sum_{i=1..n} (2i-1)", .control = "loop" },
    .{ .id = 2, .name = "sum_{i=1..n} (i if i even else 0)", .control = "loop+branch" },
    .{ .id = 3, .name = "sum_{i=1..n} i*i", .control = "loop" },
    .{ .id = 4, .name = "sum_{i=1..n} i*i*i", .control = "loop" },
    .{ .id = 5, .name = "max_{i=1..n} i", .control = "loop" },
    .{ .id = 6, .name = "sum_{i=1..n} (n - i)", .control = "loop" },
    .{ .id = 7, .name = "product_{i=1..n} i  (factorial)", .control = "loop" },
    .{ .id = 8, .name = "count_{i=1..n} (i odd)", .control = "loop+branch" },
    .{ .id = 9, .name = "sum_{i=1..n} (i if i odd else 0)", .control = "loop+branch" },
    .{ .id = 10, .name = "sum_{i=1..n} (4i^3 - 3i)", .control = "loop" },
};
// compute a(n) by actually running the loop/branch program; null on overflow
fn seqVal(id: u8, n: i128) ?i128 {
    var acc: i128 = if (id == 7) 1 else 0;
    var i: i128 = 1;
    while (i <= n) : (i += 1) {
        const t: i128 = switch (id) {
            0 => i,
            1 => 2 * i - 1,
            2 => if (@rem(i, 2) == 0) i else 0,
            3 => i * i,
            4 => i * i * i,
            5 => i, // handled as max below
            6 => n - i,
            7 => i, // handled as product below
            8 => if (@rem(i, 2) == 1) 1 else 0,
            9 => if (@rem(i, 2) == 1) i else 0,
            else => 4 * i * i * i - 3 * i,
        };
        if (id == 5) {
            acc = @max(acc, i);
        } else if (id == 7) {
            acc *= i;
            if (acc > (1 << 100)) return null; // grows too fast — abstain
        } else acc += t;
    }
    return acc;
}

fn gcd(a: i128, b: i128) i128 {
    var x = if (a < 0) -a else a;
    var y = if (b < 0) -b else b;
    while (y != 0) {
        const t = @rem(x, y);
        x = y;
        y = t;
    }
    return if (x == 0) 1 else x;
}
fn factv(k: usize) i128 {
    var f: i128 = 1;
    var j: usize = 2;
    while (j <= k) : (j += 1) f *= @intCast(j);
    return f;
}
// integer binomial C(n,k), exact
fn binom(n: i128, k: usize) i128 {
    if (k == 0) return 1;
    var num: i128 = 1;
    var j: usize = 0;
    while (j < k) : (j += 1) num *= (n - @as(i128, @intCast(j)));
    return @divTrunc(num, factv(k));
}

pub fn main() !void {
    const o = std.io.getStdOut().writer();
    try o.print("=== RICHER GENERATOR — control flow (loops+branches) + closed-form discovery, sound verifier ===\n", .{});
    try o.print("run each iterative program, recover a polynomial closed form by finite differences, then CERTIFY it\n", .{});
    try o.print("reproduces a(n) over [1,{d}]. No polynomial of degree ≤{d}? Abstain — never fake a proof.\n\n", .{ M, DMAX });
    try o.print("──────── discovered closed forms (iterative program ≡ formula, certified) ────────\n", .{});

    var closed: usize = 0;
    for (SEQS) |sq| {
        // sample a(0..DMAX+1) for the difference table
        var a: [DMAX + 2]i128 = undefined;
        var sampled_ok = true;
        for (0..DMAX + 2) |j| {
            a[j] = seqVal(sq.id, @intCast(j)) orelse {
                sampled_ok = false;
                break;
            };
        }
        if (!sampled_ok) {
            try o.print("    {s:<36} [{s:<11}]  → grows too fast — no polynomial closed form\n", .{ sq.name, sq.control });
            continue;
        }
        // forward-difference table; b[k] = Δ^k a(0); degree = first k with all-zero differences
        var diff: [DMAX + 2]i128 = a;
        var b: [DMAX + 1]i128 = undefined;
        var degree: ?usize = null;
        for (0..DMAX + 1) |k| {
            b[k] = diff[0];
            // check if level k is all zero across the remaining window
            var allzero = true;
            for (0..DMAX + 1 - k) |j| if (diff[j] != 0) {
                allzero = false;
                break;
            };
            if (allzero) {
                degree = if (k == 0) 0 else k - 1;
                break;
            }
            // advance to level k+1
            for (0..DMAX + 1 - k) |j| diff[j] = diff[j + 1] - diff[j];
        }
        if (degree == null) {
            try o.print("    {s:<36} [{s:<11}]  → not a polynomial of degree ≤{d} (honest abstain)\n", .{ sq.name, sq.control, DMAX });
            continue;
        }
        const d = degree.?;
        // CERTIFY: a(n) == Σ_{k=0..d} b[k]·C(n,k) for every n in [1,M] (the sound verifier)
        var certified = true;
        var n: i128 = 1;
        while (n <= M) : (n += 1) {
            var s: i128 = 0;
            for (0..d + 1) |k| s += b[k] * binom(n, k);
            const av = seqVal(sq.id, n) orelse {
                certified = false;
                break;
            };
            if (s != av) {
                certified = false;
                break;
            }
        }
        if (!certified) {
            try o.print("    {s:<36} [{s:<11}]  → low-order pattern broke under certification (abstain)\n", .{ sq.name, sq.control });
            continue;
        }
        // expand Σ b[k]·C(n,k) into a monomial polynomial (c_i/D) for a readable closed form
        const D = factv(d);
        var num = [_]i128{0} ** (DMAX + 1);
        for (0..d + 1) |k| {
            // falling factorial coeffs ff = n(n-1)…(n-k+1)
            var ff = [_]i128{0} ** (DMAX + 1);
            ff[0] = 1;
            var hi: usize = 0;
            for (0..k) |j| {
                // multiply ff by (n - j)
                var nf = [_]i128{0} ** (DMAX + 1);
                for (0..hi + 1) |t| {
                    nf[t + 1] += ff[t]; // * n
                    nf[t] -= ff[t] * @as(i128, @intCast(j)); // * (-j)
                }
                ff = nf;
                hi += 1;
            }
            const scale = b[k] * @divTrunc(D, factv(k));
            for (0..k + 1) |t| num[t] += scale * ff[t];
        }
        // simplify num[]/D
        var g = D;
        for (0..d + 1) |t| g = gcd(g, num[t]);
        const Ds = @divTrunc(D, g);
        var buf: [160]u8 = undefined;
        var w = std.io.fixedBufferStream(&buf);
        const ww = w.writer();
        var first = true;
        var t: usize = d + 1;
        while (t > 0) {
            t -= 1;
            const c = @divTrunc(num[t], g);
            if (c == 0) continue;
            const neg = c < 0;
            const ac = if (neg) -c else c;
            if (first) {
                if (neg) try ww.print("-", .{});
            } else if (neg) try ww.print(" - ", .{}) else try ww.print(" + ", .{});
            first = false;
            if (t == 0) {
                try ww.print("{d}", .{ac});
            } else if (t == 1) {
                if (ac == 1) try ww.print("n", .{}) else try ww.print("{d}n", .{ac});
            } else {
                if (ac == 1) try ww.print("n^{d}", .{t}) else try ww.print("{d}n^{d}", .{ ac, t });
            }
        }
        const poly = w.getWritten();
        if (Ds == 1) {
            try o.print("    {s:<36} [{s:<11}]  ≡  {s}        (deg {d}, certified over [1,{d}])\n", .{ sq.name, sq.control, poly, d, M });
        } else {
            try o.print("    {s:<36} [{s:<11}]  ≡  ({s}) / {d}        (deg {d}, certified over [1,{d}])\n", .{ sq.name, sq.control, poly, Ds, d, M });
        }
        closed += 1;
    }

    try o.print("\n  {d}/{d} sequences closed into a CERTIFIED formula. The richer generator reaches functions an\n", .{ closed, SEQS.len });
    try o.print("  expression-only search can't even pose (they need the loop/branch to define them); the certifier\n", .{});
    try o.print("  discovers the closed form by finite differences and PROVES it over the range — or abstains where none\n", .{});
    try o.print("  exists (factorial; parity-dependent sums). Discovery and honest abstention from one sound verifier.\n", .{});
}
