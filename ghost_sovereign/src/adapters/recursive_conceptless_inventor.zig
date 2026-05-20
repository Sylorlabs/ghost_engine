const std = @import("std");

// Synthesized from synthesized_conceptless_breakthrough.zig.
//
// Runtime boundary:
// - std only
// - no VSA import
// - no Flame import
// - no concept enum
// - no external model/service
//
// Difference from the parent:
// the parent hill-climbs a blended distance/law score. This child keeps the
// parent's exact self-reference benchmark, then pushes a moving maximin
// distance frontier before doing secondary balancing.

const Dim = 512;
const Words = Dim / 64;
const RefCount = 24;
const LawCount = 1536;

const ParentBestMinRef: u32 = 291;
const ParentBestHash: u64 = 0xE47F99B8ABC739EE;

const Field = [Words]u64;
const Distances = [RefCount]u32;

const SourcePrototype = [_]u64{
    0xF2DCCF1A5A1D0117,
    0xC5C4A2648F483958,
    0x9D9A4E17C31AAB1A,
    0x20994509E40FD925,
    0xAA72C6F33870B680,
    0x3F8882177B4652B5,
    0x7D67BE7E88144C7C,
    0x3F110F1907D7D281,
};

const SourceGenomeHash: u64 = 0xAF63CF03E028E569;
const SourceGenomeSeed: u64 = 0x5604D7E8AC1D9E6A;
const ChildSalt: u64 = 0x9B6C_EE5E_1E55_2026;

const Law = struct {
    a: usize,
    b: usize,
    c: usize,
    rotate: u6,
    mask: u64,
};

const Envelope = struct {
    min: u32,
    max: u32,
    mean: f64,
};

const DistStats = struct {
    min: u32,
    sum: u32,
    near_count: usize,
    floor_sum: u32,
    score: i128,
};

const Metrics = struct {
    min_ref_dist: u32,
    mean_ref_dist: f64,
    violations: usize,
    frontier: u32,
    score: i128,
};

fn splitMix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn parentSourceHash() u64 {
    var h = SourceGenomeHash ^ SourceGenomeSeed ^ 0xC0DE1E55_B17F1E55;
    for (SourcePrototype, 0..) |word, idx| {
        h = splitMix64(h ^ word ^ @as(u64, @intCast(idx * 4099)));
    }
    return h;
}

fn childSeed(seed: u64) u64 {
    return splitMix64(seed ^ ParentBestHash ^ parentSourceHash() ^ ChildSalt);
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

fn randomField(seed: u64) Field {
    var out: Field = undefined;
    var s = seed;
    for (&out, 0..) |*slot, idx| {
        s = splitMix64(s ^ @as(u64, @intCast(idx)));
        slot.* = s;
    }
    return out;
}

fn hamming(a: Field, b: Field) u32 {
    var dist: u32 = 0;
    for (a, b) |aw, bw| dist += @popCount(aw ^ bw);
    return dist;
}

fn fieldHash(field: Field) u64 {
    var h = childSeed(0xF1E1D_F09E);
    for (field, 0..) |word, idx| h = splitMix64(h ^ word ^ @as(u64, @intCast(idx * 257)));
    return h;
}

fn deriveRefs(seed: u64) [RefCount]Field {
    var refs: [RefCount]Field = undefined;

    // Deliberately the parent derivation, so the child is measured against the
    // same self-reference orbit as synthesized_conceptless_breakthrough.
    var s = seed ^ parentSourceHash();
    for (&refs, 0..) |*ref, idx| {
        s = splitMix64(s ^ @as(u64, @intCast(idx)));
        ref.* = randomField(s);
    }
    return refs;
}

fn deriveLaws(seed: u64) [LawCount]Law {
    var laws: [LawCount]Law = undefined;
    var s = seed ^ 0x51A7E1E55A11E1E5;
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
            .mask = splitMix64(s ^ SourceGenomeHash),
        };
    }
    return laws;
}

fn lawSatisfied(field: Field, law: Law) bool {
    const lhs = std.math.rotl(u64, field[law.a] ^ law.mask, law.rotate);
    const rhs = (field[law.b] +% splitMix64(field[law.c] ^ law.mask)) ^ std.math.rotr(u64, law.mask, law.rotate);
    return @popCount(lhs ^ rhs) <= 24;
}

fn countViolations(field: Field, laws: []const Law) usize {
    var count: usize = 0;
    for (laws) |law| {
        if (!lawSatisfied(field, law)) count += 1;
    }
    return count;
}

fn interEnvelope(refs: []const Field) Envelope {
    var min_d: u32 = std.math.maxInt(u32);
    var max_d: u32 = 0;
    var sum: u64 = 0;
    var pairs: usize = 0;
    for (refs, 0..) |a, i| {
        for (i + 1..refs.len) |j| {
            const d = hamming(a, refs[j]);
            min_d = @min(min_d, d);
            max_d = @max(max_d, d);
            sum += d;
            pairs += 1;
        }
    }
    return .{ .min = min_d, .max = max_d, .mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(pairs)) };
}

fn antiMajority(refs: []const Field, seed: u64) Field {
    var field: Field = [_]u64{0} ** Words;
    var rng = childSeed(seed);
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
    return field;
}

fn computeDists(field: Field, refs: []const Field) Distances {
    var dists: Distances = [_]u32{0} ** RefCount;
    for (refs, 0..) |ref, idx| dists[idx] = hamming(field, ref);
    return dists;
}

fn distStats(dists: []const u32) DistStats {
    var min_d: u32 = std.math.maxInt(u32);
    var sum: u32 = 0;
    for (dists) |d| {
        min_d = @min(min_d, d);
        sum += d;
    }

    var near_count: usize = 0;
    var floor_sum: u32 = 0;
    const floor_band = min_d + 3;
    for (dists) |d| {
        if (d <= floor_band) {
            near_count += 1;
            floor_sum += d;
        }
    }

    const score =
        @as(i128, @intCast(min_d)) * 1_000_000_000_000 -
        @as(i128, @intCast(near_count)) * 1_000_000_000 +
        @as(i128, @intCast(floor_sum)) * 1_000_000 +
        @as(i128, @intCast(sum)) * 1_000;
    return .{ .min = min_d, .sum = sum, .near_count = near_count, .floor_sum = floor_sum, .score = score };
}

fn candidateDists(field: Field, refs: []const Field, dists: Distances, bit: usize) Distances {
    var next = dists;
    const old = bitAt(field, bit);
    for (refs, 0..) |ref, idx| {
        if (old == bitAt(ref, bit)) {
            next[idx] += 1;
        } else {
            next[idx] -= 1;
        }
    }
    return next;
}

fn applyFlip(field: *Field, refs: []const Field, dists: *Distances, bit: usize) void {
    const old = bitAt(field.*, bit);
    for (refs, 0..) |ref, idx| {
        if (old == bitAt(ref, bit)) {
            dists[idx] += 1;
        } else {
            dists[idx] -= 1;
        }
    }
    flipBit(field, bit);
}

fn deficitCost(dists: []const u32, frontier: u32) i128 {
    var cost: i128 = 0;
    for (dists) |d| {
        if (d < frontier) {
            const deficit = @as(i128, @intCast(frontier - d));
            cost += deficit * deficit * 10_000 + deficit;
        }
    }
    return cost;
}

fn pushFrontier(field: *Field, refs: []const Field, dists: *Distances, max_steps: usize) u32 {
    var frontier = distStats(dists[0..refs.len]).min + 1;
    var steps: usize = 0;
    while (steps < max_steps and frontier <= Dim) {
        var cost = deficitCost(dists[0..refs.len], frontier);
        if (cost == 0) {
            frontier += 1;
            continue;
        }

        var moved_this_frontier = false;
        while (steps < max_steps and cost != 0) : (steps += 1) {
            var best_bit: ?usize = null;
            var best_cost = cost;
            var best_stats = distStats(dists[0..refs.len]);

            for (0..Dim) |bit| {
                const cand = candidateDists(field.*, refs, dists.*, bit);
                const cand_cost = deficitCost(cand[0..refs.len], frontier);
                const cand_stats = distStats(cand[0..refs.len]);
                if (cand_cost < best_cost or (cand_cost == best_cost and cand_stats.score > best_stats.score)) {
                    best_bit = bit;
                    best_cost = cand_cost;
                    best_stats = cand_stats;
                }
            }

            if (best_bit) |bit| {
                applyFlip(field, refs, dists, bit);
                cost = best_cost;
                moved_this_frontier = true;
            } else {
                break;
            }
        }

        if (cost == 0) {
            frontier += 1;
        } else if (!moved_this_frontier) {
            break;
        } else {
            break;
        }
    }
    return distStats(dists[0..refs.len]).min;
}

fn balanceFloor(field: *Field, refs: []const Field, dists: *Distances, rounds: usize) void {
    var current = distStats(dists[0..refs.len]);
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        var best_bit: ?usize = null;
        var best_stats = current;
        for (0..Dim) |bit| {
            const cand = candidateDists(field.*, refs, dists.*, bit);
            const stats = distStats(cand[0..refs.len]);
            if (stats.score > best_stats.score) {
                best_bit = bit;
                best_stats = stats;
            }
        }
        if (best_bit) |bit| {
            applyFlip(field, refs, dists, bit);
            current = best_stats;
        } else {
            break;
        }
    }
}

fn temperLaws(field: *Field, refs: []const Field, laws: []const Law, dists: *Distances, rounds: usize) void {
    var current_violations = countViolations(field.*, laws);
    var current_stats = distStats(dists[0..refs.len]);

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        var best_bit: ?usize = null;
        var best_violations = current_violations;
        var best_stats = current_stats;

        for (0..Dim) |bit| {
            const cand_dists = candidateDists(field.*, refs, dists.*, bit);
            const cand_stats = distStats(cand_dists[0..refs.len]);
            if (cand_stats.min < current_stats.min) continue;

            flipBit(field, bit);
            const cand_violations = countViolations(field.*, laws);
            flipBit(field, bit);

            if (cand_violations < best_violations or (cand_violations == best_violations and cand_stats.score > best_stats.score)) {
                best_bit = bit;
                best_violations = cand_violations;
                best_stats = cand_stats;
            }
        }

        if (best_bit) |bit| {
            applyFlip(field, refs, dists, bit);
            current_violations = best_violations;
            current_stats = best_stats;
        } else {
            break;
        }
    }
}

fn phaseShake(field: *Field, refs: []const Field, dists: *Distances, seed: u64, phase: usize) void {
    var rng = childSeed(seed ^ @as(u64, @intCast(phase * 0x9E37)));
    const flips = 4 + (phase * 7) % 37;
    for (0..flips) |_| {
        rng = splitMix64(rng);
        const bit = @as(usize, @intCast(rng % Dim));
        applyFlip(field, refs, dists, bit);
    }
}

fn measure(field: Field, refs: []const Field, laws: []const Law, frontier: u32) Metrics {
    const dists = computeDists(field, refs);
    const stats = distStats(dists[0..refs.len]);
    const violations = countViolations(field, laws);
    const mean = @as(f64, @floatFromInt(stats.sum)) / @as(f64, @floatFromInt(refs.len));
    const score =
        @as(i128, @intCast(stats.min)) * 1_000_000_000_000_000 -
        @as(i128, @intCast(violations)) * 1_000_000_000 -
        @as(i128, @intCast(stats.near_count)) * 100_000_000 +
        @as(i128, @intCast(stats.floor_sum)) * 1_000_000 +
        @as(i128, @intCast(stats.sum)) * 1_000;
    return .{
        .min_ref_dist = stats.min,
        .mean_ref_dist = mean,
        .violations = violations,
        .frontier = frontier,
        .score = score,
    };
}

fn invent(seed: u64, refs: []const Field, laws: []const Law, steps: usize, phases: usize) struct { field: Field, metrics: Metrics } {
    var best_field = antiMajority(refs, seed);
    var best_dists = computeDists(best_field, refs);
    const first_frontier = pushFrontier(&best_field, refs, &best_dists, steps);
    balanceFloor(&best_field, refs, &best_dists, steps / 4 + 1);
    var best_metrics = measure(best_field, refs, laws, first_frontier);

    for (0..phases) |phase| {
        var field = antiMajority(refs, splitMix64(seed ^ @as(u64, @intCast(phase)) ^ ParentBestHash));
        var dists = computeDists(field, refs);
        phaseShake(&field, refs, &dists, seed, phase);
        const frontier = pushFrontier(&field, refs, &dists, steps);
        balanceFloor(&field, refs, &dists, steps / 3 + 1);
        const metrics = measure(field, refs, laws, frontier);
        if (metrics.score > best_metrics.score) {
            best_field = field;
            best_metrics = metrics;
        }
    }

    best_dists = computeDists(best_field, refs);
    temperLaws(&best_field, refs, laws, &best_dists, 10);
    best_metrics = measure(best_field, refs, laws, best_metrics.frontier);

    return .{ .field = best_field, .metrics = best_metrics };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next();

    var trials: usize = 16;
    var seed: u64 = parentSourceHash();
    var steps: usize = 512;
    var phases: usize = 20;
    var csv_path: []const u8 = "results/recursive_conceptless_inventor.csv";
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--trials=")) trials = try std.fmt.parseInt(usize, arg["--trials=".len..], 10) else if (std.mem.startsWith(u8, arg, "--seed=")) seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16) else if (std.mem.startsWith(u8, arg, "--steps=")) steps = try std.fmt.parseInt(usize, arg["--steps=".len..], 10) else if (std.mem.startsWith(u8, arg, "--phases=")) phases = try std.fmt.parseInt(usize, arg["--phases=".len..], 10) else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..];
    }

    const refs = deriveRefs(seed);
    const laws = deriveLaws(seed);
    const envelope = interEnvelope(refs[0..]);
    const parent_clearance = if (ParentBestMinRef > envelope.max) ParentBestMinRef - envelope.max else 0;
    const child_target = ParentBestMinRef + 1;

    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var csv = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv.close();
    try csv.writer().writeAll("trial,min_ref_dist,mean_ref_dist,violations,frontier,score,past_parent,field_hash\n");

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== RECURSIVE CONCEPTLESS INVENTOR ===\n", .{});
    try stdout.print("imports=std_only parent_best_hash=0x{X} refs={d} envelope_min={d} envelope_mean={d:.1} envelope_max={d} parent_best={d} parent_clearance=+{d} child_target={d}\n", .{
        ParentBestHash,
        RefCount,
        envelope.min,
        envelope.mean,
        envelope.max,
        ParentBestMinRef,
        parent_clearance,
        child_target,
    });
    try stdout.print("steps={d} phases={d}\n", .{ steps, phases });
    try stdout.writeAll("trial | min_ref | mean  | violations | frontier | past_parent?\n");
    try stdout.writeAll("------|---------|-------|------------|----------|-------------\n");

    var past_parent: usize = 0;
    var best = Metrics{ .min_ref_dist = 0, .mean_ref_dist = 0, .violations = std.math.maxInt(usize), .frontier = 0, .score = std.math.minInt(i128) };
    var best_hash: u64 = 0;
    for (0..trials) |trial| {
        const trial_seed = childSeed(seed +% @as(u64, @intCast(trial)) *% 0xD1B54A32D192ED03);
        const result = invent(trial_seed, refs[0..], laws[0..], steps, phases);
        const m = result.metrics;
        const is_past_parent = m.min_ref_dist >= child_target;
        if (is_past_parent) past_parent += 1;
        const hash = fieldHash(result.field);
        if (m.score > best.score) {
            best = m;
            best_hash = hash;
        }
        try stdout.print("{d: >5} | {d: >7} | {d: >5.1} | {d: >10} | {d: >8} | {s}\n", .{
            trial,
            m.min_ref_dist,
            m.mean_ref_dist,
            m.violations,
            m.frontier,
            if (is_past_parent) "YES" else "no",
        });
        try csv.writer().print("{d},{d},{d:.4},{d},{d},{d},{d},0x{X}\n", .{
            trial,
            m.min_ref_dist,
            m.mean_ref_dist,
            m.violations,
            m.frontier,
            m.score,
            @intFromBool(is_past_parent),
            hash,
        });
    }

    const best_clearance = if (best.min_ref_dist > envelope.max) best.min_ref_dist - envelope.max else 0;
    try stdout.print("\nVERDICT: recursive_past_parent={d}/{d}; best_min_ref={d}; best_clearance=+{d}; best_violations={d}; best_score={d}; best_hash=0x{X}; csv={s}\n", .{
        past_parent,
        trials,
        best.min_ref_dist,
        best_clearance,
        best.violations,
        best.score,
        best_hash,
        csv_path,
    });
}
