const std = @import("std");
const void_eng = @import("void");
const flame = @import("flame");
const vsa = @import("vsa");

// --- INVENTION CHAIN, RELAXED THRESHOLD ---
// Re-implements VoidEngine.maybeInventText with a configurable closure-drop
// ratio so the chain can iterate for many generations instead of dying after
// one. Tracks per-generation: distance to each VSA concept, drift from the
// initial baseline, and the "REASON attractor pull" so we can see whether
// the chamber spirals OUT of REASON's neighborhood (escape velocity) or
// IN (collapse to attractor) when iterated.

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

// Local copies of void.zig's private helpers (kept private upstream).
fn calculateMedian(state: *const flame.FlameState) i128 {
    var sorted: [flame.ChamberCount]i128 = state.chamber;
    for (0..flame.ChamberCount - 1) |i| {
        for (i + 1..flame.ChamberCount) |j| {
            if (sorted[j] < sorted[i]) {
                const t = sorted[i];
                sorted[i] = sorted[j];
                sorted[j] = t;
            }
        }
    }
    return sorted[flame.ChamberCount / 2];
}

fn residualFingerprint(state: *const flame.FlameState) u64 {
    var h: u64 = 0x811C9DC5;
    for (state.chamber) |val| {
        const uval: u128 = @bitCast(val);
        h = (h ^ @as(u64, @truncate(uval))) *% 0x01000193;
        h = (h ^ @as(u64, @truncate(uval >> 64))) *% 0x01000193;
    }
    return h;
}

const InvertResult = struct {
    found: bool,
    closure_before: u128,
    closure_after: u128,
    chamber: [flame.ChamberCount]i128,
};

// Same inner machinery as VoidEngine.maybeInventText, but with a
// configurable required closure-drop ratio (0.99 = original 99% bar;
// 0.10 = accept any 10% drop).
fn invertRelaxed(
    state: *const flame.FlameState,
    text: []const u8,
    generation: u32,
    drop_ratio: f64,
    branches: usize,
) InvertResult {
    const control = flame.closureError(state);
    var out = InvertResult{
        .found = false,
        .closure_before = control,
        .closure_after = control,
        .chamber = state.chamber,
    };
    if (control == 0) return out;

    const context_hash = flame.textHash(text);
    const state_fp = residualFingerprint(state) ^ context_hash;
    const NullScar: u64 = 0x3563447E3EBAEF14;
    const med = calculateMedian(state);
    const ctrl_f = @as(f64, @floatFromInt(control));
    const required_max_f = ctrl_f * (1.0 - drop_ratio);
    const required_max: u128 = if (required_max_f < 0) 0 else @intFromFloat(required_max_f);

    var best_after: u128 = control;
    var best_chamber = state.chamber;

    for (0..branches) |branch| {
        var trial = state.*;
        const bseed = flame.splitMix64(state_fp ^ branch ^ generation);
        for (0..flame.ChamberCount) |i| {
            const gradient = trial.chamber[i] - med;
            const scar_mix = @as(i128, @intCast((NullScar >> @as(u6, @intCast(i * 6 % 60))) & 0xFFFFFFFF));
            const branch_mix = @as(i128, @intCast((bseed >> @as(u6, @intCast(i * 5 % 60))) & 0xFFFFFFFF));
            trial.chamber[i] = med - @divTrunc(gradient * 2, 1) + scar_mix ^ branch_mix;
        }
        for (0..500) |pass| {
            for (flame.Laws) |law| {
                const got = law.ca * trial.chamber[law.a] + law.cb * trial.chamber[law.b];
                const err = law.t - got;
                if (err == 0) continue;
                const denom = law.ca * law.ca + law.cb * law.cb;
                if (denom == 0) continue;
                const damp = @as(i128, @intCast(1 + (pass / 10)));
                const da = @divTrunc(err * law.ca, denom * damp);
                const db = @divTrunc(err * law.cb, denom * damp);
                trial.chamber[law.a] += @max(-1_000_000_000_000, @min(1_000_000_000_000, da));
                trial.chamber[law.b] += @max(-1_000_000_000_000, @min(1_000_000_000_000, db));
            }
        }
        const after = flame.closureError(&trial);
        if (after > required_max) continue;
        if (after < best_after) {
            best_after = after;
            best_chamber = trial.chamber;
            out.found = true;
        }
    }
    out.closure_after = best_after;
    out.chamber = best_chamber;
    return out;
}

const ConceptDist = struct { name: []const u8, dist: u32 };

fn nearestVSA(fp: Fingerprint, concept_fps: []const Fingerprint, names: []const []const u8) ConceptDist {
    var best: u32 = std.math.maxInt(u32);
    var best_name: []const u8 = "?";
    for (concept_fps, names) |cfp, name| {
        const d = hammingFp(fp, cfp);
        if (d < best) {
            best = d;
            best_name = name;
        }
    }
    return .{ .name = best_name, .dist = best };
}

fn meanVSADist(fp: Fingerprint, concept_fps: []const Fingerprint) f64 {
    var sum: u64 = 0;
    for (concept_fps) |cfp| sum += hammingFp(fp, cfp);
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(concept_fps.len));
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next();
    var message: []const u8 = "Invent a chamber geometry that transcends VSA and binds runes by meaning.";
    var generations: usize = 60;
    var base_seed: u64 = 0x145F2EA61D0202D9;
    var drop_ratio: f64 = 0.10;
    var branches: usize = 256;
    var csv_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--message=")) message = arg["--message=".len..] else if (std.mem.startsWith(u8, arg, "--gens=")) generations = try std.fmt.parseInt(usize, arg["--gens=".len..], 10) else if (std.mem.startsWith(u8, arg, "--seed=")) base_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16) else if (std.mem.startsWith(u8, arg, "--drop=")) drop_ratio = try std.fmt.parseFloat(f64, arg["--drop=".len..]) else if (std.mem.startsWith(u8, arg, "--branches=")) branches = try std.fmt.parseInt(usize, arg["--branches=".len..], 10) else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..];
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== INVENTION CHAIN (relaxed) ===\nMessage: {s}\nGens: {d}  Seed: 0x{X}  Drop: {d:.3}  Branches: {d}\n\n", .{ message, generations, base_seed, drop_ratio, branches });

    const concept_fields = std.meta.fields(vsa.Concept);
    var concept_fps_list = try aa.alloc(Fingerprint, concept_fields.len);
    var names_list = try aa.alloc([]const u8, concept_fields.len);
    inline for (concept_fields, 0..) |f, i| {
        concept_fps_list[i] = conceptFingerprint(@as(vsa.Concept, @enumFromInt(f.value)));
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
    try stdout.print("VSA inter-concept floor: min={d}  mean={d:.1}  max={d}\n", .{ min_inter, mean_inter, max_inter });

    var engine = void_eng.VoidEngine.init(base_seed);
    engine.ingestTextSequence(0xA11CEF00DBABEC0D, message, message.len * 4);
    engine.shapeTextPressure(0xBEEFDEADC0DEF00D, message);

    const baseline_fp = chamberFingerprint(engine.state.chamber);
    const baseline_near = nearestVSA(baseline_fp, concept_fps_list, names_list);
    const reason_fp = conceptFingerprint(.REASON);
    const baseline_reason = hammingFp(baseline_fp, reason_fp);
    try stdout.print("Baseline: nearest={s}@{d}  reason_dist={d}  mean={d:.1}\n\n", .{ baseline_near.name, baseline_near.dist, baseline_reason, meanVSADist(baseline_fp, concept_fps_list) });

    var maybe_csv: ?std.fs.File = null;
    if (csv_path) |path| {
        if (std.fs.path.dirname(path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
        maybe_csv = try std.fs.cwd().createFile(path, .{ .truncate = true });
        try maybe_csv.?.writer().writeAll("gen,closure_before,closure_after,nearest,nearest_dist,reason_dist,mean_vsa,drift_from_baseline\n");
    }
    defer if (maybe_csv) |f| f.close();

    try stdout.writeAll("gen | closure(after)  | drop%  | nearest VSA      | nearest | reason | mean | drift\n");
    try stdout.writeAll("----|-----------------|--------|------------------|---------|--------|------|------\n");

    var prev_reason_dist: u32 = baseline_reason;
    var max_drift: u32 = 0;
    var max_reason_dist: u32 = baseline_reason;
    var found_count: usize = 0;
    var spiral_out_steps: usize = 0;
    var spiral_in_steps: usize = 0;

    var gen: u32 = 1;
    while (gen <= generations) : (gen += 1) {
        const r = invertRelaxed(&engine.state, message, gen, drop_ratio, branches);
        if (!r.found) {
            try stdout.print("{d: >3} | NULL (no branch hit {d:.0}% drop)\n", .{ gen, drop_ratio * 100.0 });
            continue;
        }
        found_count += 1;
        engine.state.chamber = r.chamber;
        engine.state.closure_error = r.closure_after;

        const fp = chamberFingerprint(engine.state.chamber);
        const near = nearestVSA(fp, concept_fps_list, names_list);
        const reason_dist = hammingFp(fp, reason_fp);
        const mean_v = meanVSADist(fp, concept_fps_list);
        const drift = hammingFp(fp, baseline_fp);
        if (drift > max_drift) max_drift = drift;
        if (reason_dist > max_reason_dist) max_reason_dist = reason_dist;
        if (reason_dist > prev_reason_dist) spiral_out_steps += 1 else if (reason_dist < prev_reason_dist) spiral_in_steps += 1;
        prev_reason_dist = reason_dist;

        const pct = if (r.closure_before > 0)
            100.0 * @as(f64, @floatFromInt(r.closure_before - r.closure_after)) / @as(f64, @floatFromInt(r.closure_before))
        else
            0.0;

        try stdout.print("{d: >3} | {d: >15} | {d: >6.2} | {s: <16} | {d: >7} | {d: >6} | {d: >4.1} | {d: >5}\n", .{
            gen, r.closure_after, pct, near.name, near.dist, reason_dist, mean_v, drift,
        });
        if (maybe_csv) |f| try f.writer().print("{d},{d},{d},{s},{d},{d},{d:.4},{d}\n", .{
            gen, r.closure_before, r.closure_after, near.name, near.dist, reason_dist, mean_v, drift,
        });
    }

    try stdout.print("\n=== TRAJECTORY SUMMARY ===\n", .{});
    try stdout.print("Successful inversions:   {d}/{d}\n", .{ found_count, generations });
    try stdout.print("Max drift from baseline: {d} bits\n", .{max_drift});
    try stdout.print("Max distance from REASON: {d} bits  (baseline was {d})\n", .{ max_reason_dist, baseline_reason });
    try stdout.print("Steps moving AWAY from REASON: {d}\n", .{spiral_out_steps});
    try stdout.print("Steps moving TOWARD REASON:    {d}\n", .{spiral_in_steps});
    const net = @as(i64, @intCast(max_reason_dist)) - @as(i64, @intCast(baseline_reason));
    if (spiral_out_steps > spiral_in_steps + spiral_in_steps / 2 and net > 20) {
        try stdout.writeAll("VERDICT: chain ESCAPES — chamber spiraling outward from REASON's neighborhood.\n");
    } else if (spiral_in_steps > spiral_out_steps + spiral_out_steps / 2) {
        try stdout.writeAll("VERDICT: chain COLLAPSES into REASON's attractor.\n");
    } else {
        try stdout.writeAll("VERDICT: chain ORBITS REASON — neither sustained escape nor collapse.\n");
    }
}

test "invertRelaxed accepts at least one branch with relaxed threshold" {
    const message = "Invent a chamber geometry that transcends VSA and binds runes by meaning.";
    var engine = void_eng.VoidEngine.init(0x145F2EA61D0202D9);
    engine.ingestTextSequence(0xA11CEF00DBABEC0D, message, message.len * 4);
    engine.shapeTextPressure(0xBEEFDEADC0DEF00D, message);
    const r = invertRelaxed(&engine.state, message, 1, 0.10, 64);
    try std.testing.expect(r.found);
    try std.testing.expect(r.closure_after < r.closure_before);
}
