const std = @import("std");
const engine = @import("invention_engine.zig");
const u64_mixer = @import("domain_u64_mixer.zig");

// --- INVENTION CHAIN RUNNER (u64-mixer domain) ---
//
// Per directive feedback_invention_chain_directive.md:
//   engine_0 -> champion_0 -> engine_1 -> champion_1 -> ...
// Each generation runs the SAME engine binary (no hyperparameter tuning),
// but with an EXPANDED library = base library ∪ prior champions. The new
// champion must (a) strictly beat the prior champion's quality score AND
// (b) survive the expanded library's distance + reachability gates.
// Either failure HALTS the chain (no silently lowering the bar).
//
// The base engine search loop is reused unchanged — search only optimizes
// quality (Spec.qualityScalar), it never inspects the library. The gate is
// applied here in the runner against the expanded library.

const Eng = engine.Engine(u64_mixer);
const Program = u64_mixer.Program;

const FuncSamples: usize = 1024;
const ReachDepth: usize = 3; // (4+n)^3 — tractable through gen ~6
const ReachThreshold: f64 = 0.95;
const RemixBitAgreement: f64 = 0.75;
const EquivBitAgreement: f64 = 0.99;
// v2: novelty term λ. Set via CLI --lambda=. Default is calibrated so
// equivalence (1.0 agreement) costs ~20 quality points but noise-floor
// distance (0.5) costs only ~5 — leaving the search ~5 points of
// headroom to still discover high-quality novel programs.
// Subtraction baseline: novelty term is (max_agreement - 0.5) clamped
// to >=0, so noise-floor distance is FREE.
var novelty_lambda: f64 = 10.0;
const NoveltyBaseline: f64 = 0.5;
const PoolSize: usize = 16;

const ChainEntry = struct {
    name_buf: [32]u8,
    name_len: u8,
    program: Program,

    fn name(self: *const ChainEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const ExtendedLibrary = struct {
    // Base library names mirrored from domain_u64_mixer.zig (only via
    // execute() — we re-implement base programs via the same opaque
    // representation by reading them out of the domain through grading).
    base_progs: [4]Program,
    base_names: [4][]const u8,
    extras: std.ArrayList(ChainEntry),

    fn init(allocator: std.mem.Allocator) ExtendedLibrary {
        // Pull canonical library programs by running a one-shot grade
        // against a dummy candidate; cheaper: rebuild the four hand
        // programs here as Program literals. But Instruction is private,
        // so we synthesize them via execute-only oracle equivalence — at
        // chain-runner level we only need to *execute* base library
        // programs, and the domain exposes the four library entries
        // indirectly via distanceToLibrary's bookkeeping. Simplest path:
        // we don't actually need explicit base programs here — we use
        // u64_mixer.distanceToLibrary for distance to the BASE library
        // and u64_mixer.reachability for the BASE 4 primitives, then
        // ADD our own expansion checks on top against the prior
        // champions only.
        return .{
            .base_progs = undefined,
            .base_names = .{ "splitMix64", "Murmur", "xorshift", "Wang" },
            .extras = std.ArrayList(ChainEntry).init(allocator),
        };
    }

    fn deinit(self: *ExtendedLibrary) void {
        self.extras.deinit();
    }

    fn append(self: *ExtendedLibrary, gen: usize, p: Program) !void {
        var e: ChainEntry = .{ .name_buf = undefined, .name_len = 0, .program = p };
        const written = try std.fmt.bufPrint(&e.name_buf, "champion_gen_{d}", .{gen});
        e.name_len = @intCast(written.len);
        try self.extras.append(e);
    }

    fn size(self: *const ExtendedLibrary) usize {
        return 4 + self.extras.items.len;
    }
};

// Bit-agreement of two programs over a deterministic FuncSamples sweep.
fn bitAgreement(a: Program, b: Program) f64 {
    var bits: u64 = 0;
    var rng: u64 = 0xDEAD_BEEF_5EED_C0DE;
    var i: usize = 0;
    while (i < FuncSamples) : (i += 1) {
        rng = engine.smix(rng);
        const ya = a.execute(rng);
        const yb = b.execute(rng);
        bits += @as(u64, 64) - @popCount(ya ^ yb);
    }
    return @as(f64, @floatFromInt(bits)) / (@as(f64, @floatFromInt(FuncSamples)) * 64.0);
}

const ChampionExtDistance = struct {
    closest_extra_name: []const u8,
    best_bit_agreement_extra: f64,
};

fn distanceToExtras(p: Program, lib: *const ExtendedLibrary) ChampionExtDistance {
    var best: f64 = 0;
    var name: []const u8 = "<none>";
    for (lib.extras.items) |*entry| {
        const a = bitAgreement(p, entry.program);
        if (a > best) {
            best = a;
            name = entry.name();
        }
    }
    return .{ .closest_extra_name = name, .best_bit_agreement_extra = best };
}

// Composition reachability over (extras only) primitive set at given depth.
// Base-library reachability is handled by u64_mixer.reachability(); this
// adds the directive's required expansion: prior champions become composable
// primitives the new champion must NOT match.
fn reachabilityViaExtras(p: Program, lib: *const ExtendedLibrary, depth: usize) f64 {
    if (lib.extras.items.len == 0) return 0.0;
    var best: f64 = 0;
    var d: usize = 1;
    while (d <= depth) : (d += 1) {
        const n_prims = lib.extras.items.len;
        var n_paths: usize = 1;
        var dd: usize = 0;
        while (dd < d) : (dd += 1) n_paths *= n_prims;
        var path_n: usize = 0;
        while (path_n < n_paths) : (path_n += 1) {
            var path: [8]usize = .{0} ** 8;
            var t = path_n;
            var k: usize = 0;
            while (k < d) : (k += 1) { path[k] = t % n_prims; t /= n_prims; }
            var bits: u64 = 0;
            var rng: u64 = 0xDEAD_BEEF_5EED_C0DE;
            var s: usize = 0;
            while (s < FuncSamples) : (s += 1) {
                rng = engine.smix(rng);
                const yp = p.execute(rng);
                var yc = rng;
                var ki: usize = 0;
                while (ki < d) : (ki += 1) yc = lib.extras.items[path[ki]].program.execute(yc);
                bits += @as(u64, 64) - @popCount(yp ^ yc);
            }
            const score = @as(f64, @floatFromInt(bits)) / (@as(f64, @floatFromInt(FuncSamples)) * 64.0);
            if (score > best) best = score;
        }
    }
    return best;
}

const GenVerdict = enum {
    advance,
    halt_no_quality_improvement,
    halt_equivalent_to_extra,
    halt_remix_of_extra,
    halt_reachable_from_extras,
    halt_base_remix,
    halt_base_reachable,
    halt_non_quality,

    fn label(self: GenVerdict) []const u8 {
        return switch (self) {
            .advance => "ADVANCE",
            .halt_no_quality_improvement => "HALT(no_quality_improvement)",
            .halt_equivalent_to_extra => "HALT(equivalent_to_prior_champion)",
            .halt_remix_of_extra => "HALT(remix_of_prior_champion)",
            .halt_reachable_from_extras => "HALT(reachable_from_prior_champion_composition)",
            .halt_base_remix => "HALT(remix_of_base_library)",
            .halt_base_reachable => "HALT(reachable_from_base_library)",
            .halt_non_quality => "HALT(quality_gate_fail)",
        };
    }
};

const GenRecord = struct {
    gen: usize,
    score: f64,
    prev_score: f64,
    base_norm_edit: f64,
    base_bit_agreement: f64,
    base_reach_bits: f64,
    extras_bit_agreement: f64,
    extras_reach_bits: f64,
    verdict: GenVerdict,
};

// Max bit-agreement to any prior champion in the chain library.
// Returns 0 when there are no priors (no novelty pressure on gen 0).
fn maxAgreementToExtras(p: Program, lib: *const ExtendedLibrary) f64 {
    var best: f64 = 0;
    for (lib.extras.items) |*entry| {
        const a = bitAgreement(p, entry.program);
        if (a > best) best = a;
    }
    return best;
}

// v2 search: novelty-adjusted SA. Custom inner loop because the base
// engine's pool stores only quality, not the novelty-adjusted score we
// need. Mirrors engine.search() structure but uses
//     fitness(p) = qualityScalar(p) - λ * max_bit_agreement_to_extras(p)
// as the SA objective. Returns the highest-fitness program found.
const SearchPool = struct {
    progs: [PoolSize]Program,
    qs: [PoolSize]u64_mixer.Quality,
    qscores: [PoolSize]f64,
    fitness: [PoolSize]f64,
    count: usize,
};

fn fitnessOf(q_scalar: f64, p: Program, lib: *const ExtendedLibrary) f64 {
    const a = maxAgreementToExtras(p, lib);
    const excess = if (a > NoveltyBaseline) a - NoveltyBaseline else 0.0;
    return q_scalar - novelty_lambda * excess;
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

fn noveltySearch(
    rng_seed: u64,
    iters: usize,
    lib: *const ExtendedLibrary,
) struct { best: Program, best_q: u64_mixer.Quality, best_qscore: f64, best_fitness: f64, accepted: usize } {
    var rng: u64 = rng_seed;
    var pool: SearchPool = .{ .progs = undefined, .qs = undefined, .qscores = undefined, .fitness = undefined, .count = 0 };

    // Seed pool.
    while (pool.count < PoolSize) {
        const p = u64_mixer.randomProgram(&rng);
        const q = u64_mixer.evaluateQuality(p);
        if (!u64_mixer.isFinite(q)) continue;
        const qs = u64_mixer.qualityScalar(q);
        pool.progs[pool.count] = p;
        pool.qs[pool.count] = q;
        pool.qscores[pool.count] = qs;
        pool.fitness[pool.count] = fitnessOf(qs, p, lib);
        pool.count += 1;
    }

    var accepted: usize = 0;
    var i: usize = 0;
    const t_start: f64 = 8.0;
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
            break :blk u64_mixer.crossover(parent, pool.progs[other_idx], &rng);
        } else u64_mixer.mutate(parent, &rng);

        const cand_q = u64_mixer.evaluateQuality(candidate);
        if (!u64_mixer.isFinite(cand_q)) continue;
        const cand_qs = u64_mixer.qualityScalar(cand_q);
        const cand_fit = fitnessOf(cand_qs, candidate, lib);

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

fn runGeneration(
    allocator: std.mem.Allocator,
    gen: usize,
    iters: usize,
    seed: u64,
    prev_score: f64,
    lib: *const ExtendedLibrary,
    stdout: anytype,
) !struct { record: GenRecord, program: Program, score: f64 } {
    try stdout.print("\n--- generation {d} | seed=0x{X} | iters={d} | extended_library_size={d} | chain_extras_len={d} ---\n", .{
        gen, seed, iters, lib.size(), u64_mixer.chainExtrasLen(),
    });

    const sr_full = noveltySearch(seed, iters, lib);
    const sr = .{
        .best_program = sr_full.best,
        .best_score = sr_full.best_qscore,
        .accepted = sr_full.accepted,
        .iterations = iters,
    };
    try stdout.print("search done. quality_score={d:.3} fitness={d:.3} accepted={d}/{d}\n", .{
        sr.best_score, sr_full.best_fitness, sr.accepted, sr.iterations,
    });

    // Base-library gating via the existing Spec.
    const base_d = try u64_mixer.distanceToLibrary(sr.best_program, allocator);
    const base_r = try u64_mixer.reachability(sr.best_program, allocator);
    const quality = u64_mixer.evaluateQuality(sr.best_program);
    const passes_quality = u64_mixer.qualityPasses(quality);

    // Extras gating (the directive's required expansion).
    const ext_d = distanceToExtras(sr.best_program, lib);
    const ext_r_bits = reachabilityViaExtras(sr.best_program, lib, ReachDepth);

    try stdout.print(
        "base: closest={s} norm_edit={d:.3} bit_agreement={d:.3} reach_bits={d:.3}\n",
        .{ base_d.closest_name, base_d.norm_edit, base_d.best_bit_agreement, base_r.best_bit_agreement },
    );
    try stdout.print(
        "extras: closest={s} bit_agreement={d:.3} reach_bits={d:.3} (depth={d})\n",
        .{ ext_d.closest_extra_name, ext_d.best_bit_agreement_extra, ext_r_bits, ReachDepth },
    );
    try stdout.print("quality_gate: {s}\n", .{if (passes_quality) "PASS" else "FAIL"});

    // Promotion gate.
    var verdict: GenVerdict = .advance;
    if (!passes_quality) {
        verdict = .halt_non_quality;
    } else if (u64_mixer.isRemix(base_d)) {
        verdict = .halt_base_remix;
    } else if (u64_mixer.isReachable(base_r)) {
        verdict = .halt_base_reachable;
    } else if (ext_d.best_bit_agreement_extra >= EquivBitAgreement) {
        verdict = .halt_equivalent_to_extra;
    } else if (ext_d.best_bit_agreement_extra >= RemixBitAgreement) {
        verdict = .halt_remix_of_extra;
    } else if (ext_r_bits >= ReachThreshold) {
        verdict = .halt_reachable_from_extras;
    } else if (gen > 0 and sr.best_score <= prev_score) {
        verdict = .halt_no_quality_improvement;
    } else {
        verdict = .advance;
    }

    const rec = GenRecord{
        .gen = gen,
        .score = sr.best_score,
        .prev_score = prev_score,
        .base_norm_edit = base_d.norm_edit,
        .base_bit_agreement = base_d.best_bit_agreement,
        .base_reach_bits = base_r.best_bit_agreement,
        .extras_bit_agreement = ext_d.best_bit_agreement_extra,
        .extras_reach_bits = ext_r_bits,
        .verdict = verdict,
    };

    try stdout.print("verdict: {s}\n", .{verdict.label()});

    // Persist this generation's champion CSV regardless of verdict (the
    // halt itself is a result; the program that triggered it is part of
    // the record).
    var path_buf: [128]u8 = undefined;
    const champ_path = try std.fmt.bufPrint(&path_buf, "results/chain/gen_{d}_champion.csv", .{gen});
    try std.fs.cwd().makePath("results/chain");
    var f = try std.fs.cwd().createFile(champ_path, .{ .truncate = true });
    defer f.close();
    try u64_mixer.programToCsv(sr.best_program, f.writer());

    return .{ .record = rec, .program = sr.best_program, .score = sr.best_score };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var generations: usize = 5;
    var iters: usize = 8000;
    var seed: u64 = 0xC0FFEE_BABE_F00D_12;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--generations=")) {
            generations = try std.fmt.parseInt(usize, arg["--generations=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--iters=")) {
            iters = try std.fmt.parseInt(usize, arg["--iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--lambda=")) {
            novelty_lambda = try std.fmt.parseFloat(f64, arg["--lambda=".len..]);
        }
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== INVENTION CHAIN RUNNER | domain=u64-mixer ===\n", .{});
    try stdout.print("generations={d} iters_per_gen={d} root_seed=0x{X} novelty_lambda={d:.2}\n", .{ generations, iters, seed, novelty_lambda });

    try std.fs.cwd().makePath("results/chain");

    var log_file = try std.fs.cwd().createFile("results/chain/chain_log.csv", .{ .truncate = true });
    defer log_file.close();
    const log = log_file.writer();
    try log.writeAll(
        "gen,score,prev_score,advance_over_prev," ++
        "base_norm_edit,base_bit_agreement,base_reach_bits," ++
        "extras_bit_agreement,extras_reach_bits,verdict\n",
    );

    var lib = ExtendedLibrary.init(allocator);
    defer lib.deinit();

    // v2: prior champions become composable atoms via CALL_LIB.
    // engine_{n+1} now searches a STRICTLY LARGER space than engine_n.
    u64_mixer.chainExtrasReset();

    var prev_score: f64 = -std.math.inf(f64);
    var gen: usize = 0;
    var halted: bool = false;
    var halt_gen: usize = 0;
    var halt_reason: []const u8 = "n/a";

    while (gen < generations) : (gen += 1) {
        // Derive per-generation seed deterministically.
        const gen_seed = engine.smix(seed ^ (@as(u64, 0xA5A5_A5A5_5A5A_5A5A) +% gen));
        const out = try runGeneration(allocator, gen, iters, gen_seed, prev_score, &lib, stdout);
        const advanced: u8 = @intFromBool(out.record.verdict == .advance);

        try log.print(
            "{d},{d:.6},{d:.6},{d},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{s}\n",
            .{
                out.record.gen, out.record.score, out.record.prev_score, advanced,
                out.record.base_norm_edit, out.record.base_bit_agreement, out.record.base_reach_bits,
                out.record.extras_bit_agreement, out.record.extras_reach_bits,
                out.record.verdict.label(),
            },
        );

        if (out.record.verdict != .advance) {
            halted = true;
            halt_gen = gen;
            halt_reason = out.record.verdict.label();
            break;
        }

        // Champion accepted: extend the gate library AND the operator
        // set. The chainExtrasAppend call is what makes the next
        // generation a true successor — its mutate/randomProgram can now
        // emit CALL_LIB(gen) referring to this champion as an atom.
        try lib.append(gen, out.program);
        try u64_mixer.chainExtrasAppend(out.program);
        prev_score = out.score;
    }

    try stdout.print("\n=== CHAIN RESULT ===\n", .{});
    if (halted) {
        try stdout.print("HALTED at generation {d}: {s}\n", .{ halt_gen, halt_reason });
    } else {
        try stdout.print("Completed {d} generations without halt. Final score={d:.3}.\n", .{ generations, prev_score });
    }
    try stdout.print("Per-generation log: results/chain/chain_log.csv\n", .{});
    try stdout.print("Champion CSVs: results/chain/gen_<n>_champion.csv\n", .{});
}
