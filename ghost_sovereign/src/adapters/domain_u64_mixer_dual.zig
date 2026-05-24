const std = @import("std");
const engine = @import("invention_engine.zig");
const mixer = @import("domain_u64_mixer.zig");

// --- DOMAIN: dual-output u64 mixer (Exp8) ---
//
// A Program pairs two independent u64 mixer programs (A, B).
// Quality measures: individual mixer quality for A and B, plus an
// independence penalty (cross-correlation between A and B outputs
// should be zero for independent mixers). Composite = mean(qual_A,
// qual_B) - independence_penalty.
//
// PractRand testing (external): interleave A(i) and B(i) for i=0,1,...
// using mixer_csv_emit_dual (TBD). Bijectivity applies per-output.

pub const DOMAIN_NAME: []const u8 = "u64-mixer-dual";

pub const Program = struct {
    a: mixer.Program,
    b: mixer.Program,
};

pub const Quality = struct {
    qual_a: f64,
    qual_b: f64,
    independence: f64, // 1.0 = perfectly independent, 0.0 = identical
    composite: f64,
};

pub const MaxChainExtras: usize = 16;
pub var chain_extras: std.BoundedArray(Program, MaxChainExtras) = .{ .buffer = undefined, .len = 0 };
pub var live_macro_graduation: bool = false;
pub var anti_human_penalty: f64 = 0;
pub var compressor_mode: bool = false;

pub fn tryGraduateMacro(p: Program) void {
    if (!live_macro_graduation) return;
    if (chain_extras.len >= MaxChainExtras) return;
    chain_extras.append(p) catch {};
}

pub fn chainExtrasReset() void { chain_extras.len = 0; }
pub fn chainExtrasAppend(p: Program) !void { try chain_extras.append(p); }
pub fn chainExtrasLen() usize { return chain_extras.len; }

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub fn randomProgram(rng: *u64) Program {
    return .{
        .a = mixer.randomProgram(rng),
        .b = mixer.randomProgram(rng),
    };
}

pub fn mutate(p: Program, rng: *u64) Program {
    rng.* = smix(rng.*);
    if (rng.* & 1 == 0) {
        return .{ .a = mixer.mutate(p.a, rng), .b = p.b };
    } else {
        return .{ .a = p.a, .b = mixer.mutate(p.b, rng) };
    }
}

pub fn crossover(a: Program, b: Program, rng: *u64) Program {
    return .{
        .a = mixer.crossover(a.a, b.a, rng),
        .b = mixer.crossover(a.b, b.b, rng),
    };
}

const IndepSamples: usize = 256;

fn measureIndependence(p: Program) f64 {
    // Measure cross-bit correlation: for each of 64 output bit positions,
    // does output_A bit j correlate with output_B bit j?
    // Independence score = 1 - mean |corr| across all 64 output bits.
    var total_corr: f64 = 0;
    var rng: u64 = 0xABCD_EF01_2345_6789;
    var bit: u6 = 0;
    while (true) : (bit += 1) {
        var agree: u32 = 0;
        var n: usize = 0;
        while (n < IndepSamples) : (n += 1) {
            rng = smix(rng);
            const x = rng;
            const ya = p.a.execute(x);
            const yb = p.b.execute(x);
            const bit_a = (ya >> bit) & 1;
            const bit_b = (yb >> bit) & 1;
            if (bit_a == bit_b) agree += 1;
        }
        const p_agree: f64 = @as(f64, @floatFromInt(agree)) / @as(f64, @floatFromInt(IndepSamples));
        // Correlation ∈ [-1,1] via 2*(p_agree - 0.5)
        const corr = @abs(2.0 * (p_agree - 0.5));
        total_corr += corr;
        if (bit == 63) break;
    }
    return 1.0 - (total_corr / 64.0); // 1.0 = fully independent
}

pub fn evaluateQuality(p: Program) Quality {
    const qa = mixer.evaluateQuality(p.a);
    const qb = mixer.evaluateQuality(p.b);
    const indep = measureIndependence(p);
    // Penalize low independence: -50*(1-indep)
    const indep_pen: f64 = 50.0 * (1.0 - indep);
    const composite = (qa.composite + qb.composite) / 2.0 - indep_pen;
    return .{ .qual_a = qa.composite, .qual_b = qb.composite, .independence = indep, .composite = composite };
}

pub fn qualityScalar(q: Quality) f64 { return q.composite; }
pub fn qualityPasses(q: Quality) bool { return q.independence >= 0.9 and q.composite > -50.0; }
pub fn isFinite(q: Quality) bool { return std.math.isFinite(q.composite); }

pub fn programToCsv(p: Program, writer: anytype) !void {
    try writer.writeAll("# dual mixer — program A:\n");
    try mixer.programToCsv(p.a, writer);
    try writer.writeAll("# dual mixer — program B:\n");
    try mixer.programToCsv(p.b, writer);
}
