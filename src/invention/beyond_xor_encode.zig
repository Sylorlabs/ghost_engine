//! beyond_xor_encode.zig — encode certified discoveries with the BEYOND-XOR (ADD/MUL) representation, then
//! project to a rune signature so they live in ghost_engine's existing rune-lattice / shard / sigil store.
//!
//! Why beyond-XOR: ghost_engine's vsa_math.bind is XOR (a^b) — GF(2)-affine, the closure-limited operation the
//! Closure Principle shows plateaus at chance on nonlinear readouts. This module binds with MUL (elementwise
//! product) and bundles with ADD (sum) over real/integer vectors — the nonlinear escape. Part 1 MEASURES the
//! escape (a linear readout: XOR/additive features stall on parity; the MUL cross-term separates it). Part 2
//! encodes discoveries and projects them to a 4096-bit `vsa_math.HyperVector` — the exact type
//! `rune_lattice.observe(vector, context_hash, now_ms)` takes — so the discovery becomes a rune (sigil/shard infra
//! kept, not replaced).
//! Build: zig build discover ; run: ./zig-out/bin/ghost_beyond_xor_encode
const std = @import("std");
const vsa = @import("vsa_math"); // for the rune-signature HyperVector type (= @Vector(64, u64), 4096-bit)

const D: usize = 512; // beyond-XOR vector dimension

fn splitmix(s: *u64) u64 {
    s.* +%= 0x9E3779B97F4A7C15;
    var z = s.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}
// deterministic ±1 atom vector for a symbol id
fn atom(id: u64, out: []f64) void {
    var s = id *% 0xD1B54A32D192ED03 +% 0x1234567;
    for (out) |*x| x.* = if (splitmix(&s) & 1 == 0) 1.0 else -1.0;
}
fn mulBind(a: []const f64, b: []const f64, out: []f64) void { // BEYOND-XOR bind = elementwise product
    for (out, 0..) |*o, i| o.* = a[i] * b[i];
}
fn addBundle(acc: []f64, v: []const f64) void { // bundle = sum (superposition)
    for (acc, 0..) |*o, i| o.* += v[i];
}

// ── Part 1: measure the closure escape (parity readout) ──
fn perceptronAcc(comptime F: usize, feats: []const [F]f64, labels: []const u8) f64 {
    var w = [_]f64{0} ** F;
    var b: f64 = 0;
    var epoch: usize = 0;
    while (epoch < 200) : (epoch += 1) {
        for (feats, 0..) |f, i| {
            var dot: f64 = b;
            for (0..F) |k| dot += w[k] * f[k];
            const pred: u8 = if (dot > 0) 1 else 0;
            const y = labels[i];
            if (pred != y) {
                const g: f64 = if (y == 1) 1.0 else -1.0;
                for (0..F) |k| w[k] += g * f[k];
                b += g;
            }
        }
    }
    var correct: usize = 0;
    for (feats, 0..) |f, i| {
        var dot: f64 = b;
        for (0..F) |k| dot += w[k] * f[k];
        const pred: u8 = if (dot > 0) 1 else 0;
        if (pred == labels[i]) correct += 1;
    }
    return @as(f64, @floatFromInt(correct)) / @as(f64, @floatFromInt(feats.len));
}

// ── Part 2: project a beyond-XOR vector to a 4096-bit rune signature (vsa_math.HyperVector) ──
fn toRune(vec: []const f64) vsa.HyperVector {
    var hv: vsa.HyperVector = @splat(0);
    var k: usize = 0;
    while (k < 4096) : (k += 1) {
        // sign of a random projection → one bit (locality-sensitive hash; preserves cosine resonance)
        var s = @as(u64, @intCast(k)) *% 0xA24BAED4963EE407 +% 0x9E3779B1;
        var dot: f64 = 0;
        for (vec) |x| dot += x * (if (splitmix(&s) & 1 == 0) @as(f64, 1) else -1);
        if (dot > 0) hv[k >> 6] |= @as(u64, 1) << @intCast(k & 63);
    }
    return hv;
}
fn runeResonance(a: vsa.HyperVector, b: vsa.HyperVector) u32 { // shared bits out of 4096 (higher = closer)
    var same: u32 = 0;
    for (0..64) |i| same += @popCount(~(a[i] ^ b[i]));
    return same;
}

pub fn main() !void {
    const o = std.io.getStdOut().writer();
    try o.print("=== BEYOND-XOR ENCODER — escape the GF(2) closure, then store discoveries as runes ===\n\n", .{});

    // Part 1 — closure escape, measured.
    try o.print("── Part 1: closure escape on parity (XOR of two latent features) ──\n", .{});
    const pts = [4][2]f64{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 } };
    const ys = [4]u8{ 0, 1, 1, 0 }; // y = x1 XOR x2
    var lin: [4][2]f64 = undefined; // XOR/additive features only: [x1, x2]
    var bxor: [4][3]f64 = undefined; // beyond-XOR: [x1, x2, x1*x2] (the MUL cross-term)
    for (pts, 0..) |p, i| {
        lin[i] = .{ p[0], p[1] };
        bxor[i] = .{ p[0], p[1], p[0] * p[1] };
    }
    const accLin = perceptronAcc(2, &lin, &ys);
    const accBx = perceptronAcc(3, &bxor, &ys);
    try o.print("    linear readout, additive/XOR features [x1,x2]        : {d:.0}%  (stuck — parity not linearly separable)\n", .{accLin * 100});
    try o.print("    linear readout, beyond-XOR features [x1,x2, x1*x2]   : {d:.0}%  (MUL cross-term escapes the closure)\n", .{accBx * 100});

    // Part 2 — encode discoveries with ADD/MUL, project to rune signatures, show resonance.
    try o.print("\n── Part 2: encode certified discoveries as beyond-XOR vectors → rune signatures ──\n", .{});
    // a discovery = bundle over (role ⊗ filler) MUL-binds; roles: SUBJECT, RELATION, OBJECT
    const ROLE_S: u64 = 1;
    const ROLE_R: u64 = 2;
    const ROLE_O: u64 = 3;
    const Disc = struct { name: []const u8, s: u64, r: u64, ob: u64 };
    // symbol ids (fillers): 100=sum_div, 101=phi, 102=n, 110=square, 111=d_parity, 120=recurrence, 121=2^n-1
    const discs = [_]Disc{
        .{ .name = "Gauss:  sum_{d|n} phi(d) = n", .s = 100, .r = 101, .ob = 102 },
        .{ .name = "Fermat: square <=> d odd", .s = 110, .r = 5, .ob = 111 },
        .{ .name = "Mersenne: f=2f+1 = 2^n-1", .s = 120, .r = 6, .ob = 121 },
    };
    var sigs: [discs.len]vsa.HyperVector = undefined;
    var rS: [D]f64 = undefined;
    var rR: [D]f64 = undefined;
    var rO: [D]f64 = undefined;
    atom(ROLE_S, &rS);
    atom(ROLE_R, &rR);
    atom(ROLE_O, &rO);
    for (discs, 0..) |d, idx| {
        var fS: [D]f64 = undefined;
        var fR: [D]f64 = undefined;
        var fO: [D]f64 = undefined;
        atom(d.s, &fS);
        atom(d.r, &fR);
        atom(d.ob, &fO);
        var bS: [D]f64 = undefined;
        var bR: [D]f64 = undefined;
        var bO: [D]f64 = undefined;
        mulBind(&rS, &fS, &bS);
        mulBind(&rR, &fR, &bR);
        mulBind(&rO, &fO, &bO);
        var acc = [_]f64{0} ** D;
        addBundle(&acc, &bS);
        addBundle(&acc, &bR);
        addBundle(&acc, &bO);
        sigs[idx] = toRune(&acc);
        try o.print("    encoded \"{s}\"  → rune popcount {d}/4096\n", .{ d.name, @as(u32, blk: {
            var c: u32 = 0;
            for (0..64) |i| c += @popCount(sigs[idx][i]);
            break :blk c;
        }) });
    }
    try o.print("\n    rune resonance (shared bits /4096; ~2048 = unrelated, higher = same):\n", .{});
    try o.print("      self(Gauss,Gauss)            = {d}\n", .{runeResonance(sigs[0], sigs[0])});
    try o.print("      cross(Gauss,Fermat)          = {d}\n", .{runeResonance(sigs[0], sigs[1])});
    try o.print("      cross(Gauss,Mersenne)        = {d}\n", .{runeResonance(sigs[0], sigs[2])});

    try o.print("\n  Beyond-XOR (ADD/MUL) escapes the GF(2) closure (Part 1), and each discovery projects to a distinct\n", .{});
    try o.print("  4096-bit vsa_math.HyperVector rune (Part 2). Integration point (sigil/shards/runes kept):\n", .{});
    try o.print("      slot = rune_lattice.observe(sig, context_hash, now_ms);   // store the discovery as a rune\n", .{});
    try o.print("      rune_lattice.verify(slot, now_ms);                        // certified ⇒ promote its rank\n", .{});
    try o.print("  so certified discoveries become first-class, searchable runes in the existing lattice/shard store.\n", .{});
}
