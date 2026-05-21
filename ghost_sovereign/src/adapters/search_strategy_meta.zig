const std = @import("std");
const engine = @import("invention_engine.zig");
const strategy = @import("domain_search_strategy.zig");

const BootstrapIters: usize = 2_000;

const BootstrapResult = struct {
    n: usize,
    delta: f64,
    ci_low: f64,
    ci_high: f64,
};

fn usage(writer: anytype) !void {
    try writer.writeAll(
        \\usage: search_strategy_meta [--iters=N] [--seed=HEX] [--pool=N] [--budget-scale=F] [--csv=PATH] [--cases=PATH] [--champion=PATH]
        \\
        \\Runs the search-strategy meta-domain. The search objective uses only
        \\the train split. Validation/test are evaluated after champion
        \\selection and reported with paired bootstrap confidence intervals.
        \\--budget-scale=1.0 uses full calibrated per-domain budgets:
        \\u64=8K, sort=50K, boolean=200K inner iterations.
        \\
    );
}

fn ensureParent(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) try std.fs.cwd().makePath(dir);
    }
}

fn writeSummaryRow(writer: anytype, kind: []const u8, name: []const u8, split: strategy.Split, p: strategy.Program, stats: strategy.SplitStats, budget_scale: f64) !void {
    try writer.print("{s},{s},{s},{d:.6},{d:.6},{d},{d:.6},{d:.6},{d},{d},{d},{d:.6},{d},{d:.6},{d:.6},{d:.6},{d:.6}\n", .{
        kind,
        name,
        strategy.splitLabel(split),
        p.mutation_rate,
        p.crossover_rate,
        p.pool_size,
        p.t_start,
        p.cooling_exponent,
        p.restart_period,
        stats.strict_hits,
        stats.runs,
        stats.hit_rate,
        stats.quality_hits,
        stats.quality_rate,
        stats.mean_score,
        stats.mean_acceptance,
        budget_scale,
    });
}

fn writeCaseRow(writer: anytype, kind: []const u8, name: []const u8, result: strategy.CaseResult, budget_scale: f64) !void {
    try writer.print("{s},{s},{s},{s},{s},{d},{d},{d},{d},{d},{d:.6},{d:.6},{d:.6}\n", .{
        kind,
        name,
        result.name,
        strategy.splitLabel(result.split),
        result.domain,
        result.full_iters,
        result.actual_iters,
        @intFromBool(result.strict_hit),
        @intFromBool(result.quality_hit),
        @intFromBool(result.errored),
        result.best_score,
        result.acceptance_rate,
        budget_scale,
    });
}

fn lessThan(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn bootstrapDelta(champion: []const strategy.CaseResult, baseline: []const strategy.CaseResult, split: strategy.Split, seed: u64) BootstrapResult {
    var diffs: [strategy.BatteryLen]f64 = undefined;
    var n: usize = 0;
    for (champion, baseline) |c, b| {
        if (c.split != split) continue;
        diffs[n] = @as(f64, @floatFromInt(@intFromBool(c.strict_hit))) - @as(f64, @floatFromInt(@intFromBool(b.strict_hit)));
        n += 1;
    }
    if (n == 0) return .{ .n = 0, .delta = 0.0, .ci_low = 0.0, .ci_high = 0.0 };

    var total: f64 = 0.0;
    for (diffs[0..n]) |d| total += d;
    const observed = total / @as(f64, @floatFromInt(n));

    var samples: [BootstrapIters]f64 = undefined;
    var rng = seed;
    var i: usize = 0;
    while (i < BootstrapIters) : (i += 1) {
        var sample_sum: f64 = 0.0;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            rng = engine.smix(rng);
            sample_sum += diffs[rng % n];
        }
        samples[i] = sample_sum / @as(f64, @floatFromInt(n));
    }
    std.mem.sort(f64, samples[0..], {}, lessThan);
    return .{
        .n = n,
        .delta = observed,
        .ci_low = samples[(BootstrapIters * 25) / 1000],
        .ci_high = samples[(BootstrapIters * 975) / 1000],
    };
}

fn noveltyStatus(distance: strategy.DistanceResult, reach: strategy.ReachabilityResult) []const u8 {
    if (strategy.isEquivalent(distance)) return "equivalent";
    if (strategy.isTrivialVariant(distance)) return "trivial_variant";
    if (strategy.isRemix(distance)) return "remix";
    if (strategy.isReachable(reach)) return "reachable";
    return "outside_calibrated_library_floor";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var iters: usize = 8;
    var seed: u64 = 0x5E1F_AAA0_2026_0520;
    var pool: usize = 8;
    var budget_scale: f64 = 0.02;
    var csv_path: []const u8 = "results/search_strategy_meta.csv";
    var cases_path: []const u8 = "results/search_strategy_cases.csv";
    var champion_path: []const u8 = "results/search_strategy_champion.csv";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try usage(std.io.getStdOut().writer());
            return;
        } else if (std.mem.startsWith(u8, arg, "--iters=")) {
            iters = try std.fmt.parseInt(usize, arg["--iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--pool=")) {
            pool = try std.fmt.parseInt(usize, arg["--pool=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--budget-scale=")) {
            budget_scale = try std.fmt.parseFloat(f64, arg["--budget-scale=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--csv=")) {
            csv_path = arg["--csv=".len..];
        } else if (std.mem.startsWith(u8, arg, "--cases=")) {
            cases_path = arg["--cases=".len..];
        } else if (std.mem.startsWith(u8, arg, "--champion=")) {
            champion_path = arg["--champion=".len..];
        } else {
            try std.io.getStdErr().writer().print("unknown argument: {s}\n", .{arg});
            try usage(std.io.getStdErr().writer());
            return error.UnknownArgument;
        }
    }

    strategy.setEvaluationConfig(.{ .budget_scale = budget_scale });
    const config = strategy.getEvaluationConfig();
    budget_scale = config.budget_scale;

    try ensureParent(csv_path);
    try ensureParent(cases_path);
    try ensureParent(champion_path);

    var csv = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv.close();
    const csvw = csv.writer();
    try csvw.writeAll("kind,name,split,mutation_rate,crossover_rate,pool_size,t_start,cooling_exponent,restart_period,strict_hits,runs,hit_rate,quality_hits,quality_rate,mean_score,mean_acceptance,budget_scale\n");

    var cases = try std.fs.cwd().createFile(cases_path, .{ .truncate = true });
    defer cases.close();
    const casew = cases.writer();
    try casew.writeAll("kind,name,case,split,domain,full_iters,actual_iters,strict_hit,quality_hit,errored,best_score,acceptance_rate,budget_scale\n");

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== SEARCH STRATEGY META-DOMAIN / HELD-OUT HARNESS ===\n", .{});
    try stdout.print("meta iters={d} seed=0x{X} pool={d} budget_scale={d:.6}\n", .{ iters, seed, pool, budget_scale });
    if (budget_scale < 1.0) {
        try stdout.writeAll("budget_status=SCALED_SMOKE_NOT_FULL_BUDGET\n\n");
    } else {
        try stdout.writeAll("budget_status=FULL_CALIBRATED_BUDGET\n\n");
    }

    const presets = strategy.canonicalPresets();
    try stdout.writeAll("Canonical preset split battery:\n");
    for (presets) |entry| {
        const report = strategy.evaluateReport(entry.program);
        try writeSummaryRow(csvw, "library", entry.name, .train, entry.program, report.train, budget_scale);
        try writeSummaryRow(csvw, "library", entry.name, .validation, entry.program, report.validation, budget_scale);
        try writeSummaryRow(csvw, "library", entry.name, .test_set, entry.program, report.test_set, budget_scale);
        try stdout.print("  {s}: train={d}/{d} validation={d}/{d} test={d}/{d}\n", .{
            entry.name,
            report.train.strict_hits,
            report.train.runs,
            report.validation.strict_hits,
            report.validation.runs,
            report.test_set.strict_hits,
            report.test_set.runs,
        });
    }

    const baseline = strategy.bestLibraryOnTrain();
    const baseline_report = strategy.evaluateReport(baseline.program);
    try stdout.print("Train-selected library baseline: {s}\n\n", .{baseline.name});

    const Eng = engine.Engine(strategy);
    var e = Eng.init(seed);
    e.seedPool(pool);
    try stdout.print("Seeded meta pool with {d} strategies. Searching train split only...\n\n", .{e.count});

    const sr = try e.searchWithConfig(iters, .{
        .mutation_rate = 0.75,
        .crossover_rate = 0.25,
        .t_start = 5.0,
        .cooling_exponent = 1.0,
        .restart_period = 0,
    }, stdout);

    const champion_report = strategy.evaluateReport(sr.best_program);
    try writeSummaryRow(csvw, "baseline", baseline.name, .train, baseline.program, baseline_report.train, budget_scale);
    try writeSummaryRow(csvw, "baseline", baseline.name, .validation, baseline.program, baseline_report.validation, budget_scale);
    try writeSummaryRow(csvw, "baseline", baseline.name, .test_set, baseline.program, baseline_report.test_set, budget_scale);
    try writeSummaryRow(csvw, "champion", "meta_search", .train, sr.best_program, champion_report.train, budget_scale);
    try writeSummaryRow(csvw, "champion", "meta_search", .validation, sr.best_program, champion_report.validation, budget_scale);
    try writeSummaryRow(csvw, "champion", "meta_search", .test_set, sr.best_program, champion_report.test_set, budget_scale);

    var baseline_cases: [strategy.BatteryLen]strategy.CaseResult = undefined;
    var champion_cases: [strategy.BatteryLen]strategy.CaseResult = undefined;
    var idx: usize = 0;
    while (idx < strategy.BatteryLen) : (idx += 1) {
        baseline_cases[idx] = strategy.evaluateCaseAt(baseline.program, idx);
        champion_cases[idx] = strategy.evaluateCaseAt(sr.best_program, idx);
        try writeCaseRow(casew, "baseline", baseline.name, baseline_cases[idx], budget_scale);
        try writeCaseRow(casew, "champion", "meta_search", champion_cases[idx], budget_scale);
    }

    const train_ci = bootstrapDelta(champion_cases[0..], baseline_cases[0..], .train, seed ^ 0x1111);
    const validation_ci = bootstrapDelta(champion_cases[0..], baseline_cases[0..], .validation, seed ^ 0x2222);
    const test_ci = bootstrapDelta(champion_cases[0..], baseline_cases[0..], .test_set, seed ^ 0x3333);

    const distance = try strategy.distanceToLibrary(sr.best_program, allocator);
    const reach = try strategy.reachability(sr.best_program, allocator);
    const novelty = noveltyStatus(distance, reach);
    const heldout_supported = validation_ci.delta > 0.0 and test_ci.delta > 0.0 and test_ci.ci_low > 0.0 and std.mem.eql(u8, novelty, "outside_calibrated_library_floor");
    const claim_status = if (heldout_supported and budget_scale >= 1.0) "supported" else "unresolved";

    var champion = try std.fs.cwd().createFile(champion_path, .{ .truncate = true });
    defer champion.close();
    try strategy.programToCsv(sr.best_program, champion.writer());

    try stdout.print("\n=== META RESULT ===\n", .{});
    try strategy.printProgram(sr.best_program, stdout);
    try stdout.print("  baseline={s}\n", .{baseline.name});
    try stdout.print("  train_delta={d:.4} ci95=[{d:.4},{d:.4}] n={d}\n", .{ train_ci.delta, train_ci.ci_low, train_ci.ci_high, train_ci.n });
    try stdout.print("  validation_delta={d:.4} ci95=[{d:.4},{d:.4}] n={d}\n", .{ validation_ci.delta, validation_ci.ci_low, validation_ci.ci_high, validation_ci.n });
    try stdout.print("  test_delta={d:.4} ci95=[{d:.4},{d:.4}] n={d}\n", .{ test_ci.delta, test_ci.ci_low, test_ci.ci_high, test_ci.n });
    try stdout.print("  novelty_status={s}\n", .{novelty});
    try stdout.print("  closest_library={s} distance={d:.6} thresholds(eq={d:.6},trivial={d:.6},remix={d:.6})\n", .{
        distance.closest_name,
        distance.min_norm_distance,
        distance.equivalent_threshold,
        distance.trivial_threshold,
        distance.remix_threshold,
    });
    try stdout.print("  reachability_distance={d:.6} threshold={d:.6} depth={d}\n", .{ reach.min_blend_distance, reach.threshold, reach.best_depth });
    try stdout.print("  accepted_meta_mutations={d}/{d}\n", .{ sr.accepted, sr.iterations });
    try stdout.print("  claim_status={s}\n", .{claim_status});
    if (budget_scale < 1.0) {
        try stdout.writeAll("  claim_note=scaled budget run; full-budget self-improvement remains unresolved\n");
    }
    try stdout.print("\nCSV: {s}\nCases: {s}\nChampion: {s}\n", .{ csv_path, cases_path, champion_path });
}
