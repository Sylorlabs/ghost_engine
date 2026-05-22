const std = @import("std");
const engine = @import("invention_engine.zig");
const boolean = @import("domain_boolean.zig");
const sort_net = @import("domain_sort_net.zig");
const u64_mixer = @import("domain_u64_mixer.zig");

// --- DOMAIN: search-strategy meta-invention ---
//
// Program = a tuple of engine search controls:
//   mutation_rate, crossover_rate, pool_size, t_start, cooling_exponent,
//   restart_period.
//
// The meta-search objective is train-only. Validation/test batteries are
// exposed for the runner so self-improvement claims can be made from held-out
// evidence instead of the seeds optimized by the engine.

pub const DOMAIN_NAME: []const u8 = "search-strategy-meta";

const MinPool: u8 = 8;
const MaxPool: u8 = 64;
const MinTStart: f64 = 0.05;
const MaxTStart: f64 = 96.0;
const MinCooling: f64 = 0.25;
const MaxCooling: f64 = 3.0;
const MaxRestart: u16 = 2048;
const CalibrationSamples: usize = 96;

pub const Split = enum {
    train,
    validation,
    test_set,
};

const BatteryDomain = enum {
    u64_mixer,
    sort_net,
    boolean,
};

pub const BatteryCase = struct {
    name: []const u8,
    split: Split,
    domain: BatteryDomain,
    seed: u64,
    full_iters: usize,
};

const U64Budget: usize = 8_000;
const SortBudget: usize = 50_000;
const BoolBudget: usize = 200_000;

const battery = [_]BatteryCase{
    .{ .name = "train/u64/1", .split = .train, .domain = .u64_mixer, .seed = 0xABCDEF0123456789, .full_iters = U64Budget },
    .{ .name = "train/u64/2", .split = .train, .domain = .u64_mixer, .seed = 0xC0FFEEBABEF00D12, .full_iters = U64Budget },
    .{ .name = "train/u64/3", .split = .train, .domain = .u64_mixer, .seed = 0x13579BDF2468ACE0, .full_iters = U64Budget },
    .{ .name = "train/boolean/1", .split = .train, .domain = .boolean, .seed = 0x1234567890ABCDEF, .full_iters = BoolBudget },
    .{ .name = "train/boolean/2", .split = .train, .domain = .boolean, .seed = 0xBEEFFACE12345678, .full_iters = BoolBudget },
    .{ .name = "train/boolean/3", .split = .train, .domain = .boolean, .seed = 0x0DDBA11A5EED2026, .full_iters = BoolBudget },
    .{ .name = "train/sort/1", .split = .train, .domain = .sort_net, .seed = 0xCAFEBABE12345678, .full_iters = SortBudget },
    .{ .name = "train/sort/2", .split = .train, .domain = .sort_net, .seed = 0xF00DFACEA11CE001, .full_iters = SortBudget },

    .{ .name = "validation/u64/1", .split = .validation, .domain = .u64_mixer, .seed = 0x1020304050607080, .full_iters = U64Budget },
    .{ .name = "validation/u64/2", .split = .validation, .domain = .u64_mixer, .seed = 0xA5A5A5A55A5A5A5A, .full_iters = U64Budget },
    .{ .name = "validation/u64/3", .split = .validation, .domain = .u64_mixer, .seed = 0x3141592653589793, .full_iters = U64Budget },
    .{ .name = "validation/boolean/1", .split = .validation, .domain = .boolean, .seed = 0x2718281828459045, .full_iters = BoolBudget },
    .{ .name = "validation/boolean/2", .split = .validation, .domain = .boolean, .seed = 0xFEEDFACECAFED00D, .full_iters = BoolBudget },
    .{ .name = "validation/boolean/3", .split = .validation, .domain = .boolean, .seed = 0x5151515151515151, .full_iters = BoolBudget },
    .{ .name = "validation/sort/1", .split = .validation, .domain = .sort_net, .seed = 0x1111222233334444, .full_iters = SortBudget },
    .{ .name = "validation/sort/2", .split = .validation, .domain = .sort_net, .seed = 0x9999AAAABBBBCCCC, .full_iters = SortBudget },

    .{ .name = "test/u64/1", .split = .test_set, .domain = .u64_mixer, .seed = 0x0BADF00DDEADC0DE, .full_iters = U64Budget },
    .{ .name = "test/u64/2", .split = .test_set, .domain = .u64_mixer, .seed = 0x1234ABCD5678EF90, .full_iters = U64Budget },
    .{ .name = "test/u64/3", .split = .test_set, .domain = .u64_mixer, .seed = 0x55AA55AA00FF00FF, .full_iters = U64Budget },
    .{ .name = "test/boolean/1", .split = .test_set, .domain = .boolean, .seed = 0x4242424242424242, .full_iters = BoolBudget },
    .{ .name = "test/boolean/2", .split = .test_set, .domain = .boolean, .seed = 0xDEADC0DE1234FEDC, .full_iters = BoolBudget },
    .{ .name = "test/boolean/3", .split = .test_set, .domain = .boolean, .seed = 0xABCDABCD13572468, .full_iters = BoolBudget },
    .{ .name = "test/sort/1", .split = .test_set, .domain = .sort_net, .seed = 0x777788889999AAAA, .full_iters = SortBudget },
    .{ .name = "test/sort/2", .split = .test_set, .domain = .sort_net, .seed = 0x0123456789ABCDEF, .full_iters = SortBudget },
};

pub const BatteryLen: usize = battery.len;

pub const EvaluationConfig = struct {
    budget_scale: f64 = 1.0,
};

var current_config = EvaluationConfig{};

pub fn setEvaluationConfig(config: EvaluationConfig) void {
    current_config = .{ .budget_scale = clamp(config.budget_scale, 0.0001, 1.0) };
}

pub fn getEvaluationConfig() EvaluationConfig {
    return current_config;
}

pub const Program = struct {
    mutation_rate: f64,
    crossover_rate: f64,
    pool_size: u8,
    t_start: f64,
    cooling_exponent: f64,
    restart_period: u16,
    parent_selection: engine.ParentSelection,
    replacement_policy: engine.ReplacementPolicy,
    acceptance_policy: engine.AcceptancePolicy,
    cooling_schedule: engine.CoolingSchedule,
};

pub const SplitStats = struct {
    strict_hits: u8 = 0,
    runs: u8 = 0,
    quality_hits: u8 = 0,
    errors: u8 = 0,
    hit_rate: f64 = 0.0,
    quality_rate: f64 = 0.0,
    mean_score: f64 = 0.0,
    mean_acceptance: f64 = 0.0,
};

pub const Quality = struct {
    train: SplitStats,
    composite: f64,
};

pub const EvaluationReport = struct {
    train: SplitStats,
    validation: SplitStats,
    test_set: SplitStats,
};

pub const CaseResult = struct {
    name: []const u8,
    split: Split,
    domain: []const u8,
    full_iters: usize,
    actual_iters: usize,
    strict_hit: bool,
    quality_hit: bool,
    errored: bool,
    best_score: f64,
    acceptance_rate: f64,
};

const RunOutcome = struct {
    strict_hit: bool,
    quality_hit: bool,
    errored: bool,
    best_score: f64,
    acceptance_rate: f64,
};

pub const PresetEntry = struct {
    name: []const u8,
    program: Program,
};

pub fn canonicalPresets() [3]PresetEntry {
    return .{
        .{
            .name = "hill_climbing",
            .program = normalize(.{
                .mutation_rate = 1.0,
                .crossover_rate = 0.0,
                .pool_size = 16,
                .t_start = 0.05,
                .cooling_exponent = 1.0,
                .restart_period = 0,
                .parent_selection = .tournament_best,
                .replacement_policy = .worst,
                .acceptance_policy = .greedy,
                .cooling_schedule = .constant,
            }),
        },
        .{
            .name = "vanilla_sa",
            .program = normalize(.{
                .mutation_rate = 0.75,
                .crossover_rate = 0.25,
                .pool_size = 16,
                .t_start = 8.0,
                .cooling_exponent = 1.0,
                .restart_period = 0,
                .parent_selection = .random_pool,
                .replacement_policy = .worst,
                .acceptance_policy = .metropolis,
                .cooling_schedule = .exponential,
            }),
        },
        .{
            .name = "ga_pool",
            .program = normalize(.{
                .mutation_rate = 0.35,
                .crossover_rate = 0.65,
                .pool_size = 48,
                .t_start = 1.5,
                .cooling_exponent = 0.75,
                .restart_period = 0,
                .parent_selection = .rank_biased,
                .replacement_policy = .tournament_worst,
                .acceptance_policy = .threshold,
                .cooling_schedule = .inverse,
            }),
        },
    };
}

fn clamp(x: f64, lo: f64, hi: f64) f64 {
    if (!std.math.isFinite(x)) return lo;
    if (x < lo) return lo;
    if (x > hi) return hi;
    return x;
}

fn normalize(p: Program) Program {
    var q = p;
    q.mutation_rate = clamp(q.mutation_rate, 0.0, 1.0);
    q.crossover_rate = clamp(q.crossover_rate, 0.0, 1.0);
    if (q.mutation_rate + q.crossover_rate > 1.0) {
        const total = q.mutation_rate + q.crossover_rate;
        q.mutation_rate /= total;
        q.crossover_rate /= total;
    }
    if (q.pool_size < MinPool) q.pool_size = MinPool;
    if (q.pool_size > MaxPool) q.pool_size = MaxPool;
    q.t_start = clamp(q.t_start, MinTStart, MaxTStart);
    q.cooling_exponent = clamp(q.cooling_exponent, MinCooling, MaxCooling);
    if (q.restart_period > MaxRestart) q.restart_period = MaxRestart;
    return q;
}

fn unit(rng: *u64) f64 {
    rng.* = engine.smix(rng.*);
    return @as(f64, @floatFromInt(rng.* % 1_000_000)) / 1_000_000.0;
}

fn signedUnit(rng: *u64) f64 {
    return unit(rng) * 2.0 - 1.0;
}

fn randomRestart(rng: *u64) u16 {
    rng.* = engine.smix(rng.*);
    if ((rng.* & 3) == 0) return 0;
    return @intCast(128 + (rng.* % 1024));
}

fn randomParentSelection(rng: *u64) engine.ParentSelection {
    rng.* = engine.smix(rng.*);
    return @enumFromInt(@as(u2, @intCast(rng.* % 4)));
}

fn randomReplacementPolicy(rng: *u64) engine.ReplacementPolicy {
    rng.* = engine.smix(rng.*);
    return @enumFromInt(@as(u2, @intCast(rng.* % 3)));
}

fn randomAcceptancePolicy(rng: *u64) engine.AcceptancePolicy {
    rng.* = engine.smix(rng.*);
    return @enumFromInt(@as(u2, @intCast(rng.* % 3)));
}

fn randomCoolingSchedule(rng: *u64) engine.CoolingSchedule {
    rng.* = engine.smix(rng.*);
    return @enumFromInt(@as(u2, @intCast(rng.* % 4)));
}

pub fn randomProgram(rng: *u64) Program {
    rng.* = engine.smix(rng.*);
    const pool: u8 = @intCast(MinPool + (rng.* % (MaxPool - MinPool + 1)));
    const min_log = std.math.log(f64, std.math.e, MinTStart);
    const max_log = std.math.log(f64, std.math.e, MaxTStart);
    const t = std.math.exp(min_log + unit(rng) * (max_log - min_log));
    return normalize(.{
        .mutation_rate = unit(rng),
        .crossover_rate = unit(rng),
        .pool_size = pool,
        .t_start = t,
        .cooling_exponent = MinCooling + unit(rng) * (MaxCooling - MinCooling),
        .restart_period = randomRestart(rng),
        .parent_selection = randomParentSelection(rng),
        .replacement_policy = randomReplacementPolicy(rng),
        .acceptance_policy = randomAcceptancePolicy(rng),
        .cooling_schedule = randomCoolingSchedule(rng),
    });
}

pub fn mutate(p: Program, rng: *u64) Program {
    var q = p;
    rng.* = engine.smix(rng.*);
    switch (rng.* % 10) {
        0 => q.mutation_rate += signedUnit(rng) * 0.20,
        1 => q.crossover_rate += signedUnit(rng) * 0.20,
        2 => {
            const delta = @as(i16, @intFromFloat(std.math.round(signedUnit(rng) * 10.0)));
            const next = @as(i16, q.pool_size) + delta;
            q.pool_size = @intCast(@max(@as(i16, MinPool), @min(@as(i16, MaxPool), next)));
        },
        3 => q.t_start *= std.math.exp(signedUnit(rng) * 0.75),
        4 => q.cooling_exponent += signedUnit(rng) * 0.40,
        5 => {
            if (unit(rng) < 0.20) {
                q.restart_period = 0;
            } else {
                const current: i32 = if (q.restart_period == 0) 256 else q.restart_period;
                const delta = @as(i32, @intFromFloat(std.math.round(signedUnit(rng) * 256.0)));
                const next = @max(@as(i32, 0), @min(@as(i32, MaxRestart), current + delta));
                q.restart_period = @intCast(next);
            }
        },
        6 => q.parent_selection = randomParentSelection(rng),
        7 => q.replacement_policy = randomReplacementPolicy(rng),
        8 => q.acceptance_policy = randomAcceptancePolicy(rng),
        else => q.cooling_schedule = randomCoolingSchedule(rng),
    }
    return normalize(q);
}

pub fn crossover(a: Program, b: Program, rng: *u64) Program {
    var q = a;
    rng.* = engine.smix(rng.*);
    if ((rng.* & 1) != 0) q.mutation_rate = (a.mutation_rate + b.mutation_rate) * 0.5;
    rng.* = engine.smix(rng.*);
    if ((rng.* & 1) != 0) q.crossover_rate = (a.crossover_rate + b.crossover_rate) * 0.5;
    rng.* = engine.smix(rng.*);
    if ((rng.* & 1) != 0) q.pool_size = @intCast((@as(u16, a.pool_size) + @as(u16, b.pool_size)) / 2);
    rng.* = engine.smix(rng.*);
    if ((rng.* & 1) != 0) q.t_start = std.math.sqrt(a.t_start * b.t_start);
    rng.* = engine.smix(rng.*);
    if ((rng.* & 1) != 0) q.cooling_exponent = (a.cooling_exponent + b.cooling_exponent) * 0.5;
    rng.* = engine.smix(rng.*);
    if ((rng.* & 1) != 0) q.restart_period = @intCast((@as(u32, a.restart_period) + @as(u32, b.restart_period)) / 2);
    rng.* = engine.smix(rng.*);
    if ((rng.* & 1) != 0) q.parent_selection = b.parent_selection;
    rng.* = engine.smix(rng.*);
    if ((rng.* & 1) != 0) q.replacement_policy = b.replacement_policy;
    rng.* = engine.smix(rng.*);
    if ((rng.* & 1) != 0) q.acceptance_policy = b.acceptance_policy;
    rng.* = engine.smix(rng.*);
    if ((rng.* & 1) != 0) q.cooling_schedule = b.cooling_schedule;
    return normalize(q);
}

fn actualIters(case: BatteryCase) usize {
    const scaled = @ceil(@as(f64, @floatFromInt(case.full_iters)) * current_config.budget_scale);
    return @max(@as(usize, @intFromFloat(scaled)), 1);
}

fn domainName(domain: BatteryDomain) []const u8 {
    return switch (domain) {
        .u64_mixer => "u64_mixer",
        .sort_net => "sort_net",
        .boolean => "boolean",
    };
}

fn runInner(comptime Spec: type, strategy: Program, seed: u64, iters: usize) RunOutcome {
    const Eng = engine.Engine(Spec);
    var e = Eng.init(seed);
    e.seedPool(strategy.pool_size);
    if (e.count == 0) {
        return .{ .strict_hit = false, .quality_hit = false, .errored = true, .best_score = -1.0e9, .acceptance_rate = 0.0 };
    }

    const sr = e.searchWithConfig(iters, .{
        .mutation_rate = strategy.mutation_rate,
        .crossover_rate = strategy.crossover_rate,
        .t_start = strategy.t_start,
        .cooling_exponent = strategy.cooling_exponent,
        .restart_period = strategy.restart_period,
        .parent_selection = strategy.parent_selection,
        .replacement_policy = strategy.replacement_policy,
        .acceptance_policy = strategy.acceptance_policy,
        .cooling_schedule = strategy.cooling_schedule,
    }, null) catch {
        return .{ .strict_hit = false, .quality_hit = false, .errored = true, .best_score = -1.0e9, .acceptance_rate = 0.0 };
    };

    const quality_hit = Spec.qualityPasses(sr.best_quality);
    var strict_hit = false;
    if (quality_hit) {
        const grade = Eng.grade(sr.best_program, std.heap.page_allocator) catch {
            return .{
                .strict_hit = false,
                .quality_hit = quality_hit,
                .errored = true,
                .best_score = sr.best_score,
                .acceptance_rate = @as(f64, @floatFromInt(sr.accepted)) / @as(f64, @floatFromInt(@max(sr.iterations, 1))),
            };
        };
        strict_hit = grade.verdict == .invention_strict;
    }

    return .{
        .strict_hit = strict_hit,
        .quality_hit = quality_hit,
        .errored = false,
        .best_score = sr.best_score,
        .acceptance_rate = @as(f64, @floatFromInt(sr.accepted)) / @as(f64, @floatFromInt(@max(sr.iterations, 1))),
    };
}

fn runCase(strategy: Program, case: BatteryCase) RunOutcome {
    const iters = actualIters(case);
    return switch (case.domain) {
        .u64_mixer => runInner(u64_mixer, strategy, case.seed, iters),
        .sort_net => runInner(sort_net, strategy, case.seed, iters),
        .boolean => runInner(boolean, strategy, case.seed, iters),
    };
}

pub fn evaluateCaseAt(strategy: Program, index: usize) CaseResult {
    const case = battery[index];
    const out = runCase(normalize(strategy), case);
    return .{
        .name = case.name,
        .split = case.split,
        .domain = domainName(case.domain),
        .full_iters = case.full_iters,
        .actual_iters = actualIters(case),
        .strict_hit = out.strict_hit,
        .quality_hit = out.quality_hit,
        .errored = out.errored,
        .best_score = out.best_score,
        .acceptance_rate = out.acceptance_rate,
    };
}

pub fn splitLabel(split: Split) []const u8 {
    return switch (split) {
        .train => "train",
        .validation => "validation",
        .test_set => "test",
    };
}

fn scoreSplit(stats: SplitStats, p: Program) f64 {
    const restart_penalty: f64 = if (p.restart_period == 0) 0.0 else 0.01;
    const pool_penalty = @as(f64, @floatFromInt(p.pool_size - MinPool)) / @as(f64, @floatFromInt(MaxPool - MinPool)) * 0.02;
    return stats.hit_rate * 1_000.0 + stats.quality_rate * 100.0 + stats.mean_score * 0.01 + stats.mean_acceptance - restart_penalty - pool_penalty;
}

pub fn evaluateSplit(strategy: Program, wanted: Split) SplitStats {
    const p = normalize(strategy);
    var stats = SplitStats{};
    var score_sum: f64 = 0.0;
    var acceptance_sum: f64 = 0.0;

    for (battery) |case| {
        if (case.split != wanted) continue;
        const out = runCase(p, case);
        stats.runs += 1;
        stats.strict_hits += @intFromBool(out.strict_hit);
        stats.quality_hits += @intFromBool(out.quality_hit);
        stats.errors += @intFromBool(out.errored);
        score_sum += out.best_score;
        acceptance_sum += out.acceptance_rate;
    }

    if (stats.runs != 0) {
        const runs_f = @as(f64, @floatFromInt(stats.runs));
        stats.hit_rate = @as(f64, @floatFromInt(stats.strict_hits)) / runs_f;
        stats.quality_rate = @as(f64, @floatFromInt(stats.quality_hits)) / runs_f;
        stats.mean_score = score_sum / runs_f;
        stats.mean_acceptance = acceptance_sum / runs_f;
    }
    return stats;
}

pub fn evaluateReport(strategy: Program) EvaluationReport {
    return .{
        .train = evaluateSplit(strategy, .train),
        .validation = evaluateSplit(strategy, .validation),
        .test_set = evaluateSplit(strategy, .test_set),
    };
}

pub fn evaluateQuality(p: Program) Quality {
    const normalized = normalize(p);
    const train = evaluateSplit(normalized, .train);
    return .{
        .train = train,
        .composite = scoreSplit(train, normalized),
    };
}

pub fn qualityScalar(q: Quality) f64 {
    return q.composite;
}

pub fn bestLibraryOnTrain() PresetEntry {
    const presets = canonicalPresets();
    var best = presets[0];
    var best_quality = evaluateQuality(best.program);
    for (presets[1..]) |entry| {
        const q = evaluateQuality(entry.program);
        if (q.train.hit_rate > best_quality.train.hit_rate or (q.train.hit_rate == best_quality.train.hit_rate and q.composite > best_quality.composite)) {
            best = entry;
            best_quality = q;
        }
    }
    return best;
}

pub fn libraryBestTrainHitRate() f64 {
    return evaluateQuality(bestLibraryOnTrain().program).train.hit_rate;
}

pub fn qualityPasses(q: Quality) bool {
    if (q.train.runs == 0 or q.train.errors == q.train.runs) return false;
    return q.train.hit_rate > libraryBestTrainHitRate();
}

pub fn isFinite(q: Quality) bool {
    return std.math.isFinite(q.train.hit_rate) and std.math.isFinite(q.train.quality_rate) and std.math.isFinite(q.train.mean_score) and std.math.isFinite(q.composite);
}

pub const DistanceResult = struct {
    closest_name: []const u8,
    min_norm_distance: f64,
    equivalent_threshold: f64,
    trivial_threshold: f64,
    remix_threshold: f64,
    calibration_samples: usize,
};

fn restartScalar(p: Program) f64 {
    return @as(f64, @floatFromInt(p.restart_period)) / @as(f64, @floatFromInt(MaxRestart));
}

fn normTStart(p: Program) f64 {
    const min_log = std.math.log(f64, std.math.e, MinTStart);
    const max_log = std.math.log(f64, std.math.e, MaxTStart);
    return (std.math.log(f64, std.math.e, p.t_start) - min_log) / (max_log - min_log);
}

fn strategyDistance(a_raw: Program, b_raw: Program) f64 {
    const a = normalize(a_raw);
    const b = normalize(b_raw);
    const dm = a.mutation_rate - b.mutation_rate;
    const dc = a.crossover_rate - b.crossover_rate;
    const dp = @as(f64, @floatFromInt(a.pool_size)) - @as(f64, @floatFromInt(b.pool_size));
    const dt = normTStart(a) - normTStart(b);
    const de = (a.cooling_exponent - b.cooling_exponent) / (MaxCooling - MinCooling);
    const dr = restartScalar(a) - restartScalar(b);
    const dp_norm = dp / @as(f64, @floatFromInt(MaxPool - MinPool));
    const d_parent: f64 = if (a.parent_selection == b.parent_selection) 0.0 else 1.0;
    const d_replace: f64 = if (a.replacement_policy == b.replacement_policy) 0.0 else 1.0;
    const d_accept: f64 = if (a.acceptance_policy == b.acceptance_policy) 0.0 else 1.0;
    const d_cooling: f64 = if (a.cooling_schedule == b.cooling_schedule) 0.0 else 1.0;
    return std.math.sqrt((dm * dm + dc * dc + dp_norm * dp_norm + dt * dt + de * de + dr * dr + d_parent * d_parent + d_replace * d_replace + d_accept * d_accept + d_cooling * d_cooling) / 10.0);
}

fn lessThan(_: void, a: f64, b: f64) bool {
    return a < b;
}

const Calibration = struct {
    equivalent_threshold: f64,
    trivial_threshold: f64,
    remix_threshold: f64,
    reachable_threshold: f64,
};

fn calibratedThresholds() Calibration {
    var rng: u64 = 0xC411B2A7ED5EED01;
    var sample: [CalibrationSamples]Program = undefined;
    for (&sample) |*slot| {
        slot.* = randomProgram(&rng);
    }

    var nearest_random: [CalibrationSamples]f64 = undefined;
    for (sample, 0..) |p, i| {
        var best = std.math.inf(f64);
        for (sample, 0..) |q, j| {
            if (i == j) continue;
            const d = strategyDistance(p, q);
            if (d < best) best = d;
        }
        nearest_random[i] = best;
    }
    std.mem.sort(f64, nearest_random[0..], {}, lessThan);

    const presets = canonicalPresets();
    var nearest_blend: [CalibrationSamples]f64 = undefined;
    for (sample, 0..) |p, i| {
        var best = std.math.inf(f64);
        for (presets) |a| {
            const da = strategyDistance(p, a.program);
            if (da < best) best = da;
            for (presets) |b| {
                const ab = blend(a.program, b.program);
                const dab = strategyDistance(p, ab);
                if (dab < best) best = dab;
                for (presets) |c| {
                    const abc = blend(ab, c.program);
                    const dabc = strategyDistance(p, abc);
                    if (dabc < best) best = dabc;
                }
            }
        }
        nearest_blend[i] = best;
    }
    std.mem.sort(f64, nearest_blend[0..], {}, lessThan);

    const p01 = nearest_random[@max(CalibrationSamples / 100, 1) - 1];
    const p05 = nearest_random[@max((CalibrationSamples * 5) / 100, 1) - 1];
    const p25 = nearest_random[(CalibrationSamples * 25) / 100];
    const blend05 = nearest_blend[@max((CalibrationSamples * 5) / 100, 1) - 1];

    return .{
        .equivalent_threshold = p01 * 0.10,
        .trivial_threshold = p05,
        .remix_threshold = p25,
        .reachable_threshold = blend05,
    };
}

pub fn distanceToLibrary(p: Program, allocator: std.mem.Allocator) !DistanceResult {
    _ = allocator;
    const presets = canonicalPresets();
    const thresholds = calibratedThresholds();
    var best_name: []const u8 = "";
    var best = std.math.inf(f64);
    for (presets) |entry| {
        const d = strategyDistance(p, entry.program);
        if (d < best) {
            best = d;
            best_name = entry.name;
        }
    }
    return .{
        .closest_name = best_name,
        .min_norm_distance = best,
        .equivalent_threshold = thresholds.equivalent_threshold,
        .trivial_threshold = thresholds.trivial_threshold,
        .remix_threshold = thresholds.remix_threshold,
        .calibration_samples = CalibrationSamples,
    };
}

pub fn isEquivalent(d: DistanceResult) bool {
    return d.min_norm_distance <= d.equivalent_threshold;
}

pub fn isTrivialVariant(d: DistanceResult) bool {
    return d.min_norm_distance <= d.trivial_threshold;
}

pub fn isRemix(d: DistanceResult) bool {
    return d.min_norm_distance <= d.remix_threshold;
}

pub const ReachabilityResult = struct {
    min_blend_distance: f64,
    threshold: f64,
    best_depth: usize,
    reachable: bool,
    calibration_samples: usize,
};

fn blend(a: Program, b: Program) Program {
    return normalize(.{
        .mutation_rate = (a.mutation_rate + b.mutation_rate) * 0.5,
        .crossover_rate = (a.crossover_rate + b.crossover_rate) * 0.5,
        .pool_size = @intCast((@as(u16, a.pool_size) + @as(u16, b.pool_size)) / 2),
        .t_start = std.math.sqrt(a.t_start * b.t_start),
        .cooling_exponent = (a.cooling_exponent + b.cooling_exponent) * 0.5,
        .restart_period = @intCast((@as(u32, a.restart_period) + @as(u32, b.restart_period)) / 2),
        .parent_selection = a.parent_selection,
        .replacement_policy = a.replacement_policy,
        .acceptance_policy = a.acceptance_policy,
        .cooling_schedule = a.cooling_schedule,
    });
}

fn parentSelectionName(value: engine.ParentSelection) []const u8 {
    return switch (value) {
        .random_pool => "random_pool",
        .tournament_best => "tournament_best",
        .rank_biased => "rank_biased",
        .best => "best",
    };
}

fn replacementPolicyName(value: engine.ReplacementPolicy) []const u8 {
    return switch (value) {
        .worst => "worst",
        .random_pool => "random_pool",
        .tournament_worst => "tournament_worst",
    };
}

fn acceptancePolicyName(value: engine.AcceptancePolicy) []const u8 {
    return switch (value) {
        .metropolis => "metropolis",
        .greedy => "greedy",
        .threshold => "threshold",
    };
}

fn coolingScheduleName(value: engine.CoolingSchedule) []const u8 {
    return switch (value) {
        .exponential => "exponential",
        .linear => "linear",
        .inverse => "inverse",
        .constant => "constant",
    };
}

pub fn reachability(p: Program, allocator: std.mem.Allocator) !ReachabilityResult {
    _ = allocator;
    const presets = canonicalPresets();
    const thresholds = calibratedThresholds();
    var best = std.math.inf(f64);
    var best_depth: usize = 0;

    for (presets) |a| {
        const d = strategyDistance(p, a.program);
        if (d < best) {
            best = d;
            best_depth = 1;
        }
        for (presets) |b| {
            const ab = blend(a.program, b.program);
            const d2 = strategyDistance(p, ab);
            if (d2 < best) {
                best = d2;
                best_depth = 2;
            }
            for (presets) |c| {
                const abc = blend(ab, c.program);
                const d3 = strategyDistance(p, abc);
                if (d3 < best) {
                    best = d3;
                    best_depth = 3;
                }
            }
        }
    }

    return .{
        .min_blend_distance = best,
        .threshold = thresholds.reachable_threshold,
        .best_depth = best_depth,
        .reachable = best <= thresholds.reachable_threshold,
        .calibration_samples = CalibrationSamples,
    };
}

pub fn isReachable(r: ReachabilityResult) bool {
    return r.reachable;
}

pub fn printProgram(p_raw: Program, writer: anytype) !void {
    const p = normalize(p_raw);
    const q = evaluateQuality(p);
    try writer.print("  mutation_rate={d:.4}\n", .{p.mutation_rate});
    try writer.print("  crossover_rate={d:.4}\n", .{p.crossover_rate});
    try writer.print("  pool_size={d}\n", .{p.pool_size});
    try writer.print("  t_start={d:.4}\n", .{p.t_start});
    try writer.print("  cooling_exponent={d:.4}\n", .{p.cooling_exponent});
    try writer.print("  restart_period={d}\n", .{p.restart_period});
    try writer.print("  parent_selection={s}\n", .{parentSelectionName(p.parent_selection)});
    try writer.print("  replacement_policy={s}\n", .{replacementPolicyName(p.replacement_policy)});
    try writer.print("  acceptance_policy={s}\n", .{acceptancePolicyName(p.acceptance_policy)});
    try writer.print("  cooling_schedule={s}\n", .{coolingScheduleName(p.cooling_schedule)});
    try writer.print("  train_strict_hits={d}/{d} train_hit_rate={d:.4}\n", .{ q.train.strict_hits, q.train.runs, q.train.hit_rate });
    try writer.print("  train_quality_hits={d}/{d} train_quality_rate={d:.4}\n", .{ q.train.quality_hits, q.train.runs, q.train.quality_rate });
    try writer.print("  train_mean_score={d:.4} train_mean_acceptance={d:.4}\n", .{ q.train.mean_score, q.train.mean_acceptance });
}

pub fn programToCsv(p_raw: Program, writer: anytype) !void {
    const p = normalize(p_raw);
    const q = evaluateQuality(p);
    try writer.writeAll("mutation_rate,crossover_rate,pool_size,t_start,cooling_exponent,restart_period,parent_selection,replacement_policy,acceptance_policy,cooling_schedule,train_strict_hits,train_runs,train_hit_rate,train_quality_hits,train_quality_rate,train_mean_score,train_mean_acceptance,train_composite,budget_scale\n");
    try writer.print("{d:.6},{d:.6},{d},{d:.6},{d:.6},{d},{s},{s},{s},{s},{d},{d},{d:.6},{d},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6}\n", .{
        p.mutation_rate,
        p.crossover_rate,
        p.pool_size,
        p.t_start,
        p.cooling_exponent,
        p.restart_period,
        parentSelectionName(p.parent_selection),
        replacementPolicyName(p.replacement_policy),
        acceptancePolicyName(p.acceptance_policy),
        coolingScheduleName(p.cooling_schedule),
        q.train.strict_hits,
        q.train.runs,
        q.train.hit_rate,
        q.train.quality_hits,
        q.train.quality_rate,
        q.train.mean_score,
        q.train.mean_acceptance,
        q.composite,
        current_config.budget_scale,
    });
}
