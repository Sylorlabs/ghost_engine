const std = @import("std");
const mmm = @import("domain_meta_meta_meta_engine.zig");
const mm = @import("domain_meta_meta_engine.zig");
const tier0 = @import("domain_meta_engine.zig");

const EditNear: f64 = 0.25;
const EditMid: f64 = 0.50;

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

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

fn instrEq(a: mm.MetaMetaInstr, b: mm.MetaMetaInstr) bool {
    return a.op == b.op and a.dst == b.dst and a.src1 == b.src1 and a.src2 == b.src2;
}

fn metaMetaEditDistance(a: mm.MetaMetaProgram, b: mm.MetaMetaProgram) usize {
    var dp: [mm.MaxMetaMetaLen + 1][mm.MaxMetaMetaLen + 1]usize = undefined;
    var i: usize = 0;
    while (i <= a.used) : (i += 1) dp[i][0] = i;
    var j: usize = 0;
    while (j <= b.used) : (j += 1) dp[0][j] = j;
    i = 1;
    while (i <= a.used) : (i += 1) {
        j = 1;
        while (j <= b.used) : (j += 1) {
            const sub_cost: usize = if (instrEq(a.instructions[i - 1], b.instructions[j - 1])) 0 else 1;
            dp[i][j] = @min(@min(dp[i - 1][j] + 1, dp[i][j - 1] + 1), dp[i - 1][j - 1] + sub_cost);
        }
    }
    return dp[a.used][b.used];
}

fn nearestSeedNorm(candidate: mm.MetaMetaProgram, seeds: []const mm.MetaMetaProgram) f64 {
    if (seeds.len == 0) return 1.0;
    var best: f64 = 1.0e9;
    for (seeds) |seed| {
        const dist = metaMetaEditDistance(candidate, seed);
        const denom = @max(@as(usize, candidate.used), @as(usize, seed.used));
        const norm = if (denom == 0) 0 else @as(f64, @floatFromInt(dist)) / @as(f64, @floatFromInt(denom));
        if (norm < best) best = norm;
    }
    return best;
}

const OpSummary = struct {
    eval_count: u8,
    call_count: u8,
    first_eval: i32,
    first_accept: i32,
    eval_before_accept: bool,
};

fn summarizeMMMP(p: mmm.MetaMetaMetaProgram) OpSummary {
    var s = OpSummary{ .eval_count = 0, .call_count = 0, .first_eval = -1, .first_accept = -1, .eval_before_accept = false };
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        switch (p.instructions[i].op) {
            .EVAL_MM_CUR => {
                s.eval_count += 1;
                if (s.first_eval < 0) s.first_eval = @intCast(i);
            },
            .ACCEPT_MM_IF_BETTER, .ACCEPT_MM_SA => {
                if (s.first_accept < 0) s.first_accept = @intCast(i);
            },
            .CALL_MM => s.call_count += 1,
            else => {},
        }
    }
    s.eval_before_accept = s.first_eval >= 0 and s.first_accept >= 0 and s.first_eval < s.first_accept;
    return s;
}

fn summarizeMM(p: mm.MetaMetaProgram) OpSummary {
    var s = OpSummary{ .eval_count = 0, .call_count = 0, .first_eval = -1, .first_accept = -1, .eval_before_accept = false };
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        switch (p.instructions[i].op) {
            .EVAL_META_CUR => {
                s.eval_count += 1;
                if (s.first_eval < 0) s.first_eval = @intCast(i);
            },
            .ACCEPT_META_IF_BETTER, .ACCEPT_META_SA => {
                if (s.first_accept < 0) s.first_accept = @intCast(i);
            },
            .CALL_META => s.call_count += 1,
            else => {},
        }
    }
    s.eval_before_accept = s.first_eval >= 0 and s.first_accept >= 0 and s.first_eval < s.first_accept;
    return s;
}

fn bucketCount(n: u8) usize {
    if (n == 0) return 0;
    if (n == 1) return 1;
    return 2;
}

fn bucketEdit(norm: f64) usize {
    if (norm < EditNear) return 0;
    if (norm < EditMid) return 1;
    return 2;
}

const EvalResult = struct {
    sample: u32,
    anchor_mean: f64,
    holdout_mean: f64,
    nearest_seed_norm: f64,
    cell: usize,
    mmm_summary: OpSummary,
    mm_summary: OpSummary,
    champion_mmm: mmm.MetaMetaMetaProgram,
    champion_mm: mm.MetaMetaProgram,
    champion_meta: tier0.MetaProgram,
};

fn cellIndex(mmm_s: OpSummary, mm_s: OpSummary, nearest_norm: f64) usize {
    const b0: usize = if (mmm_s.eval_before_accept) 1 else 0;
    const b1: usize = bucketCount(mmm_s.call_count);
    const b2: usize = if (mm_s.eval_before_accept) 1 else 0;
    const b3: usize = bucketEdit(nearest_norm);
    return (((b0 * 3) + b1) * 2 + b2) * 3 + b3;
}

fn evaluateCandidate(
    sample: u32,
    cand: mmm.MetaMetaMetaProgram,
    mmm_outer_iters: u32,
    tier0_inner_steps: u32,
    seed_mms: []const mm.MetaMetaProgram,
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
    const mmm_s = summarizeMMMP(cand);
    const mm_s = summarizeMM(best_mm);
    const nearest_norm = nearestSeedNorm(best_mm, seed_mms);
    const cell = cellIndex(mmm_s, mm_s, nearest_norm);
    return .{
        .sample = sample,
        .anchor_mean = anchor_mean,
        .holdout_mean = holdout,
        .nearest_seed_norm = nearest_norm,
        .cell = cell,
        .mmm_summary = mmm_s,
        .mm_summary = mm_s,
        .champion_mmm = cand,
        .champion_mm = best_mm,
        .champion_meta = champ_meta,
    };
}

const Elite = struct {
    filled: bool = false,
    result: EvalResult = undefined,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var samples: u32 = 24;
    var mmm_outer_iters: u32 = 6;
    var tier1_outer_iters: u32 = 8;
    var tier0_inner_steps: u32 = 120;
    var root_seed: u64 = 0x1111_2222_3333_4444;
    var seed_mm_library: []const u8 = "";
    var out_subdir: []const u8 = "mmm_qd_probe";
    var shaped_fitness = false;
    var constrained_init = false;
    var constrained_meta_init = false;
    var constrained_mm_init = false;
    var wide_call_meta = false;
    var wide_call_mm = false;
    var repair_meta_ordering = false;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--samples=")) {
            samples = try std.fmt.parseInt(u32, arg["--samples=".len..], 10);
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
        }
    }

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

    var seed_mms = std.ArrayList(mm.MetaMetaProgram).init(allocator);
    defer seed_mms.deinit();
    if (seed_mm_library.len > 0) {
        var parts = std.mem.tokenizeAny(u8, seed_mm_library, ",");
        while (parts.next()) |path| {
            const p = try loadMetaMetaProgramCsv(allocator, path);
            try seed_mms.append(p);
            try mmm.chainExtrasMMAppend(p);
        }
    }

    var dir_buf: [160]u8 = undefined;
    const out_dir = try std.fmt.bufPrint(&dir_buf, "results/{s}", .{out_subdir});
    try std.fs.cwd().makePath(out_dir);

    var samples_path_buf: [220]u8 = undefined;
    const samples_path = try std.fmt.bufPrint(&samples_path_buf, "{s}/samples.csv", .{out_dir});
    var samples_file = try std.fs.cwd().createFile(samples_path, .{ .truncate = true });
    defer samples_file.close();
    const sw = samples_file.writer();
    try sw.writeAll("sample,cell,anchor_mean,holdout_mean,nearest_seed_norm,mmm_eval_before_accept,mmm_call_count,mm_eval_before_accept,mm_call_count\n");

    var elites = [_]Elite{.{}} ** 36;
    var global_best: ?EvalResult = null;
    var rng = root_seed;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== MMMP QUALITY-DIVERSITY PROBE ===\n", .{});
    try stdout.print("samples={d} seed=0x{X} seed_mms={d} shaped={} constrained={} constrained_meta={} constrained_mm={} wide_meta={} wide_mm={} repair={}\n", .{
        samples, root_seed, seed_mms.items.len, shaped_fitness, constrained_init, constrained_meta_init, constrained_mm_init, wide_call_meta, wide_call_mm, repair_meta_ordering,
    });

    var sample: u32 = 0;
    while (sample < samples) : (sample += 1) {
        rng = smix(rng);
        const cand = mmm.randomMetaMetaMetaProgram(&rng);
        const r = evaluateCandidate(sample, cand, mmm_outer_iters, tier0_inner_steps, seed_mms.items);
        try sw.print("{d},{d},{d:.6},{d:.6},{d:.6},{},{d},{},{d}\n", .{
            r.sample,
            r.cell,
            r.anchor_mean,
            r.holdout_mean,
            r.nearest_seed_norm,
            r.mmm_summary.eval_before_accept,
            r.mmm_summary.call_count,
            r.mm_summary.eval_before_accept,
            r.mm_summary.call_count,
        });
        if (!elites[r.cell].filled or r.holdout_mean > elites[r.cell].result.holdout_mean) {
            elites[r.cell] = .{ .filled = true, .result = r };
        }
        if (global_best == null or r.holdout_mean > global_best.?.holdout_mean) {
            global_best = r;
        }
        try stdout.print("sample {d}/{d}: cell={d} anchor={d:.4} holdout={d:.4} nearest={d:.3}\n", .{
            sample + 1, samples, r.cell, r.anchor_mean, r.holdout_mean, r.nearest_seed_norm,
        });
    }

    var archive_path_buf: [220]u8 = undefined;
    const archive_path = try std.fmt.bufPrint(&archive_path_buf, "{s}/archive.csv", .{out_dir});
    var archive_file = try std.fs.cwd().createFile(archive_path, .{ .truncate = true });
    defer archive_file.close();
    const aw = archive_file.writer();
    try aw.writeAll("cell,holdout_mean,anchor_mean,nearest_seed_norm,mmm_eval_before_accept,mmm_call_count,mm_eval_before_accept,mm_call_count,sample\n");
    var filled: usize = 0;
    for (elites, 0..) |elite, cell| {
        if (!elite.filled) continue;
        filled += 1;
        const r = elite.result;
        try aw.print("{d},{d:.6},{d:.6},{d:.6},{},{d},{},{d},{d}\n", .{
            cell,
            r.holdout_mean,
            r.anchor_mean,
            r.nearest_seed_norm,
            r.mmm_summary.eval_before_accept,
            r.mmm_summary.call_count,
            r.mm_summary.eval_before_accept,
            r.mm_summary.call_count,
            r.sample,
        });
    }

    if (global_best) |best| {
        var pb: [220]u8 = undefined;
        const mmm_path = try std.fmt.bufPrint(&pb, "{s}/BEST_champion_mmm.csv", .{out_dir});
        var f_mmm = try std.fs.cwd().createFile(mmm_path, .{ .truncate = true });
        defer f_mmm.close();
        try mmm.mmmToCsv(best.champion_mmm, f_mmm.writer());

        var pb2: [220]u8 = undefined;
        const mm_path = try std.fmt.bufPrint(&pb2, "{s}/BEST_champion_mm.csv", .{out_dir});
        var f_mm = try std.fs.cwd().createFile(mm_path, .{ .truncate = true });
        defer f_mm.close();
        try mm.metaMetaToCsv(best.champion_mm, f_mm.writer());

        var pb3: [220]u8 = undefined;
        const meta_path = try std.fmt.bufPrint(&pb3, "{s}/BEST_champion_meta.csv", .{out_dir});
        var f_meta = try std.fs.cwd().createFile(meta_path, .{ .truncate = true });
        defer f_meta.close();
        try tier0.metaToCsv(best.champion_meta, f_meta.writer());

        try stdout.print("filled_cells={d}/36\n", .{filled});
        try stdout.print("BEST_HOLDOUT = {d:.4} cell={d} sample={d} nearest_seed_norm={d:.4}\n", .{
            best.holdout_mean, best.cell, best.sample, best.nearest_seed_norm,
        });
    }
}
