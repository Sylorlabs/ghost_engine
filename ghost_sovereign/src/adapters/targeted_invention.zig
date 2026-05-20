const std = @import("std");
const absolute = @import("absolute_final");

// --- TARGETED INVENTION (Stage 2) ---
//
// Stage 1 (`absolute_invention.zig`) used random mutations across all 2M
// voxels. ~99% landed in regions the 8-walker never visits for any of the
// 8 calibration prompts, so those mutations changed no signature and
// wasted iterations.
//
// Stage 2: pre-ingest each calibration prompt, record its `dominant_edge`
// voxel index (the voxel the walker landed at — the signature carrier),
// then mutate ONLY voxels in a 32KB window (4096 voxels, matching the
// AbsoluteCore active-window size) around each prompt's dominant edge.
// The mutation pool is the union of these eight 32KB windows — at most
// 32K voxels instead of 2M (98% reduction in search space).
//
// Same value function (sum of pairwise Hamming on calibration
// fingerprints, max=1792), same SA loop, same memcpy revert.

const CALIBRATION_PROMPTS = [_][]const u8{
    "Explain the memory layout of a Zig struct with aligned fields.",
    "Write a haiku about the silence of a motherboard at night.",
    "Solve for x where 7x^2 + 13x - 5000 = 0 using Diophantine approximation.",
    "hw do i fix teh broken lgc in my asic core??",
    "Refactor the existing Sovereign meta-architecture to use a sharded ring buffer for voxel persistence.",
    "Hello, how is the weather in the cloud today?",
    "Report on current manifold resonance and L1 cache utilization.",
    "const std = @import(\"std\"); pub fn main() !void { std.debug.print(\"hello\", .{}); }",
};

const NPROMPTS = CALIBRATION_PROMPTS.len;
const NPAIRS = NPROMPTS * (NPROMPTS - 1) / 2;
const MAX_VALUE = NPAIRS * 64;
const WINDOW: usize = absolute.AbsoluteCore.WindowSize; // 4096 voxels = 32KB
const HALF_WIN: usize = WINDOW / 2;

fn signaturesForField(
    core: *absolute.AbsoluteCore,
    baseline: []const u64,
    working: []u64,
    out_sigs: *[NPROMPTS]u64,
    out_edges: *[NPROMPTS]usize,
) void {
    for (CALIBRATION_PROMPTS, 0..) |prompt, i| {
        @memcpy(working, baseline);
        @memcpy(core.field, working);
        const report = core.ingestMeasured(prompt);
        out_sigs[i] = core.field[report.dominant_edge];
        out_edges[i] = @intCast(report.dominant_edge);
    }
}

fn valueOf(sigs: *const [NPROMPTS]u64) u32 {
    var sum: u32 = 0;
    for (0..NPROMPTS) |i| for (i + 1..NPROMPTS) |j| {
        sum += @popCount(sigs[i] ^ sigs[j]);
    };
    return sum;
}

fn minPairOf(sigs: *const [NPROMPTS]u64) u32 {
    var lo: u32 = std.math.maxInt(u32);
    for (0..NPROMPTS) |i| for (i + 1..NPROMPTS) |j| {
        const d = @popCount(sigs[i] ^ sigs[j]);
        if (d < lo) lo = d;
    };
    return lo;
}

fn splitMix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var iterations: usize = 3000;
    var mut_per_step: usize = 256;
    var rng_seed: u64 = 0xCAFEBABEDEADBEEF;
    var t_start: f64 = 8.0;
    var t_end: f64 = 0.05;
    var report_every: usize = 100;
    var state_path: []const u8 = "state/targeted_invention.bin";
    var csv_path: []const u8 = "results/targeted_invention.csv";
    var dump_field_path: ?[]const u8 = "state/targeted_invention_best.bin";

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--iters=")) iterations = try std.fmt.parseInt(usize, arg["--iters=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--mut=")) mut_per_step = try std.fmt.parseInt(usize, arg["--mut=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--seed=")) rng_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16)
        else if (std.mem.startsWith(u8, arg, "--t-start=")) t_start = try std.fmt.parseFloat(f64, arg["--t-start=".len..])
        else if (std.mem.startsWith(u8, arg, "--t-end=")) t_end = try std.fmt.parseFloat(f64, arg["--t-end=".len..])
        else if (std.mem.startsWith(u8, arg, "--report=")) report_every = try std.fmt.parseInt(usize, arg["--report=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--state=")) state_path = arg["--state=".len..]
        else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..]
        else if (std.mem.startsWith(u8, arg, "--dump=")) dump_field_path = arg["--dump=".len..];
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== TARGETED INVENTION (Stage 2) ===\n", .{});
    try stdout.print("Iterations: {d}  Mut/step: {d}  T: {d:.3} -> {d:.3}\n", .{ iterations, mut_per_step, t_start, t_end });
    try stdout.print("State: {s}\n\n", .{state_path});

    var core = try absolute.AbsoluteCore.initAt(state_path, 16 * 1024 * 1024);
    defer core.deinit();

    const baseline = try allocator.alloc(u64, core.field.len);
    defer allocator.free(baseline);
    const working = try allocator.alloc(u64, core.field.len);
    defer allocator.free(working);
    @memcpy(baseline, core.field);

    var sigs: [NPROMPTS]u64 = undefined;
    var edges: [NPROMPTS]usize = undefined;
    signaturesForField(&core, baseline, working, &sigs, &edges);
    var current_value = valueOf(&sigs);
    var current_min_pair = minPairOf(&sigs);
    var best_value = current_value;
    var best_min_pair = current_min_pair;

    try stdout.print("Initial value: {d}/{d}  min-pair gap: {d}/64\n", .{ current_value, MAX_VALUE, current_min_pair });
    try stdout.writeAll("Per-prompt dominant_edge voxel indices (the active hot-spots):\n");
    for (edges, 0..) |e, i| try stdout.print("  prompt {d}: voxel {d}  ->  sig 0x{X:0>16}\n", .{ i, e, sigs[i] });

    // Pre-compute the targeted mutation pool: union of 4096-voxel windows
    // around each prompt's dominant_edge. Stored as a flat list of usize
    // voxel indices for cheap uniform sampling.
    var pool = std.AutoHashMap(usize, void).init(allocator);
    defer pool.deinit();
    for (edges) |e| {
        const start: isize = @as(isize, @intCast(e)) - @as(isize, @intCast(HALF_WIN));
        var v: isize = start;
        const end: isize = start + @as(isize, @intCast(WINDOW));
        while (v < end) : (v += 1) {
            const idx = @mod(v, @as(isize, @intCast(core.field.len)));
            try pool.put(@as(usize, @intCast(idx)), {});
        }
    }
    const pool_list = try allocator.alloc(usize, pool.count());
    defer allocator.free(pool_list);
    {
        var it = pool.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) pool_list[i] = k.*;
    }
    try stdout.print("\nTargeted mutation pool: {d} voxels ({d:.3}% of full field)\n\n", .{
        pool_list.len, 100.0 * @as(f64, @floatFromInt(pool_list.len)) / @as(f64, @floatFromInt(core.field.len)),
    });

    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var csv_file = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv_file.close();
    try csv_file.writer().writeAll("iter,T,value,min_pair,best_value,best_min_pair,accepted\n");

    const best_field = try allocator.alloc(u64, core.field.len);
    defer allocator.free(best_field);
    @memcpy(best_field, baseline);
    const snapshot = try allocator.alloc(u64, core.field.len);
    defer allocator.free(snapshot);
    @memcpy(snapshot, baseline);

    var rng = rng_seed;
    var accepted_total: usize = 0;

    try stdout.writeAll("iter | T      | value | min-pair | best | best-min | accepted%\n");
    try stdout.writeAll("-----|--------|-------|----------|------|----------|----------\n");

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        const progress = @as(f64, @floatFromInt(iter)) / @as(f64, @floatFromInt(iterations));
        const t = t_start * std.math.pow(f64, t_end / t_start, progress);

        for (0..mut_per_step) |_| {
            rng = splitMix64(rng);
            const pool_idx = @as(usize, @intCast(rng)) % pool_list.len;
            const voxel_idx = pool_list[pool_idx];
            rng = splitMix64(rng);
            baseline[voxel_idx] ^= rng;
        }

        signaturesForField(&core, baseline, working, &sigs, &edges);
        const new_value = valueOf(&sigs);
        const new_min_pair = minPairOf(&sigs);

        const delta = @as(i64, @intCast(new_value)) - @as(i64, @intCast(current_value));
        var accept = false;
        if (delta >= 0) {
            accept = true;
        } else {
            const p = std.math.exp(@as(f64, @floatFromInt(delta)) / t);
            rng = splitMix64(rng);
            const draw = @as(f64, @floatFromInt(rng % 1_000_000)) / 1_000_000.0;
            accept = draw < p;
        }

        if (accept) {
            current_value = new_value;
            current_min_pair = new_min_pair;
            accepted_total += 1;
            @memcpy(snapshot, baseline);
            if (new_value > best_value) {
                best_value = new_value;
                best_min_pair = new_min_pair;
                @memcpy(best_field, baseline);
            }
        } else {
            @memcpy(baseline, snapshot);
        }

        try csv_file.writer().print("{d},{d:.4},{d},{d},{d},{d},{d}\n", .{
            iter, t, current_value, current_min_pair, best_value, best_min_pair, @intFromBool(accept),
        });

        if ((iter + 1) % report_every == 0 or iter == 0) {
            const pct = 100.0 * @as(f64, @floatFromInt(accepted_total)) / @as(f64, @floatFromInt(iter + 1));
            try stdout.print("{d: >4} | {d: >6.3} | {d: >5} | {d: >8} | {d: >4} | {d: >8} | {d: >5.1}%\n", .{
                iter + 1, t, current_value, current_min_pair, best_value, best_min_pair, pct,
            });
        }
    }

    try stdout.print("\n=== FINAL ===\n", .{});
    try stdout.print("Best value: {d}/{d}  ({d:.1}% of max)\n", .{
        best_value, MAX_VALUE,
        100.0 * @as(f64, @floatFromInt(best_value)) / @as(f64, @floatFromInt(MAX_VALUE)),
    });
    try stdout.print("Best min-pair gap: {d}/64\n", .{best_min_pair});
    try stdout.print("Accept rate: {d:.1}%\n", .{
        100.0 * @as(f64, @floatFromInt(accepted_total)) / @as(f64, @floatFromInt(iterations)),
    });

    @memcpy(core.field, best_field);
    signaturesForField(&core, best_field, working, &sigs, &edges);
    try stdout.writeAll("Best-field fingerprints:\n");
    for (sigs, 0..) |s, i| try stdout.print("  [{d}] 0x{X:0>16}\n", .{ i, s });

    if (dump_field_path) |path| {
        if (std.fs.path.dirname(path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
        var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(std.mem.sliceAsBytes(best_field));
        try stdout.print("Best field dumped to {s}\n", .{path});
    }
}
