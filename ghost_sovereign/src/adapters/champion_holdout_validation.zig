const std = @import("std");
const tier0 = @import("domain_meta_engine.zig");

// --- LARGE HELD-OUT VALIDATION ---
//
// Loads a champion MetaProgram from CSV and compares it side-by-side
// against a freshly-run disciplined hand-coded outer SA on N held-out
// seeds (default 64). Reports mean, std, and verdict (CONFIRM if the
// discovered champion's mean strictly beats baseline by >= margin;
// otherwise HALT).
//
// Used to validate that a single-seed Tier-1 chain result holds at
// scale before promoting it to canonical.

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn parseMetaProgram(allocator: std.mem.Allocator, path: []const u8) !tier0.MetaProgram {
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

fn instrEq(a: tier0.MetaInstr, b: tier0.MetaInstr) bool {
    return a.op == b.op and a.dst == b.dst and a.src1 == b.src1 and a.src2 == b.src2;
}

fn metaEditDistance(a: tier0.MetaProgram, b: tier0.MetaProgram) usize {
    var dp: [tier0.MaxMetaLen + 1][tier0.MaxMetaLen + 1]usize = undefined;
    var i: usize = 0;
    while (i <= a.used) : (i += 1) dp[i][0] = i;
    var j: usize = 0;
    while (j <= b.used) : (j += 1) dp[0][j] = j;
    i = 1;
    while (i <= a.used) : (i += 1) {
        j = 1;
        while (j <= b.used) : (j += 1) {
            const sub_cost: usize = if (instrEq(a.instructions[i - 1], b.instructions[j - 1])) 0 else 1;
            const del = dp[i - 1][j] + 1;
            const ins = dp[i][j - 1] + 1;
            const sub = dp[i - 1][j - 1] + sub_cost;
            dp[i][j] = @min(@min(del, ins), sub);
        }
    }
    return dp[a.used][b.used];
}

const StructureSummary = struct {
    has_eval: bool,
    has_accept: bool,
    first_eval: i32,
    first_accept: i32,
    eval_before_accept: bool,
};

fn summarizeStructure(p: tier0.MetaProgram) StructureSummary {
    var s = StructureSummary{
        .has_eval = false,
        .has_accept = false,
        .first_eval = -1,
        .first_accept = -1,
        .eval_before_accept = false,
    };
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        switch (p.instructions[i].op) {
            .EVAL_CUR => {
                s.has_eval = true;
                if (s.first_eval < 0) s.first_eval = @intCast(i);
            },
            .ACCEPT_IF_BETTER, .ACCEPT_SA => {
                s.has_accept = true;
                if (s.first_accept < 0) s.first_accept = @intCast(i);
            },
            else => {},
        }
    }
    s.eval_before_accept = s.first_eval >= 0 and s.first_accept >= 0 and s.first_eval < s.first_accept;
    return s;
}

const Stats = struct { mean: f64, std: f64, min: f64, max: f64, n_finite: usize };

fn computeStats(vals: []const f64) Stats {
    var n_finite: usize = 0;
    var sum: f64 = 0;
    var min: f64 = std.math.inf(f64);
    var max: f64 = -std.math.inf(f64);
    for (vals) |v| {
        if (!std.math.isFinite(v)) continue;
        n_finite += 1;
        sum += v;
        if (v < min) min = v;
        if (v > max) max = v;
    }
    if (n_finite == 0) return .{ .mean = 0, .std = 0, .min = 0, .max = 0, .n_finite = 0 };
    const mean = sum / @as(f64, @floatFromInt(n_finite));
    var sqsum: f64 = 0;
    for (vals) |v| {
        if (!std.math.isFinite(v)) continue;
        const d = v - mean;
        sqsum += d * d;
    }
    const stdev = @sqrt(sqsum / @as(f64, @floatFromInt(n_finite)));
    return .{ .mean = mean, .std = stdev, .min = min, .max = max, .n_finite = n_finite };
}

// Disciplined hand-coded outer SA. Mirrors meta_meta_engine_runner's
// baseline. Returns the champion MetaProgram.
fn runDisciplinedBaseline(
    outer_iters: u32,
    inner_steps: u32,
    root_seed: u64,
) tier0.MetaProgram {
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

    var k: usize = 0;
    while (k < InitPool) : (k += 1) {
        rng = smix(rng);
        const cand = tier0.randomMetaProgram(&rng);
        var sum: f64 = 0;
        for (anchor_seeds) |as| {
            const q = tier0.run(cand, inner_steps, as);
            sum += if (std.math.isFinite(q)) q else -1.0e6;
        }
        const mean_q = sum / @as(f64, @floatFromInt(anchor_seeds.len));
        if (mean_q > best_anchor_q) {
            best = cand;
            best_anchor_q = mean_q;
        }
    }

    var i: u32 = 0;
    while (i < outer_iters) : (i += 1) {
        rng = smix(rng);
        const rot_seed = rng;
        rng = smix(rng);
        const cand = tier0.mutateMeta(best, &rng);

        const q_best_rot_raw = tier0.run(best, inner_steps, rot_seed);
        const q_cand_rot_raw = tier0.run(cand, inner_steps, rot_seed);
        const q_best_rot = if (std.math.isFinite(q_best_rot_raw)) q_best_rot_raw else -1.0e6;
        const q_cand_rot = if (std.math.isFinite(q_cand_rot_raw)) q_cand_rot_raw else -1.0e6;

        if (q_cand_rot > q_best_rot) {
            var anchor_sum: f64 = 0;
            for (anchor_seeds) |as| {
                const q = tier0.run(cand, inner_steps, as);
                anchor_sum += if (std.math.isFinite(q)) q else -1.0e6;
            }
            const cand_anchor_mean = anchor_sum / @as(f64, @floatFromInt(anchor_seeds.len));
            if (cand_anchor_mean > best_anchor_q) {
                best = cand;
                best_anchor_q = cand_anchor_mean;
            }
        }
    }
    return best;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var champion_path: []const u8 = "";
    var n_holdout: u32 = 64;
    var inner_steps: u32 = 180;
    var baseline_iters: u32 = 200;
    var baseline_seed: u64 = 0xBA5E_1111_2222_3333;
    var against_paths: []const u8 = "";

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--champion=")) {
            champion_path = arg["--champion=".len..];
        } else if (std.mem.startsWith(u8, arg, "--n-holdout=")) {
            n_holdout = try std.fmt.parseInt(u32, arg["--n-holdout=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--inner-steps=")) {
            inner_steps = try std.fmt.parseInt(u32, arg["--inner-steps=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--baseline-iters=")) {
            baseline_iters = try std.fmt.parseInt(u32, arg["--baseline-iters=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--baseline-seed=")) {
            baseline_seed = try std.fmt.parseInt(u64, arg["--baseline-seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--against=")) {
            against_paths = arg["--against=".len..];
        }
    }
    if (champion_path.len == 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("usage: champion_holdout_validation --champion=PATH [--n-holdout=64] [--inner-steps=180] [--baseline-iters=200] [--baseline-seed=hex]\n");
        return error.MissingArg;
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== CHAMPION HELD-OUT VALIDATION ===\n", .{});
    try stdout.print("champion={s}  n_holdout={d}  inner_steps={d}  baseline_iters={d}\n", .{
        champion_path, n_holdout, inner_steps, baseline_iters,
    });

    // Load discovered champion
    const champion = try parseMetaProgram(allocator, champion_path);
    try stdout.print("loaded champion MetaProgram with {d} instructions\n", .{champion.used});

    const ss = summarizeStructure(champion);
    try stdout.print("\n=== STRUCTURAL LINEAGE AUDIT ===\n", .{});
    try stdout.print("has_eval={} has_accept={} first_eval={d} first_accept={d} eval_before_accept={}\n", .{
        ss.has_eval, ss.has_accept, ss.first_eval, ss.first_accept, ss.eval_before_accept,
    });
    if (against_paths.len > 0) {
        var parts = std.mem.tokenizeAny(u8, against_paths, ",");
        var nearest_path: []const u8 = "";
        var nearest_dist: usize = std.math.maxInt(usize);
        var nearest_norm: f64 = 0;
        var exact_copy = false;
        var n_against: usize = 0;
        while (parts.next()) |path| {
            const other = try parseMetaProgram(allocator, path);
            const dist = metaEditDistance(champion, other);
            const denom_len: usize = @max(@as(usize, champion.used), @as(usize, other.used));
            const norm = if (denom_len == 0) 0 else @as(f64, @floatFromInt(dist)) / @as(f64, @floatFromInt(denom_len));
            if (dist == 0) exact_copy = true;
            if (dist < nearest_dist) {
                nearest_path = path;
                nearest_dist = dist;
                nearest_norm = norm;
            }
            n_against += 1;
        }
        try stdout.print("against_count={d} exact_copy={} nearest_edit_distance={d} nearest_normalized={d:.4} nearest={s}\n", .{
            n_against, exact_copy, nearest_dist, nearest_norm, nearest_path,
        });
        if (exact_copy) {
            try stdout.print("lineage_verdict=COPY\n", .{});
        } else if (nearest_norm < 0.25) {
            try stdout.print("lineage_verdict=NEAR_COPY_STRUCTURAL\n", .{});
        } else {
            try stdout.print("lineage_verdict=NON_COPY_STRUCTURAL\n", .{});
        }
    } else {
        try stdout.print("against_count=0 lineage_verdict=NOT_CHECKED\n", .{});
    }

    // Run disciplined hand-coded baseline
    try stdout.print("\n[baseline] running disciplined outer SA, iters={d}...\n", .{baseline_iters});
    const t_b0 = std.time.milliTimestamp();
    const baseline_champ = runDisciplinedBaseline(baseline_iters, inner_steps, baseline_seed);
    const t_b1 = std.time.milliTimestamp();
    try stdout.print("[baseline] done in {d} ms\n", .{t_b1 - t_b0});

    // Generate n_holdout held-out seeds, deterministic & distinct from
    // anchor/rotation/8-seed-holdout seeds used during search.
    var seeds = try allocator.alloc(u64, n_holdout);
    defer allocator.free(seeds);
    var rng: u64 = 0xC0DE_DEAD_BEEF_F00D;
    for (0..n_holdout) |i| {
        rng = smix(rng);
        seeds[i] = rng;
    }

    var champ_scores = try allocator.alloc(f64, n_holdout);
    defer allocator.free(champ_scores);
    var base_scores = try allocator.alloc(f64, n_holdout);
    defer allocator.free(base_scores);

    try stdout.print("\n[evaluate] running {d} held-out seeds for both champions...\n", .{n_holdout});
    const t_e0 = std.time.milliTimestamp();
    for (seeds, 0..) |s, i| {
        champ_scores[i] = tier0.run(champion, inner_steps, s);
        base_scores[i] = tier0.run(baseline_champ, inner_steps, s);
    }
    const t_e1 = std.time.milliTimestamp();
    try stdout.print("[evaluate] done in {d} ms\n", .{t_e1 - t_e0});

    const cs = computeStats(champ_scores);
    const bs = computeStats(base_scores);

    try stdout.print("\n=== RESULTS ===\n", .{});
    try stdout.print("                    n_finite    mean       std        min        max\n", .{});
    try stdout.print("discovered champ:   {d:>5}      {d:>10.4} {d:>10.4} {d:>10.4} {d:>10.4}\n", .{
        cs.n_finite, cs.mean, cs.std, cs.min, cs.max,
    });
    try stdout.print("baseline outer SA:  {d:>5}      {d:>10.4} {d:>10.4} {d:>10.4} {d:>10.4}\n", .{
        bs.n_finite, bs.mean, bs.std, bs.min, bs.max,
    });

    // Paired comparison: per-seed delta
    var wins: u32 = 0;
    var losses: u32 = 0;
    var ties: u32 = 0;
    var delta_sum: f64 = 0;
    var delta_count: usize = 0;
    for (0..n_holdout) |i| {
        if (!std.math.isFinite(champ_scores[i]) or !std.math.isFinite(base_scores[i])) continue;
        const d = champ_scores[i] - base_scores[i];
        delta_sum += d;
        delta_count += 1;
        if (d > 0.5) wins += 1
        else if (d < -0.5) losses += 1
        else ties += 1;
    }
    const delta_mean = if (delta_count > 0) delta_sum / @as(f64, @floatFromInt(delta_count)) else 0.0;
    try stdout.print("\nper-seed paired delta (champ - baseline): mean={d:.4}  wins={d}  losses={d}  ties={d}\n", .{
        delta_mean, wins, losses, ties,
    });

    try stdout.print("\n=== VERDICT ===\n", .{});
    if (cs.mean > bs.mean + 0.5 and wins > losses) {
        try stdout.print("CONFIRM: discovered champion beats baseline on {d}-seed held-out.\n", .{n_holdout});
        try stdout.print("         mean delta = {d:.4}, paired wins {d}/{d}\n", .{ delta_mean, wins, wins + losses + ties });
    } else if (bs.mean > cs.mean + 0.5 and losses > wins) {
        try stdout.print("HALT: baseline beats discovered champion on {d}-seed held-out.\n", .{n_holdout});
        try stdout.print("      mean delta = {d:.4}, paired losses {d}/{d}\n", .{ delta_mean, losses, wins + losses + ties });
    } else {
        try stdout.print("INCONCLUSIVE: means within noise. mean delta={d:.4}\n", .{delta_mean});
    }
}
