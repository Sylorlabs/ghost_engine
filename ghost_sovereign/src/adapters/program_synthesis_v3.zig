const std = @import("std");

// Program synthesis v3: bounded A/B harness for executable u64 mixers.
//
// Runtime boundary:
//   - std only
//   - no VSA import, no Flame import, no concept enum
//   - no model, no cloud, no network, no corpus
//
// This adapter does not claim invention by narrative. It compares search
// strategies under repeatable seeds and reports executable programs plus edge
// diagnostics. The strongest evidence is a program that is decodable, distinct
// from the reference templates, and survives external batteries.

const NumRegs = 8;
const MaxProgLen = 12;
const MaxPool = 64;
const FitSamples = 64;
const PeriodSamples = 4096;
const ChiSqSamples = 4096;
const EdgeSamples = 4096;
const ArtifactMagic: u64 = 0x315653475052474D; // MGPRGSV1, little-endian marker.
const ArtifactVersion: u32 = 1;

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

const SearchMode = enum {
    random,
    anneal,
    crossover,
    guided,
};

const RngMode = enum {
    splitmix,
    discovered,
};

const ConstMode = enum {
    standard,
    neutral,
    minimal,
};

const Instruction = struct {
    op: Op,
    dst: u3,
    src1: u3,
    src2: u3,
    imm: u64,
};

const Program = struct {
    instructions: [MaxProgLen]Instruction,
    used: u8,

    fn execute(self: Program, input: u64, const_mode: ConstMode) u64 {
        var regs = [_]u64{0} ** NumRegs;
        seedRegisters(&regs, input, const_mode);

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

const Fitness = struct {
    avalanche: f64,
    balance: f64,
    period: usize,
    chisq: f64,
    length: u8,
    base_composite: f64,
    novelty: f64,
    edge_penalty: f64,
    score: f64,

    fn isFinite(self: Fitness) bool {
        return std.math.isFinite(self.avalanche) and
            std.math.isFinite(self.balance) and
            std.math.isFinite(self.chisq) and
            std.math.isFinite(self.base_composite) and
            std.math.isFinite(self.novelty) and
            std.math.isFinite(self.edge_penalty) and
            std.math.isFinite(self.score);
    }
};

const EdgeStats = struct {
    edge_avalanche: f64,
    fixed_points: usize,
    zero_outputs: usize,
    unique_low16: usize,
    zero_out: u64,
    one_out: u64,
    ones_out: u64,
};

const Config = struct {
    mode: SearchMode = .guided,
    run_all_modes: bool = false,
    iterations: usize = 6000,
    runs: usize = 4,
    pool_seeds: usize = 64,
    pool_size: usize = 32,
    max_len: u8 = 8,
    allow_step: bool = false,
    novelty_weight: f64 = 0.0,
    edge_penalty_weight: f64 = 0.0,
    rng_mode: RngMode = .discovered,
    const_mode: ConstMode = .standard,
    seed: u64 = 0xC0FFEEBABEF00D12,
    csv_path: []const u8 = "results/program_synthesis_v3.csv",
    artifact_path: ?[]const u8 = null,
};

const RunResult = struct {
    mode: SearchMode,
    run_index: usize,
    seed: u64,
    best_program: Program,
    best_fitness: Fitness,
    best_iter: usize,
    accepted: usize,
    evaluated: usize,
    edge: EdgeStats,
};

const Candidate = struct {
    p: Program,
    f: Fitness,
};

const ChampionPool = struct {
    programs: [MaxPool]Program,
    fitnesses: [MaxPool]Fitness,
    count: usize = 0,
    capacity: usize = 32,

    fn init(capacity: usize) ChampionPool {
        return .{
            .programs = undefined,
            .fitnesses = undefined,
            .count = 0,
            .capacity = @max(@as(usize, 1), @min(capacity, MaxPool)),
        };
    }

    fn consider(self: *ChampionPool, p: Program, f: Fitness) bool {
        if (self.count < self.capacity) {
            self.programs[self.count] = p;
            self.fitnesses[self.count] = f;
            self.count += 1;
            return true;
        }

        const worst_idx = self.worstIndex();
        if (f.score > self.fitnesses[worst_idx].score) {
            self.programs[worst_idx] = p;
            self.fitnesses[worst_idx] = f;
            return true;
        }
        return false;
    }

    fn worstIndex(self: *const ChampionPool) usize {
        var worst: usize = 0;
        var i: usize = 1;
        while (i < self.count) : (i += 1) {
            if (self.fitnesses[i].score < self.fitnesses[worst].score) worst = i;
        }
        return worst;
    }

    fn best(self: *const ChampionPool) Candidate {
        var b: usize = 0;
        var i: usize = 1;
        while (i < self.count) : (i += 1) {
            if (self.fitnesses[i].score > self.fitnesses[b].score) b = i;
        }
        return .{ .p = self.programs[b], .f = self.fitnesses[b] };
    }
};

fn seedRegisters(regs: *[NumRegs]u64, input: u64, const_mode: ConstMode) void {
    regs[0] = input;
    switch (const_mode) {
        .standard => {
            regs[1] = 0x9E3779B97F4A7C15;
            regs[2] = 0xBF58476D1CE4E5B9;
            regs[3] = 0x94D049BB133111EB;
        },
        .neutral => {
            regs[1] = 0xD6E8FEB86659FD93;
            regs[2] = 0xA5A3564E27F8866F;
            regs[3] = 0xC6BC279692B5CC83;
        },
        .minimal => {
            regs[1] = 1;
            regs[2] = 3;
            regs[3] = 5;
        },
    }
    regs[4] = 0;
    regs[5] = 0;
    regs[6] = 0;
    regs[7] = 0;
}

fn splitMix64Ref(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn discoveredRun2Mix(x: u64) u64 {
    var r0 = x;
    const r1 = r0 ^ (r0 >> 37);
    r0 = r1 +% 0x9EE408BD3A3337DD;
    var r6 = r0 *% 0x0D5886EBD935161F;
    r6 = r6 ^ (r6 >> 30);
    return r6 *% 0x125B26B8C3E6F5D1;
}

fn rngStep(x: u64, mode: RngMode) u64 {
    return switch (mode) {
        .splitmix => splitMix64Ref(x),
        .discovered => discoveredRun2Mix(x),
    };
}

fn nextRand(rng: *u64, cfg: Config) u64 {
    rng.* = rngStep(rng.*, cfg.rng_mode);
    return rng.*;
}

fn splitmixProgram() Program {
    return .{
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

fn discoveredRun2Program() Program {
    return .{
        .instructions = [_]Instruction{
            .{ .op = .SHR_XOR, .dst = 1, .src1 = 0, .src2 = 0, .imm = 37 },
            .{ .op = .ADD_CONST, .dst = 0, .src1 = 1, .src2 = 0, .imm = 0x9EE408BD3A3337DD },
            .{ .op = .MUL, .dst = 6, .src1 = 0, .src2 = 0, .imm = 0x0D5886EBD935161F },
            .{ .op = .SHR_XOR, .dst = 6, .src1 = 6, .src2 = 0, .imm = 30 },
            .{ .op = .MUL, .dst = 7, .src1 = 6, .src2 = 0, .imm = 0x125B26B8C3E6F5D1 },
        } ++ [_]Instruction{.{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0 }} ** (MaxProgLen - 5),
        .used = 5,
    };
}

fn avalancheScore(p: Program, cfg: Config) f64 {
    var total: f64 = 0;
    var samples: u64 = 0;
    var rng: u64 = 0xACE_F00D_BEEF_CAFE;
    var s: usize = 0;
    while (s < FitSamples) : (s += 1) {
        rng = splitMix64Ref(rng);
        const x = rng;
        const y = p.execute(x, cfg.const_mode);
        var bit: u6 = 0;
        while (true) {
            const x_flip = x ^ (@as(u64, 1) << bit);
            const y_flip = p.execute(x_flip, cfg.const_mode);
            total += @as(f64, @floatFromInt(@popCount(y ^ y_flip)));
            samples += 1;
            if (bit == 63) break;
            bit += 1;
        }
    }
    return total / @as(f64, @floatFromInt(samples));
}

fn balanceScore(p: Program, cfg: Config) f64 {
    var total_pop: f64 = 0;
    var rng: u64 = 0x1234_5678_9ABC_DEF0;
    var n: usize = 0;
    while (n < FitSamples * 4) : (n += 1) {
        rng = splitMix64Ref(rng);
        const y = p.execute(rng, cfg.const_mode);
        total_pop += @as(f64, @floatFromInt(@popCount(y)));
    }
    return total_pop / @as(f64, @floatFromInt(FitSamples * 4));
}

fn periodEstimate(p: Program, cfg: Config, seed: u64) usize {
    var x = seed;
    var i: usize = 0;
    while (i < PeriodSamples) : (i += 1) {
        x = p.execute(x, cfg.const_mode);
        if (x == seed and i > 0) return i + 1;
    }
    return PeriodSamples;
}

fn chiSquareScore(p: Program, cfg: Config) f64 {
    var bins = [_]u32{0} ** 256;
    var rng: u64 = 0xDEAD_BEEF_BAD_F00D;
    var n: usize = 0;
    while (n < ChiSqSamples) : (n += 1) {
        rng = splitMix64Ref(rng);
        const y = p.execute(rng, cfg.const_mode);
        bins[@intCast(y & 0xFF)] += 1;
    }

    const expected = @as(f64, @floatFromInt(ChiSqSamples)) / 256.0;
    var chisq: f64 = 0;
    for (bins) |c| {
        const d = @as(f64, @floatFromInt(c)) - expected;
        chisq += (d * d) / expected;
    }
    return chisq;
}

fn evaluate(p: Program, cfg: Config) Fitness {
    const av = avalancheScore(p, cfg);
    const bal = balanceScore(p, cfg);
    const per = periodEstimate(p, cfg, 0x7E57_0001);
    const cs = chiSquareScore(p, cfg);
    const avalanche_err = @abs(av - 32.0);
    const balance_err = @abs(bal - 32.0);
    const period_score = @as(f64, @floatFromInt(per)) / @as(f64, @floatFromInt(PeriodSamples));
    const chisq_pen = if (cs > 255.0) (cs - 255.0) / 100.0 else 0.0;
    const base =
        -10.0 * avalanche_err
        - 5.0 * balance_err
        + 50.0 * period_score
        - chisq_pen
        - @as(f64, @floatFromInt(p.used)) * 0.5;
    const novelty = noveltyScore(p);
    const edge_penalty = quickEdgePenalty(p, cfg);
    return .{
        .avalanche = av,
        .balance = bal,
        .period = per,
        .chisq = cs,
        .length = p.used,
        .base_composite = base,
        .novelty = novelty,
        .edge_penalty = edge_penalty,
        .score = base + cfg.novelty_weight * novelty - cfg.edge_penalty_weight * edge_penalty,
    };
}

fn quickEdgePenalty(p: Program, cfg: Config) f64 {
    var penalty: f64 = 0;
    const zero_out = p.execute(0, cfg.const_mode);
    if (zero_out == 0) penalty += 2.0;
    if (p.execute(1, cfg.const_mode) == 1) penalty += 2.0;
    if (p.execute(~@as(u64, 0), cfg.const_mode) == ~@as(u64, 0)) penalty += 2.0;

    var fixed: usize = 0;
    var zeroes: usize = 0;
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        const x: u64 = @intCast(i);
        const y = p.execute(x, cfg.const_mode);
        if (y == x) fixed += 1;
        if (y == 0) zeroes += 1;
    }
    penalty += @as(f64, @floatFromInt(fixed)) * 0.25;
    penalty += @as(f64, @floatFromInt(zeroes)) * 0.20;

    const edge_seeds = [_]u64{ 0, 1, ~@as(u64, 0), 0x8000000000000000 };
    var total: f64 = 0;
    var samples: u64 = 0;
    for (edge_seeds) |x| {
        const y = p.execute(x, cfg.const_mode);
        var bit: u6 = 0;
        while (bit < 16) : (bit += 1) {
            const y_flip = p.execute(x ^ (@as(u64, 1) << bit), cfg.const_mode);
            total += @as(f64, @floatFromInt(@popCount(y ^ y_flip)));
            samples += 1;
        }
    }
    const edge_av = total / @as(f64, @floatFromInt(samples));
    if (edge_av < 28.0) penalty += (28.0 - edge_av) * 0.25;
    return penalty;
}

fn edgeStats(p: Program, cfg: Config) EdgeStats {
    const seeds = [_]u64{
        0,
        1,
        ~@as(u64, 0),
        0x8000000000000000,
        0x7FFFFFFFFFFFFFFF,
        0x9E3779B97F4A7C15,
        0xBF58476D1CE4E5B9,
        0x94D049BB133111EB,
        0x0123456789ABCDEF,
        0xFEDCBA9876543210,
    };

    var total: f64 = 0;
    var samples: u64 = 0;
    for (seeds) |x| {
        const y = p.execute(x, cfg.const_mode);
        var bit: u6 = 0;
        while (true) {
            const flipped = x ^ (@as(u64, 1) << bit);
            const y_flip = p.execute(flipped, cfg.const_mode);
            total += @as(f64, @floatFromInt(@popCount(y ^ y_flip)));
            samples += 1;
            if (bit == 63) break;
            bit += 1;
        }
    }

    var fixed_points: usize = 0;
    var zero_outputs: usize = 0;
    var unique_low16: usize = 0;
    var seen = [_]u64{0} ** 1024;
    var i: usize = 0;
    while (i < EdgeSamples) : (i += 1) {
        const x: u64 = @intCast(i);
        const y = p.execute(x, cfg.const_mode);
        if (y == x) fixed_points += 1;
        if (y == 0) zero_outputs += 1;
        const low: usize = @intCast(y & 0xFFFF);
        const word = low / 64;
        const bit: u6 = @intCast(low % 64);
        const mask = @as(u64, 1) << bit;
        if ((seen[word] & mask) == 0) {
            seen[word] |= mask;
            unique_low16 += 1;
        }
    }

    return .{
        .edge_avalanche = total / @as(f64, @floatFromInt(samples)),
        .fixed_points = fixed_points,
        .zero_outputs = zero_outputs,
        .unique_low16 = unique_low16,
        .zero_out = p.execute(0, cfg.const_mode),
        .one_out = p.execute(1, cfg.const_mode),
        .ones_out = p.execute(~@as(u64, 0), cfg.const_mode),
    };
}

fn randomOp(rng: *u64, cfg: Config) Op {
    const no_step = [_]Op{ .XOR, .ADD, .MUL, .ROTL, .SHL_XOR, .SHR_XOR, .ADD_CONST, .AND_NOT, .OR_SHIFT };
    const value = nextRand(rng, cfg);
    if (cfg.allow_step) return @enumFromInt(@as(u4, @intCast(value % 10)));
    return no_step[@intCast(value % no_step.len)];
}

fn guidedOp(rng: *u64, cfg: Config, guide: Fitness) Op {
    const draw = nextRand(rng, cfg) % 100;
    const av_err = @abs(guide.avalanche - 32.0);
    const bal_err = @abs(guide.balance - 32.0);

    if (av_err > 0.35) {
        if (draw < 25) return .MUL;
        if (draw < 50) return .SHR_XOR;
        if (draw < 68) return .SHL_XOR;
        if (draw < 82) return .ADD_CONST;
        if (draw < 92) return .ROTL;
    } else if (bal_err > 0.20) {
        if (draw < 24) return .XOR;
        if (draw < 46) return .ADD;
        if (draw < 68) return .ADD_CONST;
        if (draw < 84) return .MUL;
    } else {
        if (draw < 20) return .SHR_XOR;
        if (draw < 40) return .MUL;
        if (draw < 55) return .ADD_CONST;
        if (draw < 68) return .XOR;
        if (draw < 80) return .ROTL;
    }

    if (cfg.allow_step and draw == 99) return .SPLITMIX_STEP;
    return randomOp(rng, cfg);
}

fn guidedImmediate(op: Op, rng: *u64, cfg: Config) u64 {
    const common_shifts = [_]u64{ 17, 21, 23, 27, 29, 30, 31, 33, 37, 41, 47 };
    const value = nextRand(rng, cfg);
    return switch (op) {
        .SHR_XOR, .SHL_XOR, .ROTL => common_shifts[@intCast(value % common_shifts.len)],
        .MUL => value | 1,
        .ADD_CONST => value,
        .SPLITMIX_STEP => 16 + (value % 33),
        else => value,
    };
}

fn randomInstruction(rng: *u64, cfg: Config) Instruction {
    const op = randomOp(rng, cfg);
    const dst: u3 = @intCast(nextRand(rng, cfg) % NumRegs);
    const src1: u3 = @intCast(nextRand(rng, cfg) % NumRegs);
    const src2: u3 = @intCast(nextRand(rng, cfg) % NumRegs);
    const imm = nextRand(rng, cfg);
    return .{ .op = op, .dst = dst, .src1 = src1, .src2 = src2, .imm = imm };
}

fn guidedInstruction(rng: *u64, cfg: Config, guide: Fitness) Instruction {
    const op = guidedOp(rng, cfg, guide);
    const dst: u3 = @intCast(nextRand(rng, cfg) % NumRegs);
    const src1_draw = nextRand(rng, cfg) % 100;
    const src1: u3 = if (src1_draw < 55) 0 else @intCast(nextRand(rng, cfg) % NumRegs);
    const src2: u3 = @intCast(nextRand(rng, cfg) % NumRegs);
    const imm = guidedImmediate(op, rng, cfg);
    return .{ .op = op, .dst = dst, .src1 = src1, .src2 = src2, .imm = imm };
}

fn randomProgram(rng: *u64, cfg: Config) Program {
    const max_len = @max(@as(u8, 4), @min(cfg.max_len, MaxProgLen));
    const span = @as(u64, @intCast(max_len - 3));
    const len: u8 = @intCast(4 + (nextRand(rng, cfg) % span));
    var p = Program{ .instructions = undefined, .used = len };
    var i: usize = 0;
    while (i < len) : (i += 1) {
        p.instructions[i] = randomInstruction(rng, cfg);
    }
    p.instructions[len - 1].dst = NumRegs - 1;
    return p;
}

fn mutate(p: Program, rng: *u64, cfg: Config) Program {
    var q = p;
    const mode = nextRand(rng, cfg) % 16;
    if (mode < 10) {
        const idx: usize = @intCast(nextRand(rng, cfg) % q.used);
        q.instructions[idx] = randomInstruction(rng, cfg);
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else if (mode < 13 and q.used < @min(cfg.max_len, MaxProgLen)) {
        const idx: usize = @intCast(nextRand(rng, cfg) % (q.used + 1));
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.instructions[i] = q.instructions[i - 1];
        q.instructions[idx] = randomInstruction(rng, cfg);
        q.used += 1;
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else if (q.used > 4) {
        const idx: usize = @intCast(nextRand(rng, cfg) % q.used);
        var i: usize = idx;
        while (i < q.used - 1) : (i += 1) q.instructions[i] = q.instructions[i + 1];
        q.used -= 1;
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else {
        const idx: usize = @intCast(nextRand(rng, cfg) % q.used);
        q.instructions[idx].imm = nextRand(rng, cfg);
    }
    return q;
}

fn guidedMutate(p: Program, rng: *u64, cfg: Config, guide: Fitness) Program {
    var q = p;
    const mode = nextRand(rng, cfg) % 20;
    if (mode < 12) {
        const idx: usize = @intCast(nextRand(rng, cfg) % q.used);
        q.instructions[idx] = guidedInstruction(rng, cfg, guide);
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else if (mode < 15 and q.used < @min(cfg.max_len, MaxProgLen)) {
        const idx: usize = @intCast(nextRand(rng, cfg) % (q.used + 1));
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.instructions[i] = q.instructions[i - 1];
        q.instructions[idx] = guidedInstruction(rng, cfg, guide);
        q.used += 1;
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else if (mode < 17 and q.used > 4) {
        const idx: usize = @intCast(nextRand(rng, cfg) % q.used);
        var i: usize = idx;
        while (i < q.used - 1) : (i += 1) q.instructions[i] = q.instructions[i + 1];
        q.used -= 1;
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else {
        const idx: usize = @intCast(nextRand(rng, cfg) % q.used);
        q.instructions[idx].imm = guidedImmediate(q.instructions[idx].op, rng, cfg);
    }
    return q;
}

fn crossover(a: Program, b: Program, rng: *u64, cfg: Config) Program {
    const min_len = @min(a.used, b.used);
    if (min_len < 4) return a;
    const cut: usize = @intCast(nextRand(rng, cfg) % min_len);
    var q = a;
    var i = cut;
    while (i < b.used and i < MaxProgLen and i < cfg.max_len) : (i += 1) {
        q.instructions[i] = b.instructions[i];
    }
    q.used = @min(b.used, @min(cfg.max_len, MaxProgLen));
    q.instructions[q.used - 1].dst = NumRegs - 1;
    return q;
}

fn programDistance(a: Program, b: Program) f64 {
    var dist: f64 = @as(f64, @floatFromInt(if (a.used > b.used) a.used - b.used else b.used - a.used));
    const max_used = @max(a.used, b.used);
    var i: usize = 0;
    while (i < max_used) : (i += 1) {
        if (i >= a.used or i >= b.used) {
            dist += 4.0;
            continue;
        }
        const ia = a.instructions[i];
        const ib = b.instructions[i];
        if (ia.op != ib.op) dist += 2.0;
        if (ia.dst != ib.dst) dist += 0.5;
        if (ia.src1 != ib.src1) dist += 0.5;
        if (ia.src2 != ib.src2) dist += 0.5;
        const imm_diff = @popCount(ia.imm ^ ib.imm);
        dist += @min(4.0, @as(f64, @floatFromInt(imm_diff)) / 16.0);
    }
    return dist;
}

fn noveltyScore(p: Program) f64 {
    const d_ref = programDistance(p, splitmixProgram());
    const d_disc = programDistance(p, discoveredRun2Program());
    return @min(d_ref, d_disc) / 24.0;
}

fn programHash(p: Program) u64 {
    var h: u64 = 0xCBF29CE484222325;
    h ^= p.used;
    h *%= 0x100000001B3;
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const inst = p.instructions[i];
        h ^= @intFromEnum(inst.op);
        h *%= 0x100000001B3;
        h ^= inst.dst;
        h *%= 0x100000001B3;
        h ^= inst.src1;
        h *%= 0x100000001B3;
        h ^= inst.src2;
        h *%= 0x100000001B3;
        h ^= inst.imm;
        h *%= 0x100000001B3;
    }
    return h;
}

fn seedPool(pool: *ChampionPool, cfg: Config, rng: *u64) Candidate {
    var seeded: usize = 0;
    while (seeded < cfg.pool_seeds or pool.count == 0) : (seeded += 1) {
        const p = randomProgram(rng, cfg);
        const f = evaluate(p, cfg);
        if (!f.isFinite()) continue;
        _ = pool.consider(p, f);
    }
    return pool.best();
}

fn metropolisAccept(delta: f64, temperature: f64, rng: *u64, cfg: Config) bool {
    if (delta >= 0) return true;
    if (temperature <= 0) return false;
    const draw_raw = nextRand(rng, cfg) % 1_000_000;
    const draw = @as(f64, @floatFromInt(draw_raw)) / 1_000_000.0;
    return draw < std.math.exp(delta / temperature);
}

fn runRandom(cfg: Config, run_index: usize, run_seed: u64) RunResult {
    var rng = run_seed;
    var best_program = randomProgram(&rng, cfg);
    var best_fitness = evaluate(best_program, cfg);
    var best_iter: usize = 0;
    var accepted: usize = 0;
    var evaluated: usize = 1;

    var i: usize = 0;
    while (i < cfg.iterations) : (i += 1) {
        const p = randomProgram(&rng, cfg);
        const f = evaluate(p, cfg);
        evaluated += 1;
        if (!f.isFinite()) continue;
        if (f.score > best_fitness.score) {
            best_program = p;
            best_fitness = f;
            best_iter = i + 1;
            accepted += 1;
        }
    }

    return .{
        .mode = .random,
        .run_index = run_index,
        .seed = run_seed,
        .best_program = best_program,
        .best_fitness = best_fitness,
        .best_iter = best_iter,
        .accepted = accepted,
        .evaluated = evaluated,
        .edge = edgeStats(best_program, cfg),
    };
}

fn runAnneal(cfg: Config, run_index: usize, run_seed: u64) RunResult {
    var rng = run_seed;
    var pool = ChampionPool.init(1);
    var best = seedPool(&pool, cfg, &rng);
    var current = best;
    var accepted: usize = 0;
    var evaluated: usize = cfg.pool_seeds;
    var best_iter: usize = 0;

    var i: usize = 0;
    while (i < cfg.iterations) : (i += 1) {
        const progress = @as(f64, @floatFromInt(i)) / @max(1.0, @as(f64, @floatFromInt(cfg.iterations)));
        const t = 8.0 * std.math.pow(f64, 0.001, progress);
        const candidate = mutate(current.p, &rng, cfg);
        const cand_fit = evaluate(candidate, cfg);
        evaluated += 1;
        if (!cand_fit.isFinite()) continue;

        if (metropolisAccept(cand_fit.score - current.f.score, t, &rng, cfg)) {
            current = .{ .p = candidate, .f = cand_fit };
            accepted += 1;
        }
        if (cand_fit.score > best.f.score) {
            best = .{ .p = candidate, .f = cand_fit };
            best_iter = i + 1;
        }
    }

    return .{
        .mode = .anneal,
        .run_index = run_index,
        .seed = run_seed,
        .best_program = best.p,
        .best_fitness = best.f,
        .best_iter = best_iter,
        .accepted = accepted,
        .evaluated = evaluated,
        .edge = edgeStats(best.p, cfg),
    };
}

fn runPoolMode(cfg: Config, run_index: usize, run_seed: u64) RunResult {
    var rng = run_seed;
    var pool = ChampionPool.init(cfg.pool_size);
    var best_seen = seedPool(&pool, cfg, &rng);
    var accepted: usize = 0;
    var evaluated: usize = cfg.pool_seeds;
    var best_iter: usize = 0;

    var i: usize = 0;
    while (i < cfg.iterations) : (i += 1) {
        const progress = @as(f64, @floatFromInt(i)) / @max(1.0, @as(f64, @floatFromInt(cfg.iterations)));
        const t = 8.0 * std.math.pow(f64, 0.001, progress);

        const parent_idx: usize = @intCast(nextRand(&rng, cfg) % pool.count);
        const parent = pool.programs[parent_idx];
        var candidate = parent;
        if (pool.count > 1) {
            const other_idx: usize = @intCast(nextRand(&rng, cfg) % pool.count);
            candidate = crossover(parent, pool.programs[other_idx], &rng, cfg);
        }
        if (cfg.mode == .guided) {
            candidate = guidedMutate(candidate, &rng, cfg, best_seen.f);
        } else {
            candidate = mutate(candidate, &rng, cfg);
        }

        const cand_fit = evaluate(candidate, cfg);
        evaluated += 1;
        if (!cand_fit.isFinite()) continue;

        const worst_idx = pool.worstIndex();
        const delta = cand_fit.score - pool.fitnesses[worst_idx].score;
        if (metropolisAccept(delta, t, &rng, cfg)) {
            pool.programs[worst_idx] = candidate;
            pool.fitnesses[worst_idx] = cand_fit;
            accepted += 1;
        }

        const current = pool.best();
        if (current.f.score > best_seen.f.score) {
            best_seen = current;
            best_iter = i + 1;
        }
    }

    return .{
        .mode = cfg.mode,
        .run_index = run_index,
        .seed = run_seed,
        .best_program = best_seen.p,
        .best_fitness = best_seen.f,
        .best_iter = best_iter,
        .accepted = accepted,
        .evaluated = evaluated,
        .edge = edgeStats(best_seen.p, cfg),
    };
}

fn runSearch(cfg: Config, run_index: usize, run_seed: u64) RunResult {
    return switch (cfg.mode) {
        .random => runRandom(cfg, run_index, run_seed),
        .anneal => runAnneal(cfg, run_index, run_seed),
        .crossover, .guided => runPoolMode(cfg, run_index, run_seed),
    };
}

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

fn printProgram(p: Program, writer: anytype) !void {
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const inst = p.instructions[i];
        try writer.print("  [{d}] r{d} = {s}(r{d}, r{d}, imm=0x{X:0>16})\n", .{
            i,
            inst.dst,
            opName(inst.op),
            inst.src1,
            inst.src2,
            inst.imm,
        });
    }
    try writer.print("  output = r{d}\n", .{NumRegs - 1});
}

fn writeArtifact(path: []const u8, p: Program, cfg: Config, result: RunResult) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) try std.fs.cwd().makePath(dir);
    }

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    const writer = file.writer();

    try writer.writeInt(u64, ArtifactMagic, .little);
    try writer.writeInt(u32, ArtifactVersion, .little);
    try writer.writeByte(p.used);
    try writer.writeByte(@intFromEnum(cfg.const_mode));
    try writer.writeByte(@intFromBool(cfg.allow_step));
    try writer.writeByte(@intFromEnum(result.mode));
    try writer.writeInt(u64, programHash(p), .little);
    try writer.writeInt(u64, result.seed, .little);
    try writer.writeInt(u64, @bitCast(result.best_fitness.base_composite), .little);
    try writer.writeInt(u64, @bitCast(result.best_fitness.score), .little);
    try writer.writeInt(u64, result.edge.zero_out, .little);
    try writer.writeInt(u64, result.edge.one_out, .little);
    try writer.writeInt(u64, result.edge.ones_out, .little);

    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const inst = p.instructions[i];
        try writer.writeByte(@intFromEnum(inst.op));
        try writer.writeByte(@intCast(inst.dst));
        try writer.writeByte(@intCast(inst.src1));
        try writer.writeByte(@intCast(inst.src2));
        try writer.writeInt(u64, inst.imm, .little);
    }
}

fn parseSearchMode(value: []const u8) !struct { mode: SearchMode, all: bool } {
    if (std.mem.eql(u8, value, "all")) return .{ .mode = .guided, .all = true };
    if (std.mem.eql(u8, value, "random")) return .{ .mode = .random, .all = false };
    if (std.mem.eql(u8, value, "anneal")) return .{ .mode = .anneal, .all = false };
    if (std.mem.eql(u8, value, "crossover")) return .{ .mode = .crossover, .all = false };
    if (std.mem.eql(u8, value, "guided")) return .{ .mode = .guided, .all = false };
    return error.InvalidMode;
}

fn parseRngMode(value: []const u8) !RngMode {
    if (std.mem.eql(u8, value, "splitmix")) return .splitmix;
    if (std.mem.eql(u8, value, "discovered")) return .discovered;
    return error.InvalidRngMode;
}

fn parseConstMode(value: []const u8) !ConstMode {
    if (std.mem.eql(u8, value, "standard")) return .standard;
    if (std.mem.eql(u8, value, "neutral")) return .neutral;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    return error.InvalidConstMode;
}

fn parseBool01(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes")) return true;
    if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "no")) return false;
    return error.InvalidBool;
}

fn parseSeed(value: []const u8) !u64 {
    if (std.mem.startsWith(u8, value, "0x") or std.mem.startsWith(u8, value, "0X")) {
        return std.fmt.parseInt(u64, value[2..], 16);
    }
    return std.fmt.parseInt(u64, value, 16) catch std.fmt.parseInt(u64, value, 10);
}

fn resultSeed(base_seed: u64, mode: SearchMode, run_index: usize) u64 {
    var x = base_seed +% (@as(u64, @intCast(run_index)) *% 0x9E3779B97F4A7C15);
    x +%= @as(u64, @intFromEnum(mode)) *% 0xD6E8FEB86659FD93;
    return splitMix64Ref(x);
}

fn writeCsvRow(writer: anytype, result: RunResult, cfg: Config, ref_fit: Fitness) !void {
    const delta = result.best_fitness.base_composite - ref_fit.base_composite;
    try writer.print("{s},{d},0x{X},{d},{d},{d},{d},{d},{s},{s},{d:.4},{d:.4},{d},{d:.4},{d:.4},{d},{d:.4},{d},{d:.4},{d:.4},{d:.4},", .{
        @tagName(result.mode),
        result.run_index,
        result.seed,
        cfg.iterations,
        cfg.pool_size,
        cfg.pool_seeds,
        cfg.max_len,
        @intFromBool(cfg.allow_step),
        @tagName(cfg.const_mode),
        @tagName(cfg.rng_mode),
        cfg.novelty_weight,
        cfg.edge_penalty_weight,
        result.best_iter,
        result.best_fitness.avalanche,
        result.best_fitness.balance,
        result.best_fitness.period,
        result.best_fitness.chisq,
        result.best_fitness.length,
        result.best_fitness.base_composite,
        result.best_fitness.novelty,
        result.best_fitness.edge_penalty,
    });
    try writer.print("{d:.4},{d:.4},{d},{d},{d:.4},{d},{d},{d},0x{X},0x{X},0x{X},0x{X},{d}\n", .{
        result.best_fitness.score,
        delta,
        result.accepted,
        result.evaluated,
        result.edge.edge_avalanche,
        result.edge.fixed_points,
        result.edge.zero_outputs,
        result.edge.unique_low16,
        result.edge.zero_out,
        result.edge.one_out,
        result.edge.ones_out,
        programHash(result.best_program),
        @intFromBool(delta > 0),
    });
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\usage: program_synthesis_v3 [options]
        \\
        \\Options:
        \\  --mode=all|random|anneal|crossover|guided
        \\  --runs=N
        \\  --iters=N
        \\  --seeds=N          random programs used to seed each run
        \\  --pool=N           champion pool capacity, max 64
        \\  --max-len=N        runtime max instructions, 4..12
        \\  --allow-step=0|1   allow SPLITMIX_STEP in searched programs
        \\  --consts=standard|neutral|minimal
        \\  --rng=splitmix|discovered
        \\  --novelty=FLOAT    adds FLOAT * novelty to search score only
        \\  --edge-penalty=FLOAT
        \\  --seed=HEX
        \\  --csv=PATH
        \\  --artifact=PATH     write best program as binary artifact
        \\
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var cfg = Config{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try printUsage(std.io.getStdOut().writer());
            return;
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            const parsed = try parseSearchMode(arg["--mode=".len..]);
            cfg.mode = parsed.mode;
            cfg.run_all_modes = parsed.all;
        } else if (std.mem.startsWith(u8, arg, "--runs=")) {
            cfg.runs = try std.fmt.parseInt(usize, arg["--runs=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--iters=")) {
            cfg.iterations = try std.fmt.parseInt(usize, arg["--iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seeds=")) {
            cfg.pool_seeds = try std.fmt.parseInt(usize, arg["--seeds=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--pool=")) {
            cfg.pool_size = try std.fmt.parseInt(usize, arg["--pool=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--max-len=")) {
            cfg.max_len = try std.fmt.parseInt(u8, arg["--max-len=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--allow-step=")) {
            cfg.allow_step = try parseBool01(arg["--allow-step=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--consts=")) {
            cfg.const_mode = try parseConstMode(arg["--consts=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--rng=")) {
            cfg.rng_mode = try parseRngMode(arg["--rng=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--novelty=")) {
            cfg.novelty_weight = try std.fmt.parseFloat(f64, arg["--novelty=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--edge-penalty=")) {
            cfg.edge_penalty_weight = try std.fmt.parseFloat(f64, arg["--edge-penalty=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            cfg.seed = try parseSeed(arg["--seed=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--csv=")) {
            cfg.csv_path = arg["--csv=".len..];
        } else if (std.mem.startsWith(u8, arg, "--artifact=")) {
            cfg.artifact_path = arg["--artifact=".len..];
        } else {
            try std.io.getStdErr().writer().print("unknown arg: {s}\n", .{arg});
            try printUsage(std.io.getStdErr().writer());
            return error.InvalidArgument;
        }
    }

    cfg.pool_size = @max(@as(usize, 1), @min(cfg.pool_size, MaxPool));
    cfg.max_len = @max(@as(u8, 4), @min(cfg.max_len, MaxProgLen));

    if (std.fs.path.dirname(cfg.csv_path)) |dir| {
        if (dir.len != 0) try std.fs.cwd().makePath(dir);
    }
    var csv = try std.fs.cwd().createFile(cfg.csv_path, .{ .truncate = true });
    defer csv.close();
    try csv.writer().writeAll("mode,run,seed,iters,pool,pool_seeds,max_len,allow_step,consts,rng,novelty_weight,edge_penalty_weight,best_iter,avalanche,balance,period,chisq,length,base_composite,novelty,quick_edge_penalty,score,delta_ref,accepted,evaluated,edge_avalanche,fixed_points,zero_outputs,unique_low16,zero_out,one_out,ones_out,program_hash,beats_ref\n");

    const stdout = std.io.getStdOut().writer();
    const ref_fit = evaluate(splitmixProgram(), cfg);
    const ref_edge = edgeStats(splitmixProgram(), cfg);
    try stdout.print("=== PROGRAM SYNTHESIS V3 A/B HARNESS ===\n", .{});
    try stdout.print("mode={s} all={d} runs={d} iters={d} pool={d} seeds={d} max_len={d} allow_step={d} consts={s} rng={s} novelty={d:.3} edge_penalty={d:.3} seed=0x{X}\n", .{
        @tagName(cfg.mode),
        @intFromBool(cfg.run_all_modes),
        cfg.runs,
        cfg.iterations,
        cfg.pool_size,
        cfg.pool_seeds,
        cfg.max_len,
        @intFromBool(cfg.allow_step),
        @tagName(cfg.const_mode),
        @tagName(cfg.rng_mode),
        cfg.novelty_weight,
        cfg.edge_penalty_weight,
        cfg.seed,
    });
    try stdout.print("reference splitMix64: base={d:.4} avalanche={d:.4} balance={d:.4} period>={d} chisq={d:.2} edge_avalanche={d:.4} fixed={d} zero_outputs={d} unique_low16={d}\n", .{
        ref_fit.base_composite,
        ref_fit.avalanche,
        ref_fit.balance,
        ref_fit.period,
        ref_fit.chisq,
        ref_edge.edge_avalanche,
        ref_edge.fixed_points,
        ref_edge.zero_outputs,
        ref_edge.unique_low16,
    });
    try stdout.writeAll("mode run | base delta_ref score av bal chisq len best_iter edge_av fixed zero unique16 hash\n");
    try stdout.writeAll("---------|-------------------------------------------------------------------------------\n");

    const modes_all = [_]SearchMode{ .random, .anneal, .crossover, .guided };
    const modes_one = [_]SearchMode{cfg.mode};
    const modes = if (cfg.run_all_modes) modes_all[0..] else modes_one[0..];

    var global_result: ?RunResult = null;
    for (modes) |mode| {
        var run: usize = 0;
        while (run < cfg.runs) : (run += 1) {
            var run_cfg = cfg;
            run_cfg.mode = mode;
            const seed = resultSeed(cfg.seed, mode, run);
            const result = runSearch(run_cfg, run, seed);
            try writeCsvRow(csv.writer(), result, run_cfg, ref_fit);

            const delta = result.best_fitness.base_composite - ref_fit.base_composite;
            try stdout.print("{s: >8} {d: >3} | {d: >7.3} {d: >9.3} {d: >7.3} {d: >5.2} {d: >5.2} {d: >6.1} {d: >3} {d: >9} {d: >7.3} {d: >5} {d: >4} {d: >8} 0x{X}\n", .{
                @tagName(result.mode),
                result.run_index,
                result.best_fitness.base_composite,
                delta,
                result.best_fitness.score,
                result.best_fitness.avalanche,
                result.best_fitness.balance,
                result.best_fitness.chisq,
                result.best_fitness.length,
                result.best_iter,
                result.edge.edge_avalanche,
                result.edge.fixed_points,
                result.edge.zero_outputs,
                result.edge.unique_low16,
                programHash(result.best_program),
            });

            if (global_result == null or result.best_fitness.base_composite > global_result.?.best_fitness.base_composite) {
                global_result = result;
            }
        }
    }

    if (global_result) |best| {
        const delta = best.best_fitness.base_composite - ref_fit.base_composite;
        try stdout.print("\n=== BEST BY BASE COMPOSITE ===\n", .{});
        try stdout.print("mode={s} run={d} seed=0x{X} base={d:.4} delta_ref={d:.4} score={d:.4} novelty={d:.4} quick_edge_penalty={d:.4}\n", .{
            @tagName(best.mode),
            best.run_index,
            best.seed,
            best.best_fitness.base_composite,
            delta,
            best.best_fitness.score,
            best.best_fitness.novelty,
            best.best_fitness.edge_penalty,
        });
        try stdout.print("avalanche={d:.4} balance={d:.4} period>={d} chisq={d:.2} length={d}\n", .{
            best.best_fitness.avalanche,
            best.best_fitness.balance,
            best.best_fitness.period,
            best.best_fitness.chisq,
            best.best_fitness.length,
        });
        try stdout.print("edge_avalanche={d:.4} fixed_points={d} zero_outputs={d} unique_low16={d}\n", .{
            best.edge.edge_avalanche,
            best.edge.fixed_points,
            best.edge.zero_outputs,
            best.edge.unique_low16,
        });
        try stdout.print("zero=0x{X:0>16} one=0x{X:0>16} ones=0x{X:0>16} hash=0x{X}\n", .{
            best.edge.zero_out,
            best.edge.one_out,
            best.edge.ones_out,
            programHash(best.best_program),
        });
        try stdout.writeAll("program:\n");
        try printProgram(best.best_program, stdout);
        if (cfg.artifact_path) |path| {
            try writeArtifact(path, best.best_program, cfg, best);
            try stdout.print("artifact: {s}\n", .{path});
        }
        if (delta > 0) {
            try stdout.print("VERDICT: best discovered program beats splitMix64 on internal base composite by {d:.4}. External battery still required.\n", .{delta});
        } else {
            try stdout.print("VERDICT: no discovered program beat splitMix64 on internal base composite. Best deficit {d:.4}.\n", .{-delta});
        }
    }
    try stdout.print("CSV: {s}\n", .{cfg.csv_path});
}
