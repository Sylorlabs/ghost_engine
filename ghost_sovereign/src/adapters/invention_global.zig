const std = @import("std");
const flame = @import("flame");
const vsa = @import("vsa");
const void_eng = @import("void");

// --- GLOBAL INVENTION SEARCH ---
// Generates N random chamber states, relaxes each against the law lattice,
// then measures where in concept space they landed. Tests whether the
// closure-minimum surface is identical with the 20-concept VSA manifold
// (current invention is biased only because trials start near a single
// concept) or whether genuinely "alien" low-closure pockets exist outside
// the concept neighborhoods.

const FpWords = flame.ChamberCount / 64;
const Fingerprint = [FpWords]u64;

fn chamberFingerprint(chamber: [flame.ChamberCount]i128) Fingerprint {
    var fp: Fingerprint = [_]u64{0} ** FpWords;
    for (chamber, 0..) |v, i| if (v > 0) {
        fp[i / 64] |= (@as(u64, 1) << @intCast(i % 64));
    };
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

// flame.relax divides by denom without a zero-check; Void's inversion adds
// `if (denom == 0) continue;` plus safety clamps and a dampener that scales
// the step size as passes accumulate. Mirror that pattern here so random
// chambers don't trigger a panic on degenerate laws (ca == cb == 0).
fn relaxSafe(state: *flame.FlameState, passes: usize) void {
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
    }
    state.closure_error = flame.closureError(state);
}

const Outcome = struct {
    seed: u64,
    closure_initial: u128,
    closure_relaxed: u128,
    nearest_name: []const u8,
    nearest_dist: u32,
    mean_vsa: f64,
    max_vsa: u32,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next();
    var trials: usize = 1000;
    var passes: usize = 1000;
    var init_range: i128 = 50000;
    var base_seed: u64 = 0x9E3779B97F4A7C15;
    var csv_path: []const u8 = "results/invention_global.csv";
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--trials=")) trials = try std.fmt.parseInt(usize, arg["--trials=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--passes=")) passes = try std.fmt.parseInt(usize, arg["--passes=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--range=")) init_range = try std.fmt.parseInt(i128, arg["--range=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--seed=")) base_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16)
        else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..];
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== GLOBAL INVENTION SEARCH ===\n", .{});
    try stdout.print("Trials: {d}  Passes: {d}  Init range: ±{d}  Seed: 0x{X}\n\n", .{ trials, passes, init_range, base_seed });

    // VSA concept fingerprint table.
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
    for (concept_fps, 0..) |a, i| for (i + 1..concept_fps.len) |j| {
        const d = hammingFp(a, concept_fps[j]);
        if (d < min_inter) min_inter = d;
        if (d > max_inter) max_inter = d;
        sum_inter += d;
        pair_count += 1;
    };
    const mean_inter = @as(f64, @floatFromInt(sum_inter)) / @as(f64, @floatFromInt(pair_count));
    try stdout.print("VSA inter-concept Hamming: min={d}  mean={d:.1}  max={d}  ({d} pairs)\n\n", .{ min_inter, mean_inter, max_inter, pair_count });
    try stdout.print("ALIEN CRITERION: nearest_VSA > {d} bits (strictly past max inter-concept distance)\n\n", .{max_inter});

    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var csv_file = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv_file.close();
    var csv_w = csv_file.writer();
    try csv_w.writeAll("trial,seed,closure_initial,closure_relaxed,nearest,nearest_dist,mean_vsa,max_vsa\n");

    var outcomes = try aa.alloc(Outcome, trials);

    var concept_hits = try aa.alloc(usize, fields.len);
    @memset(concept_hits, 0);
    var alien_count: usize = 0;
    var beyond_inter_min: usize = 0;

    for (0..trials) |t| {
        const trial_seed = void_eng.splitMix64(base_seed +% @as(u64, @intCast(t)));
        var state = flame.FlameState{
            .chamber = randomChamber(trial_seed, init_range),
            .scar_bank = [_]u64{0} ** flame.ScarCount,
            .kernel = base_seed,
            .closure_error = 0,
        };
        state.closure_error = flame.closureError(&state);
        const initial = state.closure_error;
        relaxSafe(&state, passes);

        const fp = chamberFingerprint(state.chamber);
        var best: u32 = std.math.maxInt(u32);
        var best_idx: usize = 0;
        var sum_d: u64 = 0;
        var max_d: u32 = 0;
        for (concept_fps, 0..) |cfp, i| {
            const d = hammingFp(fp, cfp);
            sum_d += d;
            if (d > max_d) max_d = d;
            if (d < best) { best = d; best_idx = i; }
        }
        const mean_v = @as(f64, @floatFromInt(sum_d)) / @as(f64, @floatFromInt(concept_fps.len));
        concept_hits[best_idx] += 1;
        if (best > max_inter) alien_count += 1;
        if (best > min_inter) beyond_inter_min += 1;

        outcomes[t] = .{
            .seed = trial_seed,
            .closure_initial = initial,
            .closure_relaxed = state.closure_error,
            .nearest_name = names[best_idx],
            .nearest_dist = best,
            .mean_vsa = mean_v,
            .max_vsa = max_d,
        };
        try csv_w.print("{d},{x},{d},{d},{s},{d},{d:.4},{d}\n", .{
            t, trial_seed, initial, state.closure_error, names[best_idx], best, mean_v, max_d,
        });
    }

    // Sort by closure_relaxed ascending for inspection.
    std.sort.heap(Outcome, outcomes, {}, struct {
        fn lt(_: void, a: Outcome, b: Outcome) bool { return a.closure_relaxed < b.closure_relaxed; }
    }.lt);

    try stdout.writeAll("=== Top 12 lowest-closure relaxed chambers ===\n");
    try stdout.writeAll("rank | closure_initial | closure_relaxed | nearest VSA       | dist | mean | max\n");
    try stdout.writeAll("-----|-----------------|-----------------|-------------------|------|------|-----\n");
    const top_n = @min(@as(usize, 12), trials);
    for (outcomes[0..top_n], 0..) |o, rank| {
        try stdout.print("{d: >4} | {d: >15} | {d: >15} | {s: <17} | {d: >4} | {d: >4.1} | {d: >3}\n", .{
            rank + 1, o.closure_initial, o.closure_relaxed, o.nearest_name, o.nearest_dist, o.mean_vsa, o.max_vsa,
        });
    }

    try stdout.writeAll("\n=== Concept-attractor histogram (where the 1000 relaxed chambers landed) ===\n");
    for (names, concept_hits) |n, h| {
        const pct = 100.0 * @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(trials));
        try stdout.print("  {s: <10} : {d: >4} ({d: >5.1}%)\n", .{ n, h, pct });
    }

    try stdout.writeAll("\n=== VERDICT ===\n");
    try stdout.print("Trials past min inter-concept floor ({d}): {d} ({d:.1}%)\n", .{
        min_inter, beyond_inter_min, 100.0 * @as(f64, @floatFromInt(beyond_inter_min)) / @as(f64, @floatFromInt(trials)),
    });
    try stdout.print("Trials past MAX inter-concept floor ({d}) — ALIEN: {d} ({d:.1}%)\n", .{
        max_inter, alien_count, 100.0 * @as(f64, @floatFromInt(alien_count)) / @as(f64, @floatFromInt(trials)),
    });
    if (alien_count > 0) {
        try stdout.writeAll("\nVERDICT: ALIEN REGIONS EXIST. At least one random-init chamber relaxed\n");
        try stdout.writeAll("to a low-closure state OUTSIDE the entire VSA concept manifold. The current\n");
        try stdout.writeAll("invention loop just doesn't search globally. Architecture supports invention\n");
        try stdout.writeAll("once trial-generation is changed to include random restarts.\n");
    } else if (beyond_inter_min > trials / 4) {
        try stdout.writeAll("\nVERDICT: BOUNDARY-DWELLING. Many random-init chambers land in the gap\n");
        try stdout.writeAll("between VSA concepts but not strictly past max inter-concept distance.\n");
        try stdout.writeAll("Closure landscape is wider than the 20 anchors but not infinite — there\n");
        try stdout.writeAll("are gradations of 'beyond' that current architecture cannot reach.\n");
    } else {
        try stdout.writeAll("\nVERDICT: CONCEPT MANIFOLD = CLOSURE MANIFOLD. Every random-init chamber\n");
        try stdout.writeAll("relaxes into one of the 20 VSA concept neighborhoods. The closure surface\n");
        try stdout.writeAll("of the law lattice IS the concept set. No alien regions exist in this\n");
        try stdout.writeAll("geometry. Invention beyond VSA requires changing the law table itself.\n");
    }
}
