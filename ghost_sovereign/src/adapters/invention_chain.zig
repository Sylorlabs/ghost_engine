const std = @import("std");
const void_eng = @import("void");
const flame = @import("flame");
const vsa = @import("vsa");

// --- INVENTION CHAIN ---
// Iterates Void.maybeInventText for N generations, using each generation's
// chamber_snapshot as the seed state for the next. At each generation it
// measures distance from the current chamber state to each of the 20 VSA
// concept hypervectors. "Beyond VSA" is operationalized as: nearest-VSA
// distance growing past the inter-VSA-concept floor (the smallest pairwise
// Hamming between two concept hypervectors). If the trajectory crosses
// that floor and stays there, the inventions are outside the concept
// manifold the VSA lexicon names.

const FpWords = flame.ChamberCount / 64;
const Fingerprint = [FpWords]u64;

fn chamberFingerprint(chamber: [flame.ChamberCount]i128) Fingerprint {
    var fp: Fingerprint = [_]u64{0} ** FpWords;
    for (chamber, 0..) |v, i| {
        if (v > 0) fp[i / 64] |= (@as(u64, 1) << @intCast(i % 64));
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

const ConceptDist = struct { name: []const u8, dist: u32 };

fn nearestVSA(chamber_fp: Fingerprint, concept_fps: []const Fingerprint, names: []const []const u8) ConceptDist {
    var best: u32 = std.math.maxInt(u32);
    var best_name: []const u8 = "?";
    for (concept_fps, names) |cfp, name| {
        const d = hammingFp(chamber_fp, cfp);
        if (d < best) { best = d; best_name = name; }
    }
    return .{ .name = best_name, .dist = best };
}

fn meanVSADist(chamber_fp: Fingerprint, concept_fps: []const Fingerprint) f64 {
    var sum: u64 = 0;
    for (concept_fps) |cfp| sum += hammingFp(chamber_fp, cfp);
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(concept_fps.len));
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next();
    var message: []const u8 = "Invent a chamber geometry that transcends the VSA spelling attractor and binds runes by meaning.";
    var generations: usize = 32;
    var base_seed: u64 = 0x145F2EA61D0202D9;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--message=")) message = arg["--message=".len..]
        else if (std.mem.startsWith(u8, arg, "--gens=")) generations = try std.fmt.parseInt(usize, arg["--gens=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--seed=")) base_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== INVENTION CHAIN ===\nMessage: {s}\nGenerations: {d}\nSeed: 0x{X}\n\n", .{ message, generations, base_seed });

    // Build VSA concept fingerprint table + inter-concept floor.
    const concept_fields = std.meta.fields(vsa.Concept);
    var concept_fps_list = try aa.alloc(Fingerprint, concept_fields.len);
    var names_list = try aa.alloc([]const u8, concept_fields.len);
    inline for (concept_fields, 0..) |f, i| {
        const c = @as(vsa.Concept, @enumFromInt(f.value));
        concept_fps_list[i] = conceptFingerprint(c);
        names_list[i] = f.name;
    }

    var min_inter: u32 = std.math.maxInt(u32);
    var max_inter: u32 = 0;
    var sum_inter: u64 = 0;
    var pair_count: usize = 0;
    for (concept_fps_list, 0..) |a, i| for (i + 1..concept_fps_list.len) |j| {
        const d = hammingFp(a, concept_fps_list[j]);
        if (d < min_inter) min_inter = d;
        if (d > max_inter) max_inter = d;
        sum_inter += d;
        pair_count += 1;
    };
    const mean_inter = @as(f64, @floatFromInt(sum_inter)) / @as(f64, @floatFromInt(pair_count));
    try stdout.print("VSA inter-concept Hamming floor: min={d}  mean={d:.1}  max={d}  ({d} pairs)\n", .{ min_inter, mean_inter, max_inter, pair_count });
    try stdout.print("ESCAPE CRITERION: nearest_VSA > {d} bits AND mean_VSA > {d:.1}\n\n", .{ min_inter, mean_inter });

    // Initialize engine and prime it with the question.
    var engine = void_eng.VoidEngine.init(base_seed);
    engine.ingestTextSequence(0xA11CEF00DBABEC0D, message, message.len * 4);
    engine.shapeTextPressure(0xBEEFDEADC0DEF00D, message);

    const baseline_fp = chamberFingerprint(engine.state.chamber);
    const baseline_near = nearestVSA(baseline_fp, concept_fps_list, names_list);
    const baseline_mean = meanVSADist(baseline_fp, concept_fps_list);
    try stdout.print("Baseline (post-ingest, pre-invention):\n  nearest VSA = {s} @ {d}  | mean VSA = {d:.1}\n\n", .{ baseline_near.name, baseline_near.dist, baseline_mean });

    try stdout.writeAll("gen | closure_before | closure_after  | delta(%)   | nearest VSA          | mean VSA | drift_from_baseline\n");
    try stdout.writeAll("----|----------------|----------------|------------|----------------------|----------|--------------------\n");

    var prev_fp = baseline_fp;
    var any_escape = false;
    var gen: u32 = 1;
    while (gen <= generations) : (gen += 1) {
        const cand_opt = engine.maybeInventText(message, gen);
        if (cand_opt == null) {
            try stdout.print("{d: >3} | NULL — engine returned no closure-reducing candidate\n", .{gen});
            continue;
        }
        const cand = cand_opt.?;
        engine.state.chamber = cand.chamber_snapshot;
        engine.state.closure_error = cand.closure_after;

        const fp = chamberFingerprint(engine.state.chamber);
        const near = nearestVSA(fp, concept_fps_list, names_list);
        const mean_v = meanVSADist(fp, concept_fps_list);
        const drift = hammingFp(fp, baseline_fp);
        const inter_drift = hammingFp(fp, prev_fp);
        const pct = if (cand.closure_before > 0)
            -100.0 * @as(f64, @floatFromInt(cand.closure_before - cand.closure_after)) / @as(f64, @floatFromInt(cand.closure_before))
        else 0.0;
        _ = inter_drift;

        const escaped = (near.dist > min_inter) and (mean_v > mean_inter);
        if (escaped) any_escape = true;
        const tag = if (escaped) " <-- BEYOND VSA" else "";

        try stdout.print("{d: >3} | {d: >14} | {d: >14} | {d: >9.4} | {s: <14} @ {d: >3} | {d: >7.1} | {d: >18}{s}\n", .{
            gen, cand.closure_before, cand.closure_after, pct, near.name, near.dist, mean_v, drift, tag,
        });
        prev_fp = fp;
    }

    try stdout.print("\n=== TRAJECTORY VERDICT ===\n", .{});
    if (any_escape) {
        try stdout.print("At least one generation produced a chamber state OUTSIDE the VSA concept manifold\n", .{});
        try stdout.print("(nearest VSA > {d} AND mean VSA > {d:.1}).\n", .{ min_inter, mean_inter });
        try stdout.print("Interpretation: the invention loop produced novel geometry not described by the\n", .{});
        try stdout.print("VSA Concept enum. Worth inspecting the chamber state of those generations.\n", .{});
    } else {
        try stdout.print("Every generation stayed inside the VSA concept manifold.\n", .{});
        try stdout.print("Interpretation: the invention loop rearranges VSA-shaped territory but does not\n", .{});
        try stdout.print("escape it. Architectural change to the law geometry would be needed to break free.\n", .{});
    }
}

test "concept fingerprints are distinct" {
    const a = conceptFingerprint(.LOGIC);
    const b = conceptFingerprint(.CHAOS);
    try std.testing.expect(hammingFp(a, b) > 0);
}
