const std = @import("std");

// --- BIT-TAPE MACHINE substrate (2026-05-22) ---
//
// Non-remix substrate: 256-bit state, 3 irreducible Boolean primitives
// only. No human-named compound ops (no SPLITMIX_STEP, no MUM, no
// ADD_ROT, no MUL, no ROTL even — those are all human inventions).
// The instruction set is {XOR, AND, NOT} which is the minimal universal
// Boolean basis. Programs are 256-instruction sequences.
//
// Execution:
//   state := [4]u64 with state[0] = input, state[1..3] = 0
//   for each instruction in program:
//     read bits[src1], bits[src2] from state
//     compute result bit per op (XOR / AND / NOT)
//     write to bits[dst] in state
//   output := state[0] (low 64 bits)
//
// The engine has NO mixer pattern encoded in any single op. Any
// "alien" structure that emerges comes from the evolutionary search
// composing irreducible primitives — not from remixing human-designed
// macro primitives.

pub const DOMAIN_NAME: []const u8 = "bit-tape-machine/u64-output";

pub const StateBits = 256;
pub const StateWords = 4; // 256 / 64
pub const MaxProgLen: u16 = 384;
pub const MinProgLen: u16 = 96;

pub const Op = enum(u2) {
    XOR = 0,
    AND = 1,
    NOT = 2,
    // 3 is unused — keeping u2 to encode densely.
};

pub const Instr = packed struct {
    op: u2,
    dst: u8, // 0..255 bit index
    src1: u8,
    src2: u8, // unused for NOT
    _pad: u6 = 0,

    pub fn eq(a: Instr, b: Instr) bool {
        return a.op == b.op and a.dst == b.dst and a.src1 == b.src1 and a.src2 == b.src2;
    }
};

pub const Program = struct {
    instructions: [MaxProgLen]Instr,
    used: u16,

    pub fn execute(self: Program, input: u64) u64 {
        var state: [StateWords]u64 = .{ input, 0, 0, 0 };
        var i: usize = 0;
        while (i < self.used) : (i += 1) {
            const ins = self.instructions[i];
            const dst_word: u8 = ins.dst >> 6;
            const dst_bit: u6 = @intCast(ins.dst & 63);
            const src1_word: u8 = ins.src1 >> 6;
            const src1_bit: u6 = @intCast(ins.src1 & 63);
            const src2_word: u8 = ins.src2 >> 6;
            const src2_bit: u6 = @intCast(ins.src2 & 63);

            const b1: u64 = (state[src1_word] >> src1_bit) & 1;
            const b2: u64 = (state[src2_word] >> src2_bit) & 1;

            const result: u64 = switch (@as(Op, @enumFromInt(ins.op))) {
                .XOR => b1 ^ b2,
                .AND => b1 & b2,
                .NOT => 1 - b1,
            };

            state[dst_word] = (state[dst_word] & ~(@as(u64, 1) << dst_bit)) | (result << dst_bit);
        }
        return state[0];
    }
};

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub fn randomInstr(rng: *u64) Instr {
    rng.* = smix(rng.*);
    const op_raw: u2 = @intCast(rng.* % 3);
    rng.* = smix(rng.*);
    const dst: u8 = @intCast(rng.* % StateBits);
    rng.* = smix(rng.*);
    const src1: u8 = @intCast(rng.* % StateBits);
    rng.* = smix(rng.*);
    const src2: u8 = @intCast(rng.* % StateBits);
    return .{ .op = op_raw, .dst = dst, .src1 = src1, .src2 = src2 };
}

pub fn randomProgram(rng: *u64) Program {
    rng.* = smix(rng.*);
    const len_range: u64 = MaxProgLen - MinProgLen;
    const used: u16 = @intCast(MinProgLen + (rng.* % len_range));
    var p = Program{ .instructions = undefined, .used = used };
    var i: usize = 0;
    while (i < used) : (i += 1) p.instructions[i] = randomInstr(rng);
    return p;
}

pub fn mutate(p: Program, rng: *u64) Program {
    var q = p;
    rng.* = smix(rng.*);
    const mode = rng.* % 10;
    if (mode < 7) {
        // Point mutation: replace one instruction.
        rng.* = smix(rng.*);
        const idx: usize = rng.* % q.used;
        q.instructions[idx] = randomInstr(rng);
    } else if (mode < 9 and q.used < MaxProgLen) {
        // Insert an instruction.
        rng.* = smix(rng.*);
        const idx: usize = rng.* % (q.used + 1);
        var j = q.used;
        while (j > idx) : (j -= 1) q.instructions[j] = q.instructions[j - 1];
        q.instructions[idx] = randomInstr(rng);
        q.used += 1;
    } else if (q.used > MinProgLen) {
        // Delete an instruction.
        rng.* = smix(rng.*);
        const idx: usize = rng.* % q.used;
        var j: usize = idx;
        while (j < q.used - 1) : (j += 1) q.instructions[j] = q.instructions[j + 1];
        q.used -= 1;
    } else {
        // Fallback: point mutation.
        rng.* = smix(rng.*);
        const idx: usize = rng.* % q.used;
        q.instructions[idx] = randomInstr(rng);
    }
    return q;
}

pub fn crossover(a: Program, b: Program, rng: *u64) Program {
    rng.* = smix(rng.*);
    const min_used: u16 = @min(a.used, b.used);
    const cut: u16 = @intCast(rng.* % min_used);
    var q: Program = a;
    var i: usize = cut;
    while (i < q.used and i < b.used) : (i += 1) {
        q.instructions[i] = b.instructions[i];
    }
    return q;
}

// --- Fitness: classical mixer composite, on the bit-tape substrate ---
//
// Same metrics as domain_u64_mixer.zig (avalanche, balance, period,
// chi-square) so we can compare to splitMix64-shaped programs on a
// common axis. The substrate is what's different — bit-tape has no
// human-mixer macro ops, so any quality it achieves comes from
// emergent composition, not from invoking SPLITMIX_STEP / MUM / MUL.

pub const FitSamples = 16;
pub const PeriodSamples = 1024;
pub const ChiSqSamples = 1024;
pub const BalanceSamples = 128;

pub const Quality = struct {
    avalanche: f64,
    balance: f64,
    period: usize,
    chisq: f64,
    composite: f64,
};

fn avalanche(p: Program) f64 {
    var total: f64 = 0;
    var samples: u64 = 0;
    var rng: u64 = 0xACE_F00D_BEEF_CAFE;
    var s: usize = 0;
    while (s < FitSamples) : (s += 1) {
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

fn balanceFn(p: Program) f64 {
    var t: f64 = 0;
    var rng: u64 = 0x1234_5678_9ABC_DEF0;
    var n: usize = 0;
    while (n < BalanceSamples) : (n += 1) {
        rng = smix(rng);
        t += @as(f64, @floatFromInt(@popCount(p.execute(rng))));
    }
    return t / @as(f64, @floatFromInt(BalanceSamples));
}

fn periodEst(p: Program, seed: u64) usize {
    var x = seed;
    var i: usize = 0;
    while (i < PeriodSamples) : (i += 1) {
        x = p.execute(x);
        if (x == seed and i > 0) return i + 1;
    }
    return PeriodSamples;
}

fn chiSqFn(p: Program) f64 {
    var bins = [_]u32{0} ** 256;
    var rng: u64 = 0xDEAD_BEEF_BAD_F00D;
    var n: usize = 0;
    while (n < ChiSqSamples) : (n += 1) {
        rng = smix(rng);
        bins[@intCast(p.execute(rng) & 0xFF)] += 1;
    }
    const expected = @as(f64, @floatFromInt(ChiSqSamples)) / 256.0;
    var cs: f64 = 0;
    for (bins) |c| {
        const d = @as(f64, @floatFromInt(c)) - expected;
        cs += (d * d) / expected;
    }
    return cs;
}

pub fn evaluateQuality(p: Program) Quality {
    const av = avalanche(p);
    const bal = balanceFn(p);
    const per = periodEst(p, 0x7E57_0001);
    const cs = chiSqFn(p);
    const av_err = @abs(av - @as(f64, 32.0));
    const bal_err = @abs(bal - @as(f64, 32.0));
    const per_s = @as(f64, @floatFromInt(per)) / @as(f64, @floatFromInt(PeriodSamples));
    const cs_pen = if (cs > @as(f64, 255.0)) (cs - @as(f64, 255.0)) / @as(f64, 100.0) else @as(f64, 0.0);
    const composite = @as(f64, -10.0) * av_err - @as(f64, 5.0) * bal_err + @as(f64, 50.0) * per_s - cs_pen;
    return .{ .avalanche = av, .balance = bal, .period = per, .chisq = cs, .composite = composite };
}

pub fn qualityScalar(q: Quality) f64 {
    return q.composite;
}

pub fn opName(op: u2) []const u8 {
    return switch (@as(Op, @enumFromInt(op))) {
        .XOR => "XOR",
        .AND => "AND",
        .NOT => "NOT",
    };
}

pub fn programToCsv(p: Program, writer: anytype) !void {
    try writer.writeAll("idx,op_id,op_name,dst,src1,src2\n");
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const ins = p.instructions[i];
        try writer.print("{d},{d},{s},{d},{d},{d}\n", .{
            i, ins.op, opName(ins.op), ins.dst, ins.src1, ins.src2,
        });
    }
}
