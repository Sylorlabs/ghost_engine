const std = @import("std");

const NumRegs = 8;
const MaxProgLen = 12;
const ArtifactMagic: u64 = 0x315653475052474D; // MGPRGSV1, little-endian marker.
const ArtifactVersion: u32 = 1;

const Variant = enum {
    discovered,
    splitmix,
    splitmix_counter,
    v3_edge_clean,
    v3_splitmixrng_clean,
};

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

const ConstMode = enum(u8) {
    standard = 0,
    neutral = 1,
    minimal = 2,
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

const LoadedProgram = struct {
    program: Program,
    const_mode: ConstMode,
};

const golden = 0x9E3779B97F4A7C15;
const split_k1 = 0xBF58476D1CE4E5B9;
const split_k2 = 0x94D049BB133111EB;

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

fn splitMixScramble(x: u64) u64 {
    var z = x;
    z = (z ^ (z >> 30)) *% split_k1;
    z = (z ^ (z >> 27)) *% split_k2;
    return z ^ (z >> 31);
}

fn splitMix64Ref(x: u64) u64 {
    return splitMixScramble(x +% golden);
}

fn discoveredRun2Mix(x: u64) u64 {
    var r0 = x;
    const r1 = r0 ^ (r0 >> 37);
    r0 = r1 +% 0x9EE408BD3A3337DD;
    var r6 = r0 *% 0x0D5886EBD935161F;
    r6 = r6 ^ (r6 >> 30);
    return r6 *% 0x125B26B8C3E6F5D1;
}

fn v3EdgeCleanMix(x: u64) u64 {
    var r0 = x +% 0x00B28E91B16491D3;
    r0 = r0 ^ (r0 >> 28);
    const r6 = r0 *% 0x8142B093927C2357;
    return r6 ^ (r6 >> 30);
}

fn v3SplitmixRngCleanMix(x: u64) u64 {
    var r0 = x ^ (x >> 34);
    r0 = r0 *% 0x7EA15A8F3875277D;
    r0 = r0 +% 0xF45BC7F50E8DD9D1;
    return r0 ^ (r0 >> 30);
}

fn nextWord(variant: Variant, state: *u64) u64 {
    return switch (variant) {
        .discovered => blk: {
            state.* = discoveredRun2Mix(state.*);
            break :blk state.*;
        },
        .splitmix => blk: {
            state.* = splitMix64Ref(state.*);
            break :blk state.*;
        },
        .splitmix_counter => blk: {
            state.* +%= golden;
            break :blk splitMixScramble(state.*);
        },
        .v3_edge_clean => blk: {
            state.* = v3EdgeCleanMix(state.*);
            break :blk state.*;
        },
        .v3_splitmixrng_clean => blk: {
            state.* = v3SplitmixRngCleanMix(state.*);
            break :blk state.*;
        },
    };
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

fn parseConstMode(raw: u8) !ConstMode {
    return switch (raw) {
        0 => .standard,
        1 => .neutral,
        2 => .minimal,
        else => error.InvalidArtifact,
    };
}

fn loadProgramArtifact(path: []const u8) !LoadedProgram {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const reader = file.reader();

    const magic = try reader.readInt(u64, .little);
    if (magic != ArtifactMagic) return error.InvalidArtifact;
    const version = try reader.readInt(u32, .little);
    if (version != ArtifactVersion) return error.InvalidArtifact;
    const used = try reader.readByte();
    if (used == 0 or used > MaxProgLen) return error.InvalidArtifact;
    const const_mode = try parseConstMode(try reader.readByte());
    _ = try reader.readByte(); // allow_step from synthesis config
    _ = try reader.readByte(); // search mode from synthesis config
    const expected_hash = try reader.readInt(u64, .little);
    _ = try reader.readInt(u64, .little); // run seed
    _ = try reader.readInt(u64, .little); // base composite bits
    _ = try reader.readInt(u64, .little); // search score bits
    _ = try reader.readInt(u64, .little); // zero output
    _ = try reader.readInt(u64, .little); // one output
    _ = try reader.readInt(u64, .little); // all-ones output

    var program = Program{
        .instructions = [_]Instruction{.{ .op = .XOR, .dst = 0, .src1 = 0, .src2 = 0, .imm = 0 }} ** MaxProgLen,
        .used = used,
    };

    var i: usize = 0;
    while (i < used) : (i += 1) {
        const op_raw = try reader.readByte();
        if (op_raw > @intFromEnum(Op.OR_SHIFT)) return error.InvalidArtifact;
        const dst = try reader.readByte();
        const src1 = try reader.readByte();
        const src2 = try reader.readByte();
        if (dst >= NumRegs or src1 >= NumRegs or src2 >= NumRegs) return error.InvalidArtifact;
        program.instructions[i] = .{
            .op = @enumFromInt(@as(u4, @intCast(op_raw))),
            .dst = @intCast(dst),
            .src1 = @intCast(src1),
            .src2 = @intCast(src2),
            .imm = try reader.readInt(u64, .little),
        };
    }

    if (programHash(program) != expected_hash) return error.InvalidArtifact;
    return .{ .program = program, .const_mode = const_mode };
}

fn parseVariant(text: []const u8) !Variant {
    if (std.mem.eql(u8, text, "discovered") or std.mem.eql(u8, text, "discovered-run2")) return .discovered;
    if (std.mem.eql(u8, text, "splitmix") or std.mem.eql(u8, text, "splitmix-iterated")) return .splitmix;
    if (std.mem.eql(u8, text, "splitmix-counter")) return .splitmix_counter;
    if (std.mem.eql(u8, text, "v3-edge-clean")) return .v3_edge_clean;
    if (std.mem.eql(u8, text, "v3-splitmixrng-clean")) return .v3_splitmixrng_clean;
    return error.InvalidVariant;
}

fn parseHexOrDecimal(text: []const u8) !u64 {
    if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        return std.fmt.parseInt(u64, text[2..], 16);
    }
    return std.fmt.parseInt(u64, text, 16) catch std.fmt.parseInt(u64, text, 10);
}

fn parseByteCount(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidByteCount;

    var digits = text;
    var multiplier: u64 = 1;
    switch (text[text.len - 1]) {
        'k', 'K' => {
            digits = text[0 .. text.len - 1];
            multiplier = 1024;
        },
        'm', 'M' => {
            digits = text[0 .. text.len - 1];
            multiplier = 1024 * 1024;
        },
        'g', 'G' => {
            digits = text[0 .. text.len - 1];
            multiplier = 1024 * 1024 * 1024;
        },
        else => {},
    }
    if (digits.len == 0) return error.InvalidByteCount;

    const base = try std.fmt.parseInt(u64, digits, 10);
    return std.math.mul(u64, base, multiplier) catch error.ByteCountOverflow;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\usage: practrand_emit [--variant=discovered|splitmix|splitmix-counter|v3-edge-clean|v3-splitmixrng-clean] [--program=<artifact>] [--seed=<hex>] [--bytes=<n>[K|M|G]]
        \\
        \\Writes raw little-endian u64 words to stdout. Diagnostics and usage go to stderr.
        \\If --program is provided, loads a program_synthesis_v3 artifact and iterates that program instead of a named variant.
        \\Default variant is discovered-run2; default output is unbounded until the reader closes the pipe.
        \\
    );
}

fn writeRaw(writer: anytype, bytes: []const u8) !bool {
    writer.writeAll(bytes) catch |err| switch (err) {
        error.BrokenPipe => return false,
        else => return err,
    };
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var variant: Variant = .discovered;
    var state: u64 = 0x0123456789ABCDEF;
    var byte_limit: ?u64 = null;
    var program_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(std.io.getStdErr().writer());
            return;
        } else if (std.mem.startsWith(u8, arg, "--variant=")) {
            variant = parseVariant(arg["--variant=".len..]) catch |err| {
                try std.io.getStdErr().writer().print("invalid variant: {s}\n", .{arg["--variant=".len..]});
                return err;
            };
        } else if (std.mem.startsWith(u8, arg, "--program=")) {
            program_path = arg["--program=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            state = parseHexOrDecimal(arg["--seed=".len..]) catch |err| {
                try std.io.getStdErr().writer().print("invalid seed: {s}\n", .{arg["--seed=".len..]});
                return err;
            };
        } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
            byte_limit = parseByteCount(arg["--bytes=".len..]) catch |err| {
                try std.io.getStdErr().writer().print("invalid byte count: {s}\n", .{arg["--bytes=".len..]});
                return err;
            };
        } else {
            try std.io.getStdErr().writer().print("unknown argument: {s}\n", .{arg});
            try printUsage(std.io.getStdErr().writer());
            return error.InvalidArgument;
        }
    }

    const loaded_program = if (program_path) |path| try loadProgramArtifact(path) else null;
    const stdout = std.io.getStdOut().writer();
    var produced: u64 = 0;
    var buf: [32 * 1024]u8 = undefined;

    while (byte_limit == null or produced < byte_limit.?) {
        const target_bytes: usize = if (byte_limit) |limit|
            @intCast(@min(@as(u64, buf.len), limit - produced))
        else
            buf.len;

        var offset: usize = 0;
        while (offset < target_bytes) {
            const word = if (loaded_program) |artifact| blk: {
                state = artifact.program.execute(state, artifact.const_mode);
                break :blk state;
            } else nextWord(variant, &state);
            const take = @min(@as(usize, 8), target_bytes - offset);
            if (take == 8) {
                std.mem.writeInt(u64, buf[offset..][0..8], word, .little);
            } else {
                var word_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &word_bytes, word, .little);
                @memcpy(buf[offset..][0..take], word_bytes[0..take]);
            }
            offset += take;
        }

        if (!try writeRaw(stdout, buf[0..target_bytes])) return;
        produced += @as(u64, @intCast(target_bytes));
    }
}

test "discovered Run 2 stream is stable" {
    var state: u64 = 0x0123456789ABCDEF;
    try std.testing.expectEqual(@as(u64, 0xDFE838ACEED53BF0), nextWord(.discovered, &state));
    try std.testing.expectEqual(@as(u64, 0x60B0E14DAC746FF3), nextWord(.discovered, &state));
}

test "byte-count parser accepts binary suffixes" {
    try std.testing.expectEqual(@as(u64, 64), try parseByteCount("64"));
    try std.testing.expectEqual(@as(u64, 1024), try parseByteCount("1K"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024), try parseByteCount("1M"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), try parseByteCount("1G"));
}
