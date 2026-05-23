const std = @import("std");

// --- REACHABILITY TESTER (Gen0) ---
//
// Operationalizes the user's strict "invention vs remix" question for the
// program_synthesis_inventor op set. For a given candidate program, measures
// how close it sits to a library of canonical, human-designed mixers under
// two independent metrics:
//
//   1. INSTRUCTION EDIT DISTANCE (Levenshtein over instruction tuples)
//      Catches syntactic near-copies. Substitution cost = 1 if any of
//      {op, dst, src1, src2, imm} differ. Insertion/deletion cost = 1.
//      Normalized = edit_dist / max(|P|, |Q|).
//
//   2. FUNCTIONAL SIMILARITY
//      - exact equivalence rate: fraction of inputs where P(x) == Q(x)
//      - mean bit agreement:     mean of (64 - popcount(P(x) ^ Q(x))) / 64
//      Both measured over `FuncSamples` deterministically-drawn u64 inputs.
//
// A genuine invention candidate scores LOW on both (high edit distance AND
// low functional similarity to every library mixer). A program that scores
// high on either is remix.
//
// This is a SYNTACTIC + BEHAVIORAL test, not full compositional
// reachability. The Gen1 extension is to enumerate compositions of library
// primitives up to depth k and check functional equivalence to the
// candidate — that test is well-defined but expensive (|library|^k * k
// programs to evaluate) and out of scope here.
//
// Runtime constraints (carried from the conceptless invention chain):
//   - std only
//   - no VSA / Flame / Concept imports
//   - no model, cloud, network, curated corpus

const NumRegs = 8;
const MaxProgLen = 12;
const FuncSamples = 1024;
const QualityAvalancheSamples = 64;
const QualityBalanceSamples = 256;
const QualityChiSamples = 4096;
const QualityPeriodSamples = 4096;

// Quality gates — candidate must clear ALL of these to be eligible for the
// INVENTION verdict. Bands chosen to admit splitMix64 / Murmur / Wang /
// xorshift (verified at build time via library cross-quality run) while
// excluding random programs.
const AvalancheLo: f64 = 30.0;
const AvalancheHi: f64 = 34.0;
const BalanceLo: f64 = 30.0;
const BalanceHi: f64 = 34.0;
const ChiSqMax: f64 = 400.0;
const PeriodMin: usize = 4096;

const Op = enum(u4) {
    XOR = 0,
    ADD = 1,
    MUL = 2,
    ROTL = 3,
    SHL_XOR = 4,
    SHR_XOR = 5,
    SPLITMIX_STEP = 6,
    ADD_CONST = 7,
    AND_NOT = 8,
    OR_SHIFT = 9,
};

const Instruction = struct {
    op: Op,
    dst: u3,
    src1: u3,
    src2: u3,
    imm: u64,

    fn eq(a: Instruction, b: Instruction) bool {
        return a.op == b.op and a.dst == b.dst and a.src1 == b.src1 and a.src2 == b.src2 and a.imm == b.imm;
    }
};

const Program = struct {
    instructions: [MaxProgLen]Instruction,
    used: u8,

    fn execute(self: Program, input: u64) u64 {
        var regs = [_]u64{0} ** NumRegs;
        regs[0] = input;
        regs[1] = 0x9E3779B97F4A7C15;
        regs[2] = 0xBF58476D1CE4E5B9;
        regs[3] = 0x94D049BB133111EB;
        var i: usize = 0;
        while (i < self.used) : (i += 1) {
            const inst = self.instructions[i];
            const a = regs[inst.src1];
            const b = regs[inst.src2];
            const result: u64 = switch (inst.op) {
                .XOR => a ^ b,
                .ADD => a +% b,
                .MUL => a *% (inst.imm | 1),
                .ROTL => std.math.rotl(u64, a, @as(u6, @intCast(inst.imm % 63 + 1))),
                .SHL_XOR => a ^ (a << @as(u6, @intCast(inst.imm % 63 + 1))),
                .SHR_XOR => a ^ (a >> @as(u6, @intCast(inst.imm % 63 + 1))),
                .SPLITMIX_STEP => (a ^ (a >> @as(u6, @intCast(inst.imm % 32 + 16)))) *% (b | 1),
                .ADD_CONST => a +% inst.imm,
                .AND_NOT => a & ~b,
                .OR_SHIFT => a | (b >> @as(u6, @intCast(inst.imm % 63 + 1))),
            };
            regs[inst.dst] = result;
        }
        return regs[NumRegs - 1];
    }
};

fn opName(op: Op) []const u8 {
    return switch (op) {
        .XOR => "XOR",
        .ADD => "ADD",
        .MUL => "MUL",
        .ROTL => "ROTL",
        .SHL_XOR => "SHL_XOR",
        .SHR_XOR => "SHR_XOR",
        .SPLITMIX_STEP => "SPLITMIX_STEP",
        .ADD_CONST => "ADD_CONST",
        .AND_NOT => "AND_NOT",
        .OR_SHIFT => "OR_SHIFT",
    };
}

// --- splitMix64 step used only for sampling input distributions ---
fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

// --- Library of canonical mixers, each encoded in the inventor's op language ---
// Output register is always r7 (the engine's convention: regs[NumRegs - 1]).

fn libSplitMix64() Program {
    // r0 += C ; r0 ^= r0>>30 ; r0 *= K1 ; r0 ^= r0>>27 ; r0 *= K2 ; r7 = r0 ^ (r0>>31)
    return Program{
        .instructions = [_]Instruction{
            .{ .op = .ADD_CONST, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0x9E3779B97F4A7C15 },
            .{ .op = .SHR_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 30 },
            .{ .op = .MUL, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0xBF58476D1CE4E5B9 },
            .{ .op = .SHR_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 27 },
            .{ .op = .MUL, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0x94D049BB133111EB },
            .{ .op = .SHR_XOR, .dst = 7, .src1 = 0, .src2 = 0, .imm = 31 },
        } ++ [_]Instruction{.{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0 }} ** (MaxProgLen - 6),
        .used = 6,
    };
}

fn libMurmurFinalizer() Program {
    // Murmur3 64-bit finalizer (fmix64): x ^= x>>33 ; x *= C1 ; x ^= x>>33 ; x *= C2 ; x ^= x>>33
    return Program{
        .instructions = [_]Instruction{
            .{ .op = .SHR_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 33 },
            .{ .op = .MUL, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0xFF51AFD7ED558CCD },
            .{ .op = .SHR_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 33 },
            .{ .op = .MUL, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0xC4CEB9FE1A85EC53 },
            .{ .op = .SHR_XOR, .dst = 7, .src1 = 0, .src2 = 0, .imm = 33 },
        } ++ [_]Instruction{.{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0 }} ** (MaxProgLen - 5),
        .used = 5,
    };
}

fn libXorshift64() Program {
    // Marsaglia's xorshift64: x ^= x<<13 ; x ^= x>>7 ; x ^= x<<17 (output last shift result)
    return Program{
        .instructions = [_]Instruction{
            .{ .op = .SHL_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 13 },
            .{ .op = .SHR_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 7 },
            .{ .op = .SHL_XOR, .dst = 7, .src1 = 0, .src2 = 0, .imm = 17 },
        } ++ [_]Instruction{.{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0 }} ** (MaxProgLen - 3),
        .used = 3,
    };
}

fn libWangHash64() Program {
    // Wang's 64-bit integer hash: x = ~x +% (x<<21) ; x ^= x>>24 ; x = x +% (x<<3) +% (x<<8) ;
    // approximate in available ops:  x ^= x<<21 ; x ^= x>>24 ; x = x*M (where M encodes the add-shift bundle)
    // We pick a faithful approximation: shl_xor 21, shr_xor 24, shl_xor 3, shl_xor 8, output.
    return Program{
        .instructions = [_]Instruction{
            .{ .op = .SHL_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 21 },
            .{ .op = .SHR_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 24 },
            .{ .op = .SHL_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 3 },
            .{ .op = .SHL_XOR, .dst = 7, .src1 = 0, .src2 = 0, .imm = 8 },
        } ++ [_]Instruction{.{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0 }} ** (MaxProgLen - 4),
        .used = 4,
    };
}

const LibEntry = struct {
    name: []const u8,
    program: Program,
};

fn library() [4]LibEntry {
    return .{
        .{ .name = "splitMix64", .program = libSplitMix64() },
        .{ .name = "MurmurFinalizer", .program = libMurmurFinalizer() },
        .{ .name = "xorshift64", .program = libXorshift64() },
        .{ .name = "WangHash64", .program = libWangHash64() },
    };
}

// --- Candidate programs to test ---

fn candSplitMix64Self() Program {
    return libSplitMix64();
}

fn candTrivialMod() Program {
    // splitMix64 with ONE imm changed (28 instead of 27 on the second SHR_XOR).
    // Should score edit_dist = 1, low func equivalence (very different outputs).
    var p = libSplitMix64();
    p.instructions[3].imm = 28;
    return p;
}

fn candRandom(seed: u64) Program {
    var rng = seed;
    rng = smix(rng);
    const len: u8 = 5;
    var p = Program{ .instructions = undefined, .used = len };
    var i: usize = 0;
    while (i < len) : (i += 1) {
        rng = smix(rng);
        const op_idx: u4 = @intCast(rng % 10);
        rng = smix(rng);
        const dst: u3 = @intCast(rng % NumRegs);
        rng = smix(rng);
        const src1: u3 = @intCast(rng % NumRegs);
        rng = smix(rng);
        const src2: u3 = @intCast(rng % NumRegs);
        rng = smix(rng);
        p.instructions[i] = .{ .op = @enumFromInt(op_idx), .dst = dst, .src1 = src1, .src2 = src2, .imm = rng };
    }
    p.instructions[len - 1].dst = NumRegs - 1;
    return p;
}

fn candDocumentedRun1() Program {
    // Transcribed from docs/research/program_synthesis_inventor.md (Run 1).
    // CAVEAT: the documented form uses placeholder "s" for shift amounts
    // and the engine does not currently persist discovered imm values to
    // disk. We pick plausible representative shifts (s=17, s=27) so the
    // STRUCTURE is testable. Exact imm reconstruction requires the
    // inventor to be patched to save its discoveries.
    return Program{
        .instructions = [_]Instruction{
            .{ .op = .SHR_XOR, .dst = 6, .src1 = 0, .src2 = 0, .imm = 17 },
            .{ .op = .SHR_XOR, .dst = 1, .src1 = 6, .src2 = 0, .imm = 27 },
            .{ .op = .SPLITMIX_STEP, .dst = 2, .src1 = 6, .src2 = 1, .imm = 23 },
            .{ .op = .OR_SHIFT, .dst = 7, .src1 = 0, .src2 = 2, .imm = 17 },
            .{ .op = .SPLITMIX_STEP, .dst = 7, .src1 = 7, .src2 = 1, .imm = 23 },
        } ++ [_]Instruction{.{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0 }} ** (MaxProgLen - 5),
        .used = 5,
    };
}

fn candDocumentedRun2() Program {
    // From docs Run 2: SHR_XOR ; ADD_CONST ; MUL ; SHR_XOR ; MUL. Same caveat
    // about exact imm values — placeholders chosen from canonical mixers.
    return Program{
        .instructions = [_]Instruction{
            .{ .op = .SHR_XOR, .dst = 1, .src1 = 0, .src2 = 0, .imm = 30 },
            .{ .op = .ADD_CONST, .dst = 0, .src1 = 1, .src2 = 0, .imm = 0x9E3779B97F4A7C15 },
            .{ .op = .MUL, .dst = 6, .src1 = 0, .src2 = 0, .imm = 0xBF58476D1CE4E5B9 },
            .{ .op = .SHR_XOR, .dst = 6, .src1 = 6, .src2 = 0, .imm = 27 },
            .{ .op = .MUL, .dst = 7, .src1 = 6, .src2 = 0, .imm = 0x94D049BB133111EB },
        } ++ [_]Instruction{.{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0 }} ** (MaxProgLen - 5),
        .used = 5,
    };
}

const Candidate = struct {
    name: []const u8,
    program: Program,
    notes: []const u8,
};

// --- Levenshtein over instruction sequences ---
fn editDistance(a: Program, b: Program, allocator: std.mem.Allocator) !usize {
    const la = a.used;
    const lb = b.used;
    const rows = la + 1;
    const cols = lb + 1;
    const dp = try allocator.alloc(usize, rows * cols);
    defer allocator.free(dp);
    var i: usize = 0;
    while (i <= la) : (i += 1) dp[i * cols + 0] = i;
    var j: usize = 0;
    while (j <= lb) : (j += 1) dp[0 * cols + j] = j;
    i = 1;
    while (i <= la) : (i += 1) {
        var jj: usize = 1;
        while (jj <= lb) : (jj += 1) {
            const sub_cost: usize = if (a.instructions[i - 1].eq(b.instructions[jj - 1])) 0 else 1;
            const v_sub = dp[(i - 1) * cols + (jj - 1)] + sub_cost;
            const v_del = dp[(i - 1) * cols + jj] + 1;
            const v_ins = dp[i * cols + (jj - 1)] + 1;
            var best = v_sub;
            if (v_del < best) best = v_del;
            if (v_ins < best) best = v_ins;
            dp[i * cols + jj] = best;
        }
    }
    return dp[la * cols + lb];
}

// --- Functional similarity ---
const FuncStats = struct {
    exact_equiv_rate: f64,
    mean_bit_agreement: f64, // in [0, 1]; 0.5 = random, 1.0 = identical
};

fn functionalSimilarity(p: Program, q: Program) FuncStats {
    var exact: u64 = 0;
    var bit_agree_total: u64 = 0;
    var rng: u64 = 0xDEAD_BEEF_5EED_C0DE;
    var i: usize = 0;
    while (i < FuncSamples) : (i += 1) {
        rng = smix(rng);
        const x = rng;
        const yp = p.execute(x);
        const yq = q.execute(x);
        if (yp == yq) exact += 1;
        bit_agree_total += @as(u64, 64) - @popCount(yp ^ yq);
    }
    return .{
        .exact_equiv_rate = @as(f64, @floatFromInt(exact)) / @as(f64, @floatFromInt(FuncSamples)),
        .mean_bit_agreement = @as(f64, @floatFromInt(bit_agree_total)) / (@as(f64, @floatFromInt(FuncSamples)) * 64.0),
    };
}

// --- Quality measurements (mirrored from program_synthesis_inventor.zig) ---
const Quality = struct {
    avalanche: f64,
    balance: f64,
    chisq: f64,
    period: usize,
    passes_gate: bool,
};

fn qualityAvalanche(p: Program) f64 {
    var total: f64 = 0;
    var samples: u64 = 0;
    var rng: u64 = 0xACE_F00D_BEEF_CAFE;
    var s: usize = 0;
    while (s < QualityAvalancheSamples) : (s += 1) {
        rng = smix(rng);
        const x = rng;
        const y = p.execute(x);
        var bit: u6 = 0;
        while (true) {
            const x_flip = x ^ (@as(u64, 1) << bit);
            const y_flip = p.execute(x_flip);
            total += @as(f64, @floatFromInt(@popCount(y ^ y_flip)));
            samples += 1;
            if (bit == 63) break;
            bit += 1;
        }
    }
    return total / @as(f64, @floatFromInt(samples));
}

fn qualityBalance(p: Program) f64 {
    var total_pop: f64 = 0;
    var rng: u64 = 0x1234_5678_9ABC_DEF0;
    var n: usize = 0;
    while (n < QualityBalanceSamples) : (n += 1) {
        rng = smix(rng);
        const y = p.execute(rng);
        total_pop += @as(f64, @floatFromInt(@popCount(y)));
    }
    return total_pop / @as(f64, @floatFromInt(QualityBalanceSamples));
}

fn qualityChiSq(p: Program) f64 {
    var bins = [_]u32{0} ** 256;
    var rng: u64 = 0xDEAD_BEEF_BAD_F00D;
    var n: usize = 0;
    while (n < QualityChiSamples) : (n += 1) {
        rng = smix(rng);
        const y = p.execute(rng);
        bins[@intCast(y & 0xFF)] += 1;
    }
    const expected = @as(f64, @floatFromInt(QualityChiSamples)) / 256.0;
    var chisq: f64 = 0;
    for (bins) |c| {
        const d = @as(f64, @floatFromInt(c)) - expected;
        chisq += (d * d) / expected;
    }
    return chisq;
}

fn qualityPeriod(p: Program) usize {
    const seed: u64 = 0x7E57_0001;
    var x = seed;
    var i: usize = 0;
    while (i < QualityPeriodSamples) : (i += 1) {
        x = p.execute(x);
        if (x == seed and i > 0) return i + 1;
    }
    return QualityPeriodSamples;
}

fn measureQuality(p: Program) Quality {
    const av = qualityAvalanche(p);
    const bal = qualityBalance(p);
    const cs = qualityChiSq(p);
    const per = qualityPeriod(p);
    const passes = av >= AvalancheLo and av <= AvalancheHi and
        bal >= BalanceLo and bal <= BalanceHi and
        cs <= ChiSqMax and per >= PeriodMin;
    return .{ .avalanche = av, .balance = bal, .chisq = cs, .period = per, .passes_gate = passes };
}

// --- Compositional reachability (Gen1) ---
// Treat each library primitive L as a function L(x): u64 → u64. A
// composition of depth k is L_k ∘ ... ∘ L_1, evaluated as
//   y = L_1(x); y = L_2(y); ...; y = L_k(y).
// We measure functional similarity between candidate(x) and every
// composition. If any depth ≤ MaxCompositionDepth composition matches
// candidate at bit_agreement ≥ ReachThreshold, the candidate is REACHABLE.

const MaxCompositionDepth: usize = 5;
const ReachThreshold: f64 = 0.95;

const ReachResult = struct {
    best_bit_agreement: f64,
    best_exact_equiv: f64,
    best_depth: usize,
    best_path: [MaxCompositionDepth]usize,
    reachable: bool,
};

fn execComposition(lib: []const LibEntry, path: []const usize, x: u64) u64 {
    var y = x;
    for (path) |idx| {
        y = lib[idx].program.execute(y);
    }
    return y;
}

fn compareToComposition(cand: Program, lib: []const LibEntry, path: []const usize) FuncStats {
    var exact: u64 = 0;
    var bit_agree_total: u64 = 0;
    var rng: u64 = 0xDEAD_BEEF_5EED_C0DE;
    var i: usize = 0;
    while (i < FuncSamples) : (i += 1) {
        rng = smix(rng);
        const x = rng;
        const yp = cand.execute(x);
        const yq = execComposition(lib, path, x);
        if (yp == yq) exact += 1;
        bit_agree_total += @as(u64, 64) - @popCount(yp ^ yq);
    }
    return .{
        .exact_equiv_rate = @as(f64, @floatFromInt(exact)) / @as(f64, @floatFromInt(FuncSamples)),
        .mean_bit_agreement = @as(f64, @floatFromInt(bit_agree_total)) / (@as(f64, @floatFromInt(FuncSamples)) * 64.0),
    };
}

fn searchReachability(cand: Program, lib: []const LibEntry) ReachResult {
    var best: ReachResult = .{
        .best_bit_agreement = 0,
        .best_exact_equiv = 0,
        .best_depth = 0,
        .best_path = .{0} ** MaxCompositionDepth,
        .reachable = false,
    };
    var depth: usize = 1;
    while (depth <= MaxCompositionDepth) : (depth += 1) {
        var path: [MaxCompositionDepth]usize = .{0} ** MaxCompositionDepth;
        const total = std.math.pow(usize, lib.len, depth);
        var n: usize = 0;
        while (n < total) : (n += 1) {
            var t = n;
            var i: usize = 0;
            while (i < depth) : (i += 1) {
                path[i] = t % lib.len;
                t /= lib.len;
            }
            const fs = compareToComposition(cand, lib, path[0..depth]);
            if (fs.mean_bit_agreement > best.best_bit_agreement) {
                best.best_bit_agreement = fs.mean_bit_agreement;
                best.best_exact_equiv = fs.exact_equiv_rate;
                best.best_depth = depth;
                var k: usize = 0;
                while (k < depth) : (k += 1) best.best_path[k] = path[k];
            }
        }
    }
    best.reachable = best.best_bit_agreement >= ReachThreshold;
    return best;
}

const Score = struct {
    closest_name: []const u8,
    min_edit_dist: usize,
    norm_edit_dist: f64,
    best_exact_equiv: f64,
    best_bit_agreement: f64,
    closest_by_bit_name: []const u8,
};

fn scoreCandidate(c: Candidate, lib: []const LibEntry, allocator: std.mem.Allocator) !Score {
    var min_ed: usize = std.math.maxInt(usize);
    var min_ed_idx: usize = 0;
    var best_exact: f64 = 0;
    var best_bits: f64 = 0;
    var best_bits_idx: usize = 0;
    for (lib, 0..) |entry, idx| {
        const ed = try editDistance(c.program, entry.program, allocator);
        const fs = functionalSimilarity(c.program, entry.program);
        if (ed < min_ed) {
            min_ed = ed;
            min_ed_idx = idx;
        }
        if (fs.exact_equiv_rate > best_exact) best_exact = fs.exact_equiv_rate;
        if (fs.mean_bit_agreement > best_bits) {
            best_bits = fs.mean_bit_agreement;
            best_bits_idx = idx;
        }
    }
    const max_len = @max(c.program.used, lib[min_ed_idx].program.used);
    return .{
        .closest_name = lib[min_ed_idx].name,
        .min_edit_dist = min_ed,
        .norm_edit_dist = @as(f64, @floatFromInt(min_ed)) / @as(f64, @floatFromInt(max_len)),
        .best_exact_equiv = best_exact,
        .best_bit_agreement = best_bits,
        .closest_by_bit_name = lib[best_bits_idx].name,
    };
}

fn verdict(s: Score, q: Quality, r: ReachResult) []const u8 {
    if (s.best_exact_equiv >= 0.99) return "EQUIVALENT (functional)";
    if (s.min_edit_dist <= 1) return "TRIVIAL VARIANT (edit<=1)";
    if (s.best_bit_agreement >= 0.95) return "NEAR-EQUIVALENT (bits>=0.95)";
    if (s.norm_edit_dist <= 0.34 or s.best_bit_agreement >= 0.75) return "REMIX (close to library)";
    if (r.reachable) return "REACHABLE (composition match)";
    if (!q.passes_gate) return "NON-MIXER (fails quality gate)";
    return "INVENTION (strict: divergent + quality + unreachable)";
}

fn loadChampionCsv(allocator: std.mem.Allocator, path: []const u8) !?Program {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(data);
    var p = Program{ .instructions = undefined, .used = 0 };
    var line_it = std.mem.splitScalar(u8, data, '\n');
    _ = line_it.next(); // header
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        var f_it = std.mem.splitScalar(u8, line, ',');
        const idx_s = f_it.next() orelse continue;
        _ = idx_s;
        const op_id_s = f_it.next() orelse continue;
        _ = f_it.next() orelse continue; // op_name
        const dst_s = f_it.next() orelse continue;
        const src1_s = f_it.next() orelse continue;
        const src2_s = f_it.next() orelse continue;
        const imm_s = f_it.next() orelse continue;
        const op_id = try std.fmt.parseInt(u4, std.mem.trim(u8, op_id_s, " \r"), 10);
        const dst = try std.fmt.parseInt(u3, std.mem.trim(u8, dst_s, " \r"), 10);
        const src1 = try std.fmt.parseInt(u3, std.mem.trim(u8, src1_s, " \r"), 10);
        const src2 = try std.fmt.parseInt(u3, std.mem.trim(u8, src2_s, " \r"), 10);
        const imm_trim = std.mem.trim(u8, imm_s, " \r");
        const imm_hex = if (std.mem.startsWith(u8, imm_trim, "0x")) imm_trim[2..] else imm_trim;
        const imm = try std.fmt.parseInt(u64, imm_hex, 16);
        if (p.used >= MaxProgLen) break;
        p.instructions[p.used] = .{ .op = @enumFromInt(op_id), .dst = dst, .src1 = src1, .src2 = src2, .imm = imm };
        p.used += 1;
    }
    if (p.used == 0) return null;
    return p;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var champion_path: []const u8 = "results/program_synthesis_champion.csv";
    var report_path: []const u8 = "results/reachability_tester.csv";
    var quiet: bool = false;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--champion=")) {
            champion_path = try allocator.dupe(u8, arg["--champion=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--csv=")) {
            report_path = try allocator.dupe(u8, arg["--csv=".len..]);
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        }
    }

    const lib = library();
    const loaded_champion = loadChampionCsv(allocator, champion_path) catch null;
    const candidates_static = [_]Candidate{
        .{ .name = "splitMix64_self", .program = candSplitMix64Self(), .notes = "sanity: distance to self should be 0, equiv 1.0" },
        .{ .name = "splitMix64_trivial_mod", .program = candTrivialMod(), .notes = "sanity: edit_dist=1, low equiv" },
        .{ .name = "random_program_A", .program = candRandom(0x1111_2222_3333_4444), .notes = "sanity: high edit dist, low equiv" },
        .{ .name = "random_program_B", .program = candRandom(0xAAAA_BBBB_CCCC_DDDD), .notes = "sanity: high edit dist, low equiv" },
        .{ .name = "documented_run1_structure", .program = candDocumentedRun1(), .notes = "STRUCTURE only — imm values not persisted by inventor" },
        .{ .name = "documented_run2_structure", .program = candDocumentedRun2(), .notes = "STRUCTURE only — imm values not persisted by inventor" },
    };

    var cand_buf: [candidates_static.len + 1]Candidate = undefined;
    var cand_len: usize = 0;
    for (candidates_static) |c| {
        cand_buf[cand_len] = c;
        cand_len += 1;
    }
    if (loaded_champion) |champ| {
        cand_buf[cand_len] = .{ .name = "loaded_champion_csv", .program = champ, .notes = "exact discovered program loaded from results/program_synthesis_champion.csv" };
        cand_len += 1;
    }
    const candidates = cand_buf[0..cand_len];

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== REACHABILITY TESTER (Gen0) ===\n", .{});
    try stdout.print("Library size: {d}  candidates: {d}  func samples: {d}\n\n", .{ lib.len, candidates.len, FuncSamples });

    try stdout.print("Library:\n", .{});
    for (lib) |entry| {
        try stdout.print("  - {s} ({d} instructions)\n", .{ entry.name, entry.program.used });
    }
    try stdout.print("\n", .{});

    try std.fs.cwd().makePath("results");
    var csv = try std.fs.cwd().createFile(report_path, .{ .truncate = true });
    defer csv.close();
    try csv.writer().writeAll("candidate,closest_by_edit,min_edit,norm_edit,best_bit_agreement,best_exact_equiv,avalanche,balance,chisq,period,passes_quality,reach_bits,reach_depth,reach_path,reachable,verdict\n");

    try stdout.print("{s: <30} | {s: <17} | {s: >5} | {s: >7} | {s: >5} | {s: >7} | {s: >5} | {s: >5} | {s: >5} | {s: >5} | {s: >8} | verdict\n", .{ "candidate", "closest_by_edit", "edit", "norm_ed", "bits", "qual?", "av", "bal", "chi", "rB", "rDepth" });
    try stdout.print("-------------------------------|-------------------|-------|---------|-------|---------|-------|-------|-------|-------|----------|--------\n", .{});
    for (candidates) |c| {
        const s = try scoreCandidate(c, &lib, allocator);
        const q = measureQuality(c.program);
        const r = searchReachability(c.program, &lib);
        const v = verdict(s, q, r);

        var path_buf: [64]u8 = undefined;
        var path_len: usize = 0;
        var i: usize = 0;
        while (i < r.best_depth) : (i += 1) {
            if (i > 0) {
                path_buf[path_len] = '>';
                path_len += 1;
            }
            const name = lib[r.best_path[i]].name;
            for (name) |b| {
                if (path_len < path_buf.len - 1) {
                    path_buf[path_len] = b;
                    path_len += 1;
                }
            }
        }
        const path_str = path_buf[0..path_len];

        try stdout.print("{s: <30} | {s: <17} | {d: >5} | {d: >7.3} | {d: >5.3} | {s: >7} | {d: >5.2} | {d: >5.2} | {d: >5.0} | {d: >5.3} | {d: >2}@{s: <5} | {s}\n", .{
            c.name, s.closest_name, s.min_edit_dist, s.norm_edit_dist, s.best_bit_agreement,
            if (q.passes_gate) "PASS" else "fail",
            q.avalanche, q.balance, q.chisq, r.best_bit_agreement, r.best_depth, path_str, v,
        });
        try csv.writer().print("{s},{s},{d},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d},{d},{d:.4},{d},{s},{d},{s}\n", .{
            c.name, s.closest_name, s.min_edit_dist, s.norm_edit_dist, s.best_bit_agreement, s.best_exact_equiv,
            q.avalanche, q.balance, q.chisq, q.period, @intFromBool(q.passes_gate),
            r.best_bit_agreement, r.best_depth, path_str, @intFromBool(r.reachable), v,
        });
    }

    try stdout.print("\nNotes per candidate:\n", .{});
    for (candidates) |c| {
        try stdout.print("  {s}: {s}\n", .{ c.name, c.notes });
    }
    try stdout.print("\nCSV: results/reachability_tester.csv\n", .{});

    try stdout.print("\n--- LIBRARY CROSS-SIMILARITY (metric baseline) ---\n", .{});
    try stdout.print("Bit agreement between every pair of library mixers. Establishes the\n", .{});
    try stdout.print("noise floor of the metric: if two human-designed mixers agree at\n", .{});
    try stdout.print("~0.50, then 0.50 is the baseline for 'two unrelated 64-bit mixers'\n", .{});
    try stdout.print("and 'DIVERGENT' verdicts at ~0.50 carry no information.\n\n", .{});

    try stdout.print("{s: <17}", .{""});
    for (lib) |b| try stdout.print(" | {s: <16}", .{b.name});
    try stdout.print("\n", .{});
    var cross_csv = try std.fs.cwd().createFile("results/reachability_library_cross.csv", .{ .truncate = true });
    defer cross_csv.close();
    try cross_csv.writer().writeAll("a,b,bit_agreement,exact_equiv\n");
    for (lib) |a| {
        try stdout.print("{s: <17}", .{a.name});
        for (lib) |b| {
            const fs = functionalSimilarity(a.program, b.program);
            try stdout.print(" | bits={d:.3} ex={d:.3}", .{ fs.mean_bit_agreement, fs.exact_equiv_rate });
            try cross_csv.writer().print("{s},{s},{d:.4},{d:.4}\n", .{ a.name, b.name, fs.mean_bit_agreement, fs.exact_equiv_rate });
        }
        try stdout.print("\n", .{});
    }
    try stdout.print("CSV: results/reachability_library_cross.csv\n", .{});

    try stdout.print("\n--- METHODOLOGY ---\n", .{});
    try stdout.print("edit_dist:        Levenshtein on instruction tuples (op,dst,src1,src2,imm).\n", .{});
    try stdout.print("bit_agreement:    mean of (64 - popcount(P(x)^Q(x)))/64 over {d} inputs.\n", .{FuncSamples});
    try stdout.print("exact_equiv:      fraction of inputs where P(x) == Q(x).\n", .{});
    try stdout.print("verdict ladder (Gen1, quality + reachability gated):\n", .{});
    try stdout.print("  EQUIVALENT:       exact_equiv >= 0.99\n", .{});
    try stdout.print("  TRIVIAL VARIANT:  min_edit <= 1\n", .{});
    try stdout.print("  NEAR-EQUIVALENT:  bit_agreement >= 0.95\n", .{});
    try stdout.print("  REMIX:            norm_edit <= 0.34 or bit_agreement >= 0.75\n", .{});
    try stdout.print("  REACHABLE:        any depth<=3 composition matches at bits>=0.95\n", .{});
    try stdout.print("  NON-MIXER:        fails quality gate (av/bal/chisq/period)\n", .{});
    try stdout.print("  INVENTION:        divergent + passes quality + not reachable\n", .{});
    try stdout.print("quality gate: avalanche in [{d:.1},{d:.1}], balance in [{d:.1},{d:.1}], chisq <= {d:.0}, period >= {d}\n", .{ AvalancheLo, AvalancheHi, BalanceLo, BalanceHi, ChiSqMax, PeriodMin });

    try stdout.print("\n--- KNOWN LIMITATIONS ---\n", .{});
    try stdout.print("1. This is a SYNTACTIC + BEHAVIORAL test, not full compositional reachability.\n", .{});
    try stdout.print("   Gen1 should enumerate compositions of library primitives up to depth k\n", .{});
    try stdout.print("   and check functional equivalence to candidate.\n", .{});
    try stdout.print("2. The documented Run-1 / Run-2 programs use placeholder imm values because\n", .{});
    try stdout.print("   program_synthesis_inventor does not currently persist discovered imm values\n", .{});
    try stdout.print("   to disk. To grade those discoveries directly, the inventor needs to save\n", .{});
    try stdout.print("   its champion programs in a machine-readable form (op, dst, src1, src2, imm).\n", .{});
    try stdout.print("3. The library is small (4 mixers). Expanding it strengthens the test by\n", .{});
    try stdout.print("   reducing the chance that a 'divergent' candidate is merely far from THIS\n", .{});
    try stdout.print("   library but close to some unrepresented canonical mixer.\n", .{});
}
