const std = @import("std");

// Pairwise functional comparison of all champion CSVs in a directory.
// Decides whether the inventor produces N genuinely distinct inventions
// or N surface variations of one function. If every off-diagonal entry of
// the pairwise bit_agreement matrix is ~0.50 (the noise floor), the
// inventions are mutually peer-distant. If some pair scores high, those
// two champions are functionally close and count as one invention.

const NumRegs = 8;
const MaxProgLen = 12;
const FuncSamples = 1024;

const Op = enum(u4) {
    XOR = 0, ADD = 1, MUL = 2, ROTL = 3, SHL_XOR = 4, SHR_XOR = 5,
    SPLITMIX_STEP = 6, ADD_CONST = 7, AND_NOT = 8, OR_SHIFT = 9,
};

const Instruction = struct { op: Op, dst: u3, src1: u3, src2: u3, imm: u64 };

const Program = struct {
    instructions: [MaxProgLen]Instruction,
    used: u8,
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

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn loadChampionCsv(allocator: std.mem.Allocator, path: []const u8) !?Program {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(data);
    var p = Program{ .instructions = undefined, .used = 0 };
    var line_it = std.mem.splitScalar(u8, data, '\n');
    _ = line_it.next();
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        var f_it = std.mem.splitScalar(u8, line, ',');
        _ = f_it.next() orelse continue;
        const op_id_s = f_it.next() orelse continue;
        _ = f_it.next() orelse continue;
        const dst_s = f_it.next() orelse continue;
        const src1_s = f_it.next() orelse continue;
        const src2_s = f_it.next() orelse continue;
        const imm_s = f_it.next() orelse continue;
        const op_id = try std.fmt.parseInt(u4, std.mem.trim(u8, op_id_s, " \r"), 10);
        const dst = try std.fmt.parseInt(u3, std.mem.trim(u8, dst_s, " \r"), 10);
        const src1 = try std.fmt.parseInt(u3, std.mem.trim(u8, src1_s, " \r"), 10);
        const src2 = try std.fmt.parseInt(u3, std.mem.trim(u8, src2_s, " \r"), 10);
        const imm_trim = std.mem.trim(u8, imm_s, " \r");
        const imm_hex = if (std.mem.startsWith(u8, imm_trim, "0x")) imm_trim[2..] else imm_trim;
        const imm = try std.fmt.parseInt(u64, imm_hex, 16);
        if (p.used >= MaxProgLen) break;
        p.instructions[p.used] = .{ .op = @enumFromInt(op_id), .dst = dst, .src1 = src1, .src2 = src2, .imm = imm };
        p.used += 1;
    }
    if (p.used == 0) return null;
    return p;
}

fn bitAgreement(a: Program, b: Program) f64 {
    var bit_total: u64 = 0;
    var rng: u64 = 0xDEAD_BEEF_5EED_C0DE;
    var i: usize = 0;
    while (i < FuncSamples) : (i += 1) {
        rng = smix(rng);
        const ya = a.execute(rng);
        const yb = b.execute(rng);
        bit_total += @as(u64, 64) - @popCount(ya ^ yb);
    }
    return @as(f64, @floatFromInt(bit_total)) / (@as(f64, @floatFromInt(FuncSamples)) * 64.0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var n: usize = 20;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--n=")) n = try std.fmt.parseInt(usize, arg["--n=".len..], 10);
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== CHAMPION PAIRWISE COMPARISON (N={d}) ===\n\n", .{n});

    var champions = try allocator.alloc(Program, n);
    defer allocator.free(champions);
    var loaded: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "results/reproducibility/champion_{d}.csv", .{i + 1});
        if (try loadChampionCsv(allocator, path)) |p| {
            champions[loaded] = p;
            loaded += 1;
        } else {
            try stdout.print("missing: {s}\n", .{path});
        }
    }
    try stdout.print("Loaded {d} champions.\n\n", .{loaded});

    var csv = try std.fs.cwd().createFile("results/reproducibility/pairwise.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writer().writeAll("a,b,bit_agreement\n");

    var max_off: f64 = 0;
    var max_a: usize = 0;
    var max_b: usize = 0;
    var sum_off: f64 = 0;
    var count_off: usize = 0;

    try stdout.print("Pairwise bit_agreement matrix (off-diagonal only printed):\n", .{});
    var a: usize = 0;
    while (a < loaded) : (a += 1) {
        var b: usize = a + 1;
        while (b < loaded) : (b += 1) {
            const ba = bitAgreement(champions[a], champions[b]);
            try csv.writer().print("{d},{d},{d:.4}\n", .{ a + 1, b + 1, ba });
            sum_off += ba;
            count_off += 1;
            if (ba > max_off) {
                max_off = ba;
                max_a = a + 1;
                max_b = b + 1;
            }
        }
    }
    const mean_off = sum_off / @as(f64, @floatFromInt(count_off));
    try stdout.print("\nN pairs: {d}\n", .{count_off});
    try stdout.print("Mean bit_agreement off-diagonal: {d:.4}\n", .{mean_off});
    try stdout.print("Max  bit_agreement off-diagonal: {d:.4}  (champions {d} vs {d})\n", .{ max_off, max_a, max_b });
    try stdout.print("\nInterpretation:\n", .{});
    try stdout.print("  If max ~ 0.50: all champions are mutually peer-distant — {d} distinct inventions.\n", .{loaded});
    try stdout.print("  If max > 0.95: some champion pairs are functionally equivalent — collapse count.\n", .{});
    if (max_off > 0.95) {
        try stdout.print("\nRESULT: max {d:.4} >= 0.95 — at least one collision detected. Effective invention count < {d}.\n", .{ max_off, loaded });
    } else if (max_off > 0.75) {
        try stdout.print("\nRESULT: max {d:.4} in [0.75, 0.95) — moderate functional overlap on some pair. Worth inspecting.\n", .{max_off});
    } else if (max_off > 0.55) {
        try stdout.print("\nRESULT: max {d:.4} in [0.55, 0.75) — slight bias above noise floor. Investigate.\n", .{max_off});
    } else {
        try stdout.print("\nRESULT: max {d:.4} < 0.55 — all {d} champions are mutually peer-distant at the noise floor. {d} DISTINCT INVENTIONS.\n", .{ max_off, loaded, loaded });
    }
    try stdout.print("\nCSV: results/reproducibility/pairwise.csv\n", .{});
}
