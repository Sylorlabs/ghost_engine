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
        \\usage: recursive_engine_loop [--generations=N] [--meta-iters=N] [--pool=N] [--seed=HEX] [--budget-scale=F] [--csv=PATH] [--champions=PATH]
        \\
        \\Runs a recursive invention-engine improvement loop. Each generation
        \\searches for a new engine strategy from the current incumbent and
        \\promotes it only if held-out validation/test evidence beats the
        \\incumbent. Scaled budgets are dry runs; only --budget-scale=1.0 can
        \\produce a supported promotion.
        \\
    );
}

fn ensureParent(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) try std.fs.cwd().makePath(dir);
    }
}

fn lessThan(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn bootstrapDelta(candidate: []const strategy.CaseResult, incumbent: []const strategy.CaseResult, split: strategy.Split, seed: u64) BootstrapResult {
    var diffs: [strategy.BatteryLen]f64 = undefined;
    var n: usize = 0;
    for (candidate, incumbent) |c, b| {
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

fn evalCases(program: strategy.Program) [strategy.BatteryLen]strategy.CaseResult {
    var out: [strategy.BatteryLen]strategy.CaseResult = undefined;
    var i: usize = 0;
    while (i < strategy.BatteryLen) : (i += 1) {
        out[i] = strategy.evaluateCaseAt(program, i);
    }
    return out;
}

fn writeProgramRow(writer: anytype, generation: usize, role: []const u8, p: strategy.Program, report: strategy.EvaluationReport, budget_scale: f64) !void {
    try writer.print("{d},{s},{d:.6},{d:.6},{d},{d:.6},{d:.6},{d},{d},{d},{d},{d},{d},{d},{d:.6},{d},{d},{d:.6},{d},{d},{d:.6},{d:.6}\n", .{
        generation,
        role,
        p.mutation_rate,
        p.crossover_rate,
        p.pool_size,
        p.t_start,
        p.cooling_exponent,
        p.restart_period,
        @intFromEnum(p.parent_selection),
        @intFromEnum(p.replacement_policy),
        @intFromEnum(p.acceptance_policy),
        @intFromEnum(p.cooling_schedule),
        report.train.strict_hits,
        report.train.runs,
        report.train.hit_rate,
        report.validation.strict_hits,
        report.validation.runs,
        report.validation.hit_rate,
        report.test_set.strict_hits,
        report.test_set.runs,
        report.test_set.hit_rate,
        budget_scale,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var generations: usize = 3;
    var meta_iters: usize = 4;
    var pool: usize = 8;
    var seed: u64 = 0x1EAF_1009_2026_0520;
    var budget_scale: f64 = 0.02;
    var csv_path: []const u8 = "results/recursive_engine_loop.csv";
    var champions_path: []const u8 = "results/recursive_engine_champions.csv";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try usage(std.io.getStdOut().writer());
            return;
        } else if (std.mem.startsWith(u8, arg, "--generations=")) {
            generations = try std.fmt.parseInt(usize, arg["--generations=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--meta-iters=")) {
            meta_iters = try std.fmt.parseInt(usize, arg["--meta-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--pool=")) {
            pool = try std.fmt.parseInt(usize, arg["--pool=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--budget-scale=")) {
            budget_scale = try std.fmt.parseFloat(f64, arg["--budget-scale=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--csv=")) {
            csv_path = arg["--csv=".len..];
        } else if (std.mem.startsWith(u8, arg, "--champions=")) {
            champions_path = arg["--champions=".len..];
        } else {
            try std.io.getStdErr().writer().print("unknown argument: {s}\n", .{arg});
            try usage(std.io.getStdErr().writer());
            return error.UnknownArgument;
        }
    }

    strategy.setEvaluationConfig(.{ .budget_scale = budget_scale });
    budget_scale = strategy.getEvaluationConfig().budget_scale;

    try ensureParent(csv_path);
    try ensureParent(champions_path);

    var csv = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv.close();
    const csvw = csv.writer();
    try csvw.writeAll("generation,incumbent_name,candidate_name,decision,reason,train_delta,train_ci_low,train_ci_high,validation_delta,validation_ci_low,validation_ci_high,test_delta,test_ci_low,test_ci_high,novelty,accepted_meta_mutations,meta_iters,budget_scale\n");

    var champions = try std.fs.cwd().createFile(champions_path, .{ .truncate = true });
    defer champions.close();
    const champw = champions.writer();
    try champw.writeAll("generation,role,mutation_rate,crossover_rate,pool_size,t_start,cooling_exponent,restart_period,parent_selection_id,replacement_policy_id,acceptance_policy_id,cooling_schedule_id,train_hits,train_runs,train_hit_rate,validation_hits,validation_runs,validation_hit_rate,test_hits,test_runs,test_hit_rate,budget_scale\n");

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== RECURSIVE INVENTION-ENGINE LOOP ===\n", .{});
    try stdout.print("generations={d} meta_iters={d} pool={d} seed=0x{X} budget_scale={d:.6}\n", .{ generations, meta_iters, pool, seed, budget_scale });
    if (budget_scale < 1.0) {
        try stdout.writeAll("budget_status=SCALED_DRY_RUN_PROMOTIONS_DISABLED\n\n");
    } else {
        try stdout.writeAll("budget_status=FULL_CALIBRATED_PROMOTION_ENABLED\n\n");
    }

    const baseline = strategy.bestLibraryOnTrain();
    var incumbent = baseline.program;
    var incumbent_name: []const u8 = baseline.name;
    var incumbent_cases = evalCases(incumbent);
    var incumbent_report = strategy.evaluateReport(incumbent);
    try writeProgramRow(champw, 0, "incumbent", incumbent, incumbent_report, budget_scale);

    var gen: usize = 0;
    while (gen < generations) : (gen += 1) {
        const Eng = engine.Engine(strategy);
        var e = Eng.init(seed ^ engine.smix(@as(u64, @intCast(gen + 1))));
        e.seedPool(pool);
        _ = e.seedProgram(incumbent);
        for (strategy.canonicalPresets()) |preset| {
            _ = e.seedProgram(preset.program);
        }

        try stdout.print("generation {d}: incumbent={s} seeded_pool={d}\n", .{ gen + 1, incumbent_name, e.count });
        const sr = try e.searchWithConfig(meta_iters, .{
            .mutation_rate = incumbent.mutation_rate,
            .crossover_rate = incumbent.crossover_rate,
            .t_start = incumbent.t_start,
            .cooling_exponent = incumbent.cooling_exponent,
            .restart_period = incumbent.restart_period,
            .parent_selection = incumbent.parent_selection,
            .replacement_policy = incumbent.replacement_policy,
            .acceptance_policy = incumbent.acceptance_policy,
            .cooling_schedule = incumbent.cooling_schedule,
        }, null);

        const candidate = sr.best_program;
        const candidate_cases = evalCases(candidate);
        const candidate_report = strategy.evaluateReport(candidate);
        const train_ci = bootstrapDelta(candidate_cases[0..], incumbent_cases[0..], .train, seed ^ @as(u64, @intCast(0x1000 + gen)));
        const validation_ci = bootstrapDelta(candidate_cases[0..], incumbent_cases[0..], .validation, seed ^ @as(u64, @intCast(0x2000 + gen)));
        const test_ci = bootstrapDelta(candidate_cases[0..], incumbent_cases[0..], .test_set, seed ^ @as(u64, @intCast(0x3000 + gen)));
        const distance = try strategy.distanceToLibrary(candidate, allocator);
        const reach = try strategy.reachability(candidate, allocator);
        const novelty = noveltyStatus(distance, reach);
        const evidence_pass = validation_ci.delta > 0.0 and test_ci.delta > 0.0 and test_ci.ci_low > 0.0;
        const decision = if (evidence_pass and budget_scale >= 1.0) "promoted" else "rejected";
        const reason = if (evidence_pass and budget_scale < 1.0) "scaled_budget_dry_run" else if (evidence_pass) "heldout_supported" else "heldout_not_supported";

        try csvw.print("{d},{s},candidate,{s},{s},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{s},{d},{d},{d:.6}\n", .{
            gen + 1,
            incumbent_name,
            decision,
            reason,
            train_ci.delta,
            train_ci.ci_low,
            train_ci.ci_high,
            validation_ci.delta,
            validation_ci.ci_low,
            validation_ci.ci_high,
            test_ci.delta,
            test_ci.ci_low,
            test_ci.ci_high,
            novelty,
            sr.accepted,
            sr.iterations,
            budget_scale,
        });
        try writeProgramRow(champw, gen + 1, "candidate", candidate, candidate_report, budget_scale);

        try stdout.print("  candidate train={d}/{d} validation={d}/{d} test={d}/{d}\n", .{
            candidate_report.train.strict_hits,
            candidate_report.train.runs,
            candidate_report.validation.strict_hits,
            candidate_report.validation.runs,
            candidate_report.test_set.strict_hits,
            candidate_report.test_set.runs,
        });
        try stdout.print("  deltas train={d:.4} validation={d:.4} test={d:.4} test_ci=[{d:.4},{d:.4}] novelty={s} decision={s} reason={s}\n", .{
            train_ci.delta,
            validation_ci.delta,
            test_ci.delta,
            test_ci.ci_low,
            test_ci.ci_high,
            novelty,
            decision,
            reason,
        });

        if (std.mem.eql(u8, decision, "promoted")) {
            incumbent = candidate;
            incumbent_name = "recursive_candidate";
            incumbent_cases = candidate_cases;
            incumbent_report = candidate_report;
            try writeProgramRow(champw, gen + 1, "promoted_incumbent", incumbent, incumbent_report, budget_scale);
        }
    }

    try stdout.print("\nfinal_incumbent={s}\n", .{incumbent_name});
    try stdout.print("final_train={d}/{d} final_validation={d}/{d} final_test={d}/{d}\n", .{
        incumbent_report.train.strict_hits,
        incumbent_report.train.runs,
        incumbent_report.validation.strict_hits,
        incumbent_report.validation.runs,
        incumbent_report.test_set.strict_hits,
        incumbent_report.test_set.runs,
    });
    try stdout.print("CSV: {s}\nChampions: {s}\n", .{ csv_path, champions_path });
}
