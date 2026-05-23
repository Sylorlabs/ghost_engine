const std = @import("std");
const mixer = @import("domain_u64_mixer_mulfree.zig");

pub const Config = struct {
    mode: mixer.MulFreeMode = .mul_free,
    sa_steps: usize = 100_000,
    hill_iters: usize = 200,
    seed: u64 = 0xF00D_CAFE_1234_5678,
    max_prog_len: u8 = 24,
    output_dir: []const u8 = "results/phaseF_mul_free_challenge",
    label: []const u8 = "",
    emit_champion: bool = true,
};

pub const RunResult = struct {
    mode: mixer.MulFreeMode,
    seed: u64,
    best_program: mixer.Program,
    best_quality: mixer.Quality,
    best_outer_iter: usize,
    accepted: usize,
    evaluated: usize,
    elapsed_ms: u64,
};

pub const RunArtifacts = struct {
    result: RunResult,
    champion_path: []u8,
    log_path: []u8,

    pub fn deinit(self: RunArtifacts, allocator: std.mem.Allocator) void {
        allocator.free(self.champion_path);
        allocator.free(self.log_path);
    }
};

const Candidate = struct {
    program: mixer.Program,
    quality: mixer.Quality,
    accepted: usize,
    evaluated: usize,
    best_iter: usize,
};

fn nextRand(rng: *u64) u64 {
    rng.* = @import("invention_engine.zig").smix(rng.*);
    return rng.*;
}

fn acceptMetropolis(delta: f64, temperature: f64, rng: *u64) bool {
    if (delta >= 0) return true;
    if (temperature <= 0) return false;
    const draw_raw = nextRand(rng) % 1_000_000;
    const draw = @as(f64, @floatFromInt(draw_raw)) / 1_000_000.0;
    return draw < std.math.exp(delta / temperature);
}

fn annealFrom(start: mixer.Program, cfg: Config, rng: *u64) Candidate {
    var current = start;
    var current_q = mixer.evaluateQuality(current);
    var best = current;
    var best_q = current_q;
    var accepted: usize = 0;
    var evaluated: usize = 1;
    var best_iter: usize = 0;

    var i: usize = 0;
    while (i < cfg.sa_steps) : (i += 1) {
        const progress = @as(f64, @floatFromInt(i)) / @max(@as(f64, 1.0), @as(f64, @floatFromInt(cfg.sa_steps)));
        const temperature = 8.0 * std.math.pow(f64, 0.001, progress);
        const candidate = mixer.mutate(current, rng, cfg.mode, cfg.max_prog_len);
        const cand_q = mixer.evaluateQuality(candidate);
        evaluated += 1;
        if (!mixer.isFinite(cand_q)) continue;

        if (acceptMetropolis(cand_q.composite - current_q.composite, temperature, rng)) {
            current = candidate;
            current_q = cand_q;
            accepted += 1;
        }
        if (cand_q.composite > best_q.composite) {
            best = candidate;
            best_q = cand_q;
            best_iter = i + 1;
        }
    }

    return .{
        .program = best,
        .quality = best_q,
        .accepted = accepted,
        .evaluated = evaluated,
        .best_iter = best_iter,
    };
}

pub fn runSearch(cfg_raw: Config, log_writer: anytype) !RunResult {
    var cfg = cfg_raw;
    cfg.max_prog_len = mixer.normalizeMaxLen(cfg.max_prog_len);
    var rng = cfg.seed;
    const start_ms = std.time.milliTimestamp();

    var best = mixer.randomProgram(&rng, cfg.mode, cfg.max_prog_len);
    var best_q = mixer.evaluateQuality(best);
    var best_outer: usize = 0;
    var total_accepted: usize = 0;
    var total_evaluated: usize = 1;

    try log_writer.writeAll("outer_iter,mode,seed,sa_steps,max_prog_len,local_best_iter,local_avalanche,local_balance,local_period,local_chisq,local_composite,best_avalanche,best_balance,best_period,best_chisq,best_composite,best_len,best_hash,accepted,evaluated,elapsed_ms\n");

    var outer: usize = 0;
    while (outer < cfg.hill_iters) : (outer += 1) {
        const start = if (outer == 0)
            mixer.randomProgram(&rng, cfg.mode, cfg.max_prog_len)
        else
            mixer.mutate(best, &rng, cfg.mode, cfg.max_prog_len);

        const local = annealFrom(start, cfg, &rng);
        total_accepted += local.accepted;
        total_evaluated += local.evaluated;
        if (local.quality.composite > best_q.composite) {
            best = local.program;
            best_q = local.quality;
            best_outer = outer;
        }

        const elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - start_ms);
        try log_writer.print("{d},{s},0x{X},{d},{d},{d},{d:.6},{d:.6},{d},{d:.6},{d:.6},{d:.6},{d:.6},{d},{d:.6},{d:.6},{d},0x{X},{d},{d},{d}\n", .{
            outer,
            mixer.modeName(cfg.mode),
            cfg.seed,
            cfg.sa_steps,
            cfg.max_prog_len,
            local.best_iter,
            local.quality.avalanche,
            local.quality.balance,
            local.quality.period,
            local.quality.chisq,
            local.quality.composite,
            best_q.avalanche,
            best_q.balance,
            best_q.period,
            best_q.chisq,
            best_q.composite,
            best.used,
            mixer.programHash(best),
            total_accepted,
            total_evaluated,
            elapsed_ms,
        });
    }

    const elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - start_ms);
    try mixer.validateMode(best, cfg.mode);
    return .{
        .mode = cfg.mode,
        .seed = cfg.seed,
        .best_program = best,
        .best_quality = best_q,
        .best_outer_iter = best_outer,
        .accepted = total_accepted,
        .evaluated = total_evaluated,
        .elapsed_ms = elapsed_ms,
    };
}

fn effectiveLabel(cfg: Config) []const u8 {
    return if (cfg.label.len == 0) mixer.modeName(cfg.mode) else cfg.label;
}

pub fn runToFiles(allocator: std.mem.Allocator, cfg: Config) !RunArtifacts {
    try std.fs.cwd().makePath(cfg.output_dir);
    const label = effectiveLabel(cfg);
    const champion_path = try std.fmt.allocPrint(allocator, "{s}/champion_{s}.csv", .{ cfg.output_dir, label });
    errdefer allocator.free(champion_path);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/search_log_{s}.csv", .{ cfg.output_dir, label });
    errdefer allocator.free(log_path);

    var log_file = try std.fs.cwd().createFile(log_path, .{ .truncate = true });
    defer log_file.close();
    const result = try runSearch(cfg, log_file.writer());

    if (cfg.emit_champion) {
        var champion_file = try std.fs.cwd().createFile(champion_path, .{ .truncate = true });
        defer champion_file.close();
        try mixer.programToCsv(result.best_program, champion_file.writer());
    }

    return .{
        .result = result,
        .champion_path = champion_path,
        .log_path = log_path,
    };
}

fn parseSeed(value: []const u8) !u64 {
    if (std.mem.startsWith(u8, value, "0x") or std.mem.startsWith(u8, value, "0X")) {
        return std.fmt.parseInt(u64, value[2..], 16);
    }
    return std.fmt.parseInt(u64, value, 16) catch std.fmt.parseInt(u64, value, 10);
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes")) return true;
    if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "no")) return false;
    return error.InvalidBool;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\usage: mul_free_challenge [options]
        \\
        \\Options:
        \\  --mode=mul_free|no_carry|unrestricted
        \\  --sa-steps=N
        \\  --hill-iters=N
        \\  --seed=HEX
        \\  --max-prog-len=N
        \\  --output-dir=PATH
        \\  --label=NAME
        \\  --emit-champion=0|1
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
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(std.io.getStdOut().writer());
            return;
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            cfg.mode = try mixer.parseMode(arg["--mode=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--sa-steps=")) {
            cfg.sa_steps = try std.fmt.parseInt(usize, arg["--sa-steps=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--hill-iters=")) {
            cfg.hill_iters = try std.fmt.parseInt(usize, arg["--hill-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            cfg.seed = try parseSeed(arg["--seed=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--max-prog-len=")) {
            cfg.max_prog_len = try std.fmt.parseInt(u8, arg["--max-prog-len=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--output-dir=")) {
            cfg.output_dir = arg["--output-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--label=")) {
            cfg.label = arg["--label=".len..];
        } else if (std.mem.startsWith(u8, arg, "--emit-champion=")) {
            cfg.emit_champion = try parseBool(arg["--emit-champion=".len..]);
        } else {
            try std.io.getStdErr().writer().print("unknown arg: {s}\n", .{arg});
            try printUsage(std.io.getStdErr().writer());
            return error.InvalidArgument;
        }
    }

    const artifacts = try runToFiles(allocator, cfg);
    defer artifacts.deinit(allocator);

    const result = artifacts.result;
    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== MUL-FREE MIXER CHALLENGE ===\n", .{});
    try stdout.print("mode={s} seed=0x{X} sa_steps={d} hill_iters={d} max_prog_len={d}\n", .{
        mixer.modeName(result.mode),
        result.seed,
        cfg.sa_steps,
        cfg.hill_iters,
        mixer.normalizeMaxLen(cfg.max_prog_len),
    });
    try stdout.print("best_outer_iter={d} evaluated={d} accepted={d} elapsed_ms={d}\n", .{
        result.best_outer_iter,
        result.evaluated,
        result.accepted,
        result.elapsed_ms,
    });
    try stdout.print("best: composite={d:.6} avalanche={d:.6} balance={d:.6} period={d} chisq={d:.6} len={d} hash=0x{X}\n", .{
        result.best_quality.composite,
        result.best_quality.avalanche,
        result.best_quality.balance,
        result.best_quality.period,
        result.best_quality.chisq,
        result.best_program.used,
        mixer.programHash(result.best_program),
    });
    try stdout.print("champion_csv={s}\nsearch_log={s}\n", .{ artifacts.champion_path, artifacts.log_path });
    try mixer.printProgram(result.best_program, result.mode, stdout);
}
