const std = @import("std");
const bt = @import("domain_bittape.zig");

// --- BIT-TAPE INVENTOR — pure evolutionary search (2026-05-22) ---
//
// No LLM, no chain_extras, no CALL_LIB, no MMP/MMMP infrastructure.
// Classical genetic algorithm only: random population → tournament
// selection → crossover + mutation → replace worst → repeat.
//
// The only priors are:
//   1. The 3 Boolean primitives (XOR, AND, NOT) — these are
//      mathematical irreducibles, not human "mixer inventions."
//   2. The fitness function (avalanche / balance / period /
//      chi-square) — these are the standard PRNG quality metrics.
//      Using them lets us compare to existing splitMix64-shaped
//      results on a common axis.
//
// Honest expected behavior at session 1: pure evolution from random
// bit-soup will struggle to reach the avalanche=32 target. Random
// bit programs cluster near avalanche≈5-15. The fitness landscape
// is sparse. Improvement requires many generations and lucky
// recombinations. The output is a baseline measurement: where
// does pure-evolution + bit-substrate actually land?

const PopSize: usize = 64;
const Elitism: usize = 2;
const TournamentSize: usize = 5;

const Individual = struct {
    program: bt.Program,
    quality: bt.Quality,
};

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn tournamentSelect(population: []const Individual, k: usize, rng: *u64) usize {
    var best_idx: usize = 0;
    var best_q: f64 = -std.math.inf(f64);
    var j: usize = 0;
    while (j < k) : (j += 1) {
        rng.* = smix(rng.*);
        const idx: usize = rng.* % population.len;
        if (population[idx].quality.composite > best_q) {
            best_q = population[idx].quality.composite;
            best_idx = idx;
        }
    }
    return best_idx;
}

fn sortDescByQuality(population: []Individual) void {
    std.mem.sort(Individual, population, {}, struct {
        fn lt(_: void, a: Individual, b: Individual) bool {
            return a.quality.composite > b.quality.composite;
        }
    }.lt);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var generations: u32 = 200;
    var root_seed: u64 = 0xBA17_7AAE_0000_0001;
    var mutation_rate: f64 = 0.7;
    var crossover_rate: f64 = 0.5;
    var out_subdir: []const u8 = "bittape_inventor";

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--generations=")) {
            generations = try std.fmt.parseInt(u32, arg["--generations=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            root_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--mutation-rate=")) {
            mutation_rate = try std.fmt.parseFloat(f64, arg["--mutation-rate=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--crossover-rate=")) {
            crossover_rate = try std.fmt.parseFloat(f64, arg["--crossover-rate=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--out-subdir=")) {
            out_subdir = arg["--out-subdir=".len..];
        }
    }

    var dir_buf: [256]u8 = undefined;
    const out_dir = try std.fmt.bufPrint(&dir_buf, "results/{s}", .{out_subdir});
    try std.fs.cwd().makePath(out_dir);

    var csv_path_buf: [320]u8 = undefined;
    const csv_path = try std.fmt.bufPrint(&csv_path_buf, "{s}/trajectory.csv", .{out_dir});
    var csv_file = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv_file.close();
    const csv = csv_file.writer();
    try csv.writeAll("generation,best_composite,best_avalanche,best_balance,best_period,best_chisq,best_min_pb,best_max_pb,best_bias_pb,best_used,mean_composite\n");

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("=== BIT-TAPE INVENTOR ===\n");
    try stdout.print("generations={d} seed=0x{X} pop_size={d} tournament={d} elite={d} mut_rate={d:.2} xover_rate={d:.2}\n", .{
        generations, root_seed, PopSize, TournamentSize, Elitism, mutation_rate, crossover_rate,
    });

    var rng = root_seed;

    // Initialize population.
    var population = try allocator.alloc(Individual, PopSize);
    defer allocator.free(population);
    var i: usize = 0;
    while (i < PopSize) : (i += 1) {
        rng = smix(rng);
        const prog = bt.randomProgram(&rng);
        population[i] = .{ .program = prog, .quality = bt.evaluateQuality(prog) };
    }
    sortDescByQuality(population);

    try stdout.print("gen 0 init: best_composite={d:.4} av={d:.2} min_pb={d:.4} max_pb={d:.4} bal={d:.2} chisq={d:.2} period={d} used={d}\n", .{
        population[0].quality.composite,
        population[0].quality.avalanche,
        population[0].quality.min_pb,
        population[0].quality.max_pb,
        population[0].quality.balance,
        population[0].quality.chisq,
        population[0].quality.period,
        population[0].program.used,
    });

    // Evolutionary loop.
    var children = try allocator.alloc(Individual, PopSize - Elitism);
    defer allocator.free(children);

    var best_ever: Individual = population[0];

    var g: u32 = 0;
    while (g < generations) : (g += 1) {
        var c: usize = 0;
        while (c < children.len) : (c += 1) {
            const p1_idx = tournamentSelect(population, TournamentSize, &rng);
            const p2_idx = tournamentSelect(population, TournamentSize, &rng);

            rng = smix(rng);
            const do_xover = (@as(f64, @floatFromInt(rng & 0xFFFF)) / 65536.0) < crossover_rate;
            var child_prog = if (do_xover)
                bt.crossover(population[p1_idx].program, population[p2_idx].program, &rng)
            else
                population[p1_idx].program;

            rng = smix(rng);
            const do_mut = (@as(f64, @floatFromInt(rng & 0xFFFF)) / 65536.0) < mutation_rate;
            if (do_mut) child_prog = bt.mutate(child_prog, &rng);

            children[c] = .{ .program = child_prog, .quality = bt.evaluateQuality(child_prog) };
        }

        // Replace population: keep top Elitism, fill the rest with children.
        i = Elitism;
        while (i < PopSize) : (i += 1) population[i] = children[i - Elitism];
        sortDescByQuality(population);

        // Track best-ever.
        if (population[0].quality.composite > best_ever.quality.composite) {
            best_ever = population[0];
        }

        // Compute mean composite.
        var sum: f64 = 0;
        for (population) |ind| sum += ind.quality.composite;
        const mean: f64 = sum / @as(f64, @floatFromInt(population.len));

        try csv.print("{d},{d:.6},{d:.4},{d:.4},{d},{d:.4},{d:.6},{d:.6},{d:.6},{d},{d:.6}\n", .{
            g + 1,
            population[0].quality.composite,
            population[0].quality.avalanche,
            population[0].quality.balance,
            population[0].quality.period,
            population[0].quality.chisq,
            population[0].quality.min_pb,
            population[0].quality.max_pb,
            population[0].quality.bias_pb,
            population[0].program.used,
            mean,
        });

        if ((g + 1) % 10 == 0 or g == 0) {
            try stdout.print("gen {d}/{d}: best_composite={d:.4} av={d:.2} min_pb={d:.4} max_pb={d:.4} bal={d:.2} chisq={d:.2} per={d} used={d} mean_comp={d:.2}\n", .{
                g + 1,
                generations,
                population[0].quality.composite,
                population[0].quality.avalanche,
                population[0].quality.min_pb,
                population[0].quality.max_pb,
                population[0].quality.balance,
                population[0].quality.chisq,
                population[0].quality.period,
                population[0].program.used,
                mean,
            });
        }
    }

    // Save best-ever program.
    var best_path_buf: [320]u8 = undefined;
    const best_path = try std.fmt.bufPrint(&best_path_buf, "{s}/BEST_program.csv", .{out_dir});
    var best_file = try std.fs.cwd().createFile(best_path, .{ .truncate = true });
    defer best_file.close();
    try bt.programToCsv(best_ever.program, best_file.writer());

    try stdout.print("=== FINAL ===\nBEST_COMPOSITE = {d:.4} avalanche={d:.4} min_pb={d:.4} max_pb={d:.4} balance={d:.4} chisq={d:.4} period={d} used={d}\n", .{
        best_ever.quality.composite,
        best_ever.quality.avalanche,
        best_ever.quality.min_pb,
        best_ever.quality.max_pb,
        best_ever.quality.balance,
        best_ever.quality.chisq,
        best_ever.quality.period,
        best_ever.program.used,
    });
    try stdout.print("Best program written to {s}\n", .{best_path});
}
