const std = @import("std");
const mulfree = @import("domain_u64_mixer_mulfree.zig");

// --- MUL-FREE COMPAT WRAPPER (max_len=24) ---
//
// Exp5 variant: removes the max_len=12 cap from Exp2/Exp3 to allow programs
// up to 24 instructions. Question: does more program length budget escape
// the -215 attractor and PractRand GF(2)-linearity barrier?
//
// MAX_LEN_RAND=23  → span = 23-4+1 = 20 → len ∈ [4,23]
// MAX_LEN_MUTATE=24 → mutate/crossover cap = full mulfree MaxProgLen

pub const DOMAIN_NAME: []const u8 = "u64-mixer-mul-free-l24";

pub const Program = mulfree.Program;
pub const Quality = mulfree.Quality;

const MAX_LEN_RAND: u8 = 23;
const MAX_LEN_MUTATE: u8 = 24;

const MaxChainExtras: usize = 16;
pub var chain_extras: std.BoundedArray(Program, MaxChainExtras) = .{ .buffer = undefined, .len = 0 };
pub var live_macro_graduation: bool = false;
pub var anti_human_penalty: f64 = 0;
pub var compressor_mode: bool = false;

pub fn tryGraduateMacro(p: Program) void {
    if (!live_macro_graduation) return;
    if (chain_extras.len >= MaxChainExtras) return;
    chain_extras.append(p) catch {};
}

pub fn chainExtrasReset() void {
    chain_extras.len = 0;
}

pub fn chainExtrasAppend(p: Program) !void {
    try chain_extras.append(p);
}

pub fn chainExtrasLen() usize {
    return chain_extras.len;
}

pub fn randomProgram(rng: *u64) Program {
    return mulfree.randomProgram(rng, .mul_free, MAX_LEN_RAND);
}

pub fn mutate(p: Program, rng: *u64) Program {
    return mulfree.mutate(p, rng, .mul_free, MAX_LEN_MUTATE);
}

pub fn crossover(a: Program, b: Program, rng: *u64) Program {
    return mulfree.crossover(a, b, rng, MAX_LEN_MUTATE);
}

pub fn evaluateQuality(p: Program) Quality {
    return mulfree.evaluateQuality(p);
}

pub fn qualityScalar(q: Quality) f64 {
    return mulfree.qualityScalar(q);
}

pub fn qualityPasses(q: Quality) bool {
    return mulfree.qualityPasses(q);
}

pub fn isFinite(q: Quality) bool {
    return mulfree.isFinite(q);
}

pub fn programToCsv(p: Program, writer: anytype) !void {
    return mulfree.programToCsv(p, writer);
}

pub fn opName(op: mulfree.Op) []const u8 {
    return mulfree.opName(op);
}
