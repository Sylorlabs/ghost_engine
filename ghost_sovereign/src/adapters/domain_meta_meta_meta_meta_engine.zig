const std = @import("std");
const mmm = @import("domain_meta_meta_meta_engine.zig");

// --- TIER-3 DOMAIN ---
//
// A MetaMetaMetaMetaProgram (MMMMP / Engine 4) operates on
// MetaMetaMetaPrograms (MMMP / Engine 3). It is intentionally parallel
// to domain_meta_meta_meta_engine.zig: EVAL_MMM_CUR runs an MMMP for a
// bounded number of outer steps and preserves the downstream u64-mixer
// quality returned by the lower tier.

pub const META_META_META_META_DOMAIN_NAME: []const u8 = "meta-meta-meta-meta-engine/u64-mixer";

const NumScratchRegs = 4;
pub const MaxMetaMetaMetaMetaLen = 16;
pub const MinMetaMetaMetaMetaLen = 4;

pub var INNER_TIER2_OUTER_STEPS: u32 = 4;

pub const MaxChainExtrasMMM: usize = 16;
pub var chain_extras_mmm: std.BoundedArray(mmm.MetaMetaMetaProgram, MaxChainExtrasMMM) = .{ .buffer = undefined, .len = 0 };

pub fn chainExtrasMMMReset() void {
    chain_extras_mmm.len = 0;
}
pub fn chainExtrasMMMAppend(p: mmm.MetaMetaMetaProgram) !void {
    try chain_extras_mmm.append(p);
}
pub fn chainExtrasMMMLen() usize {
    return chain_extras_mmm.len;
}

pub var constrained_init: bool = false;
pub var wide_call_mmm: bool = false;

pub const MetaMetaMetaMetaOp = enum(u4) {
    INIT_MMM_CUR = 0,
    MUTATE_MMM_CUR = 1,
    MUTATE_MMM_BEST_TO_CUR = 2,
    CROSS_MMM_BEST_CUR = 3,
    EVAL_MMM_CUR = 4,
    ACCEPT_MMM_IF_BETTER = 5,
    ACCEPT_MMM_SA = 6,
    RESET_MMM_CUR_TO_BEST = 7,
    RAND_REG = 8,
    REG_XOR = 9,
    REG_SHR = 10,
    TEMP_DECAY = 11,
    CALL_MMM = 12,
    NOP = 13,
};

pub const MetaMetaMetaMetaInstr = struct {
    op: MetaMetaMetaMetaOp,
    dst: u2,
    src1: u2,
    src2: u2,
};

pub const MetaMetaMetaMetaProgram = struct {
    instructions: [MaxMetaMetaMetaMetaLen]MetaMetaMetaMetaInstr,
    used: u8,
};

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

const NegInf: f64 = -std.math.inf(f64);

pub fn repairMetaMetaMetaMetaOrdering(p: MetaMetaMetaMetaProgram) MetaMetaMetaMetaProgram {
    var q = p;
    var first_eval: ?usize = null;
    var first_accept: ?usize = null;
    var i: usize = 0;
    while (i < q.used) : (i += 1) {
        switch (q.instructions[i].op) {
            .EVAL_MMM_CUR => {
                if (first_eval == null) first_eval = i;
            },
            .ACCEPT_MMM_IF_BETTER, .ACCEPT_MMM_SA => {
                if (first_accept == null) first_accept = i;
            },
            else => {},
        }
    }

    if (first_eval == null) {
        const idx: usize = if (q.used > 0) q.used - 1 else 0;
        q.instructions[idx] = .{ .op = .EVAL_MMM_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
        if (q.used == 0) q.used = 1;
        first_eval = idx;
    }
    if (first_accept == null) {
        const idx = @min(q.used, first_eval.? + 1);
        if (q.used < MaxMetaMetaMetaMetaLen) {
            var j = q.used;
            while (j > idx) : (j -= 1) q.instructions[j] = q.instructions[j - 1];
            q.instructions[idx] = .{ .op = .ACCEPT_MMM_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 };
            q.used += 1;
            first_accept = idx;
        } else {
            const replace_idx = if (idx < q.used) idx else q.used - 1;
            q.instructions[replace_idx] = .{ .op = .ACCEPT_MMM_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 };
            first_accept = replace_idx;
        }
    }
    if (first_accept) |a| {
        if (first_eval) |e| {
            if (a < e) {
                const tmp = q.instructions[a];
                q.instructions[a] = q.instructions[e];
                q.instructions[e] = tmp;
            }
        }
    }
    return q;
}

const InnerState = struct {
    rng: u64,
    mmm_cur: mmm.MetaMetaMetaProgram,
    mmm_best: mmm.MetaMetaMetaProgram,
    q_cur: f64,
    q_best: f64,
    regs: [NumScratchRegs]u64,
    cur_evaluated: bool,
};

fn crossoverMMM(a: mmm.MetaMetaMetaProgram, b: mmm.MetaMetaMetaProgram, rng: *u64) mmm.MetaMetaMetaProgram {
    var q = a;
    if (b.used == 0) return q;
    rng.* = smix(rng.*);
    const cut: usize = rng.* % q.used;
    var i: usize = cut;
    while (i < q.used and i < b.used) : (i += 1) q.instructions[i] = b.instructions[i];
    return q;
}

pub fn run(p: MetaMetaMetaMetaProgram, outer_steps: u32, root_seed: u64) f64 {
    var r0: u64 = root_seed ^ 0xD1CE_CAFE_4444_0001;
    const init_mmm = mmm.randomMetaMetaMetaProgram(&r0);
    var st = InnerState{
        .rng = r0,
        .mmm_cur = init_mmm,
        .mmm_best = init_mmm,
        .q_cur = NegInf,
        .q_best = NegInf,
        .regs = .{ 0x100, 1, 0, 0 },
        .cur_evaluated = false,
    };
    var s: u32 = 0;
    while (s < outer_steps) : (s += 1) {
        var i: usize = 0;
        while (i < p.used) : (i += 1) execOp(&st, p.instructions[i]);
    }
    return st.q_best;
}

pub fn runReturningChampion(p: MetaMetaMetaMetaProgram, outer_steps: u32, root_seed: u64) struct { q_best: f64, mmm_best: mmm.MetaMetaMetaProgram } {
    var r0: u64 = root_seed ^ 0xD1CE_CAFE_4444_0001;
    const init_mmm = mmm.randomMetaMetaMetaProgram(&r0);
    var st = InnerState{
        .rng = r0,
        .mmm_cur = init_mmm,
        .mmm_best = init_mmm,
        .q_cur = NegInf,
        .q_best = NegInf,
        .regs = .{ 0x100, 1, 0, 0 },
        .cur_evaluated = false,
    };
    var s: u32 = 0;
    while (s < outer_steps) : (s += 1) {
        var i: usize = 0;
        while (i < p.used) : (i += 1) execOp(&st, p.instructions[i]);
    }
    return .{ .q_best = st.q_best, .mmm_best = st.mmm_best };
}

fn execOp(st: *InnerState, ins: MetaMetaMetaMetaInstr) void {
    switch (ins.op) {
        .INIT_MMM_CUR => {
            st.mmm_cur = mmm.randomMetaMetaMetaProgram(&st.rng);
            st.q_cur = NegInf;
            st.cur_evaluated = false;
        },
        .MUTATE_MMM_CUR => {
            st.mmm_cur = mmm.mutateMetaMetaMeta(st.mmm_cur, &st.rng);
            st.cur_evaluated = false;
        },
        .MUTATE_MMM_BEST_TO_CUR => {
            st.mmm_cur = mmm.mutateMetaMetaMeta(st.mmm_best, &st.rng);
            st.cur_evaluated = false;
        },
        .CROSS_MMM_BEST_CUR => {
            st.mmm_cur = crossoverMMM(st.mmm_best, st.mmm_cur, &st.rng);
            st.cur_evaluated = false;
        },
        .EVAL_MMM_CUR => {
            st.rng = smix(st.rng);
            const q = mmm.run(st.mmm_cur, INNER_TIER2_OUTER_STEPS, st.rng);
            st.q_cur = if (std.math.isFinite(q)) q else -1.0e6;
            st.cur_evaluated = true;
            if (st.q_best == NegInf) {
                st.q_best = st.q_cur;
                st.mmm_best = st.mmm_cur;
            }
        },
        .ACCEPT_MMM_IF_BETTER => {
            if (st.cur_evaluated and st.q_cur > st.q_best) {
                st.q_best = st.q_cur;
                st.mmm_best = st.mmm_cur;
            }
        },
        .ACCEPT_MMM_SA => {
            if (!st.cur_evaluated) return;
            if (st.q_cur > st.q_best) {
                st.q_best = st.q_cur;
                st.mmm_best = st.mmm_cur;
                return;
            }
            const t: f64 = @as(f64, @floatFromInt(st.regs[0] & 0xFFFF)) / 4096.0 + 1e-6;
            const delta = st.q_cur - st.q_best;
            const accept_prob = @exp(delta / t);
            st.rng = smix(st.rng);
            const r: f64 = @as(f64, @floatFromInt(st.rng >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
            if (r < accept_prob) {}
        },
        .RESET_MMM_CUR_TO_BEST => {
            st.mmm_cur = st.mmm_best;
            st.q_cur = st.q_best;
            st.cur_evaluated = (st.q_best != NegInf);
        },
        .RAND_REG => {
            st.rng = smix(st.rng);
            st.regs[ins.dst] = st.rng;
        },
        .REG_XOR => st.regs[ins.dst] = st.regs[ins.src1] ^ st.regs[ins.src2],
        .REG_SHR => {
            const sh: u6 = @intCast(st.regs[ins.src2] & 63);
            st.regs[ins.dst] = st.regs[ins.src1] >> sh;
        },
        .TEMP_DECAY => {
            const sh_amt: u6 = @intCast(@max(@as(u64, 1), st.regs[ins.src1] & 31));
            st.regs[0] = st.regs[0] -% (st.regs[0] >> sh_amt);
        },
        .CALL_MMM => {
            if (chain_extras_mmm.len > 0) {
                const idx_raw: usize = if (wide_call_mmm)
                    (@as(usize, ins.dst) << 2) | @as(usize, ins.src1)
                else
                    @as(usize, ins.dst);
                const idx = idx_raw % chain_extras_mmm.len;
                st.mmm_cur = mmm.mutateMetaMetaMeta(chain_extras_mmm.buffer[idx], &st.rng);
                st.cur_evaluated = false;
            }
        },
        .NOP => {},
    }
}

fn randomInstr(rng: *u64) MetaMetaMetaMetaInstr {
    const NumOps: u64 = @typeInfo(MetaMetaMetaMetaOp).@"enum".fields.len;
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

pub fn randomMetaMetaMetaMetaProgram(rng: *u64) MetaMetaMetaMetaProgram {
    rng.* = smix(rng.*);
    const len: u8 = @intCast(MinMetaMetaMetaMetaLen + (rng.* % (MaxMetaMetaMetaMetaLen - MinMetaMetaMetaMetaLen)));
    var p = MetaMetaMetaMetaProgram{ .instructions = undefined, .used = len };
    var i: usize = 0;
    while (i < len) : (i += 1) p.instructions[i] = randomInstr(rng);
    if (constrained_init and len >= 3) {
        p.instructions[0] = .{ .op = .INIT_MMM_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
        p.instructions[1] = .{ .op = .EVAL_MMM_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
        p.instructions[2] = .{ .op = .ACCEPT_MMM_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 };
    }
    return p;
}

pub fn mutateMetaMetaMetaMeta(p: MetaMetaMetaMetaProgram, rng: *u64) MetaMetaMetaMetaProgram {
    var q = p;
    rng.* = smix(rng.*);
    const mode = rng.* % 10;
    if (mode < 6) {
        rng.* = smix(rng.*);
        q.instructions[rng.* % q.used] = randomInstr(rng);
    } else if (mode < 8 and q.used < MaxMetaMetaMetaMetaLen) {
        rng.* = smix(rng.*);
        const idx: usize = rng.* % (q.used + 1);
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.instructions[i] = q.instructions[i - 1];
        q.instructions[idx] = randomInstr(rng);
        q.used += 1;
    } else if (q.used > MinMetaMetaMetaMetaLen) {
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
        const t = q.instructions[a];
        q.instructions[a] = q.instructions[b];
        q.instructions[b] = t;
    }
    return if (constrained_init) repairMetaMetaMetaMetaOrdering(q) else q;
}

pub fn opName(op: MetaMetaMetaMetaOp) []const u8 {
    return switch (op) {
        .INIT_MMM_CUR => "INIT_MMM_CUR",
        .MUTATE_MMM_CUR => "MUTATE_MMM_CUR",
        .MUTATE_MMM_BEST_TO_CUR => "MUTATE_MMM_BEST_TO_CUR",
        .CROSS_MMM_BEST_CUR => "CROSS_MMM_BEST_CUR",
        .EVAL_MMM_CUR => "EVAL_MMM_CUR",
        .ACCEPT_MMM_IF_BETTER => "ACCEPT_MMM_IF_BETTER",
        .ACCEPT_MMM_SA => "ACCEPT_MMM_SA",
        .RESET_MMM_CUR_TO_BEST => "RESET_MMM_CUR_TO_BEST",
        .RAND_REG => "RAND_REG",
        .REG_XOR => "REG_XOR",
        .REG_SHR => "REG_SHR",
        .TEMP_DECAY => "TEMP_DECAY",
        .CALL_MMM => "CALL_MMM",
        .NOP => "NOP",
    };
}

pub fn mmmmToCsv(p: MetaMetaMetaMetaProgram, writer: anytype) !void {
    try writer.writeAll("idx,op_id,op_name,dst,src1,src2\n");
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const ins = p.instructions[i];
        try writer.print("{d},{d},{s},{d},{d},{d}\n", .{
            i,
            @intFromEnum(ins.op),
            opName(ins.op),
            ins.dst,
            ins.src1,
            ins.src2,
        });
    }
}
