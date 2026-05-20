const std = @import("std");
const absolute = @import("absolute_final");

// --- ABSOLUTECORE INVENTION ENGINE (Stage 1, painful brute-force version) ---
//
// AbsoluteCore has no laws, no closure error, no inversion mechanism. To
// give it an invention loop we define a value function we can optimize:
//
//   value(field) = sum of pairwise Hamming distances between the 64-bit
//   fingerprints produced by ingesting each calibration prompt against a
//   working copy of `field`. With 8 prompts that's 28 pairs × up to 64 bits
//   = up to 1792 theoretical maximum.
//
// The invention loop is simulated annealing:
//   - mutate: XOR a small u64 into a random voxel of the candidate field
//   - evaluate: measure value(field)
//   - accept if value improves OR with probability exp(-delta/T)
//   - cool T over iterations
//
// XOR is self-inverse so reject is cheap (re-apply the same XOR).
// What "invention" produces here: discovered field configurations that
// classify prompts more sharply than the default-seeded field. Outputs are
// inspectable (saved field, csv trajectory, best/worst pair gaps) — Stage 2
// will read those and design a smarter search.

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
const NPAIRS = NPROMPTS * (NPROMPTS - 1) / 2; // 28
const MAX_VALUE = NPAIRS * 64; // 1792

fn signaturesForField(
    core: *absolute.AbsoluteCore,
    baseline: []const u64,
    working: []u64,
    out_sigs: *[NPROMPTS]u64,
) void {
    for (CALIBRATION_PROMPTS, 0..) |prompt, i| {
        @memcpy(working, baseline);
        @memcpy(core.field, working);
        const report = core.ingestMeasured(prompt);
        out_sigs[i] = core.field[report.dominant_edge];
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

    var iterations: usize = 5000;
    var mut_per_step: usize = 4096;
    var rng_seed: u64 = 0x1234567890ABCDEF;
    var t_start: f64 = 4.0;
    var t_end: f64 = 0.05;
    var report_every: usize = 100;
    var state_path: []const u8 = "state/absolute_invention.bin";
    var csv_path: []const u8 = "results/absolute_invention.csv";
    var dump_field_path: ?[]const u8 = "state/absolute_invention_best.bin";

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
    try stdout.print("=== ABSOLUTECORE INVENTION ENGINE (Stage 1) ===\n", .{});
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
    signaturesForField(&core, baseline, working, &sigs);
    var current_value = valueOf(&sigs);
    var current_min_pair = minPairOf(&sigs);
    var best_value = current_value;
    var best_min_pair = current_min_pair;

    try stdout.print("Initial value: {d}/{d}  min-pair gap: {d}/64\n", .{ current_value, MAX_VALUE, current_min_pair });
    try stdout.writeAll("Initial fingerprints:\n");
    for (sigs, 0..) |s, i| try stdout.print("  [{d}] 0x{X:0>16}\n", .{ i, s });
    try stdout.print("\n", .{});

    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var csv_file = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv_file.close();
    try csv_file.writer().writeAll("iter,T,value,min_pair,best_value,best_min_pair,accepted\n");

    var rng = rng_seed;
    var accepted_total: usize = 0;
    const best_field = try allocator.alloc(u64, core.field.len);
    defer allocator.free(best_field);
    @memcpy(best_field, baseline);

    try stdout.writeAll("iter | T      | value | min-pair | best | best-min | accepted%\n");
    try stdout.writeAll("-----|--------|-------|----------|------|----------|----------\n");

    // Snapshot buffer for cheap revert via memcpy. ~16MB but worth it
    // because it lets us do arbitrarily large mutation batches.
    const snapshot = try allocator.alloc(u64, core.field.len);
    defer allocator.free(snapshot);
    @memcpy(snapshot, baseline);

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        const progress = @as(f64, @floatFromInt(iter)) / @as(f64, @floatFromInt(iterations));
        const t = t_start * std.math.pow(f64, t_end / t_start, progress);

        // Apply mutation to baseline (mutation count can be any size).
        for (0..mut_per_step) |_| {
            rng = splitMix64(rng);
            const idx = @as(usize, @intCast(rng)) % baseline.len;
            rng = splitMix64(rng);
            baseline[idx] ^= rng;
        }

        signaturesForField(&core, baseline, working, &sigs);
        const new_value = valueOf(&sigs);
        const new_min_pair = minPairOf(&sigs);

        // Acceptance: improve OR Metropolis with current T.
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
            // Revert via memcpy from snapshot.
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
    try stdout.print("Initial value: ?  current: {d}  best: {d}/{d}  ({d:.1}% of max)\n", .{
        current_value, best_value, MAX_VALUE,
        100.0 * @as(f64, @floatFromInt(best_value)) / @as(f64, @floatFromInt(MAX_VALUE)),
    });
    try stdout.print("Best min-pair gap: {d}/64\n", .{best_min_pair});
    try stdout.print("Accept rate: {d:.1}%\n", .{
        100.0 * @as(f64, @floatFromInt(accepted_total)) / @as(f64, @floatFromInt(iterations)),
    });

    @memcpy(core.field, best_field);
    signaturesForField(&core, best_field, working, &sigs);
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
