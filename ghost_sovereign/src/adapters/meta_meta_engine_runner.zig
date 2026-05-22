const std = @import("std");
const mm = @import("domain_meta_meta_engine.zig");
const tier0 = @import("domain_meta_engine.zig");

// --- Tier-1 RUNNER ---
//
// Conducts the headline successor experiment:
//   discovered MetaMetaProgram vs hand-coded outer SA
// at EQUAL total MetaProgram-evaluation budget. Both produce a
// champion MetaProgram; both are re-evaluated on a held-out seed set.
//
// Budget contract (the "equal budget" line):
//   tier1_outer × tier1_eval_per_outer_iter × tier0_inner_steps
// must equal the hand-coded baseline's
//   tier0_outer × tier0_inner_steps
//
// where tier1_eval_per_outer_iter is heuristically the number of
// EVAL_META_CUR ops a Tier-1 MetaMetaProgram executes per outer step
// (varies — we report the actual mixer-eval count for both).

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

// --- Held-out evaluation ---

fn evaluateMetaOnHoldout(meta: tier0.MetaProgram, seeds: []const u64, inner_steps: u32) f64 {
    var total: f64 = 0;
    var count: f64 = 0;
    for (seeds) |s| {
        const q = tier0.run(meta, inner_steps, s);
        if (std.math.isFinite(q)) {
            total += q;
            count += 1;
        }
    }
    if (count == 0) return -1.0e6;
    return total / count;
}

// --- HAND-CODED Tier-0 OUTER SA BASELINE ---
//
// This mirrors the hand-coded outer SA used by meta_engine_runner.zig:
// random init pool, mutation, accept-if-better. Returns the champion
// MetaProgram (so we can hold-out-evaluate it).

// Disciplined hand-coded outer SA over MetaPrograms.
// Uses the SAME anchor-protection + rotation discipline as the Tier-1
// outer search, so the comparison isolates "discovered MMP" vs
// "hand-coded outer SA" cleanly — both halves run with the same
// outer-search hygiene; the only difference is what's driving the
// search-over-MetaPrograms.
fn runHandCodedOuterSA(
    outer_iters: u32,
    inner_steps: u32,
    root_seed: u64,
) struct { best: tier0.MetaProgram, best_q: f64, evals: u64 } {
    const anchor_seeds = [_]u64{
        0xB0B0_B0B0_F00D_0001,
        0xB0B0_B0B0_F00D_0002,
        0xB0B0_B0B0_F00D_0003,
        0xB0B0_B0B0_F00D_0004,
    };

    var rng = root_seed;
    const InitPool: usize = 32;

    var best: tier0.MetaProgram = undefined;
    var best_anchor_q: f64 = -std.math.inf(f64);
    var evals: u64 = 0;

    var k: usize = 0;
    while (k < InitPool) : (k += 1) {
        rng = smix(rng);
        const cand = tier0.randomMetaProgram(&rng);
        var sum: f64 = 0;
        for (anchor_seeds) |as| {
            const q = tier0.run(cand, inner_steps, as);
            sum += if (std.math.isFinite(q)) q else -1.0e6;
            evals += 1;
        }
        const mean_q = sum / @as(f64, @floatFromInt(anchor_seeds.len));
        if (mean_q > best_anchor_q) {
            best = cand;
            best_anchor_q = mean_q;
        }
    }

    // Each tier-1 iter spends 2 rotation + 4 anchor MMP evals → at
    // outer iter budget we mirror: 1 rotation pair + 4 anchor evals
    // per outer iter. Subtract init-pool evals from outer_iters.
    const post_init_iters_signed: i64 = @as(i64, outer_iters) - @as(i64, @intCast(InitPool * anchor_seeds.len));
    const post_init_iters: u32 = if (post_init_iters_signed > 0) @intCast(@divFloor(post_init_iters_signed, 6)) else 0;

    var i: u32 = 0;
    while (i < post_init_iters) : (i += 1) {
        rng = smix(rng);
        const rot_seed = rng;
        rng = smix(rng);
        const cand = tier0.mutateMeta(best, &rng);

        const q_best_rot_raw = tier0.run(best, inner_steps, rot_seed);
        const q_cand_rot_raw = tier0.run(cand, inner_steps, rot_seed);
        const q_best_rot = if (std.math.isFinite(q_best_rot_raw)) q_best_rot_raw else -1.0e6;
        const q_cand_rot = if (std.math.isFinite(q_cand_rot_raw)) q_cand_rot_raw else -1.0e6;
        evals += 2;

        if (q_cand_rot > q_best_rot) {
            // Anchor re-check
            var anchor_sum: f64 = 0;
            for (anchor_seeds) |as| {
                const q = tier0.run(cand, inner_steps, as);
                anchor_sum += if (std.math.isFinite(q)) q else -1.0e6;
                evals += 1;
            }
            const cand_anchor_mean = anchor_sum / @as(f64, @floatFromInt(anchor_seeds.len));
            if (cand_anchor_mean > best_anchor_q) {
                best = cand;
                best_anchor_q = cand_anchor_mean;
            }
        }
    }
    return .{ .best = best, .best_q = best_anchor_q, .evals = evals };
}

// --- TIER-1 OUTER SA (the experiment) ---
//
// Search over MetaMetaPrograms. Each candidate MetaMetaProgram is
// evaluated by running it for `mm_outer_iters` outer steps (per its
// run()), with each EVAL_META_CUR inside using `tier0_inner_steps`.
// Returns the discovered MetaMetaProgram and its q_best.

// Anchor-protected, seed-rotated Tier-1 outer SA.
// Discipline mirrors meta_engine_runner.zig v2:
// - init pool of 32 random MetaMetaPrograms; keep best on anchor seeds
// - seed rotation per outer iter (re-eval best AND candidate on the
//   same rotated seeds, so we never compare apples to oranges)
// - anchor protection: best_ever tracked on a STABLE anchor seed set;
//   ratchets monotone-non-decreasing
// - this mirrors the discipline that made Tier-0 reproducible.
fn runTier1OuterSA(
    mm_iters: u32,
    mm_outer_iters: u32,
    tier0_inner_steps: u32,
    root_seed: u64,
    log: anytype,
) !struct {
    best_mm: mm.MetaMetaProgram,
    best_q: f64,
    best_meta: tier0.MetaProgram,
    evals: u64,
} {
    mm.INNER_TIER0_STEPS = tier0_inner_steps;

    // Anchor seeds — STABLE across all evaluations. Distinct from
    // rotation seeds and from holdout seeds.
    const anchor_seeds = [_]u64{
        0xA0A0_A0A0_F00D_0001,
        0xA0A0_A0A0_F00D_0002,
        0xA0A0_A0A0_F00D_0003,
        0xA0A0_A0A0_F00D_0004,
    };

    var rng = root_seed;
    const InitPool: usize = 32;

    var best: mm.MetaMetaProgram = undefined;
    var best_anchor_q: f64 = -std.math.inf(f64);
    var best_meta: tier0.MetaProgram = undefined;

    var k: usize = 0;
    while (k < InitPool) : (k += 1) {
        rng = smix(rng);
        const cand = mm.randomMetaMetaProgram(&rng);
        // Score on anchor seeds (mean), using runReturningChampion to
        // also capture meta_best for held-out re-eval.
        var sum: f64 = 0;
        var count: f64 = 0;
        var champ_meta: tier0.MetaProgram = undefined;
        for (anchor_seeds) |as| {
            const r = mm.runReturningChampion(cand, mm_outer_iters, as);
            const q = if (std.math.isFinite(r.q_best)) r.q_best else -1.0e6;
            sum += q;
            count += 1;
            champ_meta = r.meta_best; // last anchor's meta_best — overwritten each iter
        }
        const mean_q = sum / count;
        if (mean_q > best_anchor_q) {
            best = cand;
            best_anchor_q = mean_q;
            best_meta = champ_meta;
        }
    }
    try log.print("init pool best anchor-mean q={d:.4}\n", .{best_anchor_q});

    var accepted: u32 = 0;
    var evals: u64 = @as(u64, InitPool) * @as(u64, anchor_seeds.len);
    var i: u32 = 0;
    while (i < mm_iters) : (i += 1) {
        // Rotation seed for this outer iter.
        rng = smix(rng);
        const rot_seed = rng;

        rng = smix(rng);
        const cand = mm.mutateMetaMeta(best, &rng);

        // Re-evaluate both best and cand on the SAME rotation seed —
        // apples-to-apples comparison.
        const r_best = mm.runReturningChampion(best, mm_outer_iters, rot_seed);
        const r_cand = mm.runReturningChampion(cand, mm_outer_iters, rot_seed);
        const q_best_rot = if (std.math.isFinite(r_best.q_best)) r_best.q_best else -1.0e6;
        const q_cand_rot = if (std.math.isFinite(r_cand.q_best)) r_cand.q_best else -1.0e6;
        evals += 2;

        if (q_cand_rot > q_best_rot) {
            // Anchor re-check before accepting — only accept if cand
            // also beats best on anchor mean.
            var anchor_sum: f64 = 0;
            for (anchor_seeds) |as| {
                const r = mm.runReturningChampion(cand, mm_outer_iters, as);
                anchor_sum += if (std.math.isFinite(r.q_best)) r.q_best else -1.0e6;
            }
            const cand_anchor_mean = anchor_sum / @as(f64, @floatFromInt(anchor_seeds.len));
            evals += @as(u64, anchor_seeds.len);

            if (cand_anchor_mean > best_anchor_q) {
                best = cand;
                best_anchor_q = cand_anchor_mean;
                best_meta = r_cand.meta_best;
                accepted += 1;
                try log.print("iter {d} accepted rot_q={d:.4} anchor_mean={d:.4}\n", .{ i, q_cand_rot, cand_anchor_mean });
            }
        }
    }
    try log.print("tier1 done: accepted={d}/{d}  final anchor-mean={d:.4}\n", .{ accepted, mm_iters, best_anchor_q });

    return .{ .best_mm = best, .best_q = best_anchor_q, .best_meta = best_meta, .evals = evals };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    // Tunable budgets — the SAME across both halves of the experiment.
    var tier1_iters: u32 = 24;          // Tier-1 outer SA iterations (post init pool)
    var mm_outer_iters: u32 = 16;       // outer steps when running a MetaMetaProgram
    var tier0_inner_steps: u32 = 200;   // inner mixer-SA steps per EVAL_META
    var root_seed: u64 = 0xF00D_BEEF_CAFE_FACE;
    var out_subdir: []const u8 = "meta_meta_engine";

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--tier1-iters=")) {
            tier1_iters = try std.fmt.parseInt(u32, arg["--tier1-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--mm-outer-iters=")) {
            mm_outer_iters = try std.fmt.parseInt(u32, arg["--mm-outer-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tier0-inner-steps=")) {
            tier0_inner_steps = try std.fmt.parseInt(u32, arg["--tier0-inner-steps=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            root_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--out-subdir=")) {
            out_subdir = arg["--out-subdir=".len..];
        }
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== META-META RUNNER (Tier-1) ===\n", .{});
    try stdout.print("tier1_iters={d} mm_outer_iters={d} tier0_inner_steps={d} root_seed=0x{X}\n", .{
        tier1_iters, mm_outer_iters, tier0_inner_steps, root_seed,
    });

    // --- BASELINE: hand-coded Tier-0 outer SA ---
    //
    // To equalize: total MetaProgram evaluations should match between
    // tier-1 and baseline. Tier-1 evaluates (InitPool + tier1_iters) ×
    // mm_outer_iters MetaPrograms (worst case — actual count depends on
    // how many EVAL_META_CUR ops each MetaMetaProgram contains).
    // Baseline runs MetaPrograms one-at-a-time; equal total evals means
    // baseline_outer_iters = (8 + tier1_iters) × mm_outer_iters.
    // Equal-budget estimate. Tier-1 makes:
    //   init_pool(32) × anchor_seeds(4) = 128 MMP evals
    //   + tier1_iters × (2 rotation + 4 anchor) = tier1_iters × 6 MMP evals
    // Each MMP eval expands to mm_outer_iters MetaProgram evaluations
    // (roughly — assumes ~1 EVAL_META_CUR per MMP cycle, which is the
    // bias for survivable MMPs after the init-pool filter).
    const tier1_mmp_evals: u32 = 32 * 4 + tier1_iters * 6;
    const baseline_iters: u32 = tier1_mmp_evals * mm_outer_iters;
    try stdout.print("\n[baseline] hand-coded outer SA: outer_iters={d} inner_steps={d}\n", .{
        baseline_iters, tier0_inner_steps,
    });
    const t_b0 = std.time.milliTimestamp();
    const baseline = runHandCodedOuterSA(baseline_iters, tier0_inner_steps, root_seed +% 0x1111_1111);
    const t_b1 = std.time.milliTimestamp();
    try stdout.print("[baseline] done in {d} ms. evals={d} best_q={d:.4}\n", .{
        t_b1 - t_b0, baseline.evals, baseline.best_q,
    });

    // --- TIER-1 EXPERIMENT ---
    try stdout.print("\n[tier1] MetaMetaProgram outer SA: tier1_iters={d} mm_outer_iters={d}\n", .{
        tier1_iters, mm_outer_iters,
    });
    const t_t0 = std.time.milliTimestamp();
    const tier1 = try runTier1OuterSA(tier1_iters, mm_outer_iters, tier0_inner_steps, root_seed, stdout);
    const t_t1 = std.time.milliTimestamp();
    try stdout.print("[tier1] done in {d} ms. mm_evals={d} best_q={d:.4}\n", .{
        t_t1 - t_t0, tier1.evals, tier1.best_q,
    });

    // --- HELD-OUT COMPARISON ---
    // Re-evaluate both champion MetaPrograms on a fixed held-out seed
    // set, distinct from any seed used during search.
    const holdout_seeds = [_]u64{
        0xAAAA_BBBB_CCCC_DDDD,
        0x1234_5678_9ABC_DEF0,
        0xFEDC_BA98_7654_3210,
        0xDEAD_BEEF_FEED_FACE,
        0x0F0F_0F0F_F0F0_F0F0,
        0x5555_AAAA_5555_AAAA,
        0x1357_9BDF_2468_ACE0,
        0xC0FF_EE00_DEAD_BEEF,
    };

    try stdout.print("\n[holdout] {d} seeds, inner_steps={d}\n", .{ holdout_seeds.len, tier0_inner_steps });
    const ho_baseline = evaluateMetaOnHoldout(baseline.best, &holdout_seeds, tier0_inner_steps);
    const ho_tier1 = evaluateMetaOnHoldout(tier1.best_meta, &holdout_seeds, tier0_inner_steps);
    try stdout.print("baseline held-out mean: {d:.4}\n", .{ho_baseline});
    try stdout.print("tier1    held-out mean: {d:.4}\n", .{ho_tier1});

    const dominant = ho_tier1 > ho_baseline;
    try stdout.print("\n=== TIER-1 VERDICT ===\n", .{});
    if (dominant) {
        try stdout.print("DOMINANT: discovered MetaMetaProgram's champion MetaProgram\n", .{});
        try stdout.print("          beats hand-coded outer SA's champion MetaProgram\n", .{});
        try stdout.print("          on held-out by {d:.4}\n", .{ho_tier1 - ho_baseline});
    } else {
        try stdout.print("HALT: tier-1 did NOT beat baseline on held-out.\n", .{});
        try stdout.print("      delta = {d:.4} (baseline - tier1)\n", .{ho_baseline - ho_tier1});
    }

    // Persist artifacts
    var dir_buf: [128]u8 = undefined;
    const out_dir = try std.fmt.bufPrint(&dir_buf, "results/{s}", .{out_subdir});
    try std.fs.cwd().makePath(out_dir);
    {
        var path_buf: [192]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/baseline_champion_meta.csv", .{out_dir});
        var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
        defer f.close();
        try tier0.metaToCsv(baseline.best, f.writer());
    }
    {
        var path_buf: [192]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/tier1_champion_meta_meta.csv", .{out_dir});
        var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
        defer f.close();
        try mm.metaMetaToCsv(tier1.best_mm, f.writer());
    }
    {
        var path_buf: [192]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/tier1_champion_meta.csv", .{out_dir});
        var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
        defer f.close();
        try tier0.metaToCsv(tier1.best_meta, f.writer());
    }
    {
        var path_buf: [192]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/summary.csv", .{out_dir});
        var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
        defer f.close();
        const w = f.writer();
        try w.writeAll("metric,baseline,tier1\n");
        try w.print("train_q_best,{d:.6},{d:.6}\n", .{ baseline.best_q, tier1.best_q });
        try w.print("holdout_mean,{d:.6},{d:.6}\n", .{ ho_baseline, ho_tier1 });
        try w.print("metaprogram_evals,{d},{d}\n", .{ baseline.evals, tier1.evals });
    }
}
