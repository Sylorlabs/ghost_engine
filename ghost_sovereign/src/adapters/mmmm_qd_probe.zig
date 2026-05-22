const std = @import("std");
const mmmm = @import("domain_meta_meta_meta_meta_engine.zig");
const mmm = @import("domain_meta_meta_meta_engine.zig");
const mm = @import("domain_meta_meta_engine.zig");
const tier0 = @import("domain_meta_engine.zig");

const anchor_seeds = [_]u64{
    0xD0D0_D0D0_F00D_0001,
    0xD0D0_D0D0_F00D_0002,
    0xD0D0_D0D0_F00D_0003,
    0xD0D0_D0D0_F00D_0004,
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
    sample: u32,
    anchor_mean: f64,
    holdout_mean: f64,
    champion_mmmm: mmmm.MetaMetaMetaMetaProgram,
    champion_mmm: mmm.MetaMetaMetaProgram,
    champion_mm: mm.MetaMetaProgram,
    champion_meta: tier0.MetaProgram,
};

fn evaluateCandidate(
    sample: u32,
    cand: mmmm.MetaMetaMetaMetaProgram,
    mmmm_outer_iters: u32,
    tier0_inner_steps: u32,
) EvalResult {
    var best_mmm: mmm.MetaMetaMetaProgram = undefined;
    var best_anchor_q: f64 = -std.math.inf(f64);
    var anchor_sum: f64 = 0;
    for (anchor_seeds) |as| {
        const r = mmmm.runReturningChampion(cand, mmmm_outer_iters, as);
        const q = if (std.math.isFinite(r.q_best)) r.q_best else -1.0e6;
        anchor_sum += q;
        if (q > best_anchor_q) {
            best_anchor_q = q;
            best_mmm = r.mmm_best;
        }
    }

    const anchor_mean = anchor_sum / @as(f64, @floatFromInt(anchor_seeds.len));
    const champ_seed = holdout_seeds[0] ^ 0xE4E4_F00D_BABE_C0DE;
    const champ_mmm_run = mmm.runReturningChampion(best_mmm, mmmm_outer_iters * 2, champ_seed);
    const champ_mm = champ_mmm_run.mm_best;
    const champ_mm_run = mm.runReturningChampion(champ_mm, mmmm_outer_iters * 2, champ_seed ^ 0x9E37_79B9);
    const champ_meta = champ_mm_run.meta_best;
    const holdout = evaluateMetaOnSeeds(champ_meta, &holdout_seeds, tier0_inner_steps);

    return .{
        .sample = sample,
        .anchor_mean = anchor_mean,
        .holdout_mean = holdout,
        .champion_mmmm = cand,
        .champion_mmm = best_mmm,
        .champion_mm = champ_mm,
        .champion_meta = champ_meta,
    };
}

fn saveArtifacts(out_dir: []const u8, r: EvalResult) !void {
    var path_buf: [512]u8 = undefined;

    const mmmm_path = try std.fmt.bufPrint(&path_buf, "{s}/BEST_champion_mmmm.csv", .{out_dir});
    var mmmm_file = try std.fs.cwd().createFile(mmmm_path, .{ .truncate = true });
    defer mmmm_file.close();
    try mmmm.mmmmToCsv(r.champion_mmmm, mmmm_file.writer());

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

    var samples: u32 = 12;
    var mmmm_outer_iters: u32 = 4;
    var tier2_outer_iters: u32 = 4;
    var tier1_outer_iters: u32 = 8;
    var tier0_inner_steps: u32 = 150;
    var root_seed: u64 = 0x4444_1111_2222_3333;
    var seed_mmm_library: []const u8 = "";
    var out_subdir: []const u8 = "mmmm_qd_probe";
    var shaped_fitness = false;
    var constrained_meta_init = false;
    var constrained_mm_init = false;
    var constrained_mmm_init = false;
    var constrained_mmmm_init = false;
    var wide_call_meta = false;
    var wide_call_mm = false;
    var wide_call_mmm = false;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--samples=")) {
            samples = try std.fmt.parseInt(u32, arg["--samples=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--mmmm-outer-iters=")) {
            mmmm_outer_iters = try std.fmt.parseInt(u32, arg["--mmmm-outer-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tier2-outer-iters=")) {
            tier2_outer_iters = try std.fmt.parseInt(u32, arg["--tier2-outer-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tier1-outer-iters=")) {
            tier1_outer_iters = try std.fmt.parseInt(u32, arg["--tier1-outer-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--tier0-inner-steps=")) {
            tier0_inner_steps = try std.fmt.parseInt(u32, arg["--tier0-inner-steps=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            root_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--seed-mmm-library=")) {
            seed_mmm_library = arg["--seed-mmm-library=".len..];
        } else if (std.mem.startsWith(u8, arg, "--out-subdir=")) {
            out_subdir = arg["--out-subdir=".len..];
        } else if (std.mem.eql(u8, arg, "--shaped-fitness")) {
            shaped_fitness = true;
        } else if (std.mem.eql(u8, arg, "--constrained-meta-init")) {
            constrained_meta_init = true;
        } else if (std.mem.eql(u8, arg, "--constrained-mm-init")) {
            constrained_mm_init = true;
        } else if (std.mem.eql(u8, arg, "--constrained-mmm-init")) {
            constrained_mmm_init = true;
        } else if (std.mem.eql(u8, arg, "--constrained-mmmm-init")) {
            constrained_mmmm_init = true;
        } else if (std.mem.eql(u8, arg, "--wide-call-meta")) {
            wide_call_meta = true;
        } else if (std.mem.eql(u8, arg, "--wide-call-mm")) {
            wide_call_mm = true;
        } else if (std.mem.eql(u8, arg, "--wide-call-mmm")) {
            wide_call_mmm = true;
        }
    }

    tier0.constrained_init = constrained_meta_init;
    mm.constrained_init = constrained_mm_init;
    mm.shaped_fitness = shaped_fitness;
    mm.wide_call_meta = wide_call_meta;
    mmm.constrained_init = constrained_mmm_init;
    mmm.wide_call_mm = wide_call_mm;
    mmmm.constrained_init = constrained_mmmm_init;
    mmmm.wide_call_mmm = wide_call_mmm;
    mm.INNER_TIER0_STEPS = tier0_inner_steps;
    mmm.INNER_TIER1_OUTER_STEPS = tier1_outer_iters;
    mmmm.INNER_TIER2_OUTER_STEPS = tier2_outer_iters;
    mmmm.chainExtrasMMMReset();

    if (seed_mmm_library.len > 0) {
        var parts = std.mem.tokenizeAny(u8, seed_mmm_library, ",");
        while (parts.next()) |path| {
            const p = try loadMetaMetaMetaProgramCsv(allocator, path);
            try mmmm.chainExtrasMMMAppend(p);
        }
    }

    var dir_buf: [256]u8 = undefined;
    const out_dir = try std.fmt.bufPrint(&dir_buf, "results/{s}", .{out_subdir});
    try std.fs.cwd().makePath(out_dir);

    var csv_path_buf: [320]u8 = undefined;
    const csv_path = try std.fmt.bufPrint(&csv_path_buf, "{s}/samples.csv", .{out_dir});
    var csv_file = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv_file.close();
    const csv = csv_file.writer();
    try csv.writeAll("sample,anchor_mean,holdout_mean,best_holdout\n");

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("=== MMMMP QUALITY PROBE ===\n");
    try stdout.print("samples={d} seed=0x{X} seed_mmmp={d} mmmm_outer={d} tier2_outer={d} tier1_outer={d} tier0_inner={d}\n", .{
        samples,
        root_seed,
        mmmm.chainExtrasMMMLen(),
        mmmm_outer_iters,
        tier2_outer_iters,
        tier1_outer_iters,
        tier0_inner_steps,
    });

    var rng = root_seed;
    var best: ?EvalResult = null;
    var sample: u32 = 0;
    while (sample < samples) : (sample += 1) {
        rng = smix(rng);
        const cand = mmmm.randomMetaMetaMetaMetaProgram(&rng);
        const r = evaluateCandidate(sample, cand, mmmm_outer_iters, tier0_inner_steps);
        if (best == null or r.holdout_mean > best.?.holdout_mean) {
            best = r;
            try saveArtifacts(out_dir, r);
        }
        try csv.print("{d},{d:.6},{d:.6},{d:.6}\n", .{
            sample,
            r.anchor_mean,
            r.holdout_mean,
            best.?.holdout_mean,
        });
        try stdout.print("sample {d}/{d}: anchor={d:.4} holdout={d:.4} best={d:.4}\n", .{
            sample + 1,
            samples,
            r.anchor_mean,
            r.holdout_mean,
            best.?.holdout_mean,
        });
    }

    if (best) |b| {
        try stdout.print("BEST_HOLDOUT = {d:.4} sample={d} anchor={d:.4}\n", .{ b.holdout_mean, b.sample, b.anchor_mean });
    }
}
