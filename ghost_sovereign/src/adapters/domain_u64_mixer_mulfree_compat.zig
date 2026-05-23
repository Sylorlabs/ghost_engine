const std = @import("std");
const mulfree = @import("domain_u64_mixer_mulfree.zig");

// --- MUL-FREE COMPAT WRAPPER ---
//
// Provides the same no-parameter API that domain_meta_engine.zig expects
// from its `target` import, but delegates to domain_u64_mixer_mulfree.zig
// in .mul_free mode. MaxProgLen is 24 in the mulfree domain but programs
// are constrained to [4,11] length on init and ≤12 on mutate/crossover,
// matching domain_u64_mixer.zig's effective range for equivalence check.
//
// MAX_LEN_RAND=11 → span = 11-4+1 = 8 → len ∈ [4,11], same as
//   domain_u64_mixer.zig's 4 + (rng % (12-4)) = 4 + rng % 8.
// MAX_LEN_MUTATE=12 → mutate/crossover cap same as original MaxProgLen.

pub const DOMAIN_NAME: []const u8 = "u64-mixer-mul-free-compat";

pub const Program = mulfree.Program;
pub const Quality = mulfree.Quality;

const MAX_LEN_RAND: u8 = 11;
const MAX_LEN_MUTATE: u8 = 12;

// --- Globals expected by domain_meta_engine.zig and runners ---

const MaxChainExtras: usize = 16;
pub var chain_extras: std.BoundedArray(Program, MaxChainExtras) = .{ .buffer = undefined, .len = 0 };
pub var live_macro_graduation: bool = false;
pub var anti_human_penalty: f64 = 0; // mulfree programs can't have human-named ops
pub var compressor_mode: bool = false; // unsupported in mulfree; stays false

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

// --- Target API (no mode parameter) ---

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
