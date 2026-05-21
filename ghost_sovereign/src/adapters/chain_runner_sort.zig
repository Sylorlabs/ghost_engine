const std = @import("std");
const engine = @import("invention_engine.zig");
const sort_net = @import("domain_sort_net.zig");

// --- INVENTION CHAIN RUNNER (sort-net N=8 domain) ---
//
// Per the directive in feedback_invention_chain_directive.md and the
// 2026-05-20 "obsoletes prior" research push: this is the second-domain
// test of the v2 chain pattern.
//
// Why sort_net N=8 specifically:
//   - Has a measurable progress axis: depth (parallel comparator layers).
//   - Known SOTA: depth-6 (Bose-Nelson 1962). Library entries Floyd-8
//     and Batcher-8 are both 19 comparators with depths >= 6.
//   - Composition is concatenation, which makes the CALL_LIB-style
//     macro mechanism a natural fit.
//   - u64-mixer chain plateaued because mixer quality is saturated
//     by information theory. Sort-net depth IS NOT — depth 6 strictly
//     dominates depth 7 in every operational sense.
//
// The chain runs the SAME engine binary every generation, but with:
//   - chain_extras populated with prior champions (sort_net module-level)
//   - novelty-adjusted SA preventing trivial CALL_LIB(k) shortcuts
//   - depth-axis "strict domination" check for the obsoletes-prior verdict.

const Program = sort_net.Program;

const ReachThresholdNorm: f64 = 0.10; // chain extras reach threshold
const PoolSize: usize = 16;

var novelty_lambda: f64 = 5.0;

// --- Extended library bookkeeping ---
const ChainEntry = struct {
    name_buf: [32]u8,
    name_len: u8,
    program: Program,
    fn name(self: *const ChainEntry) []const u8 { return self.name_buf[0..self.name_len]; }
};

const ExtendedLibrary = struct {
    extras: std.ArrayList(ChainEntry),
    fn init(allocator: std.mem.Allocator) ExtendedLibrary {
        return .{ .extras = std.ArrayList(ChainEntry).init(allocator) };
    }
    fn deinit(self: *ExtendedLibrary) void { self.extras.deinit(); }
    fn append(self: *ExtendedLibrary, gen: usize, p: Program) !void {
        var e: ChainEntry = .{ .name_buf = undefined, .name_len = 0, .program = p };
        const w = try std.fmt.bufPrint(&e.name_buf, "champion_gen_{d}", .{gen});
        e.name_len = @intCast(w.len);
        try self.extras.append(e);
    }
};

// --- Novelty metric (sort-net-specific) ---
//
// For sort_net we can't use functional bit-agreement like u64-mixer:
// two correct sorters are FUNCTIONALLY IDENTICAL on every input by
// definition. So functional similarity always maxes out for any
// correct candidate.
//
// Instead novelty = structural: 1 - normalized_edit_distance to the
// closest prior. Two genuinely different sorters with overlapping
// comparator sequences have lower structural distance than two with
// disjoint comparator sequences.
fn maxStructuralSimToExtras(p: Program, lib: *const ExtendedLibrary, allocator: std.mem.Allocator) !f64 {
    if (lib.extras.items.len == 0) return 0;
    var max_sim: f64 = 0;
    for (lib.extras.items) |*entry| {
        const ed = try editDistance(p, entry.program, allocator);
        const denom = @max(p.used, entry.program.used);
        const norm = @as(f64, @floatFromInt(ed)) / @as(f64, @floatFromInt(denom));
        const sim = 1.0 - norm;
        if (sim > max_sim) max_sim = sim;
    }
    return max_sim;
}

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
            const ac = a.comps[i - 1];
            const bc = b.comps[jj - 1];
            const eq = (ac.kind == bc.kind and ac.i == bc.i and ac.j == bc.j);
            const sub: usize = if (eq) 0 else 1;
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

// --- Custom novelty-adjusted SA loop ---
const SearchPool = struct {
    progs: [PoolSize]Program,
    qs: [PoolSize]sort_net.Quality,
    qscores: [PoolSize]f64,
    fitness: [PoolSize]f64,
    count: usize,
};

var depth_weight: f64 = 10.0;

fn fitnessOf(q_scalar: f64, p: Program, q: sort_net.Quality, lib: *const ExtendedLibrary, allocator: std.mem.Allocator) !f64 {
    const sim = try maxStructuralSimToExtras(p, lib, allocator);
    const excess = if (sim > 0.5) sim - 0.5 else 0.0;
    const novelty_penalty = novelty_lambda * excess * 100.0;

    // When the candidate is fully correct, weight depth much more
    // heavily than the substrate's default −1.0 — depth IS the chain
    // progress axis. When NOT correct, fall back to the substrate's
    // composite so the search still has a gradient to climb toward
    // correctness=1.0 in the first place.
    if (q.correctness >= 1.0 - 1e-9) {
        const base: f64 = 1000.0; // correctness cliff above any non-correct
        return base - @as(f64, @floatFromInt(q.size)) * 0.5
            - @as(f64, @floatFromInt(q.d)) * depth_weight
            - novelty_penalty;
    }
    return q_scalar - novelty_penalty;
}

fn worstIdxF(pool: *const SearchPool) usize {
    var w: usize = 0;
    for (1..pool.count) |i| if (pool.fitness[i] < pool.fitness[w]) { w = i; };
    return w;
}

fn bestIdxF(pool: *const SearchPool) usize {
    var b: usize = 0;
    for (1..pool.count) |i| if (pool.fitness[i] > pool.fitness[b]) { b = i; };
    return b;
}

const SearchResult = struct {
    best: Program,
    best_q: sort_net.Quality,
    best_qscore: f64,
    best_fitness: f64,
    accepted: usize,
};

fn noveltySearch(rng_seed: u64, iters: usize, lib: *const ExtendedLibrary, allocator: std.mem.Allocator) !SearchResult {
    var rng: u64 = rng_seed;
    var pool: SearchPool = .{ .progs = undefined, .qs = undefined, .qscores = undefined, .fitness = undefined, .count = 0 };
    while (pool.count < PoolSize) {
        const p = sort_net.randomProgram(&rng);
        const q = sort_net.evaluateQuality(p);
        if (!sort_net.isFinite(q)) continue;
        const qs = sort_net.qualityScalar(q);
        pool.progs[pool.count] = p;
        pool.qs[pool.count] = q;
        pool.qscores[pool.count] = qs;
        pool.fitness[pool.count] = try fitnessOf(qs, p, q, lib, allocator);
        pool.count += 1;
    }

    var accepted: usize = 0;
    var i: usize = 0;
    const t_start: f64 = 50.0; // sort_net composites swing larger; bigger T_start
    while (i < iters) : (i += 1) {
        const t_progress = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(iters));
        const t = t_start * std.math.pow(f64, 0.001, t_progress);

        rng = engine.smix(rng);
        const parent_idx = rng % pool.count;
        const parent = pool.progs[parent_idx];

        rng = engine.smix(rng);
        const candidate: Program = if ((rng & 3) == 0 and pool.count > 1) blk: {
            rng = engine.smix(rng);
            const other_idx = rng % pool.count;
            break :blk sort_net.crossover(parent, pool.progs[other_idx], &rng);
        } else sort_net.mutate(parent, &rng);

        const cand_q = sort_net.evaluateQuality(candidate);
        if (!sort_net.isFinite(cand_q)) continue;
        const cand_qs = sort_net.qualityScalar(cand_q);
        const cand_fit = try fitnessOf(cand_qs, candidate, cand_q, lib, allocator);

        const w = worstIdxF(&pool);
        const delta = cand_fit - pool.fitness[w];
        var accept = false;
        if (delta >= 0) accept = true else {
            rng = engine.smix(rng);
            const draw = @as(f64, @floatFromInt(rng % 1_000_000)) / 1_000_000.0;
            accept = draw < std.math.exp(delta / t);
        }
        if (accept) {
            pool.progs[w] = candidate;
            pool.qs[w] = cand_q;
            pool.qscores[w] = cand_qs;
            pool.fitness[w] = cand_fit;
            accepted += 1;
        }
    }
    const b = bestIdxF(&pool);
    return .{
        .best = pool.progs[b],
        .best_q = pool.qs[b],
        .best_qscore = pool.qscores[b],
        .best_fitness = pool.fitness[b],
        .accepted = accepted,
    };
}

// --- Promotion gate (sort_net-specific) ---
const GenVerdict = enum {
    advance,
    strict_domination, // NEW: passes invention strict AND strictly dominates prior on depth axis
    halt_non_quality,
    halt_base_remix,
    halt_base_reachable,
    halt_structurally_equivalent_to_extra,
    halt_no_quality_improvement,

    fn label(self: GenVerdict) []const u8 {
        return switch (self) {
            .advance => "ADVANCE",
            .strict_domination => "ADVANCE + STRICT_DOMINATION",
            .halt_non_quality => "HALT(non_quality)",
            .halt_base_remix => "HALT(base_remix)",
            .halt_base_reachable => "HALT(base_reachable)",
            .halt_structurally_equivalent_to_extra => "HALT(structurally_equivalent_to_prior)",
            .halt_no_quality_improvement => "HALT(no_quality_improvement)",
        };
    }
};

const GenRecord = struct {
    gen: usize,
    score: f64,
    prev_score: f64,
    depth: u8,
    prev_depth: u8,
    size: u8,
    correctness: f64,
    base_norm_edit: f64,
    extras_max_sim: f64,
    verdict: GenVerdict,
};

fn runGeneration(
    allocator: std.mem.Allocator,
    gen: usize,
    iters: usize,
    seed: u64,
    prev_score: f64,
    prev_depth: u8,
    lib: *const ExtendedLibrary,
    stdout: anytype,
) !struct { record: GenRecord, program: Program, score: f64, depth: u8 } {
    try stdout.print("\n--- generation {d} | seed=0x{X} | iters={d} | chain_extras_len={d} ---\n", .{
        gen, seed, iters, sort_net.chainExtrasLen(),
    });
    const sr = try noveltySearch(seed, iters, lib, allocator);
    const d = sort_net.programDepth(sr.best);
    const sz = sort_net.programSize(sr.best);

    try stdout.print("search done. quality={d:.3} fitness={d:.3} accepted={d}/{d}\n", .{
        sr.best_qscore, sr.best_fitness, sr.accepted, iters,
    });
    try stdout.print("champion: correctness={d:.6} size={d} depth={d}\n", .{
        sr.best_q.correctness, sz, d,
    });

    // Base library gating
    const base_d = try sort_net.distanceToLibrary(sr.best, allocator);
    const base_r = try sort_net.reachability(sr.best, allocator);
    const ext_sim = try maxStructuralSimToExtras(sr.best, lib, allocator);

    try stdout.print("base: closest={s} norm_edit={d:.3} reach_norm={d:.3}\n", .{
        base_d.closest_name, base_d.norm_edit, base_r.min_norm_edit,
    });
    try stdout.print("extras: max_structural_sim={d:.3}\n", .{ext_sim});

    // Verdict
    var verdict: GenVerdict = .advance;
    const passes_quality = sort_net.qualityPasses(sr.best_q);

    if (!passes_quality) {
        verdict = .halt_non_quality;
    } else if (sort_net.isRemix(base_d)) {
        verdict = .halt_base_remix;
    } else if (sort_net.isReachable(base_r)) {
        verdict = .halt_base_reachable;
    } else if (ext_sim >= 0.90) {
        // Structural equivalence to a prior champion.
        verdict = .halt_structurally_equivalent_to_extra;
    } else if (gen > 0 and d > prev_depth) {
        // Depth REGRESSION — the chain's progress axis went backward.
        // Use depth (not substrate composite) as the chain's metric, per
        // directive: "must be a STRICT IMPROVEMENT over the prior
        // generation on the prior generation's own metric" — and for
        // sort_net, depth IS the metric. qscore can swing on size and
        // would mask the real signal.
        verdict = .halt_no_quality_improvement;
    } else if (gen > 0 and d < prev_depth) {
        // The HEADLINE verdict: strictly shorter depth + correctness=1.0
        // + structural distance. The "obsoletes prior" check.
        verdict = .strict_domination;
    } else {
        // Same depth, distinct structure, correct. Tie + diverse.
        verdict = .advance;
    }

    try stdout.print("verdict: {s}\n", .{verdict.label()});

    // Persist champion CSV
    try std.fs.cwd().makePath("results/chain_sort");
    var path_buf: [128]u8 = undefined;
    const champ_path = try std.fmt.bufPrint(&path_buf, "results/chain_sort/gen_{d}_champion.csv", .{gen});
    var f = try std.fs.cwd().createFile(champ_path, .{ .truncate = true });
    defer f.close();
    try sort_net.programToCsv(sr.best, f.writer());

    const rec = GenRecord{
        .gen = gen,
        .score = sr.best_qscore,
        .prev_score = prev_score,
        .depth = d,
        .prev_depth = prev_depth,
        .size = sz,
        .correctness = sr.best_q.correctness,
        .base_norm_edit = base_d.norm_edit,
        .extras_max_sim = ext_sim,
        .verdict = verdict,
    };

    return .{ .record = rec, .program = sr.best, .score = sr.best_qscore, .depth = d };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var generations: usize = 5;
    var iters: usize = 50000;
    var seed: u64 = 0xCAFE_BABE_1234_5678;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--generations=")) {
            generations = try std.fmt.parseInt(usize, arg["--generations=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--iters=")) {
            iters = try std.fmt.parseInt(usize, arg["--iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--lambda=")) {
            novelty_lambda = try std.fmt.parseFloat(f64, arg["--lambda=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--depth-weight=")) {
            depth_weight = try std.fmt.parseFloat(f64, arg["--depth-weight=".len..]);
        }
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== INVENTION CHAIN RUNNER | domain=sort-net-N8 ===\n", .{});
    try stdout.print("generations={d} iters_per_gen={d} root_seed=0x{X} novelty_lambda={d:.2} depth_weight={d:.2}\n", .{
        generations, iters, seed, novelty_lambda, depth_weight,
    });

    try std.fs.cwd().makePath("results/chain_sort");
    var log_file = try std.fs.cwd().createFile("results/chain_sort/chain_log.csv", .{ .truncate = true });
    defer log_file.close();
    const log = log_file.writer();
    try log.writeAll(
        "gen,score,prev_score,depth,prev_depth,size,correctness," ++
        "base_norm_edit,extras_max_sim,verdict\n",
    );

    var lib = ExtendedLibrary.init(allocator);
    defer lib.deinit();

    sort_net.chainExtrasReset();

    var prev_score: f64 = -std.math.inf(f64);
    var prev_depth: u8 = 255;
    var gen: usize = 0;
    var halted: bool = false;
    var halt_gen: usize = 0;
    var halt_reason: []const u8 = "n/a";
    var any_strict_domination: bool = false;

    while (gen < generations) : (gen += 1) {
        const gen_seed = engine.smix(seed ^ (@as(u64, 0xA5A5_A5A5_5A5A_5A5A) +% gen));
        const out = try runGeneration(allocator, gen, iters, gen_seed, prev_score, prev_depth, &lib, stdout);
        if (out.record.verdict == .strict_domination) any_strict_domination = true;

        try log.print("{d},{d:.6},{d:.6},{d},{d},{d},{d:.6},{d:.6},{d:.6},{s}\n", .{
            out.record.gen, out.record.score, out.record.prev_score,
            out.record.depth, out.record.prev_depth, out.record.size,
            out.record.correctness, out.record.base_norm_edit,
            out.record.extras_max_sim, out.record.verdict.label(),
        });

        const advance = out.record.verdict == .advance or out.record.verdict == .strict_domination;
        if (!advance) {
            halted = true;
            halt_gen = gen;
            halt_reason = out.record.verdict.label();
            break;
        }

        try lib.append(gen, out.program);
        try sort_net.chainExtrasAppend(out.program);
        prev_score = out.score;
        prev_depth = out.depth;
    }

    try stdout.print("\n=== CHAIN RESULT ===\n", .{});
    if (halted) {
        try stdout.print("HALTED at generation {d}: {s}\n", .{ halt_gen, halt_reason });
    } else {
        try stdout.print("Completed {d} generations. Final depth={d}, score={d:.3}.\n", .{ generations, prev_depth, prev_score });
    }
    try stdout.print("STRICT_DOMINATION ever observed: {s}\n", .{if (any_strict_domination) "YES" else "NO"});
    try stdout.print("Per-generation log: results/chain_sort/chain_log.csv\n", .{});
    try stdout.print("Champion CSVs: results/chain_sort/gen_<n>_champion.csv\n", .{});
}
