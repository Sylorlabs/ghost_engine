const std = @import("std");
const tier0 = @import("domain_meta_engine_mulfree_l24.zig");

// --- TIER-1 META-META-DOMAIN ---
//
// A MetaMetaProgram is a sequence of opcodes whose primitives operate
// on MetaPrograms (tier0). Executed for K outer steps, a
// MetaMetaProgram drives a search over MetaPrograms (each evaluated
// by running it for INNER_TIER0_STEPS via tier0.run). It returns the
// best q_best ever surfaced by any MetaProgram it visited.
//
// This is the "engine inventing its successor" experiment escalation:
// can a SEARCH over MetaPrograms (driven by a discovered
// MetaMetaProgram) outperform the hand-coded outer SA used by
// meta_engine_runner? Equal budget = equal number of MetaProgram
// evaluations.

pub const META_META_DOMAIN_NAME: []const u8 = "meta-meta-engine/u64-mixer-l24";

const NumScratchRegs = 4;
pub const MaxMetaMetaLen = 16;
pub const MinMetaMetaLen = 4;

// Module-level parameter — how many inner steps each EVAL_META_CUR
// gives tier0.run. Set by the runner before starting tier1 search so
// both Tier-1 EVAL_META and the hand-coded Tier-0 baseline use the
// SAME tier0 inner-step budget. This is the equal-budget contract.
pub var INNER_TIER0_STEPS: u32 = 200;

// chain_extras: library of prior champion MetaPrograms that
// CALL_META(k) can warm-start meta_cur from. Initially empty; populated
// by the Tier-1 chain runner across generations (gen_n+1's search has
// gen_0..gen_n's champion MetaPrograms available). Analog of
// sort_net.chain_extras and u64_mixer.chain_extras.
pub const MaxChainExtras: usize = 16;
pub var chain_extras: std.BoundedArray(tier0.MetaProgram, MaxChainExtras) = .{ .buffer = undefined, .len = 0 };

pub fn chainExtrasReset() void {
    chain_extras.len = 0;
}
pub fn chainExtrasAppend(p: tier0.MetaProgram) !void {
    try chain_extras.append(p);
}
pub fn chainExtrasLen() usize {
    return chain_extras.len;
}

// When true, CALL_META composes the destination index from (dst<<2 | src1)
// giving 4-bit (16 distinct values) addressability into chain_extras
// instead of the default 2-bit (4 distinct). Used by the "wide CALL_META"
// research test: a longer chain's library has 5+ entries, but a u2 dst
// can only address the first 4 — so the rest are unreachable. With this
// toggle on, the discovered MMP can address all 16 MaxChainExtras slots.
// Opt-in (default false) so existing memory reproductions are unchanged.
pub var wide_call_meta: bool = false;

// Shaped fitness for Tier-2 (Approach #4 of 2026-05-21 invention-engine
// round). When true, run() returns a structural-validity score in
// [-1e5, 0] instead of sentinel -1e6 when no EVAL_META_CUR fires. This
// gives Tier-2 a learnable gradient over MMPs that fail to evaluate:
// programs with EVAL_META_CUR score higher than those without; programs
// where EVAL comes before ACCEPT score higher than the reverse.
//
// Default false so Tier-1 chain runner results stay reproducible.
// Tier-2 (mmm_chain_runner) enables it via --shaped-fitness flag.
pub var shaped_fitness: bool = false;

// Opt-in structural bootstrap for MetaMetaPrograms. When enabled,
// generated MMPs contain the same minimal loop as a hand-written search
// engine: INIT_META_CUR -> EVAL_META_CUR -> ACCEPT_META_IF_BETTER.
// Mutations then repair missing/misordered EVAL/ACCEPT instructions.
pub var constrained_init: bool = false;

fn shapedScore(mm_prog: MetaMetaProgram) f64 {
    var score: f64 = -1.0e5;
    var has_init_meta: bool = false;
    var has_eval_meta: bool = false;
    var has_accept_meta: bool = false;
    var first_eval_meta: i32 = -1;
    var first_accept_meta: i32 = -1;
    var n_evals: u32 = 0;
    var i: usize = 0;
    while (i < mm_prog.used) : (i += 1) {
        const op = mm_prog.instructions[i].op;
        switch (op) {
            .INIT_META_CUR => has_init_meta = true,
            .EVAL_META_CUR => {
                has_eval_meta = true;
                n_evals += 1;
                if (first_eval_meta == -1) first_eval_meta = @intCast(i);
            },
            .ACCEPT_META_IF_BETTER, .ACCEPT_META_SA => {
                has_accept_meta = true;
                if (first_accept_meta == -1) first_accept_meta = @intCast(i);
            },
            else => {},
        }
    }
    if (has_eval_meta) score += 1.0e3;
    if (has_init_meta) score += 100.0;
    if (has_accept_meta) score += 100.0;
    if (first_eval_meta >= 0 and first_accept_meta >= 0 and first_eval_meta < first_accept_meta) {
        score += 500.0;
    }
    score += @as(f64, @floatFromInt(n_evals)) * 50.0;
    return score;
}

pub fn repairMetaMetaOrdering(mm_prog: MetaMetaProgram) MetaMetaProgram {
    var q = mm_prog;
    var first_eval: ?usize = null;
    var first_accept: ?usize = null;
    var i: usize = 0;
    while (i < q.used) : (i += 1) {
        switch (q.instructions[i].op) {
            .EVAL_META_CUR => {
                if (first_eval == null) first_eval = i;
            },
            .ACCEPT_META_IF_BETTER, .ACCEPT_META_SA => {
                if (first_accept == null) first_accept = i;
            },
            else => {},
        }
    }

    if (first_eval == null) {
        const idx: usize = if (q.used > 0) q.used - 1 else 0;
        q.instructions[idx] = .{ .op = .EVAL_META_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
        if (q.used == 0) q.used = 1;
        first_eval = idx;
    }
    if (first_accept == null) {
        const idx = @min(q.used, first_eval.? + 1);
        if (q.used < MaxMetaMetaLen) {
            var j = q.used;
            while (j > idx) : (j -= 1) q.instructions[j] = q.instructions[j - 1];
            q.instructions[idx] = .{ .op = .ACCEPT_META_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 };
            q.used += 1;
            first_accept = idx;
        } else {
            const replace_idx = if (idx < q.used) idx else q.used - 1;
            q.instructions[replace_idx] = .{ .op = .ACCEPT_META_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 };
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

pub const MetaMetaOp = enum(u4) {
    INIT_META_CUR = 0, // meta_cur := randomMetaProgram(rng); q_cur := -inf
    MUTATE_META_CUR = 1, // meta_cur := mutateMeta(meta_cur, rng)
    MUTATE_META_BEST_TO_CUR = 2, // meta_cur := mutateMeta(meta_best, rng)
    CROSS_META_BEST_CUR = 3, // crossover not exported by tier0 — emulate by mixing instructions
    EVAL_META_CUR = 4, // q_cur := tier0.run(meta_cur, INNER_TIER0_STEPS, rng); cur_evaluated := true
    ACCEPT_META_IF_BETTER = 5, // if q_cur > q_best: meta_best := meta_cur
    ACCEPT_META_SA = 6, // metropolis on regs[0] temperature
    RESET_META_CUR_TO_BEST = 7,
    RAND_REG = 8,
    REG_XOR = 9,
    REG_SHR = 10,
    TEMP_DECAY = 11,
    CALL_META = 12, // meta_cur := chain_extras[dst % len]; cur_evaluated := false
    NOP = 13,
};

pub const MetaMetaInstr = struct {
    op: MetaMetaOp,
    dst: u2,
    src1: u2,
    src2: u2,
    pub fn eq(a: MetaMetaInstr, b: MetaMetaInstr) bool {
        return a.op == b.op and a.dst == b.dst and a.src1 == b.src1 and a.src2 == b.src2;
    }
};

pub const MetaMetaProgram = struct {
    instructions: [MaxMetaMetaLen]MetaMetaInstr,
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
    meta_cur: tier0.MetaProgram,
    meta_best: tier0.MetaProgram,
    q_cur: f64,
    q_best: f64,
    regs: [NumScratchRegs]u64,
    cur_evaluated: bool,
};

// Tier-0 doesn't export a crossover function for MetaProgram, so we
// roll our own minimal one: random splice.
fn crossoverMeta(a: tier0.MetaProgram, b: tier0.MetaProgram, rng: *u64) tier0.MetaProgram {
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

// Returns q_best — the best mixer-quality ever found by any
// MetaProgram surfaced during this run.
pub fn run(mm: MetaMetaProgram, outer_steps: u32, root_seed: u64) f64 {
    var r0: u64 = root_seed ^ 0x5A5A_A5A5_F00D_BABE;
    const init_meta = tier0.randomMetaProgram(&r0);
    var st = InnerState{
        .rng = r0,
        .meta_cur = init_meta,
        .meta_best = init_meta,
        .q_cur = NegInf,
        .q_best = NegInf,
        .regs = .{ 0x100, 1, 0, 0 },
        .cur_evaluated = false,
    };

    var s: u32 = 0;
    while (s < outer_steps) : (s += 1) {
        var i: usize = 0;
        while (i < mm.used) : (i += 1) {
            execOp(&st, mm.instructions[i]);
        }
    }
    if (shaped_fitness and st.q_best == NegInf) return shapedScore(mm);
    return st.q_best;
}

// Same as run() but also returns the final meta_best so the caller
// can re-evaluate it on held-out seeds.
pub fn runReturningChampion(mm: MetaMetaProgram, outer_steps: u32, root_seed: u64) struct { q_best: f64, meta_best: tier0.MetaProgram } {
    var r0: u64 = root_seed ^ 0x5A5A_A5A5_F00D_BABE;
    const init_meta = tier0.randomMetaProgram(&r0);
    var st = InnerState{
        .rng = r0,
        .meta_cur = init_meta,
        .meta_best = init_meta,
        .q_cur = NegInf,
        .q_best = NegInf,
        .regs = .{ 0x100, 1, 0, 0 },
        .cur_evaluated = false,
    };
    var s: u32 = 0;
    while (s < outer_steps) : (s += 1) {
        var i: usize = 0;
        while (i < mm.used) : (i += 1) execOp(&st, mm.instructions[i]);
    }
    const reported_q: f64 = if (shaped_fitness and st.q_best == NegInf)
        shapedScore(mm)
    else
        st.q_best;
    return .{ .q_best = reported_q, .meta_best = st.meta_best };
}

fn execOp(st: *InnerState, ins: MetaMetaInstr) void {
    switch (ins.op) {
        .INIT_META_CUR => {
            st.meta_cur = tier0.randomMetaProgram(&st.rng);
            st.q_cur = NegInf;
            st.cur_evaluated = false;
        },
        .MUTATE_META_CUR => {
            st.meta_cur = tier0.mutateMeta(st.meta_cur, &st.rng);
            st.cur_evaluated = false;
        },
        .MUTATE_META_BEST_TO_CUR => {
            st.meta_cur = tier0.mutateMeta(st.meta_best, &st.rng);
            st.cur_evaluated = false;
        },
        .CROSS_META_BEST_CUR => {
            st.meta_cur = crossoverMeta(st.meta_best, st.meta_cur, &st.rng);
            st.cur_evaluated = false;
        },
        .EVAL_META_CUR => {
            // Run the candidate MetaProgram for INNER_TIER0_STEPS steps;
            // q_cur is the q_best returned (best mixer quality the
            // MetaProgram surfaced).
            st.rng = smix(st.rng);
            const seed = st.rng;
            if (tier0.repair_meta_ordering) {
                st.meta_cur = tier0.repairMetaOrdering(st.meta_cur);
            }
            const q = tier0.run(st.meta_cur, INNER_TIER0_STEPS, seed);
            // Sentinel: replace inf/nan with a finite "very bad" value
            // so an un-evaluating MetaProgram (scoring 0) ranks below
            // an evaluating-but-bad one. Matches meta_engine_runner.zig
            // anchor-protection fix.
            st.q_cur = if (std.math.isFinite(q)) q else -1.0e6;
            st.cur_evaluated = true;
            if (st.q_best == NegInf) {
                st.q_best = st.q_cur;
                st.meta_best = st.meta_cur;
            }
        },
        .ACCEPT_META_IF_BETTER => {
            if (st.cur_evaluated and st.q_cur > st.q_best) {
                st.q_best = st.q_cur;
                st.meta_best = st.meta_cur;
            }
        },
        .ACCEPT_META_SA => {
            if (!st.cur_evaluated) return;
            if (st.q_cur > st.q_best) {
                st.q_best = st.q_cur;
                st.meta_best = st.meta_cur;
                return;
            }
            const temp_raw = st.regs[0];
            const t: f64 = @as(f64, @floatFromInt(temp_raw & 0xFFFF)) / 4096.0 + 1e-6;
            const delta = st.q_cur - st.q_best;
            const accept_prob = @exp(delta / t);
            st.rng = smix(st.rng);
            const r: f64 = @as(f64, @floatFromInt(st.rng >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
            if (r < accept_prob) {
                // Same partial-accept policy as tier0: don't downgrade
                // best; allow MUTATE_META_CUR to explore from cur.
            }
        },
        .RESET_META_CUR_TO_BEST => {
            st.meta_cur = st.meta_best;
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
        .CALL_META => {
            if (chain_extras.len > 0) {
                const idx_raw: usize = if (wide_call_meta)
                    (@as(usize, ins.dst) << 2) | @as(usize, ins.src1)
                else
                    @as(usize, ins.dst);
                const idx: usize = idx_raw % chain_extras.len;
                st.meta_cur = tier0.mutateMeta(chain_extras.buffer[idx], &st.rng);
                st.cur_evaluated = false;
            }
        },
        .NOP => {},
    }
}

// --- META-META PROGRAM CONSTRUCTION ---

fn randomMetaMetaInstr(rng: *u64) MetaMetaInstr {
    const NumOps: u64 = @typeInfo(MetaMetaOp).@"enum".fields.len;
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

pub fn randomMetaMetaProgram(rng: *u64) MetaMetaProgram {
    rng.* = smix(rng.*);
    const len: u8 = @intCast(MinMetaMetaLen + (rng.* % (MaxMetaMetaLen - MinMetaMetaLen)));
    var p = MetaMetaProgram{ .instructions = undefined, .used = len };
    var i: usize = 0;
    while (i < len) : (i += 1) p.instructions[i] = randomMetaMetaInstr(rng);
    if (constrained_init and len >= 3) {
        p.instructions[0] = .{ .op = .INIT_META_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
        p.instructions[1] = .{ .op = .EVAL_META_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
        p.instructions[2] = .{ .op = .ACCEPT_META_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 };
    }
    return p;
}

pub fn mutateMetaMeta(p: MetaMetaProgram, rng: *u64) MetaMetaProgram {
    var q = p;
    rng.* = smix(rng.*);
    const mode = rng.* % 10;
    if (mode < 6) {
        rng.* = smix(rng.*);
        const idx: usize = rng.* % q.used;
        q.instructions[idx] = randomMetaMetaInstr(rng);
    } else if (mode < 8 and q.used < MaxMetaMetaLen) {
        rng.* = smix(rng.*);
        const idx: usize = rng.* % (q.used + 1);
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.instructions[i] = q.instructions[i - 1];
        q.instructions[idx] = randomMetaMetaInstr(rng);
        q.used += 1;
    } else if (q.used > MinMetaMetaLen) {
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
    return if (constrained_init) repairMetaMetaOrdering(q) else q;
}

pub fn opName(op: MetaMetaOp) []const u8 {
    return switch (op) {
        .INIT_META_CUR => "INIT_META_CUR",
        .MUTATE_META_CUR => "MUTATE_META_CUR",
        .MUTATE_META_BEST_TO_CUR => "MUTATE_META_BEST_TO_CUR",
        .CROSS_META_BEST_CUR => "CROSS_META_BEST_CUR",
        .EVAL_META_CUR => "EVAL_META_CUR",
        .ACCEPT_META_IF_BETTER => "ACCEPT_META_IF_BETTER",
        .ACCEPT_META_SA => "ACCEPT_META_SA",
        .RESET_META_CUR_TO_BEST => "RESET_META_CUR_TO_BEST",
        .RAND_REG => "RAND_REG",
        .REG_XOR => "REG_XOR",
        .REG_SHR => "REG_SHR",
        .TEMP_DECAY => "TEMP_DECAY",
        .CALL_META => "CALL_META",
        .NOP => "NOP",
    };
}

pub fn printMetaMeta(p: MetaMetaProgram, writer: anytype) !void {
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const ins = p.instructions[i];
        try writer.print("{d:>3}  {s:<28} dst={d} src1={d} src2={d}\n", .{
            i, opName(ins.op), ins.dst, ins.src1, ins.src2,
        });
    }
}

pub fn metaMetaToCsv(p: MetaMetaProgram, writer: anytype) !void {
    try writer.writeAll("idx,op_id,op_name,dst,src1,src2\n");
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const ins = p.instructions[i];
        try writer.print("{d},{d},{s},{d},{d},{d}\n", .{
            i, @intFromEnum(ins.op), opName(ins.op), ins.dst, ins.src1, ins.src2,
        });
    }
}
