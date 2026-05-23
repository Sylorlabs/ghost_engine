const std = @import("std");
const engine = @import("invention_engine.zig");

pub const DOMAIN_NAME: []const u8 = "u64-mixer-mul-free";

pub const NumRegs = 8;
pub const MaxProgLen = 24;
const MinProgLen = 4;
const FitSamples = 64;
const PeriodSamples = 4096;
const ChiSqSamples = 4096;
const BalanceSamples = 256;

pub const MulFreeMode = enum {
    mul_free,
    no_carry,
    unrestricted,
};

pub const Op = enum(u4) {
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
    CALL_LIB = 10,
    ROTR = 11,
    BSWAP = 12,
    MUM = 13,
    ADD_ROT = 14,
};

pub const Instruction = struct {
    op: Op,
    dst: u3,
    src1: u3,
    src2: u3,
    imm: u64,
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
                .ROTL => std.math.rotl(u64, a, shift63(inst.imm)),
                .SHL_XOR => a ^ (a << shift63(inst.imm)),
                .SHR_XOR => a ^ (a >> shift63(inst.imm)),
                .SPLITMIX_STEP => (a ^ (a >> @as(u6, @intCast(inst.imm % 32 + 16)))) *% (b | 1),
                .ADD_CONST => a +% inst.imm,
                .AND_NOT => a & ~b,
                .OR_SHIFT => a | (b >> shift63(inst.imm)),
                .CALL_LIB => a,
                .ROTR => std.math.rotr(u64, a, shift63(inst.imm)),
                .BSWAP => @byteSwap(a),
                .MUM => blk: {
                    const prod: u128 = @as(u128, a) *% @as(u128, b | 1);
                    const lo: u64 = @truncate(prod);
                    const hi: u64 = @truncate(prod >> 64);
                    break :blk lo ^ hi;
                },
                .ADD_ROT => std.math.rotl(u64, a +% b, shift63(inst.imm)),
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

fn shift63(imm: u64) u6 {
    return @as(u6, @intCast(imm % 63 + 1));
}

pub fn modeName(mode: MulFreeMode) []const u8 {
    return switch (mode) {
        .mul_free => "mul_free",
        .no_carry => "no_carry",
        .unrestricted => "unrestricted",
    };
}

pub fn parseMode(value: []const u8) !MulFreeMode {
    if (std.mem.eql(u8, value, "mul_free") or std.mem.eql(u8, value, "mul-free")) return .mul_free;
    if (std.mem.eql(u8, value, "no_carry") or std.mem.eql(u8, value, "no-carry")) return .no_carry;
    if (std.mem.eql(u8, value, "strict_linear") or std.mem.eql(u8, value, "strict-linear")) return .no_carry;
    if (std.mem.eql(u8, value, "unrestricted")) return .unrestricted;
    return error.InvalidMode;
}

pub fn opAllowed(mode: MulFreeMode, op: Op) bool {
    return switch (mode) {
        .unrestricted => op != .CALL_LIB,
        .mul_free => switch (op) {
            .MUL, .MUM, .SPLITMIX_STEP, .CALL_LIB => false,
            else => true,
        },
        .no_carry => switch (op) {
            .ADD, .MUL, .SPLITMIX_STEP, .ADD_CONST, .CALL_LIB, .MUM, .ADD_ROT => false,
            else => true,
        },
    };
}

pub fn validateMode(p: Program, mode: MulFreeMode) !void {
    if (p.used == 0 or p.used > MaxProgLen) return error.InvalidProgramLength;
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        if (!opAllowed(mode, p.instructions[i].op)) return error.BannedOpcode;
    }
}

fn allowedOps(mode: MulFreeMode) []const Op {
    return switch (mode) {
        .mul_free => &.{
            .XOR,     .ADD,      .ROTL, .SHL_XOR, .SHR_XOR, .ADD_CONST,
            .AND_NOT, .OR_SHIFT, .ROTR, .BSWAP,   .ADD_ROT,
        },
        .no_carry => &.{
            .XOR,      .ROTL, .SHL_XOR, .SHR_XOR, .AND_NOT,
            .OR_SHIFT, .ROTR, .BSWAP,
        },
        .unrestricted => &.{
            .XOR,           .ADD,       .MUL,     .ROTL,     .SHL_XOR, .SHR_XOR,
            .SPLITMIX_STEP, .ADD_CONST, .AND_NOT, .OR_SHIFT, .ROTR,    .BSWAP,
            .MUM,           .ADD_ROT,
        },
    };
}

pub fn normalizeMaxLen(max_len: u8) u8 {
    return @max(@as(u8, MinProgLen), @min(max_len, MaxProgLen));
}

fn nextRand(rng: *u64) u64 {
    rng.* = engine.smix(rng.*);
    return rng.*;
}

fn randomInstr(rng: *u64, mode: MulFreeMode) Instruction {
    const ops = allowedOps(mode);
    const op = ops[@intCast(nextRand(rng) % ops.len)];
    const dst: u3 = @intCast(nextRand(rng) % NumRegs);
    const src1: u3 = @intCast(nextRand(rng) % NumRegs);
    const src2: u3 = @intCast(nextRand(rng) % NumRegs);
    const imm = nextRand(rng);
    return .{ .op = op, .dst = dst, .src1 = src1, .src2 = src2, .imm = imm };
}

pub fn randomProgram(rng: *u64, mode: MulFreeMode, max_len: u8) Program {
    const bounded_max = normalizeMaxLen(max_len);
    const span = @as(u64, @intCast(bounded_max - MinProgLen + 1));
    const len: u8 = @intCast(MinProgLen + (nextRand(rng) % span));
    var p = emptyProgram();
    p.used = len;
    var i: usize = 0;
    while (i < len) : (i += 1) p.instructions[i] = randomInstr(rng, mode);
    p.instructions[len - 1].dst = NumRegs - 1;
    return p;
}

pub fn mutate(p: Program, rng: *u64, mode: MulFreeMode, max_len: u8) Program {
    var q = p;
    const bounded_max = normalizeMaxLen(max_len);
    const draw = nextRand(rng) % 16;
    if (draw < 10) {
        const idx: usize = @intCast(nextRand(rng) % q.used);
        q.instructions[idx] = randomInstr(rng, mode);
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else if (draw < 13 and q.used < bounded_max) {
        const idx: usize = @intCast(nextRand(rng) % (q.used + 1));
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.instructions[i] = q.instructions[i - 1];
        q.instructions[idx] = randomInstr(rng, mode);
        q.used += 1;
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else if (q.used > MinProgLen) {
        const idx: usize = @intCast(nextRand(rng) % q.used);
        var i: usize = idx;
        while (i < q.used - 1) : (i += 1) q.instructions[i] = q.instructions[i + 1];
        q.used -= 1;
        q.instructions[q.used - 1].dst = NumRegs - 1;
    } else {
        const idx: usize = @intCast(nextRand(rng) % q.used);
        q.instructions[idx].imm = nextRand(rng);
    }
    return q;
}

pub fn crossover(a: Program, b: Program, rng: *u64, max_len: u8) Program {
    const bounded_max = normalizeMaxLen(max_len);
    const min_len = @min(a.used, b.used);
    if (min_len < MinProgLen) return a;
    const cut: usize = @intCast(nextRand(rng) % min_len);
    var q = a;
    var i: usize = cut;
    while (i < b.used and i < bounded_max) : (i += 1) q.instructions[i] = b.instructions[i];
    q.used = @min(b.used, bounded_max);
    q.instructions[q.used - 1].dst = NumRegs - 1;
    return q;
}

pub fn emptyProgram() Program {
    return Program{
        .instructions = [_]Instruction{.{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0 }} ** MaxProgLen,
        .used = 0,
    };
}

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
            const y_flip = p.execute(x ^ (@as(u64, 1) << bit));
            total += @as(f64, @floatFromInt(@popCount(y ^ y_flip)));
            samples += 1;
            if (bit == 63) break;
            bit += 1;
        }
    }
    return total / @as(f64, @floatFromInt(samples));
}

fn balanceFn(p: Program) f64 {
    var total: f64 = 0;
    var rng: u64 = 0x1234_5678_9ABC_DEF0;
    var n: usize = 0;
    while (n < BalanceSamples) : (n += 1) {
        rng = engine.smix(rng);
        total += @as(f64, @floatFromInt(@popCount(p.execute(rng))));
    }
    return total / @as(f64, @floatFromInt(BalanceSamples));
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
    for (bins) |count| {
        const d = @as(f64, @floatFromInt(count)) - expected;
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

    return .{
        .avalanche = av,
        .balance = bal,
        .period = per,
        .chisq = cs,
        .composite = composite,
    };
}

pub fn qualityScalar(q: Quality) f64 {
    return q.composite;
}

pub fn qualityPasses(q: Quality) bool {
    return q.avalanche >= AvalancheLo and q.avalanche <= AvalancheHi and
        q.balance >= BalanceLo and q.balance <= BalanceHi and
        q.chisq <= ChiSqMax and q.period >= PeriodMin;
}

pub fn isFinite(q: Quality) bool {
    return std.math.isFinite(q.avalanche) and std.math.isFinite(q.balance) and std.math.isFinite(q.chisq);
}

pub fn programHash(p: Program) u64 {
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

pub fn opName(op: Op) []const u8 {
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
        .CALL_LIB => "CALL_LIB",
        .ROTR => "ROTR",
        .BSWAP => "BSWAP",
        .MUM => "MUM",
        .ADD_ROT => "ADD_ROT",
    };
}

pub fn printProgram(p: Program, mode: MulFreeMode, writer: anytype) !void {
    try writer.print("[{s}] used={d} hash=0x{X}\n", .{ modeName(mode), p.used, programHash(p) });
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

pub fn programToCsv(p: Program, writer: anytype) !void {
    try writer.writeAll("idx,op_id,op_name,dst,src1,src2,imm_hex,used_len\n");
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const inst = p.instructions[i];
        try writer.print("{d},{d},{s},{d},{d},{d},0x{X:0>16},{d}\n", .{
            i,
            @intFromEnum(inst.op),
            opName(inst.op),
            inst.dst,
            inst.src1,
            inst.src2,
            inst.imm,
            p.used,
        });
    }
}

pub fn programFromCsv(allocator: std.mem.Allocator, path: []const u8) !Program {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(contents);

    var p = emptyProgram();
    var lines = std.mem.tokenizeAny(u8, contents, "\n\r");
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        }
        var fields = std.mem.tokenizeAny(u8, line, ",");
        _ = fields.next() orelse continue;
        const op_id_s = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const dst_s = fields.next() orelse continue;
        const src1_s = fields.next() orelse continue;
        const src2_s = fields.next() orelse continue;
        const imm_s = fields.next() orelse continue;
        if (p.used >= MaxProgLen) return error.ProgramTooLong;

        const op_id = try std.fmt.parseInt(u8, op_id_s, 10);
        if (op_id > @intFromEnum(Op.ADD_ROT)) return error.InvalidOpcode;
        const dst = try std.fmt.parseInt(u8, dst_s, 10);
        const src1 = try std.fmt.parseInt(u8, src1_s, 10);
        const src2 = try std.fmt.parseInt(u8, src2_s, 10);
        if (dst >= NumRegs or src1 >= NumRegs or src2 >= NumRegs) return error.InvalidRegister;
        const imm = if (std.mem.startsWith(u8, imm_s, "0x") or std.mem.startsWith(u8, imm_s, "0X"))
            try std.fmt.parseInt(u64, imm_s[2..], 16)
        else
            try std.fmt.parseInt(u64, imm_s, 10);

        p.instructions[p.used] = .{
            .op = @enumFromInt(@as(u4, @intCast(op_id))),
            .dst = @intCast(dst),
            .src1 = @intCast(src1),
            .src2 = @intCast(src2),
            .imm = imm,
        };
        p.used += 1;
    }
    if (p.used == 0) return error.EmptyProgram;
    p.instructions[p.used - 1].dst = NumRegs - 1;
    return p;
}

test "mode validation rejects banned multiplication family ops" {
    var p = emptyProgram();
    p.used = 4;
    p.instructions[0] = .{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 1, .imm = 0 };
    p.instructions[1] = .{ .op = .MUL, .dst = 1, .src1 = 0, .src2 = 0, .imm = 3 };
    p.instructions[2] = .{ .op = .SHR_XOR, .dst = 2, .src1 = 1, .src2 = 0, .imm = 27 };
    p.instructions[3] = .{ .op = .XOR, .dst = 7, .src1 = 2, .src2 = 3, .imm = 0 };

    try std.testing.expectError(error.BannedOpcode, validateMode(p, .mul_free));
    try validateMode(p, .unrestricted);
}

test "no_carry rejects ADD-family ops while mul_free allows ADD_ROT" {
    var p = emptyProgram();
    p.used = 4;
    p.instructions[0] = .{ .op = .ADD_ROT, .dst = 0, .src1 = 0, .src2 = 1, .imm = 17 };
    p.instructions[1] = .{ .op = .XOR, .dst = 1, .src1 = 0, .src2 = 2, .imm = 0 };
    p.instructions[2] = .{ .op = .ROTR, .dst = 2, .src1 = 1, .src2 = 0, .imm = 13 };
    p.instructions[3] = .{ .op = .XOR, .dst = 7, .src1 = 2, .src2 = 3, .imm = 0 };

    try validateMode(p, .mul_free);
    try std.testing.expectError(error.BannedOpcode, validateMode(p, .no_carry));
}

test "random generation and mutation obey mode policy" {
    var rng: u64 = 0xDEAD_BEEF_CAFE_BABE;
    inline for (.{ MulFreeMode.mul_free, MulFreeMode.no_carry, MulFreeMode.unrestricted }) |mode| {
        var p = randomProgram(&rng, mode, MaxProgLen);
        try validateMode(p, mode);
        var i: usize = 0;
        while (i < 512) : (i += 1) {
            p = mutate(p, &rng, mode, MaxProgLen);
            try validateMode(p, mode);
        }
    }
}
