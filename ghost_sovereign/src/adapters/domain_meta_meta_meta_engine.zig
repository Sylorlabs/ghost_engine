const std = @import("std");
const tier0 = @import("domain_meta_engine.zig");
const mm = @import("domain_meta_meta_engine.zig");

// --- TIER-2 DOMAIN ---
//
// A MetaMetaMetaProgram (MMMP) is a sequence of opcodes whose primitives
// operate on MetaMetaPrograms (mm / tier-1). EVAL_MM_CUR runs
// mm.run(mm_cur, INNER_TIER1_OUTER_STEPS, seed), and the q returned IS a
// mixer-fitness (mm.run returns its q_best which is best tier0.run
// q_best — fitness is preserved through all layers).
//
// Equal-budget contract: mm.INNER_TIER0_STEPS is set by the runner
// BEFORE Tier-2 search starts. Every EVAL_MM_CUR uses the same mm.run
// outer count (INNER_TIER1_OUTER_STEPS here) and the same tier0 inner
// steps (mm.INNER_TIER0_STEPS).

pub const META_META_META_DOMAIN_NAME: []const u8 = "meta-meta-meta-engine/u64-mixer";

const NumScratchRegs = 4;
pub const MaxMetaMetaMetaLen = 16;
pub const MinMetaMetaMetaLen = 4;

// How many outer mm.run steps each EVAL_MM_CUR gives. Keep tight — each
// EVAL is full Tier-1 mini-run.
pub var INNER_TIER1_OUTER_STEPS: u32 = 6;

pub const MaxChainExtrasMM: usize = 16;
pub var chain_extras_mm: std.BoundedArray(mm.MetaMetaProgram, MaxChainExtrasMM) = .{ .buffer = undefined, .len = 0 };

pub fn chainExtrasMMReset() void { chain_extras_mm.len = 0; }
pub fn chainExtrasMMAppend(p: mm.MetaMetaProgram) !void { try chain_extras_mm.append(p); }
pub fn chainExtrasMMLen() usize { return chain_extras_mm.len; }

// When true, the chain runner's init pool generates MMMPs that begin
// with INIT_MM_CUR → EVAL_MM_CUR → ACCEPT_MM_IF_BETTER (the analog of
// "init, evaluate, accept" — a minimal valid search loop). The rest of
// the MMMP is random. Guarantees the init population isn't sentinel-
// dominated. (Approach #5 of the 2026-05-21 invention-engine round.)
pub var constrained_init: bool = false;

pub const MetaMetaMetaOp = enum(u4) {
    INIT_MM_CUR = 0,
    MUTATE_MM_CUR = 1,
    MUTATE_MM_BEST_TO_CUR = 2,
    CROSS_MM_BEST_CUR = 3,
    EVAL_MM_CUR = 4,
    ACCEPT_MM_IF_BETTER = 5,
    ACCEPT_MM_SA = 6,
    RESET_MM_CUR_TO_BEST = 7,
    RAND_REG = 8,
    REG_XOR = 9,
    REG_SHR = 10,
    TEMP_DECAY = 11,
    CALL_MM = 12,
    NOP = 13,
};

pub const MetaMetaMetaInstr = struct {
    op: MetaMetaMetaOp,
    dst: u2,
    src1: u2,
    src2: u2,
};

pub const MetaMetaMetaProgram = struct {
    instructions: [MaxMetaMetaMetaLen]MetaMetaMetaInstr,
    used: u8,
};

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

const NegInf: f64 = -std.math.inf(f64);

const InnerState = struct {
    rng: u64,
    mm_cur: mm.MetaMetaProgram,
    mm_best: mm.MetaMetaProgram,
    q_cur: f64,
    q_best: f64,
    regs: [NumScratchRegs]u64,
    cur_evaluated: bool,
};

fn crossoverMM(a: mm.MetaMetaProgram, b: mm.MetaMetaProgram, rng: *u64) mm.MetaMetaProgram {
    var q = a;
    if (b.used == 0) return q;
    rng.* = smix(rng.*);
    const cut: usize = rng.* % q.used;
    var i: usize = cut;
    while (i < q.used and i < b.used) : (i += 1) {
        q.instructions[i] = b.instructions[i];
    }
    return q;
}

pub fn run(mmm: MetaMetaMetaProgram, outer_steps: u32, root_seed: u64) f64 {
    var r0: u64 = root_seed ^ 0xA5A5_5A5A_BABE_F00D;
    const init_mm = mm.randomMetaMetaProgram(&r0);
    var st = InnerState{
        .rng = r0,
        .mm_cur = init_mm,
        .mm_best = init_mm,
        .q_cur = NegInf,
        .q_best = NegInf,
        .regs = .{ 0x100, 1, 0, 0 },
        .cur_evaluated = false,
    };
    var s: u32 = 0;
    while (s < outer_steps) : (s += 1) {
        var i: usize = 0;
        while (i < mmm.used) : (i += 1) execOp(&st, mmm.instructions[i]);
    }
    return st.q_best;
}

pub fn runReturningChampion(mmm: MetaMetaMetaProgram, outer_steps: u32, root_seed: u64) struct { q_best: f64, mm_best: mm.MetaMetaProgram } {
    var r0: u64 = root_seed ^ 0xA5A5_5A5A_BABE_F00D;
    const init_mm = mm.randomMetaMetaProgram(&r0);
    var st = InnerState{
        .rng = r0,
        .mm_cur = init_mm,
        .mm_best = init_mm,
        .q_cur = NegInf,
        .q_best = NegInf,
        .regs = .{ 0x100, 1, 0, 0 },
        .cur_evaluated = false,
    };
    var s: u32 = 0;
    while (s < outer_steps) : (s += 1) {
        var i: usize = 0;
        while (i < mmm.used) : (i += 1) execOp(&st, mmm.instructions[i]);
    }
    return .{ .q_best = st.q_best, .mm_best = st.mm_best };
}

fn execOp(st: *InnerState, ins: MetaMetaMetaInstr) void {
    switch (ins.op) {
        .INIT_MM_CUR => {
            st.mm_cur = mm.randomMetaMetaProgram(&st.rng);
            st.q_cur = NegInf;
            st.cur_evaluated = false;
        },
        .MUTATE_MM_CUR => {
            st.mm_cur = mm.mutateMetaMeta(st.mm_cur, &st.rng);
            st.cur_evaluated = false;
        },
        .MUTATE_MM_BEST_TO_CUR => {
            st.mm_cur = mm.mutateMetaMeta(st.mm_best, &st.rng);
            st.cur_evaluated = false;
        },
        .CROSS_MM_BEST_CUR => {
            st.mm_cur = crossoverMM(st.mm_best, st.mm_cur, &st.rng);
            st.cur_evaluated = false;
        },
        .EVAL_MM_CUR => {
            st.rng = smix(st.rng);
            const seed = st.rng;
            const q = mm.run(st.mm_cur, INNER_TIER1_OUTER_STEPS, seed);
            st.q_cur = if (std.math.isFinite(q)) q else -1.0e6;
            st.cur_evaluated = true;
            if (st.q_best == NegInf) {
                st.q_best = st.q_cur;
                st.mm_best = st.mm_cur;
            }
        },
        .ACCEPT_MM_IF_BETTER => {
            if (st.cur_evaluated and st.q_cur > st.q_best) {
                st.q_best = st.q_cur;
                st.mm_best = st.mm_cur;
            }
        },
        .ACCEPT_MM_SA => {
            if (!st.cur_evaluated) return;
            if (st.q_cur > st.q_best) {
                st.q_best = st.q_cur;
                st.mm_best = st.mm_cur;
                return;
            }
            const temp_raw = st.regs[0];
            const t: f64 = @as(f64, @floatFromInt(temp_raw & 0xFFFF)) / 4096.0 + 1e-6;
            const delta = st.q_cur - st.q_best;
            const accept_prob = @exp(delta / t);
            st.rng = smix(st.rng);
            const r: f64 = @as(f64, @floatFromInt(st.rng >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
            if (r < accept_prob) {}
        },
        .RESET_MM_CUR_TO_BEST => {
            st.mm_cur = st.mm_best;
            st.q_cur = st.q_best;
            st.cur_evaluated = (st.q_best != NegInf);
        },
        .RAND_REG => {
            st.rng = smix(st.rng);
            st.regs[ins.dst] = st.rng;
        },
        .REG_XOR => {
            st.regs[ins.dst] = st.regs[ins.src1] ^ st.regs[ins.src2];
        },
        .REG_SHR => {
            const sh: u6 = @intCast(st.regs[ins.src2] & 63);
            st.regs[ins.dst] = st.regs[ins.src1] >> sh;
        },
        .TEMP_DECAY => {
            const sh_amt: u6 = @intCast(@max(@as(u64, 1), st.regs[ins.src1] & 31));
            const dec = st.regs[0] >> sh_amt;
            st.regs[0] = st.regs[0] -% dec;
        },
        .CALL_MM => {
            if (chain_extras_mm.len > 0) {
                const idx: usize = @as(usize, ins.dst) % chain_extras_mm.len;
                st.mm_cur = mm.mutateMetaMeta(chain_extras_mm.buffer[idx], &st.rng);
                st.cur_evaluated = false;
            }
        },
        .NOP => {},
    }
}

fn randomMetaMetaMetaInstr(rng: *u64) MetaMetaMetaInstr {
    const NumOps: u64 = @typeInfo(MetaMetaMetaOp).@"enum".fields.len;
    rng.* = smix(rng.*);
    const op_idx: u4 = @intCast(rng.* % NumOps);
    rng.* = smix(rng.*);
    const dst: u2 = @intCast(rng.* % NumScratchRegs);
    rng.* = smix(rng.*);
    const src1: u2 = @intCast(rng.* % NumScratchRegs);
    rng.* = smix(rng.*);
    const src2: u2 = @intCast(rng.* % NumScratchRegs);
    return .{ .op = @enumFromInt(op_idx), .dst = dst, .src1 = src1, .src2 = src2 };
}

pub fn randomMetaMetaMetaProgram(rng: *u64) MetaMetaMetaProgram {
    rng.* = smix(rng.*);
    const len: u8 = @intCast(MinMetaMetaMetaLen + (rng.* % (MaxMetaMetaMetaLen - MinMetaMetaMetaLen)));
    var p = MetaMetaMetaProgram{ .instructions = undefined, .used = len };
    var i: usize = 0;
    while (i < len) : (i += 1) p.instructions[i] = randomMetaMetaMetaInstr(rng);
    if (constrained_init and len >= 3) {
        // Hard-seed the first 3 ops as INIT, EVAL, ACCEPT to guarantee
        // a valid search loop. Remaining ops stay random.
        p.instructions[0] = .{ .op = .INIT_MM_CUR,        .dst = 0, .src1 = 0, .src2 = 0 };
        p.instructions[1] = .{ .op = .EVAL_MM_CUR,        .dst = 0, .src1 = 0, .src2 = 0 };
        p.instructions[2] = .{ .op = .ACCEPT_MM_IF_BETTER,.dst = 0, .src1 = 0, .src2 = 0 };
    }
    return p;
}

pub fn mutateMetaMetaMeta(p: MetaMetaMetaProgram, rng: *u64) MetaMetaMetaProgram {
    var q = p;
    rng.* = smix(rng.*);
    const mode = rng.* % 10;
    if (mode < 6) {
        rng.* = smix(rng.*);
        const idx: usize = rng.* % q.used;
        q.instructions[idx] = randomMetaMetaMetaInstr(rng);
    } else if (mode < 8 and q.used < MaxMetaMetaMetaLen) {
        rng.* = smix(rng.*);
        const idx: usize = rng.* % (q.used + 1);
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.instructions[i] = q.instructions[i - 1];
        q.instructions[idx] = randomMetaMetaMetaInstr(rng);
        q.used += 1;
    } else if (q.used > MinMetaMetaMetaLen) {
        rng.* = smix(rng.*);
        const idx: usize = rng.* % q.used;
        var i: usize = idx;
        while (i < q.used - 1) : (i += 1) q.instructions[i] = q.instructions[i + 1];
        q.used -= 1;
    } else {
        rng.* = smix(rng.*);
        const a: usize = rng.* % q.used;
        rng.* = smix(rng.*);
        const b: usize = rng.* % q.used;
        const t = q.instructions[a]; q.instructions[a] = q.instructions[b]; q.instructions[b] = t;
    }
    return q;
}

pub fn opName(op: MetaMetaMetaOp) []const u8 {
    return switch (op) {
        .INIT_MM_CUR => "INIT_MM_CUR",
        .MUTATE_MM_CUR => "MUTATE_MM_CUR",
        .MUTATE_MM_BEST_TO_CUR => "MUTATE_MM_BEST_TO_CUR",
        .CROSS_MM_BEST_CUR => "CROSS_MM_BEST_CUR",
        .EVAL_MM_CUR => "EVAL_MM_CUR",
        .ACCEPT_MM_IF_BETTER => "ACCEPT_MM_IF_BETTER",
        .ACCEPT_MM_SA => "ACCEPT_MM_SA",
        .RESET_MM_CUR_TO_BEST => "RESET_MM_CUR_TO_BEST",
        .RAND_REG => "RAND_REG",
        .REG_XOR => "REG_XOR",
        .REG_SHR => "REG_SHR",
        .TEMP_DECAY => "TEMP_DECAY",
        .CALL_MM => "CALL_MM",
        .NOP => "NOP",
    };
}

pub fn mmmToCsv(p: MetaMetaMetaProgram, writer: anytype) !void {
    try writer.writeAll("idx,op_id,op_name,dst,src1,src2\n");
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const ins = p.instructions[i];
        try writer.print("{d},{d},{s},{d},{d},{d}\n", .{
            i, @intFromEnum(ins.op), opName(ins.op), ins.dst, ins.src1, ins.src2,
        });
    }
}
