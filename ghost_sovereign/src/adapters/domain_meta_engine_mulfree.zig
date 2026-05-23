const std = @import("std");
const target = @import("domain_u64_mixer_mulfree_compat.zig");

// --- META-DOMAIN: ENGINE-AS-PROGRAM ---
//
// A MetaProgram is a sequence of engine-primitive opcodes
// (INIT/MUTATE/EVAL/ACCEPT/...). Executed for K steps, it performs a
// search over `target.Program` (u64-mixer programs) and returns the
// best quality found. The MetaProgram IS the search engine.
//
// Outer search (in meta_engine_runner.zig) discovers MetaPrograms whose
// q_best after K steps is high. Chain extension: meta-engine_n+1's
// outer search includes CALL_META(prior) primitives composing
// previously-discovered engines.

pub const META_DOMAIN_NAME: []const u8 = "meta-engine/u64-mixer-mul-free";

const NumScratchRegs = 4;
pub const MaxMetaLen = 16;
pub const MinMetaLen = 4;

pub const MetaOp = enum(u4) {
    INIT_CUR = 0, // cand_cur := randomProgram(rng); q_cur := -inf
    MUTATE_CUR = 1, // cand_cur := mutate(cand_cur, rng)
    MUTATE_BEST_TO_CUR = 2, // cand_cur := mutate(cand_best, rng)
    CROSS_BEST_CUR = 3, // cand_cur := crossover(cand_best, cand_cur, rng)
    EVAL_CUR = 4, // q_cur := quality(cand_cur)
    ACCEPT_IF_BETTER = 5, // if q_cur > q_best: best := cur
    ACCEPT_SA = 6, // metropolis(regs[0] as temperature)
    RESET_CUR_TO_BEST = 7, // cand_cur := cand_best; q_cur := q_best
    RAND_REG = 8, // regs[dst] := smix(rng)
    REG_XOR = 9, // regs[dst] := regs[src1] ^ regs[src2]
    REG_SHR = 10, // regs[dst] := regs[src1] >> (regs[src2] & 63)
    TEMP_DECAY = 11, // regs[0] := regs[0] - (regs[0] >> regs[src1])
    NOP = 12,
};

pub const MetaInstr = struct {
    op: MetaOp,
    dst: u2,
    src1: u2,
    src2: u2,

    pub fn eq(a: MetaInstr, b: MetaInstr) bool {
        return a.op == b.op and a.dst == b.dst and a.src1 == b.src1 and a.src2 == b.src2;
    }
};

pub const MetaProgram = struct {
    instructions: [MaxMetaLen]MetaInstr,
    used: u8,
};

// Opt-in structural bootstrap: generated MetaPrograms start with the
// minimal "make candidate, evaluate, accept" loop, and mutations repair
// missing/misordered EVAL/ACCEPT instructions. This is off by default so
// older artifact replays are unchanged.
pub var constrained_init: bool = false;

pub var repair_meta_ordering: bool = false;

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

// --- INNER STATE ---
// Held by run(); each MetaProgram step mutates it in-place.

const InnerState = struct {
    rng: u64,
    cand_cur: target.Program,
    cand_best: target.Program,
    q_cur: f64,
    q_best: f64,
    regs: [NumScratchRegs]u64,
    // The composite-score floor: when q_cur is "unknown" we keep a
    // sentinel. EVAL_CUR always overwrites it. Accept ops compare on
    // q_cur, so an un-evaluated candidate cannot displace best.
    cur_evaluated: bool,
};

const NegInf: f64 = -std.math.inf(f64);

pub fn repairMetaOrdering(meta: MetaProgram) MetaProgram {
    var q = meta;
    var first_eval: ?usize = null;
    var first_accept: ?usize = null;
    var i: usize = 0;
    while (i < q.used) : (i += 1) {
        switch (q.instructions[i].op) {
            .EVAL_CUR => {
                if (first_eval == null) first_eval = i;
            },
            .ACCEPT_IF_BETTER, .ACCEPT_SA => {
                if (first_accept == null) first_accept = i;
            },
            else => {},
        }
    }

    if (first_eval == null) {
        const idx: usize = if (q.used > 0) q.used - 1 else 0;
        q.instructions[idx] = .{ .op = .EVAL_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
        if (q.used == 0) q.used = 1;
        first_eval = idx;
    }
    if (first_accept == null) {
        const idx = @min(q.used, first_eval.? + 1);
        if (q.used < MaxMetaLen) {
            var j = q.used;
            while (j > idx) : (j -= 1) q.instructions[j] = q.instructions[j - 1];
            q.instructions[idx] = .{ .op = .ACCEPT_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 };
            q.used += 1;
            first_accept = idx;
        } else {
            const replace_idx = if (idx < q.used) idx else q.used - 1;
            q.instructions[replace_idx] = .{ .op = .ACCEPT_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 };
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

// Run the meta-program for `steps` iterations. Return q_best.
pub fn run(meta: MetaProgram, steps: u32, root_seed: u64) f64 {
    const effective_meta = if (repair_meta_ordering) repairMetaOrdering(meta) else meta;
    var r0: u64 = root_seed ^ 0xA1B2C3D4E5F60718;
    const init_prog = target.randomProgram(&r0);
    var st = InnerState{
        .rng = r0,
        .cand_cur = init_prog,
        .cand_best = init_prog,
        .q_cur = NegInf,
        .q_best = NegInf,
        .regs = .{ 0x100, 1, 0, 0 },
        .cur_evaluated = false,
    };

    var s: u32 = 0;
    while (s < steps) : (s += 1) {
        var i: usize = 0;
        while (i < effective_meta.used) : (i += 1) {
            execOp(&st, effective_meta.instructions[i]);
        }
    }
    return st.q_best;
}

pub fn runReturningChampion(meta: MetaProgram, steps: u32, root_seed: u64) struct { q_best: f64, program_best: target.Program } {
    const effective_meta = if (repair_meta_ordering) repairMetaOrdering(meta) else meta;
    var r0: u64 = root_seed ^ 0xA1B2C3D4E5F60718;
    const init_prog = target.randomProgram(&r0);
    var st = InnerState{
        .rng = r0,
        .cand_cur = init_prog,
        .cand_best = init_prog,
        .q_cur = NegInf,
        .q_best = NegInf,
        .regs = .{ 0x100, 1, 0, 0 },
        .cur_evaluated = false,
    };

    var s: u32 = 0;
    while (s < steps) : (s += 1) {
        var i: usize = 0;
        while (i < effective_meta.used) : (i += 1) {
            execOp(&st, effective_meta.instructions[i]);
        }
    }
    return .{ .q_best = st.q_best, .program_best = st.cand_best };
}

fn execOp(st: *InnerState, ins: MetaInstr) void {
    switch (ins.op) {
        .INIT_CUR => {
            st.cand_cur = target.randomProgram(&st.rng);
            st.q_cur = NegInf;
            st.cur_evaluated = false;
        },
        .MUTATE_CUR => {
            st.cand_cur = target.mutate(st.cand_cur, &st.rng);
            st.cur_evaluated = false;
        },
        .MUTATE_BEST_TO_CUR => {
            st.cand_cur = target.mutate(st.cand_best, &st.rng);
            st.cur_evaluated = false;
        },
        .CROSS_BEST_CUR => {
            st.cand_cur = target.crossover(st.cand_best, st.cand_cur, &st.rng);
            st.cur_evaluated = false;
        },
        .EVAL_CUR => {
            const q = target.evaluateQuality(st.cand_cur);
            st.q_cur = q.composite;
            st.cur_evaluated = true;
            // First eval also initialises best
            if (st.q_best == NegInf) {
                st.q_best = st.q_cur;
                st.cand_best = st.cand_cur;
                target.tryGraduateMacro(st.cand_cur);
            }
        },
        .ACCEPT_IF_BETTER => {
            if (st.cur_evaluated and st.q_cur > st.q_best) {
                st.q_best = st.q_cur;
                st.cand_best = st.cand_cur;
                target.tryGraduateMacro(st.cand_cur);
            }
        },
        .ACCEPT_SA => {
            if (!st.cur_evaluated) return;
            if (st.q_cur > st.q_best) {
                st.q_best = st.q_cur;
                st.cand_best = st.cand_cur;
                target.tryGraduateMacro(st.cand_cur);
                return;
            }
            const temp_raw = st.regs[0];
            // Map temperature register to a positive f64 in (0, ~16].
            const t: f64 = @as(f64, @floatFromInt(temp_raw & 0xFFFF)) / 4096.0 + 1e-6;
            const delta = st.q_cur - st.q_best;
            const accept_prob = @exp(delta / t);
            st.rng = smix(st.rng);
            const r: f64 = @as(f64, @floatFromInt(st.rng >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
            if (r < accept_prob) {
                // Accept worse as new "current best" cursor only — but we
                // do NOT downgrade q_best. Keep st.cand_best truly best.
                // (We accept by updating q_cur baseline via best=cur for
                // hill-walk; only honest improvements update q_best.)
                // For first cut: do nothing on probabilistic accept of
                // worse — we still let MUTATE_CUR explore from cur.
            }
        },
        .RESET_CUR_TO_BEST => {
            st.cand_cur = st.cand_best;
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
        .NOP => {},
    }
}

// --- META-PROGRAM CONSTRUCTION ---

fn randomMetaInstr(rng: *u64) MetaInstr {
    const NumOps: u64 = @typeInfo(MetaOp).@"enum".fields.len;
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

pub fn randomMetaProgram(rng: *u64) MetaProgram {
    rng.* = smix(rng.*);
    const len: u8 = @intCast(MinMetaLen + (rng.* % (MaxMetaLen - MinMetaLen)));
    var p = MetaProgram{ .instructions = undefined, .used = len };
    var i: usize = 0;
    while (i < len) : (i += 1) p.instructions[i] = randomMetaInstr(rng);
    if (constrained_init and len >= 3) {
        p.instructions[0] = .{ .op = .INIT_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
        p.instructions[1] = .{ .op = .EVAL_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
        p.instructions[2] = .{ .op = .ACCEPT_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 };
    }
    return p;
}

pub fn mutateMeta(p: MetaProgram, rng: *u64) MetaProgram {
    var q = p;
    rng.* = smix(rng.*);
    const mode = rng.* % 10;
    if (mode < 6) {
        // Replace an instruction
        rng.* = smix(rng.*);
        const idx: usize = rng.* % q.used;
        q.instructions[idx] = randomMetaInstr(rng);
    } else if (mode < 8 and q.used < MaxMetaLen) {
        // Insert
        rng.* = smix(rng.*);
        const idx: usize = rng.* % (q.used + 1);
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.instructions[i] = q.instructions[i - 1];
        q.instructions[idx] = randomMetaInstr(rng);
        q.used += 1;
    } else if (q.used > MinMetaLen) {
        // Delete
        rng.* = smix(rng.*);
        const idx: usize = rng.* % q.used;
        var i: usize = idx;
        while (i < q.used - 1) : (i += 1) q.instructions[i] = q.instructions[i + 1];
        q.used -= 1;
    } else {
        // Swap two
        rng.* = smix(rng.*);
        const i: usize = rng.* % q.used;
        rng.* = smix(rng.*);
        const j: usize = rng.* % q.used;
        const tmp = q.instructions[i];
        q.instructions[i] = q.instructions[j];
        q.instructions[j] = tmp;
    }
    return if (constrained_init) repairMetaOrdering(q) else q;
}

pub fn opName(op: MetaOp) []const u8 {
    return switch (op) {
        .INIT_CUR => "INIT_CUR",
        .MUTATE_CUR => "MUTATE_CUR",
        .MUTATE_BEST_TO_CUR => "MUTATE_BEST_TO_CUR",
        .CROSS_BEST_CUR => "CROSS_BEST_CUR",
        .EVAL_CUR => "EVAL_CUR",
        .ACCEPT_IF_BETTER => "ACCEPT_IF_BETTER",
        .ACCEPT_SA => "ACCEPT_SA",
        .RESET_CUR_TO_BEST => "RESET_CUR_TO_BEST",
        .RAND_REG => "RAND_REG",
        .REG_XOR => "REG_XOR",
        .REG_SHR => "REG_SHR",
        .TEMP_DECAY => "TEMP_DECAY",
        .NOP => "NOP",
    };
}

pub fn printMeta(p: MetaProgram, writer: anytype) !void {
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const ins = p.instructions[i];
        try writer.print("  [{d}] {s} dst=r{d} src1=r{d} src2=r{d}\n", .{
            i, opName(ins.op), ins.dst, ins.src1, ins.src2,
        });
    }
}

pub fn metaToCsv(p: MetaProgram, writer: anytype) !void {
    try writer.writeAll("idx,op_id,op_name,dst,src1,src2,used_len\n");
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const ins = p.instructions[i];
        try writer.print("{d},{d},{s},{d},{d},{d},{d}\n", .{
            i, @intFromEnum(ins.op), opName(ins.op), ins.dst, ins.src1, ins.src2, p.used,
        });
    }
}
