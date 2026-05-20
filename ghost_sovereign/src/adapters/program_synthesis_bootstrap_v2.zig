const std = @import("std");

// --- PROGRAM SYNTHESIS BOOTSTRAP V2 ---
//
// Searches over short u64-mixing programs and discovers ones with good
// avalanche, balance, and period properties. The "invention" is decodable
// Zig-printable code that actually executes, not a number on a synthetic
// benchmark.
//
// Track 2 second-generation variant: the search engine's mutation/crossover
// RNG is the best first bootstrap result (seed 0x1111111111111111, composite
// 47.97), not splitMix64 and not the original Run 2 discovered mixer.
// splitMix64 remains only as a measured baseline and deterministic sample
// generator for the existing fitness function, so results stay comparable.
//
// Reference for the engine to compete with: splitMix64, a 4-instruction
// human-designed mixer used everywhere in this codebase.
//
//   z = x +% C
//   z = (z ^ (z >> 30)) *% K1
//   z = (z ^ (z >> 27)) *% K2
//   return z ^ (z >> 31)
//
// The engine searches for programs of length 4..N that match or beat
// splitMix64's fitness without seeing it. If the engine discovers a
// distinct program with comparable fitness, that is a genuine algorithm
// invention found via self-search.
//
// Runtime boundary (carried from the conceptless invention chain):
//   - std only
//   - no VSA import, no Flame import, no concept enum
//   - no model, no cloud, no network, no curated corpus
//
// Multi-objective fitness, all bias-free measurable:
//   AVALANCHE: ∑_{bit b} popcount(P(x) ^ P(x ^ (1<<b))) / (64 * 64 samples)
//             target = 32.0 (perfect bit-spread)
//   BALANCE:  popcount(P(x_i)) averaged over N inputs, target = 32
//   PERIOD:   length of orbit until first repeat when iterating from seed
//   CHISQ:    chi-square over 256 low-byte bins, lower is more uniform
//   LENGTH:   number of instructions used (shorter is better)

const NumRegs = 8;
const MaxProgLen = 12;
const FitSamples = 64;
const PeriodSamples = 4096;
const ChiSqSamples = 4096;

const Op = enum(u4) {
    XOR = 0,
    ADD = 1,
    MUL = 2, // multiply by odd immediate (avoids zero divisor)
    ROTL = 3,
    SHL_XOR = 4, // x ^= x << imm
    SHR_XOR = 5, // x ^= x >> imm
    SPLITMIX_STEP = 6, // canonical step: (x ^ (x>>30)) *% odd K
    ADD_CONST = 7, // x +% C
    AND_NOT = 8, // x &= ~y (bit-clear)
    OR_SHIFT = 9, // x |= y >> imm
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
    used: u8, // number of instructions actually used (4..MaxProgLen)

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

// --- splitMix64 reference (the human-designed mixer we measure against) ---
fn splitMix64Ref(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn splitMix64(x: u64) u64 {
    return splitMix64Ref(x);
}

// --- Fitness components ---
fn avalancheScore(p: Program) f64 {
    var total: f64 = 0;
    var samples: u64 = 0;
    var rng: u64 = 0xACE_F00D_BEEF_CAFE;
    var s: usize = 0;
    while (s < FitSamples) : (s += 1) {
        rng = splitMix64(rng);
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

fn balanceScore(p: Program) f64 {
    var total_pop: f64 = 0;
    var rng: u64 = 0x1234_5678_9ABC_DEF0;
    var n: usize = 0;
    while (n < FitSamples * 4) : (n += 1) {
        rng = splitMix64(rng);
        const y = p.execute(rng);
        total_pop += @as(f64, @floatFromInt(@popCount(y)));
    }
    return total_pop / @as(f64, @floatFromInt(FitSamples * 4));
}

fn periodEstimate(p: Program, seed: u64) usize {
    // Floyd-style cycle detection with budget.
    var x = seed;
    var i: usize = 0;
    while (i < PeriodSamples) : (i += 1) {
        x = p.execute(x);
        if (x == seed and i > 0) return i + 1;
    }
    return PeriodSamples;
}

fn chiSquareScore(p: Program) f64 {
    var bins = [_]u32{0} ** 256;
    var rng: u64 = 0xDEAD_BEEF_BAD_F00D;
    var n: usize = 0;
    while (n < ChiSqSamples) : (n += 1) {
        rng = splitMix64(rng);
        const y = p.execute(rng);
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

const Fitness = struct {
    avalanche: f64,
    balance: f64,
    period: usize,
    chisq: f64,
    length: u8,
    composite: f64,

    fn isFinite(self: Fitness) bool {
        return std.math.isFinite(self.avalanche) and std.math.isFinite(self.balance) and std.math.isFinite(self.chisq);
    }
};

fn evaluate(p: Program) Fitness {
    const av = avalancheScore(p);
    const bal = balanceScore(p);
    const per = periodEstimate(p, 0x7E57_0001);
    const cs = chiSquareScore(p);

    // Penalty terms: distance from ideal.
    const avalanche_err = @abs(av - 32.0); // perfect = 32 bits flip on avg
    const balance_err = @abs(bal - 32.0); // perfect popcount = 32
    const period_score = @as(f64, @floatFromInt(per)) / @as(f64, @floatFromInt(PeriodSamples));
    const chisq_pen = if (cs > 255.0) (cs - 255.0) / 100.0 else 0.0; // df=255, expect ~255

    // Composite: higher is better.
    const composite =
        -10.0 * avalanche_err
        - 5.0 * balance_err
        + 50.0 * period_score
        - chisq_pen
        - @as(f64, @floatFromInt(p.used)) * 0.5;

    return .{
        .avalanche = av,
        .balance = bal,
        .period = per,
        .chisq = cs,
        .length = p.used,
        .composite = composite,
    };
}

// --- Search: simulated-annealing with mutation + occasional crossover ---
fn bootstrapGen1Mix(x: u64) u64 {
    const r6 = (x ^ (x >> 32)) *% 0x9E3779B97F4A7C15;
    const r1 = (r6 ^ (r6 >> 39)) *% 0xBF58476D1CE4E5B9;
    return r1 *% 0x49DB0AB1BE88B335;
}

fn searchRngStep(x: u64) u64 {
    return bootstrapGen1Mix(x);
}

fn randomInstruction(rng: *u64) Instruction {
    rng.* = searchRngStep(rng.*);
    const op_idx: u4 = @intCast(rng.* % 10);
    rng.* = searchRngStep(rng.*);
    const dst: u3 = @intCast(rng.* % NumRegs);
    rng.* = searchRngStep(rng.*);
    const src1: u3 = @intCast(rng.* % NumRegs);
    rng.* = searchRngStep(rng.*);
    const src2: u3 = @intCast(rng.* % NumRegs);
    rng.* = searchRngStep(rng.*);
    return .{
        .op = @enumFromInt(op_idx),
        .dst = dst,
        .src1 = src1,
        .src2 = src2,
        .imm = rng.*,
    };
}

fn randomProgram(rng: *u64) Program {
    rng.* = searchRngStep(rng.*);
    const len: u8 = @intCast(4 + (rng.* % (MaxProgLen - 4)));
    var p = Program{ .instructions = undefined, .used = len };
    var i: usize = 0;
    while (i < len) : (i += 1) {
        p.instructions[i] = randomInstruction(rng);
    }
    // Ensure last instruction writes to output register (NumRegs - 1)
    p.instructions[len - 1].dst = NumRegs - 1;
    return p;
}

fn mutate(p: Program, rng: *u64) Program {
    var q = p;
    rng.* = searchRngStep(rng.*);
    const mode = rng.* % 16;
    if (mode < 10) {
        // Point mutation: change one instruction
        rng.* = searchRngStep(rng.*);
        const idx = @as(usize, @intCast(rng.* % q.used));
        q.instructions[idx] = randomInstruction(rng);
        // Keep last instruction writing to output
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else if (mode < 13 and q.used < MaxProgLen) {
        // Insert: add an instruction
        rng.* = searchRngStep(rng.*);
        const idx = @as(usize, @intCast(rng.* % (q.used + 1)));
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.instructions[i] = q.instructions[i - 1];
        q.instructions[idx] = randomInstruction(rng);
        q.used += 1;
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else if (q.used > 4) {
        // Delete: remove an instruction
        rng.* = searchRngStep(rng.*);
        const idx = @as(usize, @intCast(rng.* % q.used));
        var i: usize = idx;
        while (i < q.used - 1) : (i += 1) q.instructions[i] = q.instructions[i + 1];
        q.used -= 1;
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else {
        // Fallback: tweak immediate of random instruction
        rng.* = searchRngStep(rng.*);
        const idx = @as(usize, @intCast(rng.* % q.used));
        rng.* = searchRngStep(rng.*);
        q.instructions[idx].imm = rng.*;
    }
    return q;
}

fn crossover(a: Program, b: Program, rng: *u64) Program {
    rng.* = searchRngStep(rng.*);
    const min_len = @min(a.used, b.used);
    if (min_len < 4) return a;
    const cut = @as(usize, @intCast(rng.* % min_len));
    var q = a;
    var i = cut;
    while (i < b.used and i < MaxProgLen) : (i += 1) {
        q.instructions[i] = b.instructions[i];
    }
    q.used = b.used;
    q.instructions[q.used - 1].dst = NumRegs - 1;
    return q;
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
            i, inst.dst, opName(inst.op), inst.src1, inst.src2, inst.imm,
        });
    }
    try writer.print("  output = r{d}\n", .{NumRegs - 1});
}

const ChampionPool = struct {
    programs: [8]Program,
    fitnesses: [8]Fitness,
    count: usize = 0,

    fn consider(self: *@This(), p: Program, f: Fitness) bool {
        if (self.count < self.programs.len) {
            self.programs[self.count] = p;
            self.fitnesses[self.count] = f;
            self.count += 1;
            return true;
        }
        // Find worst in pool
        var worst: usize = 0;
        for (1..self.count) |i| if (self.fitnesses[i].composite < self.fitnesses[worst].composite) {
            worst = i;
        };
        if (f.composite > self.fitnesses[worst].composite) {
            self.programs[worst] = p;
            self.fitnesses[worst] = f;
            return true;
        }
        return false;
    }

    fn best(self: *const @This()) struct { p: Program, f: Fitness } {
        var b: usize = 0;
        for (1..self.count) |i| if (self.fitnesses[i].composite > self.fitnesses[b].composite) {
            b = i;
        };
        return .{ .p = self.programs[b], .f = self.fitnesses[b] };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var iterations: usize = 6000;
    var pool_seeds: usize = 64;
    var rng_seed: u64 = 0xC0FFEEBABEF00D12;
    var csv_path: []const u8 = "results/program_synthesis_bootstrap_v2.csv";

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--iters=")) iterations = try std.fmt.parseInt(usize, arg["--iters=".len..], 10) else if (std.mem.startsWith(u8, arg, "--seeds=")) pool_seeds = try std.fmt.parseInt(usize, arg["--seeds=".len..], 10) else if (std.mem.startsWith(u8, arg, "--seed=")) rng_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16) else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..];
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== PROGRAM SYNTHESIS BOOTSTRAP V2 ===\n", .{});
    try stdout.print("search_rng=bootstrap_gen1_mix baseline=splitMix64\n", .{});
    try stdout.print("iterations={d} pool_seeds={d} rng_seed=0x{X}\n\n", .{ iterations, pool_seeds, rng_seed });

    // Reference: hand-coded splitMix64 inside the program language.
    // Used purely as a baseline comparison; not seen by the search.
    const splitmix_prog = Program{
        .instructions = [_]Instruction{
            .{ .op = .ADD_CONST, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0x9E3779B97F4A7C15 }, // r0 += C
            .{ .op = .SHR_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 30 }, // r0 ^= r0 >> 30
            .{ .op = .MUL, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0xBF58476D1CE4E5B9 }, // r0 *= K1
            .{ .op = .SHR_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 27 }, // r0 ^= r0 >> 27
            .{ .op = .MUL, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0x94D049BB133111EB }, // r0 *= K2
            .{ .op = .SHR_XOR, .dst = 7, .src1 = 0, .src2 = 0, .imm = 31 }, // r7 = r0 ^ (r0 >> 31)
        } ++ [_]Instruction{.{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0 }} ** (MaxProgLen - 6),
        .used = 6,
    };
    const ref_fit = evaluate(splitmix_prog);
    try stdout.print("REFERENCE (splitMix64, hand-coded, used={d} instructions):\n", .{splitmix_prog.used});
    try stdout.print("  avalanche={d:.4} balance={d:.4} period>={d} chisq={d:.2} composite={d:.2}\n\n", .{
        ref_fit.avalanche, ref_fit.balance, ref_fit.period, ref_fit.chisq, ref_fit.composite,
    });

    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var csv = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv.close();
    try csv.writer().writeAll("iter,best_avalanche,best_balance,best_period,best_chisq,best_length,best_composite,accepted,beats_ref\n");

    var pool = ChampionPool{ .programs = undefined, .fitnesses = undefined };
    var rng = rng_seed;

    // Seed pool with random programs (no human design)
    var s: usize = 0;
    while (s < pool_seeds) : (s += 1) {
        const p = randomProgram(&rng);
        const f = evaluate(p);
        if (!f.isFinite()) continue;
        _ = pool.consider(p, f);
    }

    var best_seen = pool.best();
    try stdout.print("Initial best of {d} random programs: composite={d:.2} avalanche={d:.3}\n\n", .{ pool.count, best_seen.f.composite, best_seen.f.avalanche });

    try stdout.writeAll("iter | composite | avalanche | balance | period | chisq | length | beats_ref?\n");
    try stdout.writeAll("-----|-----------|-----------|---------|--------|-------|--------|------------\n");

    var accepted_count: usize = 0;
    var beats_ref_count: usize = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const t_progress = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(iterations));
        const t = 8.0 * std.math.pow(f64, 0.001, t_progress);

        // Pick a parent from the pool
        rng = searchRngStep(rng);
        const parent_idx = @as(usize, @intCast(rng % pool.count));
        const parent = pool.programs[parent_idx];

        // Mutate or crossover
        rng = searchRngStep(rng);
        const candidate: Program = if ((rng & 3) == 0 and pool.count > 1) blk: {
            rng = searchRngStep(rng);
            const other_idx = @as(usize, @intCast(rng % pool.count));
            break :blk crossover(parent, pool.programs[other_idx], &rng);
        } else mutate(parent, &rng);

        const cand_fit = evaluate(candidate);
        if (!cand_fit.isFinite()) continue;

        // Metropolis acceptance vs pool's current worst
        var worst_idx: usize = 0;
        for (1..pool.count) |k| if (pool.fitnesses[k].composite < pool.fitnesses[worst_idx].composite) {
            worst_idx = k;
        };
        const delta = cand_fit.composite - pool.fitnesses[worst_idx].composite;
        var accept = false;
        if (delta >= 0) {
            accept = true;
        } else {
            rng = searchRngStep(rng);
            const draw = @as(f64, @floatFromInt(rng % 1_000_000)) / 1_000_000.0;
            accept = draw < std.math.exp(delta / t);
        }
        if (accept) {
            pool.programs[worst_idx] = candidate;
            pool.fitnesses[worst_idx] = cand_fit;
            accepted_count += 1;
        }

        const current = pool.best();
        if (current.f.composite > best_seen.f.composite) best_seen = current;
        const beats_ref = best_seen.f.composite > ref_fit.composite;
        if (beats_ref) beats_ref_count += 1;

        if ((i + 1) % 200 == 0 or i == 0) {
            try stdout.print("{d: >4} | {d: >9.2} | {d: >9.3} | {d: >7.3} | {d: >6} | {d: >5.0} | {d: >6} | {s}\n", .{
                i + 1, best_seen.f.composite, best_seen.f.avalanche, best_seen.f.balance, best_seen.f.period, best_seen.f.chisq, best_seen.f.length, if (beats_ref) "YES" else "no",
            });
        }
        try csv.writer().print("{d},{d:.4},{d:.4},{d},{d:.4},{d},{d:.4},{d},{d}\n", .{
            i, best_seen.f.avalanche, best_seen.f.balance, best_seen.f.period, best_seen.f.chisq, best_seen.f.length, best_seen.f.composite, accepted_count, @intFromBool(beats_ref),
        });
    }

    const final = pool.best();
    try stdout.print("\n=== FINAL DISCOVERED PROGRAM ===\n", .{});
    try stdout.print("avalanche={d:.4} balance={d:.4} period>={d} chisq={d:.2} length={d} composite={d:.2}\n", .{
        final.f.avalanche, final.f.balance, final.f.period, final.f.chisq, final.f.length, final.f.composite,
    });
    try stdout.print("vs REFERENCE splitMix64: avalanche={d:.4} balance={d:.4} period>={d} chisq={d:.2} length={d} composite={d:.2}\n\n", .{
        ref_fit.avalanche, ref_fit.balance, ref_fit.period, ref_fit.chisq, ref_fit.length, ref_fit.composite,
    });
    try stdout.writeAll("Discovered program (decodable code):\n");
    try printProgram(final.p, stdout);

    try stdout.print("\nAccepted {d} mutations out of {d} attempts ({d:.1}%)\n", .{
        accepted_count, iterations, 100.0 * @as(f64, @floatFromInt(accepted_count)) / @as(f64, @floatFromInt(iterations)),
    });
    if (final.f.composite > ref_fit.composite) {
        try stdout.print("\nVERDICT: discovered program OUTSCORES splitMix64 reference by {d:.2} composite points.\n", .{final.f.composite - ref_fit.composite});
    } else {
        try stdout.print("\nVERDICT: discovered program scores {d:.2} below splitMix64 reference. Real but not yet competitive.\n", .{ref_fit.composite - final.f.composite});
    }
    try stdout.print("CSV trajectory: {s}\n", .{csv_path});
}
