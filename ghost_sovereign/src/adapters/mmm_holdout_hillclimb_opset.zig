const std = @import("std");
const mmm = @import("domain_meta_meta_meta_engine_opset.zig");
const mm = @import("domain_meta_meta_engine_opset.zig");
const tier0 = @import("domain_meta_engine_opset.zig");
const mixer = @import("domain_opset.zig");

const anchor_seeds = [_]u64{
    0xC0C0_C0C0_F00D_0001,
    0xC0C0_C0C0_F00D_0002,
    0xC0C0_C0C0_F00D_0003,
    0xC0C0_C0C0_F00D_0004,
};

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

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn loadMetaMetaProgramCsv(allocator: std.mem.Allocator, path: []const u8) !mm.MetaMetaProgram {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(contents);

    var p = mm.MetaMetaProgram{ .instructions = undefined, .used = 0 };
    var lines = std.mem.tokenizeAny(u8, contents, "\n\r");
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        }
        var fields = std.mem.tokenizeAny(u8, line, ",");
        _ = fields.next() orelse continue;
        const op_id_s = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const dst_s = fields.next() orelse continue;
        const src1_s = fields.next() orelse continue;
        const src2_s = fields.next() orelse continue;
        if (p.used >= mm.MaxMetaMetaLen) break;
        p.instructions[p.used] = .{
            .op = @enumFromInt(try std.fmt.parseInt(u8, op_id_s, 10)),
            .dst = @intCast(try std.fmt.parseInt(u8, dst_s, 10)),
            .src1 = @intCast(try std.fmt.parseInt(u8, src1_s, 10)),
            .src2 = @intCast(try std.fmt.parseInt(u8, src2_s, 10)),
        };
        p.used += 1;
    }
    return p;
}

fn loadMetaMetaMetaProgramCsv(allocator: std.mem.Allocator, path: []const u8) !mmm.MetaMetaMetaProgram {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(contents);

    var p = mmm.MetaMetaMetaProgram{ .instructions = undefined, .used = 0 };
    var lines = std.mem.tokenizeAny(u8, contents, "\n\r");
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        }
        var fields = std.mem.tokenizeAny(u8, line, ",");
        _ = fields.next() orelse continue;
        const op_id_s = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const dst_s = fields.next() orelse continue;
        const src1_s = fields.next() orelse continue;
        const src2_s = fields.next() orelse continue;
        if (p.used >= mmm.MaxMetaMetaMetaLen) break;
        p.instructions[p.used] = .{
            .op = @enumFromInt(try std.fmt.parseInt(u8, op_id_s, 10)),
            .dst = @intCast(try std.fmt.parseInt(u8, dst_s, 10)),
            .src1 = @intCast(try std.fmt.parseInt(u8, src1_s, 10)),
            .src2 = @intCast(try std.fmt.parseInt(u8, src2_s, 10)),
        };
        p.used += 1;
    }
    return p;
}

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

const EvalResult = struct {
    iter: u32,
    anchor_mean: f64,
    holdout_mean: f64,
    champion_mmm: mmm.MetaMetaMetaProgram,
    champion_mm: mm.MetaMetaProgram,
    champion_meta: tier0.MetaProgram,
};

fn evaluateCandidate(
    iter: u32,
    cand: mmm.MetaMetaMetaProgram,
    mmm_outer_iters: u32,
    tier0_inner_steps: u32,
) EvalResult {
    var best_mm: mm.MetaMetaProgram = undefined;
    var best_anchor_q: f64 = -std.math.inf(f64);
    var anchor_sum: f64 = 0;
    for (anchor_seeds) |as| {
        const r = mmm.runReturningChampion(cand, mmm_outer_iters, as);
        const q = if (std.math.isFinite(r.q_best)) r.q_best else -1.0e6;
        anchor_sum += q;
        if (q > best_anchor_q) {
            best_anchor_q = q;
            best_mm = r.mm_best;
        }
    }

    const anchor_mean = anchor_sum / @as(f64, @floatFromInt(anchor_seeds.len));
    const champ_seed = holdout_seeds[0] ^ 0x5A5A_F00D_BABE_C0DE;
    const champ_mm_run = mm.runReturningChampion(best_mm, mmm_outer_iters * 2, champ_seed);
    const champ_meta = champ_mm_run.meta_best;
    const holdout = evaluateMetaOnSeeds(champ_meta, &holdout_seeds, tier0_inner_steps);

    return .{
        .iter = iter,
        .anchor_mean = anchor_mean,
        .holdout_mean = holdout,
        .champion_mmm = cand,
        .champion_mm = best_mm,
        .champion_meta = champ_meta,
    };
}

fn saveArtifacts(out_dir: []const u8, r: EvalResult) !void {
    var path_buf: [512]u8 = undefined;

    const mmm_path = try std.fmt.bufPrint(&path_buf, "{s}/BEST_champion_mmm.csv", .{out_dir});
    var mmm_file = try std.fs.cwd().createFile(mmm_path, .{ .truncate = true });
    defer mmm_file.close();
    try mmm.mmmToCsv(r.champion_mmm, mmm_file.writer());

    const mm_path = try std.fmt.bufPrint(&path_buf, "{s}/BEST_champion_mm.csv", .{out_dir});
    var mm_file = try std.fs.cwd().createFile(mm_path, .{ .truncate = true });
    defer mm_file.close();
    try mm.metaMetaToCsv(r.champion_mm, mm_file.writer());

    const meta_path = try std.fmt.bufPrint(&path_buf, "{s}/BEST_champion_meta.csv", .{out_dir});
    var meta_file = try std.fs.cwd().createFile(meta_path, .{ .truncate = true });
    defer meta_file.close();
    try tier0.metaToCsv(r.champion_meta, meta_file.writer());
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var iters: u32 = 128;
    var mmm_outer_iters: u32 = 6;
    var tier1_outer_iters: u32 = 8;
    var tier0_inner_steps: u32 = 120;
    var root_seed: u64 = 0x1111_2222_3333_4444;
    var seed_mm_library: []const u8 = "";
    var start_mmm_path: []const u8 = "";
    var out_subdir: []const u8 = "mmm_holdout_hillclimb";
    var shaped_fitness = false;
    var constrained_init = false;
    var constrained_meta_init = false;
    var constrained_mm_init = false;
    var wide_call_meta = false;
    var wide_call_mm = false;
    var repair_meta_ordering = false;
    var restart_every: u32 = 0;
    var anti_human_penalty: f64 = 0;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--iters=")) {
            iters = try std.fmt.parseInt(u32, arg["--iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--mmm-outer-iters=")) {
            mmm_outer_iters = try std.fmt.parseInt(u32, arg["--mmm-outer-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tier1-outer-iters=")) {
            tier1_outer_iters = try std.fmt.parseInt(u32, arg["--tier1-outer-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tier0-inner-steps=")) {
            tier0_inner_steps = try std.fmt.parseInt(u32, arg["--tier0-inner-steps=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            root_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--seed-mm-library=")) {
            seed_mm_library = arg["--seed-mm-library=".len..];
        } else if (std.mem.startsWith(u8, arg, "--start-mmm=")) {
            start_mmm_path = arg["--start-mmm=".len..];
        } else if (std.mem.startsWith(u8, arg, "--out-subdir=")) {
            out_subdir = arg["--out-subdir=".len..];
        } else if (std.mem.eql(u8, arg, "--shaped-fitness")) {
            shaped_fitness = true;
        } else if (std.mem.eql(u8, arg, "--constrained-init")) {
            constrained_init = true;
        } else if (std.mem.eql(u8, arg, "--constrained-meta-init")) {
            constrained_meta_init = true;
        } else if (std.mem.eql(u8, arg, "--constrained-mm-init")) {
            constrained_mm_init = true;
        } else if (std.mem.eql(u8, arg, "--wide-call-meta")) {
            wide_call_meta = true;
        } else if (std.mem.eql(u8, arg, "--wide-call-mm")) {
            wide_call_mm = true;
        } else if (std.mem.eql(u8, arg, "--repair-meta-ordering")) {
            repair_meta_ordering = true;
        } else if (std.mem.startsWith(u8, arg, "--restart-every=")) {
            restart_every = try std.fmt.parseInt(u32, arg["--restart-every=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--anti-human-penalty=")) {
            anti_human_penalty = try std.fmt.parseFloat(f64, arg["--anti-human-penalty=".len..]);
        } else if (std.mem.eql(u8, arg, "--compressor-mode")) {
            mixer.compressor_mode = true;
        } else if (std.mem.eql(u8, arg, "--live-macro-graduation")) {
            mixer.live_macro_graduation = true;
        }
    }

    mixer.anti_human_penalty = anti_human_penalty;
    mm.shaped_fitness = shaped_fitness;
    mm.wide_call_meta = wide_call_meta;
    mm.constrained_init = constrained_mm_init;
    tier0.constrained_init = constrained_meta_init;
    tier0.repair_meta_ordering = repair_meta_ordering;
    mmm.constrained_init = constrained_init;
    mmm.wide_call_mm = wide_call_mm;
    mm.INNER_TIER0_STEPS = tier0_inner_steps;
    mmm.INNER_TIER1_OUTER_STEPS = tier1_outer_iters;
    mmm.chainExtrasMMReset();

    if (seed_mm_library.len > 0) {
        var parts = std.mem.tokenizeAny(u8, seed_mm_library, ",");
        while (parts.next()) |path| {
            const p = try loadMetaMetaProgramCsv(allocator, path);
            try mmm.chainExtrasMMAppend(p);
        }
    }

    var dir_buf: [256]u8 = undefined;
    const out_dir = try std.fmt.bufPrint(&dir_buf, "results/{s}", .{out_subdir});
    try std.fs.cwd().makePath(out_dir);

    var csv_path_buf: [320]u8 = undefined;
    const csv_path = try std.fmt.bufPrint(&csv_path_buf, "{s}/hillclimb.csv", .{out_dir});
    var csv_file = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv_file.close();
    const csv = csv_file.writer();
    try csv.writeAll("iter,accepted,best_updated,anchor_mean,holdout_mean,current_holdout,best_holdout\n");

    var rng = root_seed;
    var initial = if (start_mmm_path.len > 0)
        try loadMetaMetaMetaProgramCsv(allocator, start_mmm_path)
    else blk: {
        rng = smix(rng);
        break :blk mmm.randomMetaMetaMetaProgram(&rng);
    };
    if (constrained_init) initial = mmm.repairMetaMetaMetaOrdering(initial);

    var current = evaluateCandidate(0, initial, mmm_outer_iters, tier0_inner_steps);
    var best = current;
    try saveArtifacts(out_dir, best);
    try csv.print("{d},{},{},{d:.6},{d:.6},{d:.6},{d:.6}\n", .{
        0, true, true, current.anchor_mean, current.holdout_mean, current.holdout_mean, best.holdout_mean,
    });

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("=== MMMP HOLDOUT HILLCLIMB ===\n");
    try stdout.print("iters={d} seed=0x{X} start={s} mmm_outer={d} tier1_outer={d} tier0_inner={d} shaped={} constrained={} constrained_meta={} constrained_mm={} wide_meta={} wide_mm={} restart_every={d}\n", .{
        iters,
        root_seed,
        if (start_mmm_path.len > 0) start_mmm_path else "(random)",
        mmm_outer_iters,
        tier1_outer_iters,
        tier0_inner_steps,
        shaped_fitness,
        constrained_init,
        constrained_meta_init,
        constrained_mm_init,
        wide_call_meta,
        wide_call_mm,
        restart_every,
    });
    try stdout.print("iter 0: anchor={d:.4} holdout={d:.4} BEST\n", .{ current.anchor_mean, current.holdout_mean });

    var iter: u32 = 1;
    while (iter <= iters) : (iter += 1) {
        rng = smix(rng);
        const do_restart = restart_every > 0 and iter % restart_every == 0;
        var cand = if (do_restart) mmm.randomMetaMetaMetaProgram(&rng) else mmm.mutateMetaMetaMeta(current.champion_mmm, &rng);
        if (constrained_init) cand = mmm.repairMetaMetaMetaOrdering(cand);
        const r = evaluateCandidate(iter, cand, mmm_outer_iters, tier0_inner_steps);

        const accepted = r.holdout_mean > current.holdout_mean + 0.05 or
            (r.holdout_mean >= current.holdout_mean - 0.05 and r.anchor_mean > current.anchor_mean + 0.25);
        if (accepted) current = r;

        var best_updated = false;
        if (r.holdout_mean > best.holdout_mean + 0.0001) {
            best = r;
            best_updated = true;
            try saveArtifacts(out_dir, best);
        }

        try csv.print("{d},{},{},{d:.6},{d:.6},{d:.6},{d:.6}\n", .{
            iter,
            accepted,
            best_updated,
            r.anchor_mean,
            r.holdout_mean,
            current.holdout_mean,
            best.holdout_mean,
        });
        try stdout.print("iter {d}/{d}: anchor={d:.4} holdout={d:.4} current={d:.4} best={d:.4} {s}{s}\n", .{
            iter,
            iters,
            r.anchor_mean,
            r.holdout_mean,
            current.holdout_mean,
            best.holdout_mean,
            if (accepted) "ACCEPT " else "",
            if (best_updated) "BEST" else "",
        });
    }

    try stdout.print("BEST_HOLDOUT = {d:.4} iter={d} anchor={d:.4}\n", .{
        best.holdout_mean,
        best.iter,
        best.anchor_mean,
    });
}
