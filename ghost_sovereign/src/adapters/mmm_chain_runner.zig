const std = @import("std");
const mmm = @import("domain_meta_meta_meta_engine.zig");
const mm = @import("domain_meta_meta_engine.zig");
const tier0 = @import("domain_meta_engine.zig");

// --- TIER-2 CHAIN RUNNER ---
//
// Engine-inventing-engine-inventing-engine-inventing-engine.
//
// Each Tier-2 generation:
//   1. Runs anchor-protected + seed-rotated outer SA over
//      MetaMetaMetaPrograms (MMMPs). Inside, EVAL_MM_CUR runs a full
//      Tier-1 mini-search via mm.run.
//   2. Extracts the champion MMMP's discovered MetaMetaProgram (re-run
//      with runReturningChampion).
//   3. Re-runs that MetaMetaProgram on the held-out anchor seeds via
//      mm.runReturningChampion → final MetaProgram champion.
//   4. Scores that MetaProgram on STABLE held-out seeds via tier0.run.
//   5. Compares to prior generation's holdout score.
//
// chain_extras_mm holds prior generations' champion MetaMetaPrograms so
// CALL_MM can warm-start mm_cur from a prior champion.

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

// Load a MetaMetaProgram CSV produced by mm.metaMetaToCsv.
// Format: idx,op_id,op_name,dst,src1,src2
fn loadMetaMetaProgramCsv(allocator: std.mem.Allocator, path: []const u8) !mm.MetaMetaProgram {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(contents);

    var p = mm.MetaMetaProgram{ .instructions = undefined, .used = 0 };
    var lines = std.mem.tokenizeAny(u8, contents, "\n\r");
    var first = true;
    while (lines.next()) |line| {
        if (first) { first = false; continue; }
        var fields = std.mem.tokenizeAny(u8, line, ",");
        _ = fields.next() orelse continue; // idx
        const op_id_s = fields.next() orelse continue;
        _ = fields.next() orelse continue; // op_name
        const dst_s = fields.next() orelse continue;
        const src1_s = fields.next() orelse continue;
        const src2_s = fields.next() orelse continue;
        const op_id = try std.fmt.parseInt(u8, op_id_s, 10);
        const dst = try std.fmt.parseInt(u8, dst_s, 10);
        const src1 = try std.fmt.parseInt(u8, src1_s, 10);
        const src2 = try std.fmt.parseInt(u8, src2_s, 10);
        p.instructions[p.used] = .{
            .op = @enumFromInt(op_id),
            .dst = @intCast(dst),
            .src1 = @intCast(src1),
            .src2 = @intCast(src2),
        };
        p.used += 1;
        if (p.used >= mm.MaxMetaMetaLen) break;
    }
    return p;
}

// Anchor seeds for Tier-2 outer search.
const tier2_anchor_seeds = [_]u64{
    0xC0C0_C0C0_F00D_0001,
    0xC0C0_C0C0_F00D_0002,
    0xC0C0_C0C0_F00D_0003,
    0xC0C0_C0C0_F00D_0004,
};

// 8 held-out seeds, fixed across all generations. Same as tier-1 chain
// for cross-comparability.
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

fn evaluateMetaOnSeeds(meta: tier0.MetaProgram, seeds: []const u64, inner_steps: u32) f64 {
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

const GenResult = struct {
    gen: usize,
    train_anchor_mean: f64,
    holdout_mean: f64,
    accepted: u32,
    mmm_evals: u64,
    champion_mmm: mmm.MetaMetaMetaProgram,
    champion_mm: mm.MetaMetaProgram,
    champion_meta: tier0.MetaProgram,
};

fn runTier2Generation(
    gen: usize,
    tier2_iters: u32,
    mmm_outer_iters: u32,
    tier1_outer_iters: u32,
    tier0_inner_steps: u32,
    root_seed: u64,
    log: anytype,
) !GenResult {
    mm.INNER_TIER0_STEPS = tier0_inner_steps;
    mmm.INNER_TIER1_OUTER_STEPS = tier1_outer_iters;

    var rng = root_seed;
    const InitPool: usize = 16;

    var best_mmm: mmm.MetaMetaMetaProgram = undefined;
    var best_anchor_q: f64 = -std.math.inf(f64);
    var best_mm_champ: mm.MetaMetaProgram = undefined;
    var evals: u64 = 0;

    var k: usize = 0;
    while (k < InitPool) : (k += 1) {
        rng = smix(rng);
        const cand = mmm.randomMetaMetaMetaProgram(&rng);
        var sum: f64 = 0;
        var champ_mm: mm.MetaMetaProgram = undefined;
        var champ_q: f64 = -std.math.inf(f64);
        for (tier2_anchor_seeds) |as| {
            const r = mmm.runReturningChampion(cand, mmm_outer_iters, as);
            const q = if (std.math.isFinite(r.q_best)) r.q_best else -1.0e6;
            sum += q;
            if (q > champ_q) {
                champ_q = q;
                champ_mm = r.mm_best;
            }
            evals += 1;
        }
        const mean_q = sum / @as(f64, @floatFromInt(tier2_anchor_seeds.len));
        if (mean_q > best_anchor_q) {
            best_mmm = cand;
            best_anchor_q = mean_q;
            best_mm_champ = champ_mm;
        }
    }
    try log.print("  init pool best anchor-mean q={d:.4}\n", .{best_anchor_q});

    var accepted: u32 = 0;
    var i: u32 = 0;
    while (i < tier2_iters) : (i += 1) {
        rng = smix(rng);
        const rot_seed = rng;
        rng = smix(rng);
        const cand = mmm.mutateMetaMetaMeta(best_mmm, &rng);

        const r_best = mmm.runReturningChampion(best_mmm, mmm_outer_iters, rot_seed);
        const r_cand = mmm.runReturningChampion(cand, mmm_outer_iters, rot_seed);
        const q_best_rot = if (std.math.isFinite(r_best.q_best)) r_best.q_best else -1.0e6;
        const q_cand_rot = if (std.math.isFinite(r_cand.q_best)) r_cand.q_best else -1.0e6;
        evals += 2;

        if (q_cand_rot <= q_best_rot) continue;

        var anchor_sum: f64 = 0;
        var cand_mm_anchor: mm.MetaMetaProgram = undefined;
        var cand_mm_q: f64 = -std.math.inf(f64);
        for (tier2_anchor_seeds) |as| {
            const r = mmm.runReturningChampion(cand, mmm_outer_iters, as);
            const q = if (std.math.isFinite(r.q_best)) r.q_best else -1.0e6;
            anchor_sum += q;
            if (q > cand_mm_q) {
                cand_mm_q = q;
                cand_mm_anchor = r.mm_best;
            }
            evals += 1;
        }
        const cand_anchor_mean = anchor_sum / @as(f64, @floatFromInt(tier2_anchor_seeds.len));
        if (cand_anchor_mean <= best_anchor_q) continue;

        best_mmm = cand;
        best_anchor_q = cand_anchor_mean;
        best_mm_champ = cand_mm_anchor;
        accepted += 1;
        try log.print("  iter {d} accepted anchor={d:.4}\n", .{ i, cand_anchor_mean });
    }

    // Extract the final-level Meta champion: run the discovered
    // MetaMetaProgram on holdout-seed-0 via mm.runReturningChampion to
    // pull out its discovered MetaProgram. Then score that MetaProgram
    // on the 8 holdout seeds.
    const champ_seed = holdout_seeds[0] ^ 0x5A5A_F00D_BABE_C0DE;
    const champ_mm_run = mm.runReturningChampion(best_mm_champ, mmm_outer_iters * 2, champ_seed);
    const champ_meta = champ_mm_run.meta_best;
    const holdout = evaluateMetaOnSeeds(champ_meta, &holdout_seeds, tier0_inner_steps);

    try log.print("  gen {d}: accepted={d}/{d} anchor_mean={d:.4} holdout={d:.4} mmm_evals={d}\n", .{
        gen, accepted, tier2_iters, best_anchor_q, holdout, evals,
    });

    return GenResult{
        .gen = gen,
        .train_anchor_mean = best_anchor_q,
        .holdout_mean = holdout,
        .accepted = accepted,
        .mmm_evals = evals,
        .champion_mmm = best_mmm,
        .champion_mm = best_mm_champ,
        .champion_meta = champ_meta,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var generations: u32 = 3;
    var tier2_iters: u32 = 8;
    var mmm_outer_iters: u32 = 6;
    var tier1_outer_iters: u32 = 6;
    var tier0_inner_steps: u32 = 100;
    var root_seed: u64 = 0x1111_2222_3333_4444;
    var out_subdir: []const u8 = "mmm_chain";
    var seed_mm_library: []const u8 = "";
    var shaped_fitness: bool = false;
    var constrained_init: bool = false;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--generations=")) {
            generations = try std.fmt.parseInt(u32, arg["--generations=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tier2-iters=")) {
            tier2_iters = try std.fmt.parseInt(u32, arg["--tier2-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--mmm-outer-iters=")) {
            mmm_outer_iters = try std.fmt.parseInt(u32, arg["--mmm-outer-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tier1-outer-iters=")) {
            tier1_outer_iters = try std.fmt.parseInt(u32, arg["--tier1-outer-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tier0-inner-steps=")) {
            tier0_inner_steps = try std.fmt.parseInt(u32, arg["--tier0-inner-steps=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            root_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--out-subdir=")) {
            out_subdir = arg["--out-subdir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seed-mm-library=")) {
            seed_mm_library = arg["--seed-mm-library=".len..];
        } else if (std.mem.eql(u8, arg, "--shaped-fitness")) {
            shaped_fitness = true;
        } else if (std.mem.eql(u8, arg, "--constrained-init")) {
            constrained_init = true;
        }
    }
    mm.shaped_fitness = shaped_fitness;
    mmm.constrained_init = constrained_init;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== TIER-2 CHAIN RUNNER (MMMP) ===\n", .{});
    try stdout.print("generations={d} tier2_iters={d} mmm_outer_iters={d} tier1_outer_iters={d} tier0_inner_steps={d} root_seed=0x{X} shaped_fitness={} constrained_init={}\n", .{
        generations, tier2_iters, mmm_outer_iters, tier1_outer_iters, tier0_inner_steps, root_seed, shaped_fitness, constrained_init,
    });

    mm.chainExtrasReset();
    mmm.chainExtrasMMReset();

    if (seed_mm_library.len > 0) {
        var parts = std.mem.tokenizeAny(u8, seed_mm_library, ",");
        while (parts.next()) |p| {
            const mm_prog = try loadMetaMetaProgramCsv(allocator, p);
            try mmm.chainExtrasMMAppend(mm_prog);
            try stdout.print("seeded mm_library[{d}] = {s}  ({d} instrs)\n", .{ mmm.chainExtrasMMLen() - 1, p, mm_prog.used });
        }
    }

    var dir_buf: [128]u8 = undefined;
    const out_dir = try std.fmt.bufPrint(&dir_buf, "results/{s}", .{out_subdir});
    try std.fs.cwd().makePath(out_dir);

    var log_path_buf: [192]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_path_buf, "{s}/chain_log.csv", .{out_dir});
    var log_file = try std.fs.cwd().createFile(log_path, .{ .truncate = true });
    defer log_file.close();
    const log = log_file.writer();
    try log.writeAll("gen,train_anchor_mean,holdout_mean,prev_holdout,verdict,accepted,mmm_evals,chain_extras_mm_len\n");

    var prev_holdout: f64 = -std.math.inf(f64);
    var any_strict_domination: bool = false;
    var halted = false;

    var gen: u32 = 0;
    while (gen < generations) : (gen += 1) {
        try stdout.print("\n--- generation {d} | chain_extras_mm_len={d} ---\n", .{ gen, mmm.chainExtrasMMLen() });
        const gen_seed = smix(root_seed ^ (@as(u64, 0xC3C3_C3C3_3C3C_3C3C) +% gen));
        const r = try runTier2Generation(gen, tier2_iters, mmm_outer_iters, tier1_outer_iters, tier0_inner_steps, gen_seed, stdout);

        var verdict: []const u8 = "ADVANCE";
        if (gen > 0) {
            if (r.holdout_mean > prev_holdout + 0.5) {
                verdict = "ADVANCE + STRICT_DOMINATION";
                any_strict_domination = true;
            } else if (r.holdout_mean < prev_holdout - 0.5) {
                verdict = "HALT(holdout_regression)";
                halted = true;
            } else {
                verdict = "ADVANCE(tie)";
            }
        }

        try log.print("{d},{d:.6},{d:.6},{d:.6},{s},{d},{d},{d}\n", .{
            r.gen, r.train_anchor_mean, r.holdout_mean,
            if (std.math.isFinite(prev_holdout)) prev_holdout else 0.0,
            verdict, r.accepted, r.mmm_evals, mmm.chainExtrasMMLen(),
        });
        try stdout.print("verdict: {s}  (holdout {d:.4} vs prev {d:.4})\n", .{
            verdict, r.holdout_mean, if (std.math.isFinite(prev_holdout)) prev_holdout else 0.0,
        });

        // Persist champions
        {
            var pb: [192]u8 = undefined;
            const p = try std.fmt.bufPrint(&pb, "{s}/gen_{d}_champion_mmm.csv", .{ out_dir, gen });
            var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
            defer f.close();
            try mmm.mmmToCsv(r.champion_mmm, f.writer());
        }
        {
            var pb: [192]u8 = undefined;
            const p = try std.fmt.bufPrint(&pb, "{s}/gen_{d}_champion_mm.csv", .{ out_dir, gen });
            var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
            defer f.close();
            try mm.metaMetaToCsv(r.champion_mm, f.writer());
        }
        {
            var pb: [192]u8 = undefined;
            const p = try std.fmt.bufPrint(&pb, "{s}/gen_{d}_champion_meta.csv", .{ out_dir, gen });
            var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
            defer f.close();
            try tier0.metaToCsv(r.champion_meta, f.writer());
        }

        if (halted) break;

        try mmm.chainExtrasMMAppend(r.champion_mm);
        prev_holdout = r.holdout_mean;
    }

    try stdout.print("\n=== CHAIN RESULT ===\n", .{});
    if (halted) {
        try stdout.print("HALTED at generation {d}\n", .{gen});
    } else {
        try stdout.print("Completed {d} generations.\n", .{generations});
    }
    try stdout.print("STRICT_DOMINATION ever observed: {s}\n", .{if (any_strict_domination) "YES" else "NO"});
}
