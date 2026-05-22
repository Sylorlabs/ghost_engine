const std = @import("std");
const mm = @import("domain_meta_meta_engine.zig");
const tier0 = @import("domain_meta_engine.zig");

// --- Load MetaProgram CSV into a tier0.MetaProgram value ---
fn loadMetaProgramCsv(allocator: std.mem.Allocator, path: []const u8) !tier0.MetaProgram {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(contents);

    var p = tier0.MetaProgram{ .instructions = undefined, .used = 0 };
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
        if (p.used >= tier0.MaxMetaLen) break;
    }
    return p;
}

// --- TIER-1 CHAIN RUNNER ---
//
// Multi-generation Tier-1 search. Each generation:
//   1. Runs an anchor-protected + seed-rotated outer SA over
//      MetaMetaPrograms, with mm.chain_extras populated with prior
//      generations' champion MetaPrograms (so CALL_META can warm-start
//      meta_cur from a prior champion).
//   2. Evaluates the champion MetaProgram on a STABLE held-out seed
//      set (distinct from anchor and rotation seeds).
//   3. Compares to the previous generation's held-out score.
//   4. Reports ADVANCE / STRICT_DOMINATION / HALT.
//
// Equal budget across generations: same tier1_iters, mm_outer_iters,
// tier0_inner_steps. If gen_n+1's held-out > gen_n's held-out at
// equal budget, that's a dominant successor — analog of sort_net's
// strict_domination on the depth axis.

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

// 4 stable anchor seeds for outer-search anchor-mean scoring.
// Distinct from the held-out 8 and from rotation seeds.
const anchor_seeds = [_]u64{
    0xA0A0_A0A0_F00D_0001,
    0xA0A0_A0A0_F00D_0002,
    0xA0A0_A0A0_F00D_0003,
    0xA0A0_A0A0_F00D_0004,
};

// 8 held-out seeds, fixed across all generations — gives a stable
// progress axis for the chain.
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
    mm_evals: u64,
    champion_mm: mm.MetaMetaProgram,
    champion_meta: tier0.MetaProgram,
};

// Null writer for worker threads: stdout can't be safely shared across
// threads without locking, so retry attempts run silent and the main
// thread does the logging after they join.
const NullWriter = struct {
    pub fn print(self: NullWriter, comptime fmt: []const u8, args: anytype) !void {
        _ = self; _ = fmt; _ = args;
    }
    pub fn writeAll(self: NullWriter, bytes: []const u8) !void {
        _ = self; _ = bytes;
    }
};

// Per-attempt thread context. Each spawned worker gets its own ctx
// and writes its result here. ctx.err captures any tier-1 failure.
const AttemptCtx = struct {
    gen: u32,
    tier1_iters: u32,
    mm_outer_iters: u32,
    tier0_inner_steps: u32,
    seed: u64,
    result: GenResult = undefined,
    err: ?anyerror = null,
    done: bool = false,
};

fn attemptWorker(ctx: *AttemptCtx) void {
    const nw = NullWriter{};
    const r = runTier1Generation(
        ctx.gen,
        ctx.tier1_iters,
        ctx.mm_outer_iters,
        ctx.tier0_inner_steps,
        ctx.seed,
        nw,
    ) catch |e| {
        ctx.err = e;
        ctx.done = true;
        return;
    };
    ctx.result = r;
    ctx.done = true;
}

// Disciplined Tier-1 search: anchor-protected + rotation + held-out
// gate. Returns the champion MetaProgram + its scores.
fn runTier1Generation(
    gen: usize,
    tier1_iters: u32,
    mm_outer_iters: u32,
    tier0_inner_steps: u32,
    root_seed: u64,
    log: anytype,
) !GenResult {
    mm.INNER_TIER0_STEPS = tier0_inner_steps;

    var rng = root_seed;
    const InitPool: usize = 32;

    // Init pool — score on anchor mean
    var best_mm: mm.MetaMetaProgram = undefined;
    var best_anchor_q: f64 = -std.math.inf(f64);
    var best_meta: tier0.MetaProgram = undefined;
    var evals: u64 = 0;

    var k: usize = 0;
    while (k < InitPool) : (k += 1) {
        rng = smix(rng);
        const cand = mm.randomMetaMetaProgram(&rng);
        var sum: f64 = 0;
        // Pick the BEST meta_best across the anchor seeds for this MMP,
        // not the last one. (Previous bug: last anchor's meta_best
        // overwrote earlier even when earlier was better — caused
        // champion MetaProgram to be near-random instead of best-of-4.)
        var champ_meta: tier0.MetaProgram = undefined;
        var champ_q: f64 = -std.math.inf(f64);
        for (anchor_seeds) |as| {
            const r = mm.runReturningChampion(cand, mm_outer_iters, as);
            const q = if (std.math.isFinite(r.q_best)) r.q_best else -1.0e6;
            sum += q;
            if (q > champ_q) {
                champ_q = q;
                champ_meta = r.meta_best;
            }
            evals += 1;
        }
        const mean_q = sum / @as(f64, @floatFromInt(anchor_seeds.len));
        if (mean_q > best_anchor_q) {
            best_mm = cand;
            best_anchor_q = mean_q;
            best_meta = champ_meta;
        }
    }
    try log.print("  init pool best anchor-mean q={d:.4}\n", .{best_anchor_q});

    var accepted: u32 = 0;
    var i: u32 = 0;
    while (i < tier1_iters) : (i += 1) {
        rng = smix(rng);
        const rot_seed = rng;
        rng = smix(rng);
        const cand = mm.mutateMetaMeta(best_mm, &rng);

        const r_best = mm.runReturningChampion(best_mm, mm_outer_iters, rot_seed);
        const r_cand = mm.runReturningChampion(cand, mm_outer_iters, rot_seed);
        const q_best_rot = if (std.math.isFinite(r_best.q_best)) r_best.q_best else -1.0e6;
        const q_cand_rot = if (std.math.isFinite(r_cand.q_best)) r_cand.q_best else -1.0e6;
        evals += 2;

        if (q_cand_rot <= q_best_rot) continue;

        // Anchor re-check — pick best meta across anchor seeds (not last).
        var anchor_sum: f64 = 0;
        var cand_meta_anchor: tier0.MetaProgram = undefined;
        var cand_meta_q: f64 = -std.math.inf(f64);
        for (anchor_seeds) |as| {
            const r = mm.runReturningChampion(cand, mm_outer_iters, as);
            const q = if (std.math.isFinite(r.q_best)) r.q_best else -1.0e6;
            anchor_sum += q;
            if (q > cand_meta_q) {
                cand_meta_q = q;
                cand_meta_anchor = r.meta_best;
            }
            evals += 1;
        }
        const cand_anchor_mean = anchor_sum / @as(f64, @floatFromInt(anchor_seeds.len));
        if (cand_anchor_mean <= best_anchor_q) continue;

        // Both rotation and anchor gates passed — accept.
        // (Held-out probe gate removed: in pilot it rejected 100% of
        // candidates because probe noise > improvement. We rely on
        // rotation + anchor for in-search hygiene and final 8-seed
        // held-out for the post-hoc dominance check.)
        best_mm = cand;
        best_anchor_q = cand_anchor_mean;
        best_meta = cand_meta_anchor;
        accepted += 1;
        try log.print("  iter {d} accepted anchor={d:.4}\n", .{ i, cand_anchor_mean });
    }

    const holdout = evaluateMetaOnSeeds(best_meta, &holdout_seeds, tier0_inner_steps);
    try log.print("  gen {d}: accepted={d}/{d} anchor_mean={d:.4} holdout={d:.4} mm_evals={d}\n", .{
        gen, accepted, tier1_iters, best_anchor_q, holdout, evals,
    });

    return GenResult{
        .gen = gen,
        .train_anchor_mean = best_anchor_q,
        .holdout_mean = holdout,
        .accepted = accepted,
        .mm_evals = evals,
        .champion_mm = best_mm,
        .champion_meta = best_meta,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var generations: u32 = 4;
    var tier1_iters: u32 = 20;
    var mm_outer_iters: u32 = 12;
    var tier0_inner_steps: u32 = 150;
    var root_seed: u64 = 0xF00D_BEEF_CAFE_FACE;
    var out_subdir: []const u8 = "mm_chain";
    var seed_library: []const u8 = "";
    var wide_call_meta: bool = false;
    // Monotone retry mode. When >0, each gen runs up to N attempts
    // with rotated seeds; only ADVANCEs cumulative_best if any attempt
    // strictly beats prior best holdout. Chain never hard-halts —
    // always runs through all `generations`. The reported invention is
    // the BEST champion ever observed, not the latest.
    var monotone_retries: u32 = 0;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--generations=")) {
            generations = try std.fmt.parseInt(u32, arg["--generations=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tier1-iters=")) {
            tier1_iters = try std.fmt.parseInt(u32, arg["--tier1-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--mm-outer-iters=")) {
            mm_outer_iters = try std.fmt.parseInt(u32, arg["--mm-outer-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tier0-inner-steps=")) {
            tier0_inner_steps = try std.fmt.parseInt(u32, arg["--tier0-inner-steps=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            root_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--out-subdir=")) {
            out_subdir = arg["--out-subdir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seed-library=")) {
            seed_library = arg["--seed-library=".len..];
        } else if (std.mem.eql(u8, arg, "--wide-call-meta")) {
            wide_call_meta = true;
        } else if (std.mem.startsWith(u8, arg, "--monotone-retries=")) {
            monotone_retries = try std.fmt.parseInt(u32, arg["--monotone-retries=".len..], 10);
        }
    }
    mm.wide_call_meta = wide_call_meta;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== TIER-1 CHAIN RUNNER ===\n", .{});
    try stdout.print("generations={d} tier1_iters={d} mm_outer_iters={d} tier0_inner_steps={d} root_seed=0x{X} wide_call_meta={} monotone_retries={d}\n", .{
        generations, tier1_iters, mm_outer_iters, tier0_inner_steps, root_seed, wide_call_meta, monotone_retries,
    });

    // Reset Tier-1's MetaProgram library at start of chain
    mm.chainExtrasReset();

    // Optionally seed the library from prior runs — this is the
    // "successor inventing successor" loop test. Each path in
    // --seed-library=p1,p2,... is loaded and appended to chain_extras
    // BEFORE the first generation starts. Gen 0 then has CALL_META
    // access to these prior champions from the start.
    if (seed_library.len > 0) {
        var parts = std.mem.tokenizeAny(u8, seed_library, ",");
        while (parts.next()) |p| {
            const meta = try loadMetaProgramCsv(allocator, p);
            try mm.chainExtrasAppend(meta);
            try stdout.print("seeded library[{d}] = {s}  ({d} instrs)\n", .{ mm.chainExtrasLen() - 1, p, meta.used });
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
    try log.writeAll("gen,attempt,train_anchor_mean,holdout_mean,best_so_far,verdict,accepted,mm_evals,chain_extras_len\n");

    var prev_holdout: f64 = -std.math.inf(f64);
    var cumulative_best_holdout: f64 = -std.math.inf(f64);
    var cumulative_best_meta: tier0.MetaProgram = undefined;
    var cumulative_best_mm: mm.MetaMetaProgram = undefined;
    var cumulative_best_gen: u32 = 0;
    var cumulative_best_attempt: u32 = 0;
    var any_strict_domination: bool = false;
    var halted = false;

    var gen: u32 = 0;
    while (gen < generations) : (gen += 1) {
        try stdout.print("\n--- generation {d} | chain_extras_len={d} | best_so_far={d:.4} ---\n", .{
            gen, mm.chainExtrasLen(), cumulative_best_holdout,
        });

        // Run up to max_attempts attempts. In monotone mode, the gen
        // ADVANCEs only if at least one attempt strictly beats the
        // cumulative-best holdout. Otherwise the gen is logged as a
        // SOFT_HALT (no chain_extras update) but the chain continues
        // through `generations`. This is the "patient stubborn" mode:
        // gen N+1 might fail every attempt but we still try gen N+2.
        //
        // PARALLEL: all retry attempts run on their own threads, each
        // with a distinct rotated seed. Main thread joins them and
        // picks the best holdout. Uses up to N cores per gen.
        const max_attempts: u32 = if (monotone_retries == 0) 1 else monotone_retries;
        var best_attempt_r: GenResult = undefined;
        var have_best_attempt: bool = false;
        const attempts_run: u32 = max_attempts;
        var advance_this_gen: bool = false;

        try stdout.print("  spawning {d} parallel attempts...\n", .{max_attempts});
        var ctxs = try allocator.alloc(AttemptCtx, max_attempts);
        defer allocator.free(ctxs);
        var threads = try allocator.alloc(std.Thread, max_attempts);
        defer allocator.free(threads);
        var best_attempt_idx: u32 = 0;

        for (0..max_attempts) |i| {
            const attempt_u: u32 = @intCast(i);
            const gen_seed = smix(
                root_seed
                ^ (@as(u64, 0xA5A5_A5A5_5A5A_5A5A) +% gen)
                ^ (@as(u64, 0xC0DE_BABE_0001) *% (@as(u64, attempt_u) +% 1))
            );
            ctxs[i] = .{
                .gen = gen,
                .tier1_iters = tier1_iters,
                .mm_outer_iters = mm_outer_iters,
                .tier0_inner_steps = tier0_inner_steps,
                .seed = gen_seed,
            };
            threads[i] = try std.Thread.spawn(.{}, attemptWorker, .{&ctxs[i]});
        }
        for (threads) |t| t.join();

        // Collect: pick best holdout, log per-attempt rows.
        for (ctxs, 0..) |*ctx, i| {
            const attempt_u: u32 = @intCast(i);
            if (ctx.err) |e| {
                try stdout.print("  attempt {d}/{d} ERROR {s}\n", .{ attempt_u + 1, max_attempts, @errorName(e) });
                continue;
            }
            const r = ctx.result;
            try stdout.print("  attempt {d}/{d} seed=0x{X} anchor={d:.4} holdout={d:.4}\n", .{
                attempt_u + 1, max_attempts, ctx.seed, r.train_anchor_mean, r.holdout_mean,
            });

            if (!have_best_attempt or r.holdout_mean > best_attempt_r.holdout_mean) {
                best_attempt_r = r;
                have_best_attempt = true;
                best_attempt_idx = attempt_u + 1;
            }

            const attempt_verdict: []const u8 = if (r.holdout_mean > cumulative_best_holdout + 0.5)
                "STRICT_PROGRESS"
            else
                "NO_PROGRESS";
            try log.print("{d},{d},{d:.6},{d:.6},{d:.6},{s},{d},{d},{d}\n", .{
                r.gen, attempt_u + 1, r.train_anchor_mean, r.holdout_mean, cumulative_best_holdout,
                attempt_verdict, r.accepted, r.mm_evals, mm.chainExtrasLen(),
            });
        }

        if (!have_best_attempt) {
            try stdout.print("  ALL attempts errored; treating as no-progress\n", .{});
            // best_attempt_r stays uninitialized; downstream uses placeholder
            best_attempt_r = .{
                .gen = gen, .train_anchor_mean = -1.0e6, .holdout_mean = -1.0e6,
                .accepted = 0, .mm_evals = 0,
                .champion_mm = undefined, .champion_meta = undefined,
            };
        }

        if (monotone_retries == 0 or (have_best_attempt and best_attempt_r.holdout_mean > cumulative_best_holdout + 0.5)) {
            advance_this_gen = true;
        }

        const r = best_attempt_r;

        // Compute gen-level verdict (against PREV gen holdout, for backward-
        // compatible reporting) and cumulative status.
        var verdict: []const u8 = "ADVANCE";
        if (monotone_retries > 0) {
            if (advance_this_gen) {
                verdict = "ADVANCE + STRICT_PROGRESS";
                any_strict_domination = true;
            } else {
                verdict = "SOFT_HALT(retries_exhausted_but_continuing)";
            }
        } else {
            // Legacy verdict (used for monotone_retries=0).
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
        }

        // Gen-level summary log entry (attempt=0 indicates summary).
        try log.print("{d},0,{d:.6},{d:.6},{d:.6},{s},{d},{d},{d}\n", .{
            r.gen, r.train_anchor_mean, r.holdout_mean, cumulative_best_holdout,
            verdict, r.accepted, r.mm_evals, mm.chainExtrasLen(),
        });
        try stdout.print("gen {d} summary: {s}  (best_attempt_holdout={d:.4}  best_so_far={d:.4}  attempts_run={d})\n", .{
            gen, verdict, r.holdout_mean, cumulative_best_holdout, attempts_run,
        });

        // Persist this gen's best-attempt champion (always, for inspection).
        {
            var pb: [192]u8 = undefined;
            const p = try std.fmt.bufPrint(&pb, "{s}/gen_{d}_champion_meta.csv", .{ out_dir, gen });
            var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
            defer f.close();
            try tier0.metaToCsv(r.champion_meta, f.writer());
        }
        {
            var pb: [192]u8 = undefined;
            const p = try std.fmt.bufPrint(&pb, "{s}/gen_{d}_champion_meta_meta.csv", .{ out_dir, gen });
            var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
            defer f.close();
            try mm.metaMetaToCsv(r.champion_mm, f.writer());
        }

        if (advance_this_gen) {
            // Update cumulative best + append champion to chain_extras for
            // future gens to CALL_META.
            if (r.holdout_mean > cumulative_best_holdout) {
                cumulative_best_holdout = r.holdout_mean;
                cumulative_best_meta = r.champion_meta;
                cumulative_best_mm = r.champion_mm;
                cumulative_best_gen = gen;
                cumulative_best_attempt = best_attempt_idx;
            }
            try mm.chainExtrasAppend(r.champion_meta);
        }
        // Legacy mode honors HALT verdict; monotone mode never halts.
        if (halted and monotone_retries == 0) break;
        prev_holdout = r.holdout_mean;
    }

    try stdout.print("\n=== CHAIN RESULT ===\n", .{});
    if (halted) {
        try stdout.print("HALTED at generation {d}\n", .{gen});
    } else {
        try stdout.print("Completed {d} generations.\n", .{generations});
    }
    try stdout.print("STRICT_DOMINATION ever observed: {s}\n", .{if (any_strict_domination) "YES" else "NO"});
    try stdout.print("BEST_HOLDOUT_EVER = {d:.4}  (at gen {d}, attempt {d})\n", .{
        cumulative_best_holdout, cumulative_best_gen, cumulative_best_attempt,
    });

    // Persist the cumulative best champion as the FINAL invention output.
    if (std.math.isFinite(cumulative_best_holdout)) {
        var pb: [192]u8 = undefined;
        const p = try std.fmt.bufPrint(&pb, "{s}/BEST_champion_meta.csv", .{out_dir});
        var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
        defer f.close();
        try tier0.metaToCsv(cumulative_best_meta, f.writer());
    }
    if (std.math.isFinite(cumulative_best_holdout)) {
        var pb: [192]u8 = undefined;
        const p = try std.fmt.bufPrint(&pb, "{s}/BEST_champion_meta_meta.csv", .{out_dir});
        var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
        defer f.close();
        try mm.metaMetaToCsv(cumulative_best_mm, f.writer());
    }
}
