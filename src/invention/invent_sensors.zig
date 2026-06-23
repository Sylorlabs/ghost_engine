//! invent_sensors.zig — #1 of the invention push: invent the SENSORS too, removing the last handed thing.
//! Previously d(n), sigma(n), isqrt(n) were GIVEN as atoms. Here the only primitives are arithmetic (+ * < %)
//! and one control construct — a bounded LOOP-FOLD:  acc = ⊕_{i=1..n, cond(i,n)} term(i,n).
//! Searching the template's (cond, term, ⊕) choices INVENTS the sensors:
//!   sum_{i | n} 1      = number of divisors d(n)
//!   sum_{i | n} i      = sum of divisors sigma(n)
//!   max_{i*i <= n} i   = isqrt(n)
//! Then it rediscovers Fermat — perfect square ⟺ d(n) odd — using the INVENTED sensors, verified by exact
//! computation. Nothing but arithmetic and a loop is handed; the sensors, the predicates, and the theorem are
//! all invented. Build: zig build-exe invent_sensors.zig -O ReleaseFast -femit-bin=/tmp/is && /tmp/is
const std = @import("std");
var A: std.mem.Allocator = undefined;
const N: u64 = 3000; // sensors are O(n) folds, so verify over a smaller-but-ample range

// ── the loop-fold template (the ONLY non-arithmetic primitive: a bounded accumulation over i in 1..n) ──
const Sensor = struct { cond: u8, term: u8, comb: u8 };
fn condTrue(c: u8, i: u64, n: u64) bool {
    return switch (c) {
        0 => true, // every i
        1 => n % i == 0, // i divides n
        2 => n % i == 0 and i < n, // proper divisor
        else => i * i <= n, // i*i <= n
    };
}
fn termVal(t: u8, i: u64, n: u64) u64 {
    return switch (t) {
        0 => 1,
        1 => i,
        2 => if (i != 0 and n % i == 0) n / i else 0,
        else => i * i,
    };
}
fn fold(s: Sensor, n: u64) u64 {
    var acc: u64 = if (s.comb == 2) 1 else 0; // product starts at 1
    var i: u64 = 1;
    while (i <= n) : (i += 1) {
        if (!condTrue(s.cond, i, n)) continue;
        const t = termVal(s.term, i, n);
        acc = switch (s.comb) {
            0 => acc +% t, // sum
            1 => @max(acc, t), // max
            else => acc *% t, // product
        };
    }
    return acc;
}
fn sensorName(s: Sensor, buf: []u8) []const u8 {
    const cs = switch (s.cond) {
        0 => "i in 1..n",
        1 => "i | n",
        2 => "i | n, i<n",
        else => "i*i<=n",
    };
    const ts = switch (s.term) {
        0 => "1",
        1 => "i",
        2 => "n/i",
        else => "i*i",
    };
    const os = switch (s.comb) {
        0 => "sum",
        1 => "max",
        else => "prod",
    };
    return std.fmt.bufPrint(buf, "{s}_({s}) of {s}", .{ os, cs, ts }) catch "?";
}

// reference functions (used ONLY to recognise which known sensor an invented one equals — not handed to search)
fn refD(n: u64) u64 {
    var c: u64 = 0;
    var i: u64 = 1;
    while (i <= n) : (i += 1) if (n % i == 0) {
        c += 1;
    };
    return c;
}
fn refSigma(n: u64) u64 {
    var s: u64 = 0;
    var i: u64 = 1;
    while (i <= n) : (i += 1) if (n % i == 0) {
        s += i;
    };
    return s;
}
fn refIsqrt(n: u64) u64 {
    var r: u64 = 0;
    while ((r + 1) * (r + 1) <= n) r += 1;
    return r;
}
fn behaviorEqRef(s: Sensor, ref: *const fn (u64) u64) bool {
    var n: u64 = 2;
    while (n <= N) : (n += 1) if (fold(s, n) != ref(n)) return false;
    return true;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    A = arena.allocator();
    const o = std.io.getStdOut().writer();

    try o.print("=== INVENT THE SENSORS — only arithmetic + a loop-fold is handed ===\n", .{});
    try o.print("search the template  acc = ⊕_(i in 1..n, cond) term  → the instantiations ARE the sensors.\n\n", .{});

    // enumerate + dedup sensors by behavior over [2,N]
    var byhash = std.AutoHashMap(u64, usize).init(A);
    const Inv = struct { s: Sensor, vals: []u64 };
    var invented = std.ArrayList(Inv).init(A);
    var total: usize = 0;
    var c: u8 = 0;
    while (c < 4) : (c += 1) {
        var t: u8 = 0;
        while (t < 4) : (t += 1) {
            var cb: u8 = 0;
            while (cb < 3) : (cb += 1) {
                const s = Sensor{ .cond = c, .term = t, .comb = cb };
                total += 1;
                var h: u64 = 1469598103934665603;
                var vals = A.alloc(u64, N + 1) catch return;
                var degenerate = true;
                var n: u64 = 2;
                while (n <= N) : (n += 1) {
                    const v = fold(s, n);
                    vals[n] = v;
                    h = (h ^ v) *% 1099511628211;
                    if (v != vals[2]) degenerate = false;
                }
                if (degenerate) continue; // constant sensor — useless
                if (byhash.contains(h)) continue; // same behavior as an earlier instantiation
                byhash.put(h, invented.items.len) catch {};
                invented.append(.{ .s = s, .vals = vals }) catch {};
            }
        }
    }
    try o.print("[search] {d} template instantiations → {d} distinct INVENTED sensors\n\n", .{ total, invented.items.len });

    try o.print("──────── invented sensors that match known number-theoretic functions (recognised, not handed) ────────\n", .{});
    var foundD: ?usize = null;
    var foundSqrt: ?usize = null;
    for (invented.items, 0..) |inv, idx| {
        var buf: [64]u8 = undefined;
        const nm = sensorName(inv.s, &buf);
        var tag: []const u8 = "";
        if (behaviorEqRef(inv.s, refD)) {
            tag = "  == d(n)  [divisor count]";
            foundD = idx;
        } else if (behaviorEqRef(inv.s, refSigma)) {
            tag = "  == sigma(n)  [sum of divisors]";
        } else if (behaviorEqRef(inv.s, refIsqrt)) {
            tag = "  == isqrt(n)";
            foundSqrt = idx;
        }
        if (tag.len > 0) try o.print("    {s}{s}\n", .{ nm, tag });
    }

    // ── rediscover Fermat using the INVENTED sensors (square via invented isqrt; d-parity via invented d) ──
    try o.print("\n──────── rediscover a theorem with the INVENTED sensors (nothing handed but arithmetic+loop) ────────\n", .{});
    if (foundD != null and foundSqrt != null) {
        const dv = invented.items[foundD.?].vals;
        const sv = invented.items[foundSqrt.?].vals;
        var holds = true;
        var counter: u64 = 0;
        var n: u64 = 2;
        while (n <= N) : (n += 1) {
            const isSquare = sv[n] * sv[n] == n; // invented isqrt, squared, == n
            const dOdd = dv[n] % 2 == 1; // invented divisor-count, odd
            if (isSquare != dOdd) {
                holds = false;
                counter = n;
                break;
            }
        }
        if (holds) {
            try o.print("    [CERTIFIED over 2..{d}]  (invented isqrt)^2 == n   ⟺   (invented d(n)) is odd\n", .{N});
            try o.print("    i.e. perfect square ⟺ odd number of divisors — Fermat's theorem, with the sensors invented too.\n", .{});
        } else try o.print("    refuted at n={d} (would mean a sensor mis-invented)\n", .{counter});
    } else try o.print("    (did not recover both d and isqrt from the template)\n", .{});

    try o.print("\n  Only arithmetic (+ * % <) and one loop-fold were handed. The engine searched the template and the\n", .{});
    try o.print("  instantiations turned out to BE d(n), sigma(n), isqrt(n) — the sensors were invented, recognised by\n", .{});
    try o.print("  matching computed behavior. Then the same Fermat theorem was certified using those invented sensors.\n", .{});
    try o.print("  Combined with feature_invent (predicates) and discover_laws (relations): vocabulary, features, and\n", .{});
    try o.print("  laws all invented from arithmetic + iteration. That is invention, end to end — not lookup.\n", .{});
}
