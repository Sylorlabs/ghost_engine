const std = @import("std");
const engine = @import("invention_engine.zig");

// --- DOMAIN: u64 mixer ---
//
// Spec-conforming module for the generic invention engine. The program
// language is the 10-op u64 instruction set from program_synthesis_inventor.
// Quality is mixer fitness (avalanche, balance, chi-square, period).
// Library is the canonical u64 mixer set (splitMix64, Murmur, xorshift, Wang).
// Divergence axis: FUNCTIONAL (bit_agreement of P(x) vs Q(x)).
// Reachability: functional similarity to depth ≤ 3 composition of library mixers.

pub const DOMAIN_NAME: []const u8 = "u64-mixer";

const NumRegs = 8;
const MaxProgLen = 12;
const FitSamples = 64;
const PeriodSamples = 4096;
const ChiSqSamples = 4096;
const BalanceSamples = 256;
const FuncSamples = 1024;

const Op = enum(u4) {
    XOR = 0, ADD = 1, MUL = 2, ROTL = 3, SHL_XOR = 4, SHR_XOR = 5,
    SPLITMIX_STEP = 6, ADD_CONST = 7, AND_NOT = 8, OR_SHIFT = 9,
    // CALL_LIB(imm) executes chain_extras[imm % chain_extras.len] on
    // regs[src1]. When chain_extras is empty, randomInstr never emits
    // CALL_LIB and execute treats it as a pass-through. This is the
    // successor-engine mechanism: gen n+1's search composes prior
    // champions as atomic operators, not just as gate constraints.
    CALL_LIB = 10,
};

pub const MaxChainExtras: usize = 16;
pub var chain_extras: std.BoundedArray(Program, MaxChainExtras) = .{ .buffer = undefined, .len = 0 };

// CALL_LIB recursion bound. SA produces programs with multiple CALL_LIB
// ops; combined with deep chains, the worst-case nested execute() can
// blow the stack. 8 levels is more than enough for legitimate
// composition (gen=5 chain max depth 5) but blocks runaway recursion
// from pathological discovered programs.
const MaxCallLibDepth: u32 = 8;
threadlocal var call_lib_depth: u32 = 0;

pub fn chainExtrasReset() void {
    chain_extras.len = 0;
}

pub fn chainExtrasAppend(p: Program) !void {
    try chain_extras.append(p);
}

pub fn chainExtrasLen() usize {
    return chain_extras.len;
}

const Instruction = struct {
    op: Op, dst: u3, src1: u3, src2: u3, imm: u64,
    fn eq(a: Instruction, b: Instruction) bool {
        return a.op == b.op and a.dst == b.dst and a.src1 == b.src1 and a.src2 == b.src2 and a.imm == b.imm;
    }
};

pub const Program = struct {
    instructions: [MaxProgLen]Instruction,
    used: u8,

    pub fn execute(self: Program, input: u64) u64 {
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
                .CALL_LIB => blk: {
                    // Defensive: empty chain_extras => pass-through.
                    // Recursion guard: past MaxCallLibDepth, also pass
                    // through. Without this the chain segfaults at gen 2.
                    if (chain_extras.len == 0) break :blk a;
                    if (call_lib_depth >= MaxCallLibDepth) break :blk a;
                    call_lib_depth += 1;
                    defer call_lib_depth -= 1;
                    const idx: usize = @intCast(inst.imm % chain_extras.len);
                    break :blk chain_extras.buffer[idx].execute(a);
                },
            };
            regs[inst.dst] = result;
        }
        return regs[NumRegs - 1];
    }
};

pub const Quality = struct {
    avalanche: f64,
    balance: f64,
    period: usize,
    chisq: f64,
    composite: f64,
};

const AvalancheLo: f64 = 30.0;
const AvalancheHi: f64 = 34.0;
const BalanceLo: f64 = 30.0;
const BalanceHi: f64 = 34.0;
const ChiSqMax: f64 = 400.0;
const PeriodMin: usize = 4096;

fn avalanche(p: Program) f64 {
    var total: f64 = 0;
    var samples: u64 = 0;
    var rng: u64 = 0xACE_F00D_BEEF_CAFE;
    var s: usize = 0;
    while (s < FitSamples) : (s += 1) {
        rng = engine.smix(rng);
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
        rng = engine.smix(rng);
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
        rng = engine.smix(rng);
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
    const av_err = @abs(av - 32.0);
    const bal_err = @abs(bal - 32.0);
    const per_s = @as(f64, @floatFromInt(per)) / @as(f64, @floatFromInt(PeriodSamples));
    const cs_pen = if (cs > 255.0) (cs - 255.0) / 100.0 else 0.0;
    const composite = -10.0 * av_err - 5.0 * bal_err + 50.0 * per_s - cs_pen - @as(f64, @floatFromInt(p.used)) * 0.5;
    return .{ .avalanche = av, .balance = bal, .period = per, .chisq = cs, .composite = composite };
}

pub fn qualityScalar(q: Quality) f64 {
    return q.composite;
}

pub fn qualityPasses(q: Quality) bool {
    return q.avalanche >= AvalancheLo and q.avalanche <= AvalancheHi
        and q.balance >= BalanceLo and q.balance <= BalanceHi
        and q.chisq <= ChiSqMax and q.period >= PeriodMin;
}

pub fn isFinite(q: Quality) bool {
    return std.math.isFinite(q.avalanche) and std.math.isFinite(q.balance) and std.math.isFinite(q.chisq);
}

// --- Library ---
fn libSplitMix64() Program {
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

fn libMurmur() Program {
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

fn libXorshift() Program {
    return Program{
        .instructions = [_]Instruction{
            .{ .op = .SHL_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 13 },
            .{ .op = .SHR_XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 7 },
            .{ .op = .SHL_XOR, .dst = 7, .src1 = 0, .src2 = 0, .imm = 17 },
        } ++ [_]Instruction{.{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0 }} ** (MaxProgLen - 3),
        .used = 3,
    };
}

fn libWang() Program {
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

const LibEntry = struct { name: []const u8, program: Program };
fn library() [4]LibEntry {
    return .{
        .{ .name = "splitMix64", .program = libSplitMix64() },
        .{ .name = "Murmur", .program = libMurmur() },
        .{ .name = "xorshift", .program = libXorshift() },
        .{ .name = "Wang", .program = libWang() },
    };
}

// --- Distance ---
pub const DistanceResult = struct {
    closest_name: []const u8,
    min_edit: usize,
    norm_edit: f64,
    best_bit_agreement: f64,
    best_exact: f64,
    closest_by_bits: []const u8,
};

fn editDistance(a: Program, b: Program, allocator: std.mem.Allocator) !usize {
    const la = a.used; const lb = b.used;
    const cols = lb + 1;
    const dp = try allocator.alloc(usize, (la + 1) * cols);
    defer allocator.free(dp);
    var i: usize = 0;
    while (i <= la) : (i += 1) dp[i * cols + 0] = i;
    var j: usize = 0;
    while (j <= lb) : (j += 1) dp[0 * cols + j] = j;
    i = 1;
    while (i <= la) : (i += 1) {
        var jj: usize = 1;
        while (jj <= lb) : (jj += 1) {
            const sub: usize = if (a.instructions[i - 1].eq(b.instructions[jj - 1])) 0 else 1;
            const v_sub = dp[(i - 1) * cols + (jj - 1)] + sub;
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

fn functionalSim(p: Program, q: Program) struct { bits: f64, exact: f64 } {
    var exact: u64 = 0;
    var total: u64 = 0;
    var rng: u64 = 0xDEAD_BEEF_5EED_C0DE;
    var i: usize = 0;
    while (i < FuncSamples) : (i += 1) {
        rng = engine.smix(rng);
        const yp = p.execute(rng);
        const yq = q.execute(rng);
        if (yp == yq) exact += 1;
        total += @as(u64, 64) - @popCount(yp ^ yq);
    }
    return .{
        .bits = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(FuncSamples)) * 64.0),
        .exact = @as(f64, @floatFromInt(exact)) / @as(f64, @floatFromInt(FuncSamples)),
    };
}

pub fn distanceToLibrary(p: Program, allocator: std.mem.Allocator) !DistanceResult {
    const lib = library();
    var min_ed: usize = std.math.maxInt(usize);
    var min_idx: usize = 0;
    var best_bits: f64 = 0;
    var best_bits_idx: usize = 0;
    var best_exact: f64 = 0;
    for (lib, 0..) |entry, idx| {
        const ed = try editDistance(p, entry.program, allocator);
        const fs = functionalSim(p, entry.program);
        if (ed < min_ed) { min_ed = ed; min_idx = idx; }
        if (fs.bits > best_bits) { best_bits = fs.bits; best_bits_idx = idx; }
        if (fs.exact > best_exact) best_exact = fs.exact;
    }
    const max_len = @max(p.used, lib[min_idx].program.used);
    return .{
        .closest_name = lib[min_idx].name,
        .min_edit = min_ed,
        .norm_edit = @as(f64, @floatFromInt(min_ed)) / @as(f64, @floatFromInt(max_len)),
        .best_bit_agreement = best_bits,
        .best_exact = best_exact,
        .closest_by_bits = lib[best_bits_idx].name,
    };
}

pub fn isEquivalent(d: DistanceResult) bool { return d.best_exact >= 0.99; }
pub fn isTrivialVariant(d: DistanceResult) bool { return d.min_edit <= 1; }
pub fn isRemix(d: DistanceResult) bool {
    return d.norm_edit <= 0.34 or d.best_bit_agreement >= 0.75;
}

// --- Reachability via depth ≤ 3 functional composition ---
pub const ReachabilityResult = struct {
    best_bit_agreement: f64,
    best_depth: usize,
    reachable: bool,
};
const MaxCompositionDepth: usize = 3;
const ReachThreshold: f64 = 0.95;

pub fn reachability(p: Program, allocator: std.mem.Allocator) !ReachabilityResult {
    _ = allocator;
    const lib = library();
    var best: ReachabilityResult = .{ .best_bit_agreement = 0, .best_depth = 0, .reachable = false };
    var depth: usize = 1;
    while (depth <= MaxCompositionDepth) : (depth += 1) {
        const total = std.math.pow(usize, lib.len, depth);
        var n: usize = 0;
        while (n < total) : (n += 1) {
            var path: [MaxCompositionDepth]usize = .{0} ** MaxCompositionDepth;
            var t = n; var i: usize = 0;
            while (i < depth) : (i += 1) { path[i] = t % lib.len; t /= lib.len; }
            var bits: u64 = 0;
            var rng: u64 = 0xDEAD_BEEF_5EED_C0DE;
            var s: usize = 0;
            while (s < FuncSamples) : (s += 1) {
                rng = engine.smix(rng);
                const yp = p.execute(rng);
                var yc = rng;
                var k: usize = 0;
                while (k < depth) : (k += 1) yc = lib[path[k]].program.execute(yc);
                bits += @as(u64, 64) - @popCount(yp ^ yc);
            }
            const score = @as(f64, @floatFromInt(bits)) / (@as(f64, @floatFromInt(FuncSamples)) * 64.0);
            if (score > best.best_bit_agreement) {
                best.best_bit_agreement = score;
                best.best_depth = depth;
            }
        }
    }
    best.reachable = best.best_bit_agreement >= ReachThreshold;
    return best;
}

pub fn isReachable(r: ReachabilityResult) bool { return r.reachable; }

// --- Mutation / crossover / random init ---
fn randomInstr(rng: *u64) Instruction {
    rng.* = engine.smix(rng.*);
    // Expand op range to include CALL_LIB only when chain_extras is
    // populated. Keeps base general_inventor behavior unchanged.
    const n_ops: u64 = if (chain_extras.len > 0) 11 else 10;
    const op_idx: u4 = @intCast(rng.* % n_ops);
    rng.* = engine.smix(rng.*);
    const dst: u3 = @intCast(rng.* % NumRegs);
    rng.* = engine.smix(rng.*);
    const src1: u3 = @intCast(rng.* % NumRegs);
    rng.* = engine.smix(rng.*);
    const src2: u3 = @intCast(rng.* % NumRegs);
    rng.* = engine.smix(rng.*);
    return .{ .op = @enumFromInt(op_idx), .dst = dst, .src1 = src1, .src2 = src2, .imm = rng.* };
}

pub fn randomProgram(rng: *u64) Program {
    rng.* = engine.smix(rng.*);
    const len: u8 = @intCast(4 + (rng.* % (MaxProgLen - 4)));
    var p = Program{ .instructions = undefined, .used = len };
    var i: usize = 0;
    while (i < len) : (i += 1) p.instructions[i] = randomInstr(rng);
    p.instructions[len - 1].dst = NumRegs - 1;
    return p;
}

pub fn mutate(p: Program, rng: *u64) Program {
    var q = p;
    rng.* = engine.smix(rng.*);
    const mode = rng.* % 16;
    if (mode < 10) {
        rng.* = engine.smix(rng.*);
        const idx: usize = rng.* % q.used;
        q.instructions[idx] = randomInstr(rng);
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else if (mode < 13 and q.used < MaxProgLen) {
        rng.* = engine.smix(rng.*);
        const idx: usize = rng.* % (q.used + 1);
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.instructions[i] = q.instructions[i - 1];
        q.instructions[idx] = randomInstr(rng);
        q.used += 1;
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else if (q.used > 4) {
        rng.* = engine.smix(rng.*);
        const idx: usize = rng.* % q.used;
        var i: usize = idx;
        while (i < q.used - 1) : (i += 1) q.instructions[i] = q.instructions[i + 1];
        q.used -= 1;
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else {
        rng.* = engine.smix(rng.*);
        const idx: usize = rng.* % q.used;
        rng.* = engine.smix(rng.*);
        q.instructions[idx].imm = rng.*;
    }
    return q;
}

pub fn crossover(a: Program, b: Program, rng: *u64) Program {
    rng.* = engine.smix(rng.*);
    const min_len = @min(a.used, b.used);
    if (min_len < 4) return a;
    const cut: usize = rng.* % min_len;
    var q = a;
    var i: usize = cut;
    while (i < b.used and i < MaxProgLen) : (i += 1) q.instructions[i] = b.instructions[i];
    q.used = b.used;
    q.instructions[q.used - 1].dst = NumRegs - 1;
    return q;
}

fn opName(op: Op) []const u8 {
    return switch (op) {
        .XOR => "XOR", .ADD => "ADD", .MUL => "MUL", .ROTL => "ROTL",
        .SHL_XOR => "SHL_XOR", .SHR_XOR => "SHR_XOR", .SPLITMIX_STEP => "SPLITMIX_STEP",
        .ADD_CONST => "ADD_CONST", .AND_NOT => "AND_NOT", .OR_SHIFT => "OR_SHIFT",
        .CALL_LIB => "CALL_LIB",
    };
}

pub fn printProgram(p: Program, writer: anytype) !void {
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const inst = p.instructions[i];
        try writer.print("  [{d}] r{d} = {s}(r{d}, r{d}, imm=0x{X:0>16})\n", .{
            i, inst.dst, opName(inst.op), inst.src1, inst.src2, inst.imm,
        });
    }
}

pub fn programToCsv(p: Program, writer: anytype) !void {
    try writer.writeAll("idx,op_id,op_name,dst,src1,src2,imm_hex,used_len\n");
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const inst = p.instructions[i];
        try writer.print("{d},{d},{s},{d},{d},{d},0x{X:0>16},{d}\n", .{
            i, @intFromEnum(inst.op), opName(inst.op), inst.dst, inst.src1, inst.src2, inst.imm, p.used,
        });
    }
}
