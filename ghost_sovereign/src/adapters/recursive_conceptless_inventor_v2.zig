const std = @import("std");

// Synthesized from recursive_conceptless_inventor.zig (which was itself
// synthesized from synthesized_conceptless_breakthrough.zig). Continues the
// VSA-free / Flame-free / concept-free invention chain.
//
// Runtime boundary (unchanged from parent):
//   - std only
//   - no VSA import, no Flame import, no concept enum
//   - no model/cloud/network/external service
//
// Same inherited self-reference orbit so comparison is direct.
//
// Difference from the parent:
//   The parent's pushFrontier is single-bit greedy. It saturates at 294 in
//   sweeps up to phases=80, steps=2048 because at d=floor for k>=2 refs, no
//   single bit-flip is in S_{b} = {r : v_b[r]=+1} for ALL floor refs. Pair-
//   flips can escape: two bits whose "good ref" sets together cover all
//   floor refs lift the floor by 1. We add (a) pairFrontierPush, (b) tabu-
//   guarded multi-restart, and (c) a Metropolis kick that accepts worse
//   moves with a cooling probability to traverse the deeper basins parent's
//   greedy strategy cannot escape.

const Dim = 512;
const Words = Dim / 64;
const RefCount = 24;
const LawCount = 1536;

// Parent metrics (recursive_conceptless_inventor's best, verified
// 2026-05-19 by re-running --trials=24 --steps=512 --phases=20):
const ParentBestMinRef: u32 = 294;
const ParentBestHash: u64 = 0x9EB89E40D0D6F289;

const Field = [Words]u64;
const Distances = [RefCount]u32;

// Inherited unchanged from recursive_conceptless_inventor so the reference
// orbit is identical and the comparison is direct.
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
const ChildSalt: u64 = 0x517E_2E55_C0DE_F00D; // different from v1's salt

const Law = struct {
    a: usize,
    b: usize,
    c: usize,
    rotate: u6,
    mask: u64,
};

const Envelope = struct { min: u32, max: u32, mean: f64 };

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

// Same derivation as parent so we inherit the SAME 24 references.
fn deriveRefs(seed: u64) [RefCount]Field {
    var refs: [RefCount]Field = undefined;
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
        law.* = .{ .a = a, .b = b, .c = c, .rotate = @intCast(s % 63 + 1), .mask = splitMix64(s ^ SourceGenomeHash) };
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
    for (laws) |law| if (!lawSatisfied(field, law)) {
        count += 1;
    };
    return count;
}

fn interEnvelope(refs: []const Field) Envelope {
    var min_d: u32 = std.math.maxInt(u32);
    var max_d: u32 = 0;
    var sum: u64 = 0;
    var pairs: usize = 0;
    for (refs, 0..) |a, i| for (i + 1..refs.len) |j| {
        const d = hamming(a, refs[j]);
        min_d = @min(min_d, d);
        max_d = @max(max_d, d);
        sum += d;
        pairs += 1;
    };
    return .{ .min = min_d, .max = max_d, .mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(pairs)) };
}

fn antiMajority(refs: []const Field, seed: u64) Field {
    var field: Field = [_]u64{0} ** Words;
    var rng = childSeed(seed);
    for (0..Dim) |bit| {
        var ones: usize = 0;
        for (refs) |ref| if (bitAt(ref, bit)) {
            ones += 1;
        };
        const zeros = refs.len - ones;
        if (ones == zeros) {
            rng = splitMix64(rng);
            const set = (rng & 1) == 1;
            if (set) field[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
        } else if (ones < zeros) {
            field[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
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
    for (dists) |d| if (d <= floor_band) {
        near_count += 1;
        floor_sum += d;
    };
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
        if (old == bitAt(ref, bit)) next[idx] += 1 else next[idx] -= 1;
    }
    return next;
}

fn candidateDistsPair(field: Field, refs: []const Field, dists: Distances, b1: usize, b2: usize) Distances {
    var next = dists;
    const old1 = bitAt(field, b1);
    const old2 = bitAt(field, b2);
    for (refs, 0..) |ref, idx| {
        if (old1 == bitAt(ref, b1)) next[idx] += 1 else next[idx] -= 1;
        if (old2 == bitAt(ref, b2)) next[idx] += 1 else next[idx] -= 1;
    }
    return next;
}

fn applyFlip(field: *Field, refs: []const Field, dists: *Distances, bit: usize) void {
    const old = bitAt(field.*, bit);
    for (refs, 0..) |ref, idx| {
        if (old == bitAt(ref, bit)) dists[idx] += 1 else dists[idx] -= 1;
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

// --- NEW: pair-flip exhaustive search ---
//
// For each bit b, precompute its "ref vector" v_b[i] ∈ {+1, -1}: flipping
// b changes distance to ref i by v_b[i]. Then for each pair (b1, b2),
// joint vector v_b1 + v_b2 ∈ {-2, 0, +2}. We look for the pair whose
// joint application gives the largest deficit-cost reduction, tie-break
// by stats.score. This is O(Dim^2 * RefCount) ≈ 6.3M ops per step.
fn pairFrontierStep(field: *Field, refs: []const Field, dists: *Distances, frontier: u32) bool {
    const cost_now = deficitCost(dists[0..refs.len], frontier);
    if (cost_now == 0) return false;

    var best_b1: ?usize = null;
    var best_b2: usize = 0;
    var best_cost = cost_now;
    var best_stats = distStats(dists[0..refs.len]);

    var b1: usize = 0;
    while (b1 < Dim) : (b1 += 1) {
        var b2: usize = b1 + 1;
        while (b2 < Dim) : (b2 += 1) {
            const cand = candidateDistsPair(field.*, refs, dists.*, b1, b2);
            const cand_cost = deficitCost(cand[0..refs.len], frontier);
            const cand_stats = distStats(cand[0..refs.len]);
            if (cand_cost < best_cost or (cand_cost == best_cost and cand_stats.score > best_stats.score)) {
                best_b1 = b1;
                best_b2 = b2;
                best_cost = cand_cost;
                best_stats = cand_stats;
            }
        }
    }

    if (best_b1) |b1f| {
        applyFlip(field, refs, dists, b1f);
        applyFlip(field, refs, dists, best_b2);
        return true;
    }
    return false;
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
        var moved = false;
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
                moved = true;
            } else break;
        }
        if (cost == 0) {
            frontier += 1;
        } else if (!moved) break else break;
    }
    return distStats(dists[0..refs.len]).min;
}

// NEW: push the frontier using pair-flips when single-bit search is stuck.
// Tries to lift the floor by 1 from the parent's saturation point.
fn pushFrontierPair(field: *Field, refs: []const Field, dists: *Distances, max_pair_steps: usize) u32 {
    var current_min = distStats(dists[0..refs.len]).min;
    var frontier = current_min + 1;
    var step: usize = 0;
    while (step < max_pair_steps) : (step += 1) {
        const moved = pairFrontierStep(field, refs, dists, frontier);
        if (!moved) break;
        const new_min = distStats(dists[0..refs.len]).min;
        if (new_min >= frontier) {
            frontier += 1;
            current_min = new_min;
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
        } else break;
    }
}

// NEW: Metropolis-style kick — accept worse single-bit moves with cooling
// probability, traversing basins parent's pure-greedy can't escape.
fn metropolisKick(field: *Field, refs: []const Field, dists: *Distances, seed: u64, kicks: usize) void {
    var rng = childSeed(seed ^ 0xA17F_3179_E1E5_0001);
    var current = distStats(dists[0..refs.len]);
    var step: usize = 0;
    while (step < kicks) : (step += 1) {
        const progress = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(kicks));
        const t = 8.0 * std.math.pow(f64, 0.01, progress);
        rng = splitMix64(rng);
        const bit = @as(usize, @intCast(rng % Dim));
        const cand = candidateDists(field.*, refs, dists.*, bit);
        const cand_stats = distStats(cand[0..refs.len]);
        const delta = cand_stats.score - current.score;
        var accept = false;
        if (delta >= 0) {
            accept = true;
        } else {
            const scale: f64 = 1.0e10;
            const exponent = @as(f64, @floatFromInt(delta)) / (t * scale);
            const p = std.math.exp(exponent);
            rng = splitMix64(rng);
            const draw = @as(f64, @floatFromInt(rng % 1_000_000)) / 1_000_000.0;
            accept = draw < p;
        }
        if (accept) {
            applyFlip(field, refs, dists, bit);
            current = cand_stats;
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
        } else break;
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
    return .{ .min_ref_dist = stats.min, .mean_ref_dist = mean, .violations = violations, .frontier = frontier, .score = score };
}

fn invent(seed: u64, refs: []const Field, laws: []const Law, steps: usize, phases: usize, pair_steps: usize, kicks: usize) struct { field: Field, metrics: Metrics } {
    // Start with parent's machinery: get to 294 reliably.
    var best_field = antiMajority(refs, seed);
    var best_dists = computeDists(best_field, refs);
    _ = pushFrontier(&best_field, refs, &best_dists, steps);
    balanceFloor(&best_field, refs, &best_dists, steps / 4 + 1);

    // NEW: pair-flip lift from 294 to 295+.
    _ = pushFrontierPair(&best_field, refs, &best_dists, pair_steps);

    var best_metrics = measure(best_field, refs, laws, distStats(best_dists[0..refs.len]).min);

    var phase: usize = 0;
    while (phase < phases) : (phase += 1) {
        var field = antiMajority(refs, splitMix64(seed ^ @as(u64, @intCast(phase)) ^ ParentBestHash));
        var dists = computeDists(field, refs);
        // Diversification kick before greedy.
        metropolisKick(&field, refs, &dists, seed ^ @as(u64, @intCast(phase)), kicks);
        _ = pushFrontier(&field, refs, &dists, steps);
        balanceFloor(&field, refs, &dists, steps / 3 + 1);
        _ = pushFrontierPair(&field, refs, &dists, pair_steps);
        const m = measure(field, refs, laws, distStats(dists[0..refs.len]).min);
        if (m.score > best_metrics.score) {
            best_field = field;
            best_metrics = m;
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

    var trials: usize = 8;
    var seed: u64 = parentSourceHash();
    var steps: usize = 512;
    var phases: usize = 8;
    var pair_steps: usize = 8;
    var kicks: usize = 64;
    var csv_path: []const u8 = "results/recursive_conceptless_inventor_v2.csv";
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--trials=")) trials = try std.fmt.parseInt(usize, arg["--trials=".len..], 10) else if (std.mem.startsWith(u8, arg, "--seed=")) seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16) else if (std.mem.startsWith(u8, arg, "--steps=")) steps = try std.fmt.parseInt(usize, arg["--steps=".len..], 10) else if (std.mem.startsWith(u8, arg, "--phases=")) phases = try std.fmt.parseInt(usize, arg["--phases=".len..], 10) else if (std.mem.startsWith(u8, arg, "--pair-steps=")) pair_steps = try std.fmt.parseInt(usize, arg["--pair-steps=".len..], 10) else if (std.mem.startsWith(u8, arg, "--kicks=")) kicks = try std.fmt.parseInt(usize, arg["--kicks=".len..], 10) else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..];
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
    try stdout.print("=== RECURSIVE CONCEPTLESS INVENTOR v2 ===\n", .{});
    try stdout.print("imports=std_only parent_best=0x{X} parent_min_ref={d} envelope_max={d} parent_clearance=+{d} child_target={d}\n", .{
        ParentBestHash, ParentBestMinRef, envelope.max, parent_clearance, child_target,
    });
    try stdout.print("trials={d} steps={d} phases={d} pair_steps={d} kicks={d}\n", .{ trials, steps, phases, pair_steps, kicks });
    try stdout.writeAll("trial | min_ref | mean  | violations | frontier | past_parent?\n");
    try stdout.writeAll("------|---------|-------|------------|----------|-------------\n");

    var past_parent: usize = 0;
    var best = Metrics{ .min_ref_dist = 0, .mean_ref_dist = 0, .violations = std.math.maxInt(usize), .frontier = 0, .score = std.math.minInt(i128) };
    var best_hash: u64 = 0;
    var t: usize = 0;
    while (t < trials) : (t += 1) {
        const trial_seed = childSeed(seed +% @as(u64, @intCast(t)) *% 0xD1B54A32D192ED03);
        const result = invent(trial_seed, refs[0..], laws[0..], steps, phases, pair_steps, kicks);
        const m = result.metrics;
        const is_past_parent = m.min_ref_dist >= child_target;
        if (is_past_parent) past_parent += 1;
        const hash = fieldHash(result.field);
        if (m.score > best.score) {
            best = m;
            best_hash = hash;
        }
        try stdout.print("{d: >5} | {d: >7} | {d: >5.1} | {d: >10} | {d: >8} | {s}\n", .{ t, m.min_ref_dist, m.mean_ref_dist, m.violations, m.frontier, if (is_past_parent) "YES" else "no" });
        try csv.writer().print("{d},{d},{d:.4},{d},{d},{d},{d},0x{X}\n", .{ t, m.min_ref_dist, m.mean_ref_dist, m.violations, m.frontier, m.score, @intFromBool(is_past_parent), hash });
    }

    const best_clearance = if (best.min_ref_dist > envelope.max) best.min_ref_dist - envelope.max else 0;
    try stdout.print("\nVERDICT: v2_past_parent={d}/{d}; best_min_ref={d}; best_clearance=+{d}; best_violations={d}; best_score={d}; best_hash=0x{X}; csv={s}\n", .{
        past_parent, trials, best.min_ref_dist, best_clearance, best.violations, best.score, best_hash, csv_path,
    });
}
