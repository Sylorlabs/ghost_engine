const std = @import("std");

// --- CONCEPTLESS INVENTOR ---
//
// Standalone geometry engine with no VSA import, no Flame import, no concept
// dictionary, and no human-language anchors in the scoring loop.
//
// It still runs on human-built code, integers, and hardware. That cannot be
// removed honestly. What is removed here is the VSA/concept/Flame-law cage.

const Dim = 512;
const Words = Dim / 64;
const LawCount = 1536;
const RefCount = 24;

const Field = [Words]u64;

const Law = struct {
    a: usize,
    b: usize,
    c: usize,
    rotate: u6,
    mask: u64,
};

const Metrics = struct {
    violations: usize,
    min_ref_dist: u32,
    mean_ref_dist: f64,
    orbit_energy: u64,
    score: i128,
};

const DistanceStats = struct {
    min: u32,
    sum: u32,
};

fn splitMix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn randomField(seed: u64) Field {
    var out: Field = undefined;
    var s = seed;
    for (&out, 0..) |*slot, idx| {
        s = splitMix64(s ^ @as(u64, @intCast(idx)));
        slot.* = s;
    }
    return out;
}

fn fingerprintHash(field: Field) u64 {
    var h: u64 = 0xC0DE1E55A11E0001;
    for (field, 0..) |word, idx| {
        h = splitMix64(h ^ word ^ @as(u64, @intCast(idx * 257)));
    }
    return h;
}

fn deriveLaws(seed: u64) [LawCount]Law {
    var laws: [LawCount]Law = undefined;
    var s = seed ^ 0xA51F_1E55_C0DE_0000;
    for (&laws, 0..) |*law, idx| {
        s = splitMix64(s ^ @as(u64, @intCast(idx)));
        const a = @as(usize, @intCast(s % Words));
        s = splitMix64(s);
        const b = @as(usize, @intCast(s % Words));
        s = splitMix64(s);
        const c = @as(usize, @intCast(s % Words));
        s = splitMix64(s);
        law.* = .{
            .a = a,
            .b = b,
            .c = c,
            .rotate = @intCast(s % 63 + 1),
            .mask = splitMix64(s ^ 0x51F7_5E1F),
        };
    }
    return laws;
}

fn deriveReferences(seed: u64) [RefCount]Field {
    var refs: [RefCount]Field = undefined;
    var s = seed ^ 0xF00D_BA5E_D15C_A11;
    for (&refs, 0..) |*field, idx| {
        s = splitMix64(s ^ @as(u64, @intCast(idx)));
        field.* = randomField(s);
    }
    return refs;
}

fn hamming(a: Field, b: Field) u32 {
    var dist: u32 = 0;
    for (a, b) |aw, bw| dist += @popCount(aw ^ bw);
    return dist;
}

fn bitAt(field: Field, idx: usize) bool {
    return ((field[idx / 64] >> @intCast(idx % 64)) & 1) != 0;
}

fn setBit(field: *Field, idx: usize, value: bool) void {
    const mask = @as(u64, 1) << @intCast(idx % 64);
    if (value) {
        field[idx / 64] |= mask;
    } else {
        field[idx / 64] &= ~mask;
    }
}

fn flipBit(field: *Field, idx: usize) void {
    field[idx / 64] ^= @as(u64, 1) << @intCast(idx % 64);
}

fn distanceStats(dists: []const u32) DistanceStats {
    var min: u32 = std.math.maxInt(u32);
    var sum: u32 = 0;
    for (dists) |d| {
        if (d < min) min = d;
        sum += d;
    }
    return .{ .min = min, .sum = sum };
}

fn synthesizeEscapeField(refs: []const Field, seed: u64) Field {
    var field: Field = [_]u64{0} ** Words;
    var rng = seed ^ 0xE5CA9E_F1E1D_0001;
    for (0..Dim) |bit| {
        var ones: usize = 0;
        for (refs) |ref| {
            if (bitAt(ref, bit)) ones += 1;
        }
        const zeros = refs.len - ones;
        if (ones == zeros) {
            rng = splitMix64(rng);
            setBit(&field, bit, (rng & 1) == 1);
        } else {
            setBit(&field, bit, ones < zeros);
        }
    }

    var dists: [RefCount]u32 = [_]u32{0} ** RefCount;
    for (refs, 0..) |ref, idx| dists[idx] = hamming(field, ref);

    var pass: usize = 0;
    while (pass < 12) : (pass += 1) {
        const current = distanceStats(dists[0..refs.len]);
        var best_bit: ?usize = null;
        var best_min = current.min;
        var best_sum = current.sum;

        for (0..Dim) |bit| {
            const old = bitAt(field, bit);
            var candidate = dists;
            for (refs, 0..) |ref, idx| {
                if (old == bitAt(ref, bit)) {
                    candidate[idx] += 1;
                } else {
                    candidate[idx] -= 1;
                }
            }
            const stats = distanceStats(candidate[0..refs.len]);
            if (stats.min > best_min or (stats.min == best_min and stats.sum > best_sum)) {
                best_bit = bit;
                best_min = stats.min;
                best_sum = stats.sum;
            }
        }

        if (best_bit) |bit| {
            const old = bitAt(field, bit);
            for (refs, 0..) |ref, idx| {
                if (old == bitAt(ref, bit)) {
                    dists[idx] += 1;
                } else {
                    dists[idx] -= 1;
                }
            }
            flipBit(&field, bit);
        } else {
            break;
        }
    }

    return field;
}

fn lawSatisfied(field: Field, law: Law) bool {
    const lhs = std.math.rotl(u64, field[law.a] ^ law.mask, law.rotate);
    const rhs = (field[law.b] +% splitMix64(field[law.c] ^ law.mask)) ^ std.math.rotr(u64, law.mask, law.rotate);
    return @popCount(lhs ^ rhs) <= 24;
}

fn countViolations(field: Field, laws: []const Law) usize {
    var violations: usize = 0;
    for (laws) |law| {
        if (!lawSatisfied(field, law)) violations += 1;
    }
    return violations;
}

fn orbitEnergy(field: Field) u64 {
    var energy: u64 = 0;
    for (field, 0..) |word, idx| {
        const mixed = word ^ std.math.rotl(u64, word, @as(u6, @intCast((idx * 7) % 63 + 1)));
        energy +%= @as(u64, @popCount(mixed)) *% @as(u64, @intCast(idx + 1));
    }
    return energy;
}

fn measure(field: Field, laws: []const Law, refs: []const Field, target_dist: u32) Metrics {
    var min_ref: u32 = std.math.maxInt(u32);
    var sum_ref: u64 = 0;
    for (refs) |ref| {
        const d = hamming(field, ref);
        if (d < min_ref) min_ref = d;
        sum_ref += d;
    }
    const violations = countViolations(field, laws);
    const energy = orbitEnergy(field);
    const target_gap: i128 = if (min_ref < target_dist) @intCast(target_dist - min_ref) else 0;
    const score =
        @as(i128, @intCast(min_ref)) * 250_000 +
        @as(i128, @intCast(energy & 0xFFFF)) -
        @as(i128, @intCast(violations)) * 1_000 -
        target_gap * 500_000;
    return .{
        .violations = violations,
        .min_ref_dist = min_ref,
        .mean_ref_dist = @as(f64, @floatFromInt(sum_ref)) / @as(f64, @floatFromInt(refs.len)),
        .orbit_energy = energy,
        .score = score,
    };
}

fn mutate(field: *Field, rng: *u64, flips: usize) void {
    for (0..flips) |_| {
        rng.* = splitMix64(rng.*);
        const bit = @as(usize, @intCast(rng.* % Dim));
        field[bit / 64] ^= @as(u64, 1) << @intCast(bit % 64);
    }
}

fn repair(field: *Field, laws: []const Law, rng: *u64, rounds: usize) void {
    for (0..rounds) |round| {
        for (laws) |law| {
            if (lawSatisfied(field.*, law)) continue;
            const idx = switch ((round + law.a + law.b + law.c) % 3) {
                0 => law.a,
                1 => law.b,
                else => law.c,
            };
            rng.* = splitMix64(rng.* ^ law.mask ^ @as(u64, @intCast(round)));
            const corrective = std.math.rotl(u64, law.mask ^ rng.*, law.rotate);
            field[idx] ^= corrective;
        }
    }
}

fn restoreEscapeDistance(field: *Field, escape: Field, refs: []const Field, target_dist: u32) void {
    var current_min: u32 = std.math.maxInt(u32);
    for (refs) |ref| current_min = @min(current_min, hamming(field.*, ref));
    if (current_min >= target_dist) return;

    for (0..Dim) |bit| {
        if (bitAt(field.*, bit) == bitAt(escape, bit)) continue;
        const old = bitAt(field.*, bit);
        setBit(field, bit, bitAt(escape, bit));
        var next_min: u32 = std.math.maxInt(u32);
        for (refs) |ref| next_min = @min(next_min, hamming(field.*, ref));
        if (next_min >= current_min) {
            current_min = next_min;
            if (current_min >= target_dist) return;
        } else {
            setBit(field, bit, old);
        }
    }
}

fn invent(seed: u64, laws: []const Law, refs: []const Field, iterations: usize, target_dist: u32) struct { field: Field, metrics: Metrics } {
    var rng = seed ^ 0x1A1E_0000_5E1F_0001;
    const escape = synthesizeEscapeField(refs, seed);
    var current = escape;
    mutate(&current, &rng, @as(usize, @intCast(seed % 17)));
    restoreEscapeDistance(&current, escape, refs, target_dist);
    var current_metrics = measure(current, laws, refs, target_dist);
    var best = current;
    var best_metrics = current_metrics;

    for (0..iterations) |iter| {
        var candidate = current;
        const flips = 3 + @as(usize, @intCast((splitMix64(rng ^ @as(u64, @intCast(iter))) % 29)));
        mutate(&candidate, &rng, flips);
        if ((iter % 5) == 0) repair(&candidate, laws, &rng, 1);
        restoreEscapeDistance(&candidate, escape, refs, target_dist);
        const candidate_metrics = measure(candidate, laws, refs, target_dist);
        const delta = candidate_metrics.score - current_metrics.score;
        var accept = delta >= 0;
        if (!accept) {
            rng = splitMix64(rng);
            const heat = @as(i128, @intCast(1 + iterations - iter));
            const threshold = @as(i128, @intCast(rng % 100_000)) * heat;
            accept = -delta < threshold;
        }
        if (accept) {
            current = candidate;
            current_metrics = candidate_metrics;
        }
        if (candidate_metrics.score > best_metrics.score) {
            best = candidate;
            best_metrics = candidate_metrics;
        }
    }

    return .{ .field = best, .metrics = best_metrics };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next();

    var trials: usize = 24;
    var iterations: usize = 600;
    var target_dist: u32 = 0;
    var seed: u64 = 0xC0DE1E55A11E51F7;
    var csv_path: []const u8 = "results/conceptless_inventor.csv";

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--trials=")) trials = try std.fmt.parseInt(usize, arg["--trials=".len..], 10) else if (std.mem.startsWith(u8, arg, "--iters=")) iterations = try std.fmt.parseInt(usize, arg["--iters=".len..], 10) else if (std.mem.startsWith(u8, arg, "--target=")) target_dist = try std.fmt.parseInt(u32, arg["--target=".len..], 10) else if (std.mem.startsWith(u8, arg, "--seed=")) seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16) else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..];
    }

    const law_seed = fingerprintHash(randomField(seed));
    const laws = deriveLaws(law_seed);
    const refs = deriveReferences(splitMix64(law_seed));
    var max_inter_ref: u32 = 0;
    var min_inter_ref: u32 = std.math.maxInt(u32);
    var sum_inter_ref: u64 = 0;
    var pair_count: usize = 0;
    for (refs, 0..) |a, i| {
        for (i + 1..refs.len) |j| {
            const d = hamming(a, refs[j]);
            if (d > max_inter_ref) max_inter_ref = d;
            if (d < min_inter_ref) min_inter_ref = d;
            sum_inter_ref += d;
            pair_count += 1;
        }
    }
    if (target_dist == 0) target_dist = max_inter_ref + 1;
    const escape = synthesizeEscapeField(refs[0..], seed);
    const escape_metrics = measure(escape, laws[0..], refs[0..], target_dist);

    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var csv = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv.close();
    try csv.writer().writeAll("trial,min_ref_dist,mean_ref_dist,violations,orbit_energy,score,past_target,field_hash\n");

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== CONCEPTLESS INVENTOR ===\n", .{});
    try stdout.print("imports=std_only  dim={d} laws={d} refs={d} target_dist={d} iters={d}\n", .{ Dim, LawCount, RefCount, target_dist, iterations });
    try stdout.print("self-ref envelope: min={d} mean={d:.1} max={d}; escape_seed min_ref={d} violations={d}\n", .{
        min_inter_ref,
        @as(f64, @floatFromInt(sum_inter_ref)) / @as(f64, @floatFromInt(pair_count)),
        max_inter_ref,
        escape_metrics.min_ref_dist,
        escape_metrics.violations,
    });
    try stdout.writeAll("trial | min_ref | mean  | violations | orbit     | score      | past?\n");
    try stdout.writeAll("------|---------|-------|------------|-----------|------------|------\n");

    var past: usize = 0;
    var best_metrics = Metrics{
        .violations = std.math.maxInt(usize),
        .min_ref_dist = 0,
        .mean_ref_dist = 0,
        .orbit_energy = 0,
        .score = std.math.minInt(i128),
    };
    var best_hash: u64 = 0;

    for (0..trials) |trial| {
        const trial_seed = splitMix64(seed +% @as(u64, @intCast(trial)) *% 0xD1B54A32D192ED03);
        const result = invent(trial_seed, laws[0..], refs[0..], iterations, target_dist);
        const m = result.metrics;
        const is_past = m.min_ref_dist >= target_dist;
        if (is_past) past += 1;
        const field_hash = fingerprintHash(result.field);
        if (m.score > best_metrics.score) {
            best_metrics = m;
            best_hash = field_hash;
        }
        try stdout.print("{d: >5} | {d: >7} | {d: >5.1} | {d: >10} | {d: >9} | {d: >10} | {s}\n", .{
            trial,
            m.min_ref_dist,
            m.mean_ref_dist,
            m.violations,
            m.orbit_energy & 0xFFFF_FFFF,
            m.score,
            if (is_past) "YES" else "no",
        });
        try csv.writer().print("{d},{d},{d:.4},{d},{d},{d},{d},0x{X}\n", .{
            trial,
            m.min_ref_dist,
            m.mean_ref_dist,
            m.violations,
            m.orbit_energy,
            m.score,
            @intFromBool(is_past),
            field_hash,
        });
    }

    try stdout.print("\nVERDICT: conceptless_past_target={d}/{d}; best_min_ref={d}; best_violations={d}; best_score={d}; best_hash=0x{X}; csv={s}\n", .{
        past,
        trials,
        best_metrics.min_ref_dist,
        best_metrics.violations,
        best_metrics.score,
        best_hash,
        csv_path,
    });
}
