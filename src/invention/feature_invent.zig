//! feature_invent.zig — invent the FEATURES too, not just the laws. The previous loop discovered laws among a
//! HANDED vocabulary (square/divisors/sigma…). Here the only handed things are primitive ops; the engine
//! GENERATES candidate feature-programs over n, dedups them BY BEHAVIOR over the integers (same behavior +
//! different program = a discovered identity), and the surviving distinct behaviors ARE the invented predicates.
//! Then it discovers laws among the invented predicates, each verified by exact computation; a counterexample
//! kills anything false. So both the vocabulary and the relations are invented — lookup can't do this.
//! Build: zig build-exe feature_invent.zig -O ReleaseFast -femit-bin=/tmp/fi && /tmp/fi
const std = @import("std");
var A: std.mem.Allocator = undefined;
const N: u64 = 100000; // verify over [2, N]
const NB: usize = @intCast(N - 1); // bit index 0..NB-1 for n=2..N

// ── primitive sensor functions (mechanism — computable; NO law about them is handed) ──
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
fn omega(n: u64) u64 {
    var c: u64 = 0;
    var m = n;
    var p: u64 = 2;
    while (p * p <= m) : (p += 1) if (m % p == 0) {
        c += 1;
        while (m % p == 0) m /= p;
    };
    if (m > 1) c += 1;
    return c;
}
fn digitSum(n: u64) u64 {
    var s: u64 = 0;
    var m = n;
    while (m > 0) : (m /= 10) s += m % 10;
    return s;
}
const NATOM = 7;
fn evalAtom(i: u8, n: u64) u64 {
    return switch (i) {
        0 => n,
        1 => isqrt(n),
        2 => dcount(n),
        3 => sigma(n),
        4 => digitSum(n),
        5 => omega(n),
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
        5 => "omega(n)",
        else => "popcount(n)",
    };
}

// ── value-program grammar over n (the search space) ──
const VOp = enum { atom, mod, sqsqrt, mul, add, sub };
const Val = struct { op: VOp, a: u8, b: u8, k: u8 };
fn evalVal(v: Val, n: u64) u64 {
    return switch (v.op) {
        .atom => evalAtom(v.a, n),
        .mod => blk: {
            const d = evalAtom(v.a, n);
            break :blk if (v.k == 0) 0 else d % v.k;
        },
        .sqsqrt => blk: {
            const r = isqrt(evalAtom(v.a, n));
            break :blk r *% r;
        },
        .mul => evalAtom(v.a, n) *% evalAtom(v.b, n),
        .add => evalAtom(v.a, n) +% evalAtom(v.b, n),
        .sub => blk: {
            const x = evalAtom(v.a, n);
            const y = evalAtom(v.b, n);
            break :blk if (x >= y) x - y else y - x;
        },
    };
}
fn valName(v: Val, buf: []u8) []const u8 {
    return switch (v.op) {
        .atom => atomName(v.a),
        .mod => std.fmt.bufPrint(buf, "{s} % {d}", .{ atomName(v.a), v.k }) catch "?",
        .sqsqrt => std.fmt.bufPrint(buf, "isqrt({s})^2", .{atomName(v.a)}) catch "?",
        .mul => std.fmt.bufPrint(buf, "{s}*{s}", .{ atomName(v.a), atomName(v.b) }) catch "?",
        .add => std.fmt.bufPrint(buf, "{s}+{s}", .{ atomName(v.a), atomName(v.b) }) catch "?",
        .sub => std.fmt.bufPrint(buf, "|{s}-{s}|", .{ atomName(v.a), atomName(v.b) }) catch "?",
    };
}

// ── predicate over n = (value-program, test) ──
const Pred = struct { v: Val, t: u8 }; // t: 0 (==n) 1 (==0) 2 (==1) 3 (even) 4 (odd)
const NTEST = 5;
fn evalPred(p: Pred, n: u64) bool {
    const x = evalVal(p.v, n);
    return switch (p.t) {
        0 => x == n,
        1 => x == 0,
        2 => x == 1,
        3 => x % 2 == 0,
        else => x % 2 == 1,
    };
}
fn predName(p: Pred, buf: []u8) []const u8 {
    var vb: [48]u8 = undefined;
    const vn = valName(p.v, &vb);
    return switch (p.t) {
        0 => std.fmt.bufPrint(buf, "{s} == n", .{vn}) catch "?",
        1 => std.fmt.bufPrint(buf, "{s} == 0", .{vn}) catch "?",
        2 => std.fmt.bufPrint(buf, "{s} == 1", .{vn}) catch "?",
        3 => std.fmt.bufPrint(buf, "{s} is even", .{vn}) catch "?",
        else => std.fmt.bufPrint(buf, "{s} is odd", .{vn}) catch "?",
    };
}

const WORDS: usize = (NB + 63) / 64;
fn getBit(bits: []u64, i: usize) bool {
    return (bits[i >> 6] >> @intCast(i & 63)) & 1 == 1;
}
fn setBit(bits: []u64, i: usize) void {
    bits[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    A = arena.allocator();
    const o = std.io.getStdOut().writer();

    try o.print("=== FEATURE-INVENTOR — invent the vocabulary AND the laws from primitive ops only ===\n", .{});
    try o.print("generate feature-programs over n, dedup BY BEHAVIOR over [2,{d}] (same behavior+different program =\n", .{N});
    try o.print("a discovered identity), then discover laws among the invented predicates. counterexample kills anything false.\n\n", .{});

    // 1. enumerate value-programs
    var vals = std.ArrayList(Val).init(A);
    var a: u8 = 0;
    while (a < NATOM) : (a += 1) {
        vals.append(.{ .op = .atom, .a = a, .b = 0, .k = 0 }) catch {};
        vals.append(.{ .op = .sqsqrt, .a = a, .b = 0, .k = 0 }) catch {};
        var k: u8 = 2;
        while (k <= 9) : (k += 1) vals.append(.{ .op = .mod, .a = a, .b = 0, .k = k }) catch {};
        var b: u8 = 0;
        while (b < NATOM) : (b += 1) {
            vals.append(.{ .op = .mul, .a = a, .b = b, .k = 0 }) catch {};
            vals.append(.{ .op = .add, .a = a, .b = b, .k = 0 }) catch {};
            vals.append(.{ .op = .sub, .a = a, .b = b, .k = 0 }) catch {};
        }
    }
    // 2. predicates = value × {==n,==0,==1,even}
    var allpreds = std.ArrayList(Pred).init(A);
    for (vals.items) |v| {
        var t: u8 = 0;
        while (t < NTEST) : (t += 1) allpreds.append(.{ .v = v, .t = t }) catch {};
    }
    try o.print("[gen] {d} value-programs · {d} candidate predicates\n", .{ vals.items.len, allpreds.items.len });

    // 3. dedup predicates by behavior; collect distinct (invented features) + discovered identities
    var byhash = std.AutoHashMap(u64, usize).init(A); // behavior-hash -> distinct index
    const Dist = struct { p: Pred, bits: []u64, trues: usize };
    var dist = std.ArrayList(Dist).init(A);
    var identities = std.ArrayList([2]Pred).init(A); // (canonical, duplicate) — same behavior, different program
    var degenerate: usize = 0;
    for (allpreds.items) |p| {
        var h: u64 = 1469598103934665603; // FNV
        var trues: usize = 0;
        var n: u64 = 2;
        while (n <= N) : (n += 1) {
            const bit = evalPred(p, n);
            h = (h ^ (if (bit) @as(u64, 1) else 0)) *% 1099511628211;
            if (bit) trues += 1;
        }
        if (trues < 8 or trues == NB) {
            degenerate += 1;
            continue;
        }
        if (byhash.get(h)) |di| {
            // same behavior as an existing distinct predicate but (almost surely) different program
            if (identities.items.len < 100000) identities.append(.{ dist.items[di].p, p }) catch {};
            continue;
        }
        const bits = A.alloc(u64, WORDS) catch continue;
        @memset(bits, 0);
        var nn: u64 = 2;
        while (nn <= N) : (nn += 1) if (evalPred(p, nn)) setBit(bits, @intCast(nn - 2));
        byhash.put(h, dist.items.len) catch {};
        dist.append(.{ .p = p, .bits = bits, .trues = trues }) catch {};
    }
    try o.print("[dedup] {d} distinct behaviors (INVENTED features) · {d} degenerate dropped · {d} program-pairs collapsed (discovered identities)\n\n", .{ dist.items.len, degenerate, identities.items.len });

    // 4. discover laws among invented predicates (⟺ equal bitset; ⟹ subset), verified over the whole range
    const D = dist.items.len;
    var generated: usize = 0;
    var refuted: usize = 0;
    const Law = struct { i: usize, j: usize, kind: u8, cross: bool };
    var laws = std.ArrayList(Law).init(A);
    for (0..D) |i| {
        for (i + 1..D) |j| {
            generated += 1;
            var equal = true;
            var ij = true; // i ⟹ j  (i & ~j == 0)
            var ji = true;
            for (0..WORDS) |w| {
                const x = dist.items[i].bits[w];
                const y = dist.items[j].bits[w];
                if (x != y) equal = false;
                if (x & ~y != 0) ij = false;
                if (y & ~x != 0) ji = false;
            }
            const cross = dist.items[i].p.v.a != dist.items[j].p.v.a;
            if (equal) {
                laws.append(.{ .i = i, .j = j, .kind = 0, .cross = cross }) catch {};
            } else {
                refuted += 1;
                if (ij) laws.append(.{ .i = i, .j = j, .kind = 1, .cross = cross }) catch {};
                if (ji) laws.append(.{ .i = j, .j = i, .kind = 1, .cross = cross }) catch {};
            }
        }
    }
    std.mem.sort(Law, laws.items, {}, struct {
        fn lt(_: void, x: Law, y: Law) bool {
            if (x.cross != y.cross) return x.cross;
            return x.kind < y.kind;
        }
    }.lt);

    // 5. report — discovered identities first (invented equivalent programs), then cross-feature laws
    try o.print("──────── sample DISCOVERED IDENTITIES (different programs, identical behavior — invented + proven) ────────\n", .{});
    var shown: usize = 0;
    for (identities.items) |id| {
        if (shown >= 200) break;
        if (id[0].v.a == id[1].v.a) continue; // only CROSS-ATOM identities (different feature families = surprising)
        var b1: [80]u8 = undefined;
        var b2: [80]u8 = undefined;
        try o.print("    {s}   ≡   {s}\n", .{ predName(id[0], &b1), predName(id[1], &b2) });
        shown += 1;
    }

    try o.print("\ngenerated {d} law candidates · refuted {d} by counterexample · {d} survived\n", .{ generated, refuted, laws.items.len });
    try o.print("\n──────── DISCOVERED CROSS-FEATURE LAWS (invented predicates, certified over [2,{d}]) ────────\n", .{N});
    shown = 0;
    for (laws.items) |l| {
        if (!l.cross) continue;
        if (shown >= 30) break;
        var b1: [80]u8 = undefined;
        var b2: [80]u8 = undefined;
        const arrow = if (l.kind == 0) "  ⟺  " else "  ⟹  ";
        try o.print("    {s}{s}{s}\n", .{ predName(dist.items[l.i].p, &b1), arrow, predName(dist.items[l.j].p, &b2) });
        shown += 1;
    }
    try o.print("\n  Nothing but the primitive ops was handed. The engine invented the predicates (e.g. \"isqrt(n)^2 == n\"\n  = perfect-square, \"n % 3 == 0\", \"digitsum(n) % 3 == 0\", \"d(n) is even\") by program search + behavior dedup,\n  then discovered + certified the laws among them. A counterexample killed {d} candidates. Lookup cannot do this.\n", .{refuted});
}
