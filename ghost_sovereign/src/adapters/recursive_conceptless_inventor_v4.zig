const std = @import("std");

const Dim = 512;
const Words = Dim / 64;
const RefCount = 24;
const LawCount = 1536;
const Population = 64;

const ParentBestMinRef: u32 = 296;
const ParentBestHash: u64 = 0x5412E401A4765E9E;

const Field = [Words]u64;
const Distances = [RefCount]u32;
const DistStats = struct { min: u32, sum: u32, score: i128 };
const Candidate = struct {
    field: Field,
    pattern: u64,
    stats: DistStats,
};

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
const ChildSalt: u64 = 0x517E_2E55_C0DE_F00D;

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

fn deriveRefs(seed: u64) [RefCount]Field {
    var refs: [RefCount]Field = undefined;
    var s = seed ^ parentSourceHash();
    for (&refs, 0..) |*ref, idx| {
        s = splitMix64(s ^ @as(u64, @intCast(idx)));
        ref.* = randomField(s);
    }
    return refs;
}

fn antiMajority(refs: []const Field, seed: u64) Field {
    var field: Field = [_]u64{0} ** Words;
    var rng = childSeed(seed);
    for (0..Dim) |bit| {
        var ones: usize = 0;
        for (refs) |ref| {
            if (((ref[bit / 64] >> @intCast(bit % 64)) & 1) != 0) ones += 1;
        }
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

fn distStats(dists: []const u32) DistStats {
    var min_d: u32 = std.math.maxInt(u32);
    var sum: u32 = 0;
    for (dists) |d| {
        min_d = @min(min_d, d);
        sum += d;
    }
    var near_count: usize = 0;
    const floor_band = min_d + 3;
    for (dists) |d| if (d <= floor_band) {
        near_count += 1;
    };
    const score =
        @as(i128, @intCast(min_d)) * 1_000_000_000_000 -
        @as(i128, @intCast(near_count)) * 1_000_000_000 +
        @as(i128, @intCast(sum)) * 1_000;
    return .{ .min = min_d, .sum = sum, .score = score };
}

fn measureCandidate(field: Field, pattern: u64, refs: []const Field) Candidate {
    var dists: Distances = undefined;
    for (refs, 0..) |ref, idx| dists[idx] = hamming(field, ref);
    return .{ .field = field, .pattern = pattern, .stats = distStats(dists[0..refs.len]) };
}

fn dominates(a: DistStats, b: DistStats) bool {
    return a.min >= b.min and a.sum >= b.sum and (a.min > b.min or a.sum > b.sum);
}

fn worstIndex(pool: *const [Population]Candidate, count: usize) usize {
    var worst: usize = 0;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        if (pool[i].stats.min < pool[worst].stats.min or
            (pool[i].stats.min == pool[worst].stats.min and pool[i].stats.sum < pool[worst].stats.sum))
        {
            worst = i;
        }
    }
    return worst;
}

fn consider(pool: *[Population]Candidate, count: *usize, child: Candidate) bool {
    var i: usize = 0;
    while (i < count.*) : (i += 1) {
        if (dominates(pool[i].stats, child.stats)) return false;
    }

    i = 0;
    while (i < count.*) : (i += 1) {
        if (dominates(child.stats, pool[i].stats)) {
            pool[i] = child;
            return true;
        }
    }

    if (count.* < Population) {
        pool[count.*] = child;
        count.* += 1;
        return true;
    }

    const worst = worstIndex(pool, count.*);
    if (child.stats.score > pool[worst].stats.score) {
        pool[worst] = child;
        return true;
    }
    return false;
}

fn bestCandidate(pool: *const [Population]Candidate, count: usize) Candidate {
    var best = pool[0];
    var i: usize = 1;
    while (i < count) : (i += 1) {
        if (pool[i].stats.min > best.stats.min or
            (pool[i].stats.min == best.stats.min and pool[i].stats.sum > best.stats.sum))
        {
            best = pool[i];
        }
    }
    return best;
}

fn runPareto(stdout: anytype, trials: usize, steps: usize) !void {
    const refs = deriveRefs(0x9E3779B97F4A7C15);
    var pool: [Population]Candidate = undefined;
    var count: usize = 0;
    var rng = splitMix64(parentSourceHash() ^ ChildSalt ^ 0xFAE_E70);

    var seed_idx: usize = 0;
    const init_count = @max(@min(trials, Population), @as(usize, 1));
    while (seed_idx < init_count) : (seed_idx += 1) {
        var field = antiMajority(&refs, @as(u64, @intCast(seed_idx)));
        rng = splitMix64(rng);
        const pattern = splitMix64(rng);
        if ((rng & 1) == 1) field[@as(usize, @intCast(rng % Words))] ^= pattern;
        _ = consider(&pool, &count, measureCandidate(field, pattern, &refs));
    }

    var best = bestCandidate(&pool, count);
    try stdout.print("Initial Pareto pool={d} best_min_ref={d} spread_sum={d}\n", .{ count, best.stats.min, best.stats.sum });

    var step: usize = 0;
    while (step < steps) : (step += 1) {
        rng = splitMix64(rng);
        const parent_idx = @as(usize, @intCast(rng % count));
        var child = pool[parent_idx];

        rng = splitMix64(rng);
        if ((rng & 3) == 0) {
            const bit = @as(u6, @intCast(rng % 64));
            child.pattern ^= @as(u64, 1) << bit;
        } else {
            const w = @as(usize, @intCast(rng % Words));
            child.field[w] ^= child.pattern;
        }

        child = measureCandidate(child.field, child.pattern, &refs);
        _ = consider(&pool, &count, child);
        const current = bestCandidate(&pool, count);
        if (current.stats.min > best.stats.min or
            (current.stats.min == best.stats.min and current.stats.sum > best.stats.sum))
        {
            best = current;
            try stdout.print("Pareto step {d}: best_min_ref={d} spread_sum={d} pattern={X:0>16}\n", .{
                step,
                best.stats.min,
                best.stats.sum,
                best.pattern,
            });
        }
    }

    try stdout.print("\nPareto best min ref: {d} spread_sum={d}\n", .{ best.stats.min, best.stats.sum });
    if (best.stats.min > ParentBestMinRef) {
        try stdout.print("VERDICT: BROKE CEILING! {d} > {d}\n", .{ best.stats.min, ParentBestMinRef });
    } else {
        try stdout.print("VERDICT: FAILED to break ceiling. {d} <= {d}\n", .{ best.stats.min, ParentBestMinRef });
    }
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== RECURSIVE CONCEPTLESS INVENTOR V4 ===\n", .{});
    try stdout.print("Operator: Block-flip SA (Learned 64-bit Pattern XOR)\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var trials: usize = 8;
    var steps: usize = 200000;
    var pareto = false;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--trials=")) trials = try std.fmt.parseInt(usize, arg["--trials=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--steps=")) steps = try std.fmt.parseInt(usize, arg["--steps=".len..], 10)
        else if (std.mem.eql(u8, arg, "--pareto")) pareto = true;
    }

    if (pareto) {
        try stdout.print("Operator: Pareto block-flip MOEA (min_ref + spread_sum)\n\n", .{});
        try runPareto(stdout, trials, steps);
        return;
    }

    const refs = deriveRefs(0x9E3779B97F4A7C15);

    var best_min: u32 = 0;
    
    var t: usize = 0;
    while (t < trials) : (t += 1) {
        var field = antiMajority(&refs, @as(u64, @intCast(t)));
        var dists: Distances = undefined;
        for (refs, 0..) |ref, idx| dists[idx] = hamming(field, ref);
        var stats = distStats(dists[0..refs.len]);
        
        var pattern: u64 = 0;
        var rng = splitMix64(parentSourceHash() ^ @as(u64, @intCast(t)));
        
        var s: usize = 0;
        while (s < steps) : (s += 1) {
            rng = splitMix64(rng);
            const mode = rng % 4;
            if (mode == 0) {
                // Mutate pattern
                rng = splitMix64(rng);
                const bit = @as(u6, @intCast(rng % 64));
                pattern ^= (@as(u64, 1) << bit);
            } else {
                // Apply pattern
                rng = splitMix64(rng);
                const w = @as(usize, @intCast(rng % Words));
                field[w] ^= pattern;
                
                var new_dists: Distances = undefined;
                for (refs, 0..) |ref, idx| new_dists[idx] = hamming(field, ref);
                const new_stats = distStats(new_dists[0..refs.len]);
                
                if (new_stats.score >= stats.score) {
                    dists = new_dists;
                    stats = new_stats;
                } else {
                    // Revert
                    field[w] ^= pattern;
                }
            }
            if (stats.min > best_min) {
                best_min = stats.min;
                try stdout.print("Trial {d} step {d}: new best min_ref = {d} (pattern = {X:0>16})\n", .{ t, s, best_min, pattern });
            }
        }
        try stdout.print("Trial {d} finished. Min ref = {d}\n", .{ t, stats.min });
    }
    
    try stdout.print("\nGlobal best min ref: {d}\n", .{ best_min });
    if (best_min > ParentBestMinRef) {
        try stdout.print("VERDICT: BROKE CEILING! {d} > {d}\n", .{ best_min, ParentBestMinRef });
    } else {
        try stdout.print("VERDICT: FAILED to break ceiling. {d} <= {d}\n", .{ best_min, ParentBestMinRef });
    }
}
