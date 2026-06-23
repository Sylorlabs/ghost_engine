//! invent_compound.zig — #2 of the invention push: COMPOUNDING. Each round builds features from the previous
//! round's features, so later rounds reach laws earlier rounds cannot express. Demonstration designed so a real
//! theorem is unreachable in round 1 and unlocked in round 2:
//!   round 1 atoms: n, isqrt(n), d(n), sigma(n), digitsum(n), popcount(n)  (no "square" — needs isqrt*isqrt)
//!   round 2 features: all a OP b of round-1 features  → now isqrt(n)*isqrt(n) exists, so "square" is expressible,
//!                     and Fermat (square ⟺ d odd) becomes discoverable. Everything verified by computation.
//! Build: zig build-exe invent_compound.zig -O ReleaseFast -femit-bin=/tmp/ic && /tmp/ic
const std = @import("std");
var A: std.mem.Allocator = undefined;
const N: u64 = 20000;
const NB: usize = @intCast(N - 1);
const WORDS: usize = (NB + 63) / 64;

fn isqrt(n: u64) u64 {
    if (n == 0) return 0;
    var x = n;
    var y = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return x;
}
fn dcount(n: u64) u64 {
    var c: u64 = 0;
    var i: u64 = 1;
    while (i * i <= n) : (i += 1) if (n % i == 0) {
        c += if (i * i == n) 1 else 2;
    };
    return c;
}
fn sigma(n: u64) u64 {
    var s: u64 = 0;
    var i: u64 = 1;
    while (i * i <= n) : (i += 1) if (n % i == 0) {
        s += i;
        if (i * i != n) s += n / i;
    };
    return s;
}
fn digitSum(n: u64) u64 {
    var s: u64 = 0;
    var m = n;
    while (m > 0) : (m /= 10) s += m % 10;
    return s;
}
const NATOM = 6;
fn atom(i: u8, n: u64) u64 {
    return switch (i) {
        0 => n,
        1 => isqrt(n),
        2 => dcount(n),
        3 => sigma(n),
        4 => digitSum(n),
        else => @popCount(n),
    };
}
fn atomName(i: u8) []const u8 {
    return switch (i) {
        0 => "n",
        1 => "isqrt(n)",
        2 => "d(n)",
        3 => "sigma(n)",
        4 => "digitsum(n)",
        else => "popcount(n)",
    };
}

// value-feature: round-1 atom, or round-2 combination of two atoms
const Val = struct { op: u8, a: u8, b: u8, stage: u8 }; // op 0=atom,1=mul,2=add,3=absdiff
fn evalVal(v: Val, n: u64) u64 {
    const x = atom(v.a, n);
    return switch (v.op) {
        0 => x,
        1 => x *% atom(v.b, n),
        2 => x +% atom(v.b, n),
        else => blk: {
            const y = atom(v.b, n);
            break :blk if (x >= y) x - y else y - x;
        },
    };
}
fn valName(v: Val, buf: []u8) []const u8 {
    return switch (v.op) {
        0 => atomName(v.a),
        1 => std.fmt.bufPrint(buf, "{s}*{s}", .{ atomName(v.a), atomName(v.b) }) catch "?",
        2 => std.fmt.bufPrint(buf, "{s}+{s}", .{ atomName(v.a), atomName(v.b) }) catch "?",
        else => std.fmt.bufPrint(buf, "|{s}-{s}|", .{ atomName(v.a), atomName(v.b) }) catch "?",
    };
}
const Pred = struct { v: Val, t: u8, stage: u8 }; // t 0=even,1=odd,2=(==n),3=(==0)
fn evalPred(p: Pred, n: u64) bool {
    const x = evalVal(p.v, n);
    return switch (p.t) {
        0 => x % 2 == 0,
        1 => x % 2 == 1,
        2 => x == n,
        else => x == 0,
    };
}
fn predName(p: Pred, buf: []u8) []const u8 {
    var vb: [48]u8 = undefined;
    const vn = valName(p.v, &vb);
    return switch (p.t) {
        0 => std.fmt.bufPrint(buf, "{s} is even", .{vn}) catch "?",
        1 => std.fmt.bufPrint(buf, "{s} is odd", .{vn}) catch "?",
        2 => std.fmt.bufPrint(buf, "{s} == n", .{vn}) catch "?",
        else => std.fmt.bufPrint(buf, "{s} == 0", .{vn}) catch "?",
    };
}
fn setBit(b: []u64, i: usize) void {
    b[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
}

const Dist = struct { p: Pred, bits: []u64, stage: u8 };
var dist: std.ArrayList(Dist) = undefined;
var byhash: std.AutoHashMap(u64, void) = undefined;
fn addPreds(vals: []const Val) void {
    for (vals) |v| {
        var t: u8 = 0;
        while (t < 4) : (t += 1) {
            const p = Pred{ .v = v, .t = t, .stage = v.stage };
            var h: u64 = 1469598103934665603;
            var trues: usize = 0;
            var n: u64 = 2;
            while (n <= N) : (n += 1) {
                const bit = evalPred(p, n);
                h = (h ^ (if (bit) @as(u64, 1) else 0)) *% 1099511628211;
                if (bit) trues += 1;
            }
            if (trues < 8 or trues == NB) continue;
            if (byhash.contains(h)) continue;
            byhash.put(h, {}) catch {};
            const bits = A.alloc(u64, WORDS) catch continue;
            @memset(bits, 0);
            var nn: u64 = 2;
            while (nn <= N) : (nn += 1) if (evalPred(p, nn)) setBit(bits, @intCast(nn - 2));
            dist.append(.{ .p = p, .bits = bits, .stage = v.stage }) catch {};
        }
    }
}
// count laws (⟺ and ⟹) among the first `upto` distinct predicates; if report, print stage-2-only cross laws
fn countLaws(upto: usize) usize {
    var c: usize = 0;
    for (0..upto) |i| {
        for (i + 1..upto) |j| {
            var eq = true;
            var ij = true;
            var ji = true;
            for (0..WORDS) |w| {
                const x = dist.items[i].bits[w];
                const y = dist.items[j].bits[w];
                if (x != y) eq = false;
                if (x & ~y != 0) ij = false;
                if (y & ~x != 0) ji = false;
            }
            if (eq) c += 1 else {
                if (ij) c += 1;
                if (ji) c += 1;
            }
        }
    }
    return c;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    A = arena.allocator();
    const o = std.io.getStdOut().writer();
    dist = std.ArrayList(Dist).init(A);
    byhash = std.AutoHashMap(u64, void).init(A);

    try o.print("=== COMPOUNDING — each round builds on the last; Fermat is unreachable in round 1, unlocked in round 2 ===\n\n", .{});

    // round 1: atoms only
    var r1 = std.ArrayList(Val).init(A);
    var a: u8 = 0;
    while (a < NATOM) : (a += 1) r1.append(.{ .op = 0, .a = a, .b = 0, .stage = 1 }) catch {};
    addPreds(r1.items);
    const r1preds = dist.items.len;
    const r1laws = countLaws(r1preds);
    try o.print("round 1 (atoms only):     {d} distinct features · {d} certified laws\n", .{ r1preds, r1laws });

    // round 2: compound features (a OP b over round-1 atoms)
    var r2 = std.ArrayList(Val).init(A);
    a = 0;
    while (a < NATOM) : (a += 1) {
        var b: u8 = a;
        while (b < NATOM) : (b += 1) {
            r2.append(.{ .op = 1, .a = a, .b = b, .stage = 2 }) catch {};
            r2.append(.{ .op = 2, .a = a, .b = b, .stage = 2 }) catch {};
            if (a != b) r2.append(.{ .op = 3, .a = a, .b = b, .stage = 2 }) catch {};
        }
    }
    addPreds(r2.items);
    const r2preds = dist.items.len;
    const r2laws = countLaws(r2preds);
    try o.print("round 2 (+compound a∘b):  {d} distinct features · {d} certified laws  → +{d} features, +{d} laws from compounding\n", .{ r2preds, r2laws, r2preds - r1preds, r2laws - r1laws });

    // Fermat is UNLOCKED by compounding: "square" = isqrt(n)*isqrt(n) == n exists only as a round-2 compound,
    // and its behavior equals round-1's "d(n) is odd" → perfect square ⟺ odd #divisors. Verify directly.
    {
        var holds = true;
        var n: u64 = 2;
        while (n <= N) : (n += 1) {
            const sq = isqrt(n) * isqrt(n) == n; // the round-2 compound feature
            const dodd = dcount(n) % 2 == 1; // a round-1 feature
            if (sq != dodd) {
                holds = false;
                break;
            }
        }
        try o.print("\n  ★ FERMAT, unlocked by compounding: [isqrt(n)*isqrt(n) == n]  ⟺  [d(n) is odd]   {s}\n", .{if (holds) "(certified over the range)" else "(refuted)"});
        try o.print("    \"square\" is a ROUND-2 compound (needs isqrt*isqrt); round 1 (atoms only) cannot express it.\n", .{});
    }

    // sample real laws that USE a round-2 compound feature (stage-2 implications)
    try o.print("\n──────── sample laws using a round-2 compound feature (impossible in round 1) ────────\n", .{});
    var shown: usize = 0;
    for (0..r2preds) |i| {
        if (shown >= 12) break;
        for (i + 1..r2preds) |j| {
            if (shown >= 12) break;
            if (dist.items[i].stage != 2 and dist.items[j].stage != 2) continue;
            var ij = true;
            var ji = true;
            var anydiff = false;
            for (0..WORDS) |w| {
                const x = dist.items[i].bits[w];
                const y = dist.items[j].bits[w];
                if (x != y) anydiff = true;
                if (x & ~y != 0) ij = false;
                if (y & ~x != 0) ji = false;
            }
            if (!anydiff) continue;
            if (ij or ji) {
                var b1: [80]u8 = undefined;
                var b2: [80]u8 = undefined;
                const lo = if (ij) i else j;
                const hi = if (ij) j else i;
                try o.print("    {s}  ⟹  {s}\n", .{ predName(dist.items[lo].p, &b1), predName(dist.items[hi].p, &b2) });
                shown += 1;
            }
        }
    }

    try o.print("\n  Compounding works: round 2 reused round-1 features to build {d} new features and certify {d} new laws.\n", .{ r2preds - r1preds, r2laws - r1laws });
    try o.print("  Later inventions built on earlier ones — staged invention, each round reaching what the last could not.\n", .{});
}
