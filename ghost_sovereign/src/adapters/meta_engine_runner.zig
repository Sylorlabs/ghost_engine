const std = @import("std");
const meta = @import("domain_meta_engine.zig");

// Outer search: discover MetaPrograms (engines) whose run() returns
// high q_best over inner steps K. Fitness of a candidate MetaProgram =
// average q_best across `eval_seeds` independent inner runs.
//
// This is the Tier-0 engine-inventing-engine harness:
//  - The outer loop here is a hard-coded SA over MetaPrograms.
//  - The inner loop (what each MetaProgram does) is itself searched.
//  - Future tiers: replace this outer loop with a MetaMetaProgram, etc.

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn parseU64Hex(s: []const u8) !u64 {
    const trimmed = if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X"))
        s[2..]
    else
        s;
    return try std.fmt.parseInt(u64, trimmed, 16);
}

const Cli = struct {
    outer_iters: u32 = 400,
    inner_steps: u32 = 200,
    eval_seeds: u32 = 3,
    root_seed: u64 = 0xC0FFEE_BAD_CAFE_12,
    out_dir: []const u8 = "results/meta_engine",
};

fn parseCli(args: [][:0]u8) Cli {
    var c = Cli{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.startsWith(u8, a, "--outer-iters=")) {
            c.outer_iters = std.fmt.parseInt(u32, a["--outer-iters=".len..], 10) catch c.outer_iters;
        } else if (std.mem.startsWith(u8, a, "--inner-steps=")) {
            c.inner_steps = std.fmt.parseInt(u32, a["--inner-steps=".len..], 10) catch c.inner_steps;
        } else if (std.mem.startsWith(u8, a, "--eval-seeds=")) {
            c.eval_seeds = std.fmt.parseInt(u32, a["--eval-seeds=".len..], 10) catch c.eval_seeds;
        } else if (std.mem.startsWith(u8, a, "--seed=")) {
            c.root_seed = parseU64Hex(a["--seed=".len..]) catch c.root_seed;
        } else if (std.mem.startsWith(u8, a, "--out-dir=")) {
            c.out_dir = a["--out-dir=".len..];
        }
    }
    return c;
}

fn fitnessOf(m: meta.MetaProgram, inner_steps: u32, eval_seeds: u32, root: u64) f64 {
    var total: f64 = 0;
    var n: f64 = 0;
    var s: u32 = 0;
    var seed: u64 = root;
    while (s < eval_seeds) : (s += 1) {
        seed = smix(seed +% 0x9E37_79B1 +% s);
        const q = meta.run(m, inner_steps, seed);
        const score = if (std.math.isInf(q) or std.math.isNan(q)) 0.0 else q;
        total += score;
        n += 1;
    }
    return total / n;
}

// Fitness with a per-outer-iter seed offset. When the outer loop calls
// this with a different `epoch` each iteration, the evaluation seed
// set rotates across iterations. A MetaProgram that wins only on
// seeds (e, ..) cannot keep winning when the next iteration switches
// to seeds (e+1, ..). This breaks the overfit-to-fixed-seed-set
// pathology that the first run exhibited (held-out 25 vs train 47).
fn fitnessOfEpoch(m: meta.MetaProgram, inner_steps: u32, eval_seeds: u32, root: u64, epoch: u32) f64 {
    const rotated_root = root ^ smix(@as(u64, epoch) *% 0xA0761D6478BD642F);
    return fitnessOf(m, inner_steps, eval_seeds, rotated_root);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const cli = parseCli(args);
    std.fs.cwd().makePath(cli.out_dir) catch {};

    const stdout = std.io.getStdOut().writer();

    try stdout.print(
        "meta-engine outer search: outer_iters={d} inner_steps={d} eval_seeds={d} seed=0x{X}\n",
        .{ cli.outer_iters, cli.inner_steps, cli.eval_seeds, cli.root_seed },
    );

    var rng: u64 = cli.root_seed;
    var best = meta.randomMetaProgram(&rng);
    var best_fit = fitnessOf(best, cli.inner_steps, cli.eval_seeds, cli.root_seed);

    try stdout.print("init: fitness={d:.4} used={d}\n", .{ best_fit, best.used });

    // Build per-iteration log.
    var log_path_buf: [512]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_path_buf, "{s}/outer_log.csv", .{cli.out_dir});
    var log_file = try std.fs.cwd().createFile(log_path, .{});
    defer log_file.close();
    const log = log_file.writer();
    try log.writeAll("iter,candidate_fit,best_fit,accepted,len\n");

    var accepted: u32 = 0;
    var i: u32 = 0;
    while (i < cli.outer_iters) : (i += 1) {
        // Rotate the eval seed set every iteration. Re-evaluate BOTH
        // best and candidate on this iteration's seed set so the
        // comparison is fair. A program can only win if it beats best
        // on a freshly-drawn seed set — no overfit to a fixed one.
        const best_fit_epoch = fitnessOfEpoch(best, cli.inner_steps, cli.eval_seeds, cli.root_seed, i);
        const candidate = meta.mutateMeta(best, &rng);
        const cand_fit = fitnessOfEpoch(candidate, cli.inner_steps, cli.eval_seeds, cli.root_seed, i);
        const better = cand_fit > best_fit_epoch;
        if (better) {
            best = candidate;
            best_fit = cand_fit;
            accepted += 1;
        }
        try log.print("{d},{d:.4},{d:.4},{d},{d}\n", .{
            i, cand_fit, best_fit_epoch, @as(u8, if (better) 1 else 0), candidate.used,
        });
        if (i % 25 == 0 or better) {
            try stdout.print("  iter {d}: cand={d:.3} best(epoch)={d:.3} {s}\n", .{
                i, cand_fit, best_fit_epoch, if (better) "ACCEPTED" else "rejected",
            });
        }
    }
    try stdout.print(
        "\nfinal: best_fit={d:.4} accepted={d}/{d}\n",
        .{ best_fit, accepted, cli.outer_iters },
    );

    // Dump best meta-program.
    try stdout.print("\nbest meta-program ({d} ops):\n", .{best.used});
    try meta.printMeta(best, stdout);

    // VALIDATE: re-evaluate the best engine across many INDEPENDENT
    // seeds disjoint from the ones used during outer search. This is
    // what tells us whether the discovered fitness was real or seed-
    // luck against the search-time seed set.
    const validate_seeds: u32 = 20;
    const validate_root: u64 = cli.root_seed ^ 0xFFFF_FFFF_FFFF_FFFF;
    var v_total: f64 = 0;
    var v_min: f64 = std.math.inf(f64);
    var v_max: f64 = -std.math.inf(f64);
    var vs: u32 = 0;
    var v_seed: u64 = validate_root;
    while (vs < validate_seeds) : (vs += 1) {
        v_seed = smix(v_seed +% 0xDEADBEEF +% vs);
        var q = meta.run(best, cli.inner_steps, v_seed);
        if (std.math.isInf(q) or std.math.isNan(q)) q = 0.0;
        v_total += q;
        if (q < v_min) v_min = q;
        if (q > v_max) v_max = q;
    }
    try stdout.print(
        "\nVALIDATION on {d} held-out seeds: mean={d:.4} min={d:.4} max={d:.4}\n",
        .{ validate_seeds, v_total / @as(f64, @floatFromInt(validate_seeds)), v_min, v_max },
    );

    var csv_path_buf: [512]u8 = undefined;
    const csv_path = try std.fmt.bufPrint(&csv_path_buf, "{s}/best_meta.csv", .{cli.out_dir});
    var csv_file = try std.fs.cwd().createFile(csv_path, .{});
    defer csv_file.close();
    const csv = csv_file.writer();
    try meta.metaToCsv(best, csv);

    try stdout.print("wrote {s} and {s}\n", .{ log_path, csv_path });
}
