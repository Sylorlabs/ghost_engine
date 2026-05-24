const std = @import("std");
const engine = @import("invention_engine.zig");
const mixer_base = @import("domain_u64_mixer.zig");

// --- DOMAIN: opset discovery (Exp9) ---
//
// A Program is an opset bitmask — a u16 where each bit enables one of
// the 14 mixer opcodes. quality(p) runs a short hill-climb SA over u64
// mixers restricted to the enabled ops and returns the best composite
// found. The outer meta-engine discovers WHICH opset enables the best
// mixers, effectively learning the inner domain from scratch.
//
// Expected finding: opsets that include MUL (bit 2) should reach higher
// quality, validating the MUL-necessity conjecture via a novel path —
// the engine rediscovers necessity without being told.
//
// Opcodes and their bit positions (match Op enum in domain_u64_mixer.zig):
//   bit 0 = XOR, bit 1 = ADD, bit 2 = MUL, bit 3 = ROTL,
//   bit 4 = SHL_XOR, bit 5 = SHR_XOR, bit 6 = SPLITMIX_STEP,
//   bit 7 = ADD_CONST, bit 8 = AND_NOT, bit 9 = OR_SHIFT,
//   bit 10 = CALL_LIB, bit 11 = ROTR, bit 12 = BSWAP,
//   bit 13 = MUM, bit 14 = ADD_ROT

pub const DOMAIN_NAME: []const u8 = "opset-discovery";

// Program = opset bitmask (which of 14 ops are allowed)
pub const Program = struct {
    opset_bits: u15, // bits 0..13 enable each Op in the mixer op enum
};

pub const Quality = struct {
    opset_bits: u15,
    n_allowed: u8,
    best_mixer_q: f64,
    composite: f64,
};

pub const MaxChainExtras: usize = 16;
pub var chain_extras: std.BoundedArray(Program, MaxChainExtras) = .{ .buffer = undefined, .len = 0 };
pub var live_macro_graduation: bool = false;
pub var anti_human_penalty: f64 = 0;
pub var compressor_mode: bool = false;

pub fn chainExtrasReset() void { chain_extras.len = 0; }
pub fn chainExtrasAppend(p: Program) !void { try chain_extras.append(p); }
pub fn chainExtrasLen() usize { return chain_extras.len; }
pub fn tryGraduateMacro(_: Program) void {}

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub fn randomProgram(rng: *u64) Program {
    rng.* = smix(rng.*);
    // Require at least 2 ops to be enabled; bias toward more ops.
    const raw: u15 = @intCast(rng.* & 0x7FFF);
    // Always enable at least ADD (bit 1) and ROTL (bit 3) so the search
    // has a non-degenerate starting point; other bits from random.
    const forced: u15 = (1 << 1) | (1 << 3);
    return .{ .opset_bits = raw | forced };
}

pub fn mutate(p: Program, rng: *u64) Program {
    rng.* = smix(rng.*);
    const mode = rng.* % 4;
    const forced: u15 = (1 << 1) | (1 << 3);
    if (mode < 2) {
        // Flip a random bit
        rng.* = smix(rng.*);
        const bit: u4 = @intCast(rng.* % 15);
        return .{ .opset_bits = (p.opset_bits ^ (@as(u15, 1) << bit)) | forced };
    } else if (mode == 2) {
        // Enable a random bit
        rng.* = smix(rng.*);
        const bit: u4 = @intCast(rng.* % 15);
        return .{ .opset_bits = p.opset_bits | (@as(u15, 1) << bit) | forced };
    } else {
        // Disable a random bit (keep forced)
        rng.* = smix(rng.*);
        const bit: u4 = @intCast(rng.* % 15);
        return .{ .opset_bits = (p.opset_bits & ~(@as(u15, 1) << bit)) | forced };
    }
}

pub fn crossover(a: Program, b: Program, rng: *u64) Program {
    rng.* = smix(rng.*);
    const mask: u15 = @intCast(rng.* & 0x7FFF);
    const forced: u15 = (1 << 1) | (1 << 3);
    return .{ .opset_bits = ((a.opset_bits & mask) | (b.opset_bits & ~mask)) | forced };
}

// Deliberately small: each opset quality call runs a quick inner SA.
// With 3-tier outer meta-engine at 24 iters, keeping this small
// (~5 steps × 1 sample) caps total pilot time under 60 s.
const InnerSaSteps: u32 = 1; // 200→10→1: 1 inner SA step per opset quality call; fast enough for outer meta to learn opset rankings
const InnerSaSamples: u32 = 1;

// Run a short SA over mixer programs restricted to the given opset.
// Returns the best composite quality found.
fn innerSaQuality(opset_bits: u15, root_seed: u64) f64 {
    // Save and set the opset restriction
    const saved_ban_mul = mixer_base.ban_mul_family;
    // We'll use a different mechanism: directly test if each op is in the opset
    // by temporarily enabling sac_fitness=false and using the standard quality.
    // The restriction is implemented by filtering ops during mutation/generation.
    // For simplicity: count quality of programs that only use allowed ops.
    // We approximate by running the standard SA but biasing randomInstr to only
    // pick allowed ops. Since we can't easily hook into mixer_base.randomInstr,
    // we instead use a penalty for disallowed ops.
    _ = saved_ban_mul;

    var rng: u64 = root_seed ^ 0xF00D_BABE_0000_0001;
    var cur = mixer_base.randomProgram(&rng);
    const init_q = mixer_base.evaluateQuality(cur);
    var best_composite = init_q.composite;

    // Penalize ops not in opset_bits
    var cur_penalty: f64 = 0;
    {
        var i: usize = 0;
        while (i < cur.used) : (i += 1) {
            const op_bit: u15 = @as(u15, 1) << @intCast(@intFromEnum(cur.instructions[i].op) % 15);
            if (opset_bits & op_bit == 0) cur_penalty += 20.0;
        }
    }
    best_composite -= cur_penalty;

    var s: u32 = 0;
    while (s < InnerSaSteps) : (s += 1) {
        const cand = mixer_base.mutate(cur, &rng);
        var cand_pen: f64 = 0;
        var j: usize = 0;
        while (j < cand.used) : (j += 1) {
            const op_bit: u15 = @as(u15, 1) << @intCast(@intFromEnum(cand.instructions[j].op) % 15);
            if (opset_bits & op_bit == 0) cand_pen += 20.0;
        }
        const cq = mixer_base.evaluateQuality(cand);
        const cand_composite = cq.composite - cand_pen;
        if (cand_composite > best_composite) {
            best_composite = cand_composite;
            cur = cand;
        }
    }
    return best_composite;
}

pub fn evaluateQuality(p: Program) Quality {
    var rng: u64 = 0xC0DE_BABE_1234_5678;
    var total: f64 = 0;
    var n: u32 = 0;
    while (n < InnerSaSamples) : (n += 1) {
        rng = smix(rng);
        total += innerSaQuality(p.opset_bits, rng);
    }
    const mean_q = total / @as(f64, @floatFromInt(InnerSaSamples));
    const n_allowed: u8 = @popCount(p.opset_bits);
    // Slight bonus for fewer ops (parsimony) — but mainly follow quality.
    const parsimony: f64 = @as(f64, @floatFromInt(15 - n_allowed)) * 0.1;
    const composite = mean_q + parsimony;
    return .{ .opset_bits = p.opset_bits, .n_allowed = n_allowed, .best_mixer_q = mean_q, .composite = composite };
}

pub fn qualityScalar(q: Quality) f64 { return q.composite; }
pub fn qualityPasses(q: Quality) bool { return q.best_mixer_q > 20.0; }
pub fn isFinite(q: Quality) bool { return std.math.isFinite(q.composite); }

pub fn programToCsv(p: Program, writer: anytype) !void {
    try writer.writeAll("opset_bits,n_allowed\n");
    try writer.print("{d},{d}\n", .{ p.opset_bits, @popCount(p.opset_bits) });
}
