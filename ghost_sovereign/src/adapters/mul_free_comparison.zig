const std = @import("std");
const engine = @import("invention_engine.zig");
const mixer = @import("domain_u64_mixer_mulfree.zig");
const challenge = @import("mul_free_challenge.zig");

const Tier = struct {
    label: []const u8,
};

const tiers = [_]Tier{
    .{ .label = "1M" },
    .{ .label = "64M" },
    .{ .label = "1G" },
    .{ .label = "16G" },
    .{ .label = "64G" },
    .{ .label = "1T" },
};

const Config = struct {
    output_dir: []const u8 = "results/phaseF_mul_free_challenge",
    seed: u64 = 0xF00D_CAFE_1234_5678,
    seeds: usize = 3,
    pilot_sa_steps: usize = 10_000,
    pilot_hill_iters: usize = 100,
    sa_steps: usize = 100_000,
    hill_iters: usize = 200,
    run_full: bool = true,
    pilot_only: bool = false,
    practrand: bool = false,
    verify: bool = true,
    max_tier: []const u8 = "64G",
    pilot_min_composite: f64 = -1.0e9,
    verify_bits: u8 = 8,
    verify_timeout_ms: u32 = 30_000,
};

const PractRandResult = struct {
    top_tier: []const u8,
    pass_1m: bool,
    pass_64m: bool,
    last_log_path: []u8,

    fn deinit(self: PractRandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.last_log_path);
    }
};

const VerifyResult = struct {
    verdict: []const u8,
    log_path: []u8,

    fn deinit(self: VerifyResult, allocator: std.mem.Allocator) void {
        allocator.free(self.log_path);
    }
};

const RunRecord = struct {
    phase: []const u8,
    mode: mixer.MulFreeMode,
    seed_index: usize,
    seed: u64,
    champion_path: []u8,
    log_path: []u8,
    practrand_log_path: []u8,
    verify_log_path: []u8,
    best_quality: mixer.Quality,
    len: u8,
    hash: u64,
    evaluated: usize,
    elapsed_ms: u64,
    practrand_top_tier: []const u8,
    practrand_pass_1m: bool,
    practrand_pass_64m: bool,
    verify_verdict: []const u8,

    fn deinit(self: RunRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.champion_path);
        allocator.free(self.log_path);
        allocator.free(self.practrand_log_path);
        allocator.free(self.verify_log_path);
    }
};

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

fn tierLimitIndex(label: []const u8) !usize {
    for (tiers, 0..) |tier, idx| {
        if (std.mem.eql(u8, tier.label, label)) return idx;
    }
    return error.InvalidTier;
}

fn modeSeed(base: u64, mode: mixer.MulFreeMode, seed_index: usize, pilot: bool) u64 {
    var x = base;
    x +%= @as(u64, @intCast(seed_index)) *% 0x9E3779B97F4A7C15;
    x +%= switch (mode) {
        .mul_free => 0x1111_2222_3333_4444,
        .no_carry => 0x5555_6666_7777_8888,
        .unrestricted => 0x9999_AAAA_BBBB_CCCC,
    };
    if (pilot) x +%= 0xD00D_0000_0000_0001;
    return engine.smix(x);
}

fn maxLenForMode(mode: mixer.MulFreeMode) u8 {
    return switch (mode) {
        .unrestricted => 12,
        .mul_free, .no_carry => 24,
    };
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.append('\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice("'\\''");
        } else {
            try out.append(c);
        }
    }
    try out.append('\'');
    return out.toOwnedSlice();
}

fn termExitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn runShell(allocator: std.mem.Allocator, command: []const u8) !bool {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/bin/sh", "-lc", command },
        .max_output_bytes = 4 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return termExitedZero(result.term);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn practrandLogPassed(allocator: std.mem.Allocator, path: []const u8) !bool {
    const contents = try readFileAlloc(allocator, path, 2 * 1024 * 1024);
    defer allocator.free(contents);
    if (std.mem.indexOf(u8, contents, "no anomalies in") == null) return false;
    if (std.mem.indexOf(u8, contents, "unusual") != null) return false;
    if (std.mem.indexOf(u8, contents, "suspicious") != null) return false;
    if (std.mem.indexOf(u8, contents, "FAIL") != null) return false;
    return true;
}

fn runPractRandTiers(
    allocator: std.mem.Allocator,
    cfg: Config,
    mode: mixer.MulFreeMode,
    label: []const u8,
    champion_path: []const u8,
) !PractRandResult {
    const limit = try tierLimitIndex(cfg.max_tier);
    var top: []const u8 = "not_run";
    var pass_1m = false;
    var pass_64m = false;
    var last_log_path = try allocator.dupe(u8, "");
    errdefer allocator.free(last_log_path);

    const q_champion = try shellQuote(allocator, champion_path);
    defer allocator.free(q_champion);
    const q_mode = try shellQuote(allocator, mixer.modeName(mode));
    defer allocator.free(q_mode);

    var idx: usize = 0;
    while (idx <= limit) : (idx += 1) {
        const tier = tiers[idx];
        allocator.free(last_log_path);
        last_log_path = try std.fmt.allocPrint(allocator, "{s}/practrand_{s}_{s}.txt", .{ cfg.output_dir, label, tier.label });

        const q_log = try shellQuote(allocator, last_log_path);
        defer allocator.free(q_log);
        const command = try std.fmt.allocPrint(
            allocator,
            "./zig-out/bin/practrand_emit_mulfree --mode={s} --program={s} --bytes={s} | RNG_test stdin64 -tlmax {s} > {s} 2>&1",
            .{ q_mode, q_champion, tier.label, tier.label, q_log },
        );
        defer allocator.free(command);

        _ = try runShell(allocator, command);
        const passed = practrandLogPassed(allocator, last_log_path) catch false;
        if (!passed) break;
        top = tier.label;
        if (std.mem.eql(u8, tier.label, "1M")) pass_1m = true;
        if (std.mem.eql(u8, tier.label, "64M")) pass_64m = true;
        if (idx > 1) pass_64m = true;
    }

    return .{
        .top_tier = top,
        .pass_1m = pass_1m,
        .pass_64m = pass_64m,
        .last_log_path = last_log_path,
    };
}

fn verifyLogVerdict(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const contents = try readFileAlloc(allocator, path, 2 * 1024 * 1024);
    defer allocator.free(contents);
    if (std.mem.indexOf(u8, contents, "VERIFIED") != null) return "verified";
    if (std.mem.indexOf(u8, contents, "COUNTER-EXAMPLE") != null) return "counter_example";
    if (std.mem.indexOf(u8, contents, "UNKNOWN") != null) return "unknown";
    return "error";
}

fn runVerify(
    allocator: std.mem.Allocator,
    cfg: Config,
    label: []const u8,
    champion_path: []const u8,
) !VerifyResult {
    const log_path = try std.fmt.allocPrint(allocator, "{s}/verify_{s}.txt", .{ cfg.output_dir, label });
    errdefer allocator.free(log_path);
    const q_champion = try shellQuote(allocator, champion_path);
    defer allocator.free(q_champion);
    const q_log = try shellQuote(allocator, log_path);
    defer allocator.free(q_log);
    const command = try std.fmt.allocPrint(
        allocator,
        "./zig-out/bin/verify_cli --domain=mixer --csv={s} --bits={d} --timeout-ms={d} > {s} 2>&1",
        .{ q_champion, cfg.verify_bits, cfg.verify_timeout_ms, q_log },
    );
    defer allocator.free(command);

    _ = try runShell(allocator, command);
    return .{ .verdict = try verifyLogVerdict(allocator, log_path), .log_path = log_path };
}

fn runOne(
    allocator: std.mem.Allocator,
    cfg: Config,
    phase: []const u8,
    mode: mixer.MulFreeMode,
    seed_index: usize,
    pilot: bool,
    stdout: anytype,
) !RunRecord {
    const seed = modeSeed(cfg.seed, mode, seed_index, pilot);
    const label = try std.fmt.allocPrint(allocator, "{s}_{s}_seed{d}", .{ phase, mixer.modeName(mode), seed_index + 1 });
    defer allocator.free(label);

    const run_cfg = challenge.Config{
        .mode = mode,
        .sa_steps = if (pilot) cfg.pilot_sa_steps else cfg.sa_steps,
        .hill_iters = if (pilot) cfg.pilot_hill_iters else cfg.hill_iters,
        .seed = seed,
        .max_prog_len = maxLenForMode(mode),
        .output_dir = cfg.output_dir,
        .label = label,
        .emit_champion = true,
    };

    var artifacts = try challenge.runToFiles(allocator, run_cfg);
    errdefer artifacts.deinit(allocator);

    var pr = PractRandResult{
        .top_tier = "not_run",
        .pass_1m = false,
        .pass_64m = false,
        .last_log_path = try allocator.dupe(u8, ""),
    };
    errdefer pr.deinit(allocator);
    if (cfg.practrand) {
        pr.deinit(allocator);
        pr = try runPractRandTiers(allocator, cfg, mode, label, artifacts.champion_path);
    }

    var vr = VerifyResult{
        .verdict = "not_run",
        .log_path = try allocator.dupe(u8, ""),
    };
    errdefer vr.deinit(allocator);
    if (cfg.verify and pr.pass_64m) {
        vr.deinit(allocator);
        vr = try runVerify(allocator, cfg, label, artifacts.champion_path);
    }

    try stdout.print("{s: >5} {s: >12} seed={d} composite={d:.4} av={d:.3} bal={d:.3} chisq={d:.1} len={d} hash=0x{X} pr_top={s} verify={s}\n", .{
        phase,
        mixer.modeName(mode),
        seed_index + 1,
        artifacts.result.best_quality.composite,
        artifacts.result.best_quality.avalanche,
        artifacts.result.best_quality.balance,
        artifacts.result.best_quality.chisq,
        artifacts.result.best_program.used,
        mixer.programHash(artifacts.result.best_program),
        pr.top_tier,
        vr.verdict,
    });

    return .{
        .phase = phase,
        .mode = mode,
        .seed_index = seed_index,
        .seed = seed,
        .champion_path = artifacts.champion_path,
        .log_path = artifacts.log_path,
        .practrand_log_path = pr.last_log_path,
        .verify_log_path = vr.log_path,
        .best_quality = artifacts.result.best_quality,
        .len = artifacts.result.best_program.used,
        .hash = mixer.programHash(artifacts.result.best_program),
        .evaluated = artifacts.result.evaluated,
        .elapsed_ms = artifacts.result.elapsed_ms,
        .practrand_top_tier = pr.top_tier,
        .practrand_pass_1m = pr.pass_1m,
        .practrand_pass_64m = pr.pass_64m,
        .verify_verdict = vr.verdict,
    };
}

fn writeComparison(
    allocator: std.mem.Allocator,
    cfg: Config,
    records: []const RunRecord,
    pilot_gate_passed: bool,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/comparison.txt", .{cfg.output_dir});
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    const w = file.writer();

    try w.print("Ghost Sovereign MUL-free mixer challenge comparison\n", .{});
    try w.print("pilot_gate_passed={d}\n", .{@intFromBool(pilot_gate_passed)});
    try w.print("base_seed=0x{X} seeds={d} pilot={d}x{d} full={d}x{d} practrand={d} max_tier={s} verify={d} bits={d}\n\n", .{
        cfg.seed,
        cfg.seeds,
        cfg.pilot_sa_steps,
        cfg.pilot_hill_iters,
        cfg.sa_steps,
        cfg.hill_iters,
        @intFromBool(cfg.practrand),
        cfg.max_tier,
        @intFromBool(cfg.verify),
        cfg.verify_bits,
    });
    try w.writeAll("phase,mode,seed_index,seed,composite,avalanche,balance,period,chisq,len,hash,evaluated,elapsed_ms,practrand_top,pass_1M,pass_64M,verify,champion_csv,search_log,practrand_log,verify_log\n");
    for (records) |r| {
        try w.print("{s},{s},{d},0x{X},{d:.6},{d:.6},{d:.6},{d},{d:.6},{d},0x{X},{d},{d},{s},{d},{d},{s},{s},{s},{s},{s}\n", .{
            r.phase,
            mixer.modeName(r.mode),
            r.seed_index + 1,
            r.seed,
            r.best_quality.composite,
            r.best_quality.avalanche,
            r.best_quality.balance,
            r.best_quality.period,
            r.best_quality.chisq,
            r.len,
            r.hash,
            r.evaluated,
            r.elapsed_ms,
            r.practrand_top_tier,
            @intFromBool(r.practrand_pass_1m),
            @intFromBool(r.practrand_pass_64m),
            r.verify_verdict,
            r.champion_path,
            r.log_path,
            r.practrand_log_path,
            r.verify_log_path,
        });
    }
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\usage: mul_free_comparison [options]
        \\
        \\Options:
        \\  --output-dir=PATH
        \\  --seed=HEX
        \\  --seeds=N
        \\  --pilot-sa-steps=N
        \\  --pilot-hill-iters=N
        \\  --sa-steps=N
        \\  --hill-iters=N
        \\  --full=0|1
        \\  --pilot-only=0|1
        \\  --pilot-min-composite=FLOAT
        \\  --practrand=0|1
        \\  --max-tier=1M|64M|1G|16G|64G|1T
        \\  --verify=0|1
        \\  --verify-bits=N
        \\  --verify-timeout-ms=N
        \\
        \\The default performs pilot + full internal searches only. Set --practrand=1 to enable tiered external validation.
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
        } else if (std.mem.startsWith(u8, arg, "--output-dir=")) {
            cfg.output_dir = arg["--output-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            cfg.seed = try parseSeed(arg["--seed=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--seeds=")) {
            cfg.seeds = try std.fmt.parseInt(usize, arg["--seeds=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--pilot-sa-steps=")) {
            cfg.pilot_sa_steps = try std.fmt.parseInt(usize, arg["--pilot-sa-steps=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--pilot-hill-iters=")) {
            cfg.pilot_hill_iters = try std.fmt.parseInt(usize, arg["--pilot-hill-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--sa-steps=")) {
            cfg.sa_steps = try std.fmt.parseInt(usize, arg["--sa-steps=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--hill-iters=")) {
            cfg.hill_iters = try std.fmt.parseInt(usize, arg["--hill-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--full=")) {
            cfg.run_full = try parseBool(arg["--full=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--pilot-only=")) {
            cfg.pilot_only = try parseBool(arg["--pilot-only=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--pilot-min-composite=")) {
            cfg.pilot_min_composite = try std.fmt.parseFloat(f64, arg["--pilot-min-composite=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--practrand=")) {
            cfg.practrand = try parseBool(arg["--practrand=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--max-tier=")) {
            _ = try tierLimitIndex(arg["--max-tier=".len..]);
            cfg.max_tier = arg["--max-tier=".len..];
        } else if (std.mem.startsWith(u8, arg, "--verify=")) {
            cfg.verify = try parseBool(arg["--verify=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--verify-bits=")) {
            cfg.verify_bits = try std.fmt.parseInt(u8, arg["--verify-bits=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--verify-timeout-ms=")) {
            cfg.verify_timeout_ms = try std.fmt.parseInt(u32, arg["--verify-timeout-ms=".len..], 10);
        } else {
            try std.io.getStdErr().writer().print("unknown arg: {s}\n", .{arg});
            try printUsage(std.io.getStdErr().writer());
            return error.InvalidArgument;
        }
    }

    cfg.seeds = @max(@as(usize, 1), cfg.seeds);
    try std.fs.cwd().makePath(cfg.output_dir);

    var records = std.ArrayList(RunRecord).init(allocator);
    defer {
        for (records.items) |record| record.deinit(allocator);
        records.deinit();
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== MUL-FREE MATCHED-BUDGET COMPARISON ===\n", .{});
    try stdout.print("pilot={d}x{d} full={d}x{d} seeds={d} practrand={d} max_tier={s}\n", .{
        cfg.pilot_sa_steps,
        cfg.pilot_hill_iters,
        cfg.sa_steps,
        cfg.hill_iters,
        cfg.seeds,
        @intFromBool(cfg.practrand),
        cfg.max_tier,
    });

    const modes = [_]mixer.MulFreeMode{ .mul_free, .no_carry, .unrestricted };
    var pilot_gate_passed = true;
    var mul_free_pilot_passed_1m = false;
    var mul_free_best_pilot: f64 = -1.0e100;

    for (modes) |mode| {
        var seed_index: usize = 0;
        while (seed_index < cfg.seeds) : (seed_index += 1) {
            const rec = try runOne(allocator, cfg, "pilot", mode, seed_index, true, stdout);
            if (mode == .mul_free) {
                if (rec.best_quality.composite > mul_free_best_pilot) mul_free_best_pilot = rec.best_quality.composite;
                if (rec.practrand_pass_1m) mul_free_pilot_passed_1m = true;
            }
            try records.append(rec);
        }
    }

    if (cfg.practrand) {
        pilot_gate_passed = mul_free_pilot_passed_1m;
    } else {
        pilot_gate_passed = mul_free_best_pilot >= cfg.pilot_min_composite;
    }

    if (!pilot_gate_passed) {
        try stdout.print("PILOT_GATE_FAILED: mul_free_best={d:.4} pass_1M={d}; full run skipped\n", .{
            mul_free_best_pilot,
            @intFromBool(mul_free_pilot_passed_1m),
        });
    } else if (cfg.run_full and !cfg.pilot_only) {
        for (modes) |mode| {
            var seed_index: usize = 0;
            while (seed_index < cfg.seeds) : (seed_index += 1) {
                const rec = try runOne(allocator, cfg, "full", mode, seed_index, false, stdout);
                try records.append(rec);
            }
        }
    }

    try writeComparison(allocator, cfg, records.items, pilot_gate_passed);
    try stdout.print("comparison={s}/comparison.txt\n", .{cfg.output_dir});
}
