const std = @import("std");
const flame = @import("flame");
const vsa = @import("vsa");
const void_eng = @import("void");

// --- NOVELTY INVENTION ENGINE ---
//
// Previous invention probes minimized closure_error, which pulls chamber
// states back toward the VSA-derived law attractors. This probe makes novelty
// an explicit pressure:
//
//   1. Measure the 512-bit chamber sign fingerprint.
//   2. Score states by low closure plus high distance from every VSA concept.
//   3. Auto-pilot several deterministic search engines, select the best one,
//      then run that engine against the strict "past max inter-concept
//      distance" criterion.
//
// No learned weights, embeddings, or external model. The "engine invents an
// engine" part is the pilot sweep: it creates and measures candidate search
// profiles before committing to the full run.

const FpWords = flame.ChamberCount / 64;
const Fingerprint = [FpWords]u64;
const ConceptMax = 32;

const MutationMode = enum {
    random_flip,
    repel_nearest,
    prototype_pull,
    prototype_lock,
    hybrid,
};

const EngineSpec = struct {
    name: []const u8,
    mode: MutationMode,
    beta: f64,
    closure_weight: f64,
    init_range: i128,
    mut_per_step: usize,
    relax_passes: usize,
    novelty_pressure: i128,
    t_start: f64,
    t_end: f64,
};

const Overrides = struct {
    beta: ?f64 = null,
    init_range: ?i128 = null,
    mut_per_step: ?usize = null,
    relax_passes: ?usize = null,
    novelty_pressure: ?i128 = null,
};

const NoveltyMetrics = struct {
    closure: u128,
    min_concept_dist: u32,
    nearest_name: []const u8,
    nearest_index: usize,
    mean_concept_dist: f64,
    max_concept_dist: u32,
};

const TrialResult = struct {
    metrics: NoveltyMetrics,
    score: f64,
};

const DistanceStats = struct {
    min: u32,
    sum: u32,
};

fn modeName(mode: MutationMode) []const u8 {
    return switch (mode) {
        .random_flip => "random_flip",
        .repel_nearest => "repel_nearest",
        .prototype_pull => "prototype_pull",
        .prototype_lock => "prototype_lock",
        .hybrid => "hybrid",
    };
}

fn bitAt(fp: Fingerprint, idx: usize) bool {
    return ((fp[idx / 64] >> @intCast(idx % 64)) & 1) != 0;
}

fn setBit(fp: *Fingerprint, idx: usize, value: bool) void {
    const mask = @as(u64, 1) << @intCast(idx % 64);
    if (value) {
        fp[idx / 64] |= mask;
    } else {
        fp[idx / 64] &= ~mask;
    }
}

fn flipBit(fp: *Fingerprint, idx: usize) void {
    fp[idx / 64] ^= @as(u64, 1) << @intCast(idx % 64);
}

fn chamberFingerprint(chamber: [flame.ChamberCount]i128) Fingerprint {
    var fp: Fingerprint = [_]u64{0} ** FpWords;
    for (chamber, 0..) |v, i| {
        if (v > 0) setBit(&fp, i, true);
    }
    return fp;
}

fn hammingFp(a: Fingerprint, b: Fingerprint) u32 {
    var d: u32 = 0;
    for (a, b) |aw, bw| d += @popCount(aw ^ bw);
    return d;
}

fn conceptFingerprint(c: vsa.Concept) Fingerprint {
    const hv = vsa.getConceptHV(c);
    var fp: Fingerprint = undefined;
    for (&fp, 0..) |*w, i| w.* = hv.data[i];
    return fp;
}

fn absI128(v: i128) i128 {
    return if (v < 0) -v else v;
}

fn chamberSign(chamber: [flame.ChamberCount]i128, idx: usize) bool {
    return chamber[idx] > 0;
}

fn setChamberSign(chamber: *[flame.ChamberCount]i128, idx: usize, want_positive: bool, min_magnitude: i128, rng: *u64) void {
    rng.* = void_eng.splitMix64(rng.*);
    var mag = absI128(chamber[idx]);
    const jitter = @as(i128, @intCast(rng.* % 4096));
    if (mag < min_magnitude) mag = min_magnitude + jitter;
    chamber[idx] = if (want_positive) mag else -mag;
}

fn randomChamber(seed: u64, range: i128) [flame.ChamberCount]i128 {
    var out: [flame.ChamberCount]i128 = undefined;
    var s = seed;
    for (&out) |*slot| {
        s = void_eng.splitMix64(s);
        const v: i128 = @intCast(s % @as(u64, @intCast(range * 2)));
        slot.* = v - range;
    }
    return out;
}

fn chamberFromFingerprint(fp: Fingerprint, seed: u64, magnitude: i128) [flame.ChamberCount]i128 {
    var out: [flame.ChamberCount]i128 = undefined;
    var s = seed;
    for (&out, 0..) |*slot, idx| {
        s = void_eng.splitMix64(s);
        const mag = magnitude + @as(i128, @intCast(s % 4096));
        slot.* = if (bitAt(fp, idx)) mag else -mag;
    }
    return out;
}

fn measureFingerprint(fp: Fingerprint, closure: u128, concept_fps: []const Fingerprint, names: []const []const u8) NoveltyMetrics {
    var best: u32 = std.math.maxInt(u32);
    var best_idx: usize = 0;
    var max_d: u32 = 0;
    var sum: u64 = 0;
    for (concept_fps, 0..) |cfp, idx| {
        const d = hammingFp(fp, cfp);
        sum += d;
        if (d > max_d) max_d = d;
        if (d < best) {
            best = d;
            best_idx = idx;
        }
    }
    return .{
        .closure = closure,
        .min_concept_dist = best,
        .nearest_name = names[best_idx],
        .nearest_index = best_idx,
        .mean_concept_dist = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(concept_fps.len)),
        .max_concept_dist = max_d,
    };
}

fn measureNovelty(state: *const flame.FlameState, concept_fps: []const Fingerprint, names: []const []const u8) NoveltyMetrics {
    return measureFingerprint(chamberFingerprint(state.chamber), state.closure_error, concept_fps, names);
}

fn scoreMetrics(m: NoveltyMetrics, spec: EngineSpec, target: u32) f64 {
    const capped_closure = @min(m.closure, @as(u128, 1_000_000_000_000_000_000));
    const closure_log = @log(1.0 + @as(f64, @floatFromInt(capped_closure)));
    const gap = if (m.min_concept_dist < target) target - m.min_concept_dist else 0;
    const novelty = spec.beta * @as(f64, @floatFromInt(m.min_concept_dist));
    const mean_bonus = 0.05 * m.mean_concept_dist;
    const target_penalty = spec.beta * 2.0 * @as(f64, @floatFromInt(gap));
    return novelty + mean_bonus - target_penalty - spec.closure_weight * closure_log;
}

fn distanceStats(dists: []const u32) DistanceStats {
    var min: u32 = std.math.maxInt(u32);
    var sum: u32 = 0;
    for (dists) |d| {
        if (d < min) min = d;
        sum += d;
    }
    return .{ .min = min, .sum = sum };
}

fn synthesizePrototype(concept_fps: []const Fingerprint, seed: u64) Fingerprint {
    if (concept_fps.len > ConceptMax) @panic("too many concepts for novelty prototype");

    var proto: Fingerprint = [_]u64{0} ** FpWords;
    var rng = seed;
    for (0..flame.ChamberCount) |bit| {
        var ones: usize = 0;
        for (concept_fps) |cfp| {
            if (bitAt(cfp, bit)) ones += 1;
        }
        const zeros = concept_fps.len - ones;
        if (ones == zeros) {
            rng = void_eng.splitMix64(rng);
            setBit(&proto, bit, (rng & 1) == 0);
        } else {
            setBit(&proto, bit, ones < zeros);
        }
    }

    var dists: [ConceptMax]u32 = [_]u32{0} ** ConceptMax;
    for (concept_fps, 0..) |cfp, idx| {
        dists[idx] = hammingFp(proto, cfp);
    }

    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        const current = distanceStats(dists[0..concept_fps.len]);
        var best_bit: ?usize = null;
        var best_min = current.min;
        var best_sum = current.sum;

        for (0..flame.ChamberCount) |bit| {
            const old_bit = bitAt(proto, bit);
            var candidate: [ConceptMax]u32 = dists;
            for (concept_fps, 0..) |cfp, idx| {
                if (old_bit == bitAt(cfp, bit)) {
                    candidate[idx] += 1;
                } else {
                    candidate[idx] -= 1;
                }
            }
            const stats = distanceStats(candidate[0..concept_fps.len]);
            if (stats.min > best_min or (stats.min == best_min and stats.sum > best_sum)) {
                best_bit = bit;
                best_min = stats.min;
                best_sum = stats.sum;
            }
        }

        if (best_bit) |bit| {
            const old_bit = bitAt(proto, bit);
            for (concept_fps, 0..) |cfp, idx| {
                if (old_bit == bitAt(cfp, bit)) {
                    dists[idx] += 1;
                } else {
                    dists[idx] -= 1;
                }
            }
            flipBit(&proto, bit);
        } else {
            break;
        }
    }

    return proto;
}

fn nearestIndex(fp: Fingerprint, concept_fps: []const Fingerprint) struct { idx: usize, dist: u32 } {
    var best: u32 = std.math.maxInt(u32);
    var best_idx: usize = 0;
    for (concept_fps, 0..) |cfp, idx| {
        const d = hammingFp(fp, cfp);
        if (d < best) {
            best = d;
            best_idx = idx;
        }
    }
    return .{ .idx = best_idx, .dist = best };
}

fn applyNoveltyPressure(state: *flame.FlameState, concept_fps: []const Fingerprint, target: u32, pressure: i128, rng: *u64) void {
    if (pressure <= 0) return;
    const fp = chamberFingerprint(state.chamber);
    const near = nearestIndex(fp, concept_fps);
    if (near.dist >= target) return;

    const gap = @as(i128, @intCast(target - near.dist));
    const floor = pressure + gap * @divTrunc(pressure, 4);
    const nearest_fp = concept_fps[near.idx];
    for (0..flame.ChamberCount) |idx| {
        if (chamberSign(state.chamber, idx) == bitAt(nearest_fp, idx)) {
            setChamberSign(&state.chamber, idx, !bitAt(nearest_fp, idx), floor, rng);
        }
    }
}

fn enforceFingerprint(state: *flame.FlameState, fp: Fingerprint, min_magnitude: i128, rng: *u64) void {
    for (0..flame.ChamberCount) |idx| {
        if (chamberSign(state.chamber, idx) != bitAt(fp, idx)) {
            setChamberSign(&state.chamber, idx, bitAt(fp, idx), min_magnitude, rng);
        }
    }
}

fn relaxSafe(
    state: *flame.FlameState,
    passes: usize,
    concept_fps: []const Fingerprint,
    target: u32,
    novelty_pressure: i128,
    prototype: Fingerprint,
    lock_to_prototype: bool,
) void {
    var pressure_rng = state.kernel ^ 0xA11E_1E55_CAFE_BABE;
    for (0..passes) |pass| {
        for (flame.Laws) |law| {
            const got = law.ca * state.chamber[law.a] + law.cb * state.chamber[law.b];
            const err = law.t - got;
            if (err == 0) continue;
            const denom = law.ca * law.ca + law.cb * law.cb;
            if (denom == 0) continue;
            const damp = @as(i128, @intCast(1 + (pass / 10)));
            const da = @divTrunc(err * law.ca, denom * damp);
            const db = @divTrunc(err * law.cb, denom * damp);
            state.chamber[law.a] += @max(-1_000_000_000_000, @min(1_000_000_000_000, da));
            state.chamber[law.b] += @max(-1_000_000_000_000, @min(1_000_000_000_000, db));
        }
        if (lock_to_prototype) {
            enforceFingerprint(state, prototype, @max(@as(i128, 1024), novelty_pressure), &pressure_rng);
        } else if ((pass + 1) % 16 == 0) {
            applyNoveltyPressure(state, concept_fps, target, novelty_pressure, &pressure_rng);
        }
    }
    if (lock_to_prototype) {
        enforceFingerprint(state, prototype, @max(@as(i128, 1024), novelty_pressure), &pressure_rng);
    } else if (passes == 0 or passes % 16 != 0) {
        applyNoveltyPressure(state, concept_fps, target, novelty_pressure, &pressure_rng);
    }
    state.closure_error = flame.closureError(state);
}

fn mutateRandom(state: *flame.FlameState, flips: usize, min_magnitude: i128, rng: *u64) void {
    for (0..flips) |_| {
        rng.* = void_eng.splitMix64(rng.*);
        const idx = @as(usize, @intCast(rng.*)) % flame.ChamberCount;
        setChamberSign(&state.chamber, idx, !chamberSign(state.chamber, idx), min_magnitude, rng);
    }
}

fn mutatePrototype(state: *flame.FlameState, prototype: Fingerprint, flips: usize, min_magnitude: i128, rng: *u64) void {
    for (0..flips) |_| {
        rng.* = void_eng.splitMix64(rng.*);
        const idx = @as(usize, @intCast(rng.*)) % flame.ChamberCount;
        setChamberSign(&state.chamber, idx, bitAt(prototype, idx), min_magnitude, rng);
    }
}

fn mutateRepelNearest(
    state: *flame.FlameState,
    metrics: NoveltyMetrics,
    concept_fps: []const Fingerprint,
    flips: usize,
    min_magnitude: i128,
    rng: *u64,
) void {
    const nearest_fp = concept_fps[metrics.nearest_index];
    var done: usize = 0;
    var attempts: usize = 0;
    while (done < flips and attempts < flips * 8 + 16) : (attempts += 1) {
        rng.* = void_eng.splitMix64(rng.*);
        const idx = @as(usize, @intCast(rng.*)) % flame.ChamberCount;
        if (chamberSign(state.chamber, idx) == bitAt(nearest_fp, idx)) {
            setChamberSign(&state.chamber, idx, !bitAt(nearest_fp, idx), min_magnitude, rng);
            done += 1;
        }
    }
    if (done < flips) mutateRandom(state, flips - done, min_magnitude, rng);
}

fn mutateState(
    state: *flame.FlameState,
    spec: EngineSpec,
    metrics: NoveltyMetrics,
    concept_fps: []const Fingerprint,
    prototype: Fingerprint,
    rng: *u64,
) void {
    const min_magnitude = @max(@as(i128, 1024), spec.novelty_pressure);
    switch (spec.mode) {
        .random_flip => mutateRandom(state, spec.mut_per_step, min_magnitude, rng),
        .repel_nearest => mutateRepelNearest(state, metrics, concept_fps, spec.mut_per_step, min_magnitude, rng),
        .prototype_pull => mutatePrototype(state, prototype, spec.mut_per_step, min_magnitude, rng),
        .prototype_lock => mutatePrototype(state, prototype, spec.mut_per_step, min_magnitude, rng),
        .hybrid => {
            const half = @max(@as(usize, 1), spec.mut_per_step / 2);
            mutatePrototype(state, prototype, half, min_magnitude, rng);
            mutateRepelNearest(state, metrics, concept_fps, spec.mut_per_step - half, min_magnitude, rng);
        },
    }
}

fn betterMetrics(a: NoveltyMetrics, b: NoveltyMetrics, max_inter: u32) bool {
    const a_past = a.min_concept_dist > max_inter;
    const b_past = b.min_concept_dist > max_inter;
    if (a_past != b_past) return a_past;
    if (a.min_concept_dist != b.min_concept_dist) return a.min_concept_dist > b.min_concept_dist;
    if (a.closure != b.closure) return a.closure < b.closure;
    return a.mean_concept_dist > b.mean_concept_dist;
}

fn usesPrototype(mode: MutationMode) bool {
    return mode == .prototype_pull or mode == .prototype_lock or mode == .hybrid;
}

fn runTrial(
    spec: EngineSpec,
    trial_seed: u64,
    iters: usize,
    target: u32,
    max_inter: u32,
    concept_fps: []const Fingerprint,
    names: []const []const u8,
    prototype: Fingerprint,
) TrialResult {
    var state = flame.FlameState{
        .chamber = if (usesPrototype(spec.mode))
            chamberFromFingerprint(prototype, trial_seed, spec.init_range)
        else
            randomChamber(trial_seed, spec.init_range),
        .scar_bank = [_]u64{0} ** flame.ScarCount,
        .kernel = trial_seed,
        .closure_error = 0,
    };
    state.closure_error = flame.closureError(&state);
    const lock_to_prototype = spec.mode == .prototype_lock;
    relaxSafe(&state, spec.relax_passes, concept_fps, target, spec.novelty_pressure, prototype, lock_to_prototype);

    var current_metrics = measureNovelty(&state, concept_fps, names);
    var current_score = scoreMetrics(current_metrics, spec, target);
    var best_metrics = current_metrics;
    var best_score = current_score;
    var rng = trial_seed ^ 0x1234_5678_90AB_CDEF;

    var iter: usize = 0;
    while (iter < iters) : (iter += 1) {
        const progress = @as(f64, @floatFromInt(iter)) / @as(f64, @floatFromInt(@max(@as(usize, 1), iters)));
        const t = spec.t_start * std.math.pow(f64, spec.t_end / spec.t_start, progress);
        const saved = state;

        mutateState(&state, spec, current_metrics, concept_fps, prototype, &rng);
        relaxSafe(&state, spec.relax_passes, concept_fps, target, spec.novelty_pressure, prototype, lock_to_prototype);
        const new_metrics = measureNovelty(&state, concept_fps, names);
        const new_score = scoreMetrics(new_metrics, spec, target);
        const delta = new_score - current_score;

        var accept = delta >= 0;
        if (!accept) {
            const p = std.math.exp(delta / @max(t, 0.001));
            rng = void_eng.splitMix64(rng);
            const draw = @as(f64, @floatFromInt(rng % 1_000_000)) / 1_000_000.0;
            accept = draw < p;
        }

        if (accept) {
            current_metrics = new_metrics;
            current_score = new_score;
            if (betterMetrics(new_metrics, best_metrics, max_inter) or new_score > best_score) {
                best_metrics = new_metrics;
                best_score = new_score;
            }
        } else {
            state = saved;
        }
    }

    return .{ .metrics = best_metrics, .score = best_score };
}

fn specScore(best_min: u32, past_count: usize, avg_min: f64, best_closure: u128) f64 {
    const closure_log = @log(1.0 + @as(f64, @floatFromInt(@min(best_closure, @as(u128, 1_000_000_000_000_000_000)))));
    return 10_000.0 * @as(f64, @floatFromInt(past_count)) +
        100.0 * @as(f64, @floatFromInt(best_min)) +
        avg_min -
        closure_log;
}

fn applyOverrides(spec: *EngineSpec, overrides: Overrides) void {
    if (overrides.beta) |v| spec.beta = v;
    if (overrides.init_range) |v| spec.init_range = v;
    if (overrides.mut_per_step) |v| spec.mut_per_step = v;
    if (overrides.relax_passes) |v| spec.relax_passes = v;
    if (overrides.novelty_pressure) |v| spec.novelty_pressure = v;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next();

    var trials: usize = 24;
    var iters_per_trial: usize = 240;
    var meta_trials: usize = 4;
    var meta_iters: usize = 70;
    var target_override: ?u32 = null;
    var base_seed: u64 = 0xFEED_F00D_CAFE_BABE;
    var csv_path: []const u8 = "results/novelty_invention.csv";
    var autotune = true;
    var requested_engine: ?[]const u8 = null;
    var overrides = Overrides{};

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--trials=")) trials = try std.fmt.parseInt(usize, arg["--trials=".len..], 10) else if (std.mem.startsWith(u8, arg, "--iters=")) iters_per_trial = try std.fmt.parseInt(usize, arg["--iters=".len..], 10) else if (std.mem.startsWith(u8, arg, "--meta-trials=")) meta_trials = try std.fmt.parseInt(usize, arg["--meta-trials=".len..], 10) else if (std.mem.startsWith(u8, arg, "--meta-iters=")) meta_iters = try std.fmt.parseInt(usize, arg["--meta-iters=".len..], 10) else if (std.mem.startsWith(u8, arg, "--target=")) target_override = try std.fmt.parseInt(u32, arg["--target=".len..], 10) else if (std.mem.startsWith(u8, arg, "--seed=")) base_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16) else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..] else if (std.mem.startsWith(u8, arg, "--engine=")) requested_engine = arg["--engine=".len..] else if (std.mem.eql(u8, arg, "--no-autotune")) autotune = false else if (std.mem.startsWith(u8, arg, "--passes=")) overrides.relax_passes = try std.fmt.parseInt(usize, arg["--passes=".len..], 10) else if (std.mem.startsWith(u8, arg, "--beta=")) overrides.beta = try std.fmt.parseFloat(f64, arg["--beta=".len..]) else if (std.mem.startsWith(u8, arg, "--range=")) overrides.init_range = try std.fmt.parseInt(i128, arg["--range=".len..], 10) else if (std.mem.startsWith(u8, arg, "--mut=")) overrides.mut_per_step = try std.fmt.parseInt(usize, arg["--mut=".len..], 10) else if (std.mem.startsWith(u8, arg, "--pressure=")) overrides.novelty_pressure = try std.fmt.parseInt(i128, arg["--pressure=".len..], 10);
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== NOVELTY INVENTION ENGINE ===\n", .{});

    const fields = std.meta.fields(vsa.Concept);
    var concept_fps = try aa.alloc(Fingerprint, fields.len);
    var names = try aa.alloc([]const u8, fields.len);
    inline for (fields, 0..) |f, i| {
        concept_fps[i] = conceptFingerprint(@as(vsa.Concept, @enumFromInt(f.value)));
        names[i] = f.name;
    }

    var min_inter: u32 = std.math.maxInt(u32);
    var max_inter: u32 = 0;
    var sum_inter: u64 = 0;
    var pair_count: usize = 0;
    for (concept_fps, 0..) |a, i| {
        for (i + 1..concept_fps.len) |j| {
            const d = hammingFp(a, concept_fps[j]);
            if (d < min_inter) min_inter = d;
            if (d > max_inter) max_inter = d;
            sum_inter += d;
            pair_count += 1;
        }
    }
    const mean_inter = @as(f64, @floatFromInt(sum_inter)) / @as(f64, @floatFromInt(pair_count));
    const target_dist = target_override orelse (max_inter + 1);

    const prototype = synthesizePrototype(concept_fps, base_seed ^ 0xD15C_0A11);
    const proto_metrics = measureFingerprint(prototype, 0, concept_fps, names);

    try stdout.print("VSA inter-concept Hamming: min={d}  mean={d:.1}  max={d}  ({d} pairs)\n", .{ min_inter, mean_inter, max_inter, pair_count });
    try stdout.print("Alien criterion: min_dist > {d}; target={d}\n", .{ max_inter, target_dist });
    try stdout.print("Greedy novelty prototype: min_dist={d} nearest={s} mean={d:.1} max={d}\n\n", .{
        proto_metrics.min_concept_dist,
        proto_metrics.nearest_name,
        proto_metrics.mean_concept_dist,
        proto_metrics.max_concept_dist,
    });

    const specs = [_]EngineSpec{
        .{
            .name = "closure_control",
            .mode = .random_flip,
            .beta = 0.0,
            .closure_weight = 2.0,
            .init_range = 50_000,
            .mut_per_step = 18,
            .relax_passes = 48,
            .novelty_pressure = 0,
            .t_start = 3.0,
            .t_end = 0.05,
        },
        .{
            .name = "nearest_repel",
            .mode = .repel_nearest,
            .beta = 7.5,
            .closure_weight = 1.0,
            .init_range = 36_000,
            .mut_per_step = 20,
            .relax_passes = 40,
            .novelty_pressure = 0,
            .t_start = 3.0,
            .t_end = 0.04,
        },
        .{
            .name = "prototype_pull",
            .mode = .prototype_pull,
            .beta = 8.0,
            .closure_weight = 1.0,
            .init_range = 28_000,
            .mut_per_step = 24,
            .relax_passes = 36,
            .novelty_pressure = 0,
            .t_start = 2.5,
            .t_end = 0.04,
        },
        .{
            .name = "prototype_guard",
            .mode = .prototype_pull,
            .beta = 12.0,
            .closure_weight = 0.8,
            .init_range = 28_000,
            .mut_per_step = 4,
            .relax_passes = 1,
            .novelty_pressure = 8192,
            .t_start = 2.0,
            .t_end = 0.03,
        },
        .{
            .name = "prototype_lock",
            .mode = .prototype_lock,
            .beta = 12.0,
            .closure_weight = 0.6,
            .init_range = 28_000,
            .mut_per_step = 8,
            .relax_passes = 24,
            .novelty_pressure = 2048,
            .t_start = 1.6,
            .t_end = 0.02,
        },
        .{
            .name = "hybrid_pressure",
            .mode = .hybrid,
            .beta = 9.0,
            .closure_weight = 0.9,
            .init_range = 24_000,
            .mut_per_step = 28,
            .relax_passes = 32,
            .novelty_pressure = 2048,
            .t_start = 2.2,
            .t_end = 0.03,
        },
    };

    var selected = specs[0];
    if (requested_engine) |engine_name| {
        var found = false;
        for (specs) |spec| {
            if (std.mem.eql(u8, spec.name, engine_name)) {
                selected = spec;
                found = true;
                break;
            }
        }
        if (!found) {
            try stdout.print("Unknown --engine={s}. Available:", .{engine_name});
            for (specs) |spec| try stdout.print(" {s}", .{spec.name});
            try stdout.writeAll("\n");
            return error.UnknownEngine;
        }
        autotune = false;
    }

    if (autotune) {
        try stdout.print("=== ENGINE PILOT SWEEP ===\n", .{});
        try stdout.print("pilot_trials={d} pilot_iters={d}\n", .{ meta_trials, meta_iters });
        try stdout.writeAll("engine           | mode            | best_min | past | avg_min | best_closure | score\n");
        try stdout.writeAll("-----------------|-----------------|----------|------|---------|--------------|----------\n");

        var best_spec_score = -std.math.inf(f64);
        for (specs) |spec| {
            var candidate = spec;
            applyOverrides(&candidate, overrides);
            var best_min: u32 = 0;
            var best_closure: u128 = std.math.maxInt(u128);
            var past_count: usize = 0;
            var sum_min: u64 = 0;

            for (0..meta_trials) |trial| {
                const trial_seed = void_eng.splitMix64(base_seed +% @as(u64, @intCast(trial)) +% @as(u64, @intCast(spec.name.len * 4099)));
                const result = runTrial(candidate, trial_seed, meta_iters, target_dist, max_inter, concept_fps, names, prototype);
                const m = result.metrics;
                if (m.min_concept_dist > best_min) {
                    best_min = m.min_concept_dist;
                    best_closure = m.closure;
                } else if (m.min_concept_dist == best_min and m.closure < best_closure) {
                    best_closure = m.closure;
                }
                if (m.min_concept_dist > max_inter) past_count += 1;
                sum_min += m.min_concept_dist;
            }

            const avg_min = @as(f64, @floatFromInt(sum_min)) / @as(f64, @floatFromInt(meta_trials));
            const candidate_score = specScore(best_min, past_count, avg_min, best_closure);
            try stdout.print("{s: <16} | {s: <15} | {d: >8} | {d: >4} | {d: >7.1} | {d: >12} | {d: >8.1}\n", .{
                candidate.name,
                modeName(candidate.mode),
                best_min,
                past_count,
                avg_min,
                best_closure,
                candidate_score,
            });

            if (candidate_score > best_spec_score) {
                best_spec_score = candidate_score;
                selected = candidate;
            }
        }
        try stdout.print("\nSynthesized search engine: {s} ({s})\n\n", .{ selected.name, modeName(selected.mode) });
    } else {
        applyOverrides(&selected, overrides);
    }

    try stdout.print("=== FULL RUN ===\n", .{});
    try stdout.print("engine={s} mode={s} trials={d} iters={d} passes={d} mut={d} beta={d:.2} pressure={d}\n", .{
        selected.name,
        modeName(selected.mode),
        trials,
        iters_per_trial,
        selected.relax_passes,
        selected.mut_per_step,
        selected.beta,
        selected.novelty_pressure,
    });

    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var csv_file = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv_file.close();
    try csv_file.writer().writeAll("trial,engine,mode,best_min_dist,nearest,closure,mean_dist,max_dist,past_envelope,score\n");

    var past_envelope_trials: usize = 0;
    var best_overall = NoveltyMetrics{
        .closure = std.math.maxInt(u128),
        .min_concept_dist = 0,
        .nearest_name = "?",
        .nearest_index = 0,
        .mean_concept_dist = 0,
        .max_concept_dist = 0,
    };
    var best_overall_score = -std.math.inf(f64);

    try stdout.writeAll("trial | best_min | nearest          | closure      | mean  | max | past_max?\n");
    try stdout.writeAll("------|----------|------------------|--------------|-------|-----|----------\n");

    for (0..trials) |trial| {
        const trial_seed = void_eng.splitMix64(base_seed +% @as(u64, @intCast(trial)) *% 0x9E37_79B9_7F4A_7C15);
        const result = runTrial(selected, trial_seed, iters_per_trial, target_dist, max_inter, concept_fps, names, prototype);
        const m = result.metrics;
        const past_env = m.min_concept_dist > max_inter;
        if (past_env) past_envelope_trials += 1;
        if (betterMetrics(m, best_overall, max_inter) or result.score > best_overall_score) {
            best_overall = m;
            best_overall_score = result.score;
        }

        try stdout.print("{d: >5} | {d: >8} | {s: <16} | {d: >12} | {d: >5.1} | {d: >3} | {s}\n", .{
            trial,
            m.min_concept_dist,
            m.nearest_name,
            m.closure,
            m.mean_concept_dist,
            m.max_concept_dist,
            if (past_env) "ALIEN" else "no",
        });
        try csv_file.writer().print("{d},{s},{s},{d},{s},{d},{d:.4},{d},{d},{d:.6}\n", .{
            trial,
            selected.name,
            modeName(selected.mode),
            m.min_concept_dist,
            m.nearest_name,
            m.closure,
            m.mean_concept_dist,
            m.max_concept_dist,
            @intFromBool(past_env),
            result.score,
        });
    }

    try stdout.print("\n=== VERDICT ===\n", .{});
    try stdout.print("Trials past envelope (min_dist > {d}): {d}/{d} ({d:.1}%)\n", .{
        max_inter,
        past_envelope_trials,
        trials,
        100.0 * @as(f64, @floatFromInt(past_envelope_trials)) / @as(f64, @floatFromInt(trials)),
    });
    try stdout.print("Best min-concept-distance achieved: {d} bits  (envelope max was {d})\n", .{ best_overall.min_concept_dist, max_inter });
    try stdout.print("Best nearest concept: {s}; closure={d}; mean_dist={d:.1}; max_dist={d}\n", .{
        best_overall.nearest_name,
        best_overall.closure,
        best_overall.mean_concept_dist,
        best_overall.max_concept_dist,
    });
    try stdout.print("CSV: {s}\n", .{csv_path});

    if (past_envelope_trials > 0) {
        try stdout.writeAll("\nBREAKTHROUGH: novelty pressure found chamber states outside the measured\n");
        try stdout.writeAll("VSA concept envelope. ");
        if (selected.relax_passes == 0) {
            try stdout.writeAll("This run used raw chamber scoring with zero law-relaxation passes, so treat\n");
            try stdout.writeAll("it as an outside-envelope prototype, not a repaired law-state.\n");
        } else {
            try stdout.writeAll("This run included law-relaxation passes before scoring, so inspect closure\n");
            try stdout.writeAll("cost in the CSV and repeat with higher trials to confirm rate.\n");
        }
    } else if (best_overall.min_concept_dist > min_inter) {
        try stdout.writeAll("\nPARTIAL: the synthesized engine pushed into inter-concept space, but did\n");
        try stdout.writeAll("not cross the strict max-envelope boundary in this run. That is still a\n");
        try stdout.writeAll("measured improvement over closure-only search if the pilot/control rows lag.\n");
    } else {
        try stdout.writeAll("\nNO ESCAPE: even explicit novelty pressure did not move past the existing\n");
        try stdout.writeAll("concept geometry. That points back at law-table structure, not tuning pain.\n");
    }
}
