const std = @import("std");
const bt = @import("domain_bittape.zig");

// Verification tool for bit-tape inventor outputs.
//
// Modes:
//   --rigorous-fitness: re-evaluate quality at 4x the inventor's
//     sample count. Catches "fitness-gaming" artifacts where a
//     program passes the small-sample test but fails at scale.
//   --emit-stream --bytes=N: produce N bytes of u64 stream from
//     repeated program execution, suitable to pipe into PractRand:
//       bittape_inspect --program=BEST.csv --emit-stream --bytes=64M | RNG_test stdin64 -tlmax 64M

fn loadProgramCsv(allocator: std.mem.Allocator, path: []const u8) !bt.Program {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(contents);

    var p = bt.Program{ .instructions = undefined, .used = 0 };
    var lines = std.mem.tokenizeAny(u8, contents, "\n\r");
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        }
        var fields = std.mem.tokenizeAny(u8, line, ",");
        _ = fields.next() orelse continue; // idx
        const op_id_s = fields.next() orelse continue;
        _ = fields.next() orelse continue; // op_name
        const dst_s = fields.next() orelse continue;
        const src1_s = fields.next() orelse continue;
        const src2_s = fields.next() orelse continue;
        if (p.used >= bt.MaxProgLen) break;
        p.instructions[p.used] = .{
            .op = @intCast(try std.fmt.parseInt(u8, op_id_s, 10)),
            .dst = try std.fmt.parseInt(u8, dst_s, 10),
            .src1 = try std.fmt.parseInt(u8, src1_s, 10),
            .src2 = try std.fmt.parseInt(u8, src2_s, 10),
        };
        p.used += 1;
    }
    return p;
}

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

const RigorousFitSamples = 64; // 4x default
const RigorousBalSamples = 1024;
const RigorousChiSqSamples = 16384;
const RigorousPeriodSamples = 16384;

fn rigorousAvalanche(p: bt.Program) f64 {
    var total: f64 = 0;
    var samples: u64 = 0;
    var rng: u64 = 0xACE_F00D_BEEF_CAFE;
    var s: usize = 0;
    while (s < RigorousFitSamples) : (s += 1) {
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

fn rigorousBalance(p: bt.Program) f64 {
    var t: f64 = 0;
    var rng: u64 = 0x1234_5678_9ABC_DEF0;
    var n: usize = 0;
    while (n < RigorousBalSamples) : (n += 1) {
        rng = smix(rng);
        t += @as(f64, @floatFromInt(@popCount(p.execute(rng))));
    }
    return t / @as(f64, @floatFromInt(RigorousBalSamples));
}

fn rigorousChiSq(p: bt.Program) f64 {
    var bins = [_]u32{0} ** 256;
    var rng: u64 = 0xDEAD_BEEF_BAD_F00D;
    var n: usize = 0;
    while (n < RigorousChiSqSamples) : (n += 1) {
        rng = smix(rng);
        bins[@intCast(p.execute(rng) & 0xFF)] += 1;
    }
    const expected = @as(f64, @floatFromInt(RigorousChiSqSamples)) / 256.0;
    var cs: f64 = 0;
    for (bins) |c| {
        const d = @as(f64, @floatFromInt(c)) - expected;
        cs += (d * d) / expected;
    }
    return cs;
}

fn rigorousPeriod(p: bt.Program, seed: u64) usize {
    var x = seed;
    var i: usize = 0;
    while (i < RigorousPeriodSamples) : (i += 1) {
        x = p.execute(x);
        if (x == seed and i > 0) return i + 1;
    }
    return RigorousPeriodSamples;
}

/// Stronger structural test: compute avalanche separately for each
/// output bit, then report the worst-case bit (the bit that's least
/// sensitive to input flips). For a "real" mixer this should be
/// close to 0.5 for every bit. For a degenerate solution that
/// computes y[i] = f(x[i]) independently per bit, this would be very
/// skewed.
fn perOutputBitAvalanche(p: bt.Program, out_min: *f64, out_max: *f64, out_mean: *f64) void {
    var per_bit: [64]f64 = [_]f64{0} ** 64;
    var rng: u64 = 0xACE_F00D_BEEF_CAFE;
    const samples = 128;
    var s: usize = 0;
    while (s < samples) : (s += 1) {
        rng = smix(rng);
        const x = rng;
        const y = p.execute(x);
        var in_bit: u6 = 0;
        while (true) {
            const x_flip = x ^ (@as(u64, 1) << in_bit);
            const y_flip = p.execute(x_flip);
            const delta = y ^ y_flip;
            var out_bit: u6 = 0;
            while (true) {
                if ((delta >> out_bit) & 1 == 1) per_bit[out_bit] += 1;
                if (out_bit == 63) break;
                out_bit += 1;
            }
            if (in_bit == 63) break;
            in_bit += 1;
        }
    }
    // Normalize: max possible flips per output bit = samples * 64.
    const max_flips: f64 = @as(f64, @floatFromInt(samples)) * 64.0;
    var min_v: f64 = 1.0;
    var max_v: f64 = 0.0;
    var sum_v: f64 = 0.0;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const frac = per_bit[i] / max_flips;
        if (frac < min_v) min_v = frac;
        if (frac > max_v) max_v = frac;
        sum_v += frac;
    }
    out_min.* = min_v;
    out_max.* = max_v;
    out_mean.* = sum_v / 64.0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var program_path: []const u8 = "";
    var stream_bytes: u64 = 0;
    var stream_seed: u64 = 0x0123_4567_89AB_CDEF;
    var rigorous = false;
    var per_bit = false;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--program=")) {
            program_path = arg["--program=".len..];
        } else if (std.mem.eql(u8, arg, "--rigorous-fitness")) {
            rigorous = true;
        } else if (std.mem.eql(u8, arg, "--per-bit-avalanche")) {
            per_bit = true;
        } else if (std.mem.startsWith(u8, arg, "--emit-stream-bytes=")) {
            const v = arg["--emit-stream-bytes=".len..];
            if (std.mem.endsWith(u8, v, "M")) {
                stream_bytes = (try std.fmt.parseInt(u64, v[0 .. v.len - 1], 10)) * 1024 * 1024;
            } else if (std.mem.endsWith(u8, v, "K")) {
                stream_bytes = (try std.fmt.parseInt(u64, v[0 .. v.len - 1], 10)) * 1024;
            } else {
                stream_bytes = try std.fmt.parseInt(u64, v, 10);
            }
        } else if (std.mem.startsWith(u8, arg, "--stream-seed=")) {
            stream_seed = try std.fmt.parseInt(u64, arg["--stream-seed=".len..], 16);
        }
    }

    if (program_path.len == 0) {
        std.debug.print("usage: bittape_inspect --program=PATH [--rigorous-fitness] [--per-bit-avalanche] [--emit-stream-bytes=N[K|M]]\n", .{});
        return;
    }

    const program = try loadProgramCsv(allocator, program_path);
    const stderr = std.io.getStdErr().writer();

    if (rigorous) {
        try stderr.print("=== RIGOROUS QUALITY (4x sample budget) ===\n", .{});
        const av = rigorousAvalanche(program);
        const bal = rigorousBalance(program);
        const per = rigorousPeriod(program, 0x7E57_0001);
        const cs = rigorousChiSq(program);
        try stderr.print("program={s} used={d}\n", .{ program_path, program.used });
        try stderr.print("rigorous_avalanche={d:.6} (target 32.0)\n", .{av});
        try stderr.print("rigorous_balance={d:.6} (target 32.0)\n", .{bal});
        try stderr.print("rigorous_period={d} / {d} (max)\n", .{ per, RigorousPeriodSamples });
        try stderr.print("rigorous_chisq={d:.4} (pass if <= 255)\n", .{cs});
    }

    if (per_bit) {
        var min_v: f64 = 0;
        var max_v: f64 = 0;
        var mean_v: f64 = 0;
        perOutputBitAvalanche(program, &min_v, &max_v, &mean_v);
        try stderr.print("=== PER-OUTPUT-BIT AVALANCHE ===\n", .{});
        try stderr.print("min_bit_flip_frac={d:.6} max_bit_flip_frac={d:.6} mean={d:.6} (target ~0.5)\n", .{ min_v, max_v, mean_v });
    }

    if (stream_bytes > 0) {
        try stderr.print("=== EMITTING STREAM ({d} bytes) ===\n", .{stream_bytes});
        const stdout = std.io.getStdOut().writer();
        var x = stream_seed;
        var bytes_emitted: u64 = 0;
        while (bytes_emitted < stream_bytes) {
            x = program.execute(x);
            try stdout.writeAll(std.mem.asBytes(&x));
            bytes_emitted += 8;
        }
    }
}
