const std = @import("std");

/// The 4096-bit Vector Symbolic Architecture HyperVector.
/// Mapped natively to a 64-lane vector of 64-bit integers.
/// Compiles directly to AVX-512 / AVX2 SIMD instructions.
pub const HyperVector = @Vector(64, u64);

pub const LANES = 64;
pub const BITS = 4096;

/// Binding rotation amount, in bits, across the FULL 4096-bit space.
/// 257 = 4*64 + 1: it shifts by 4 whole lanes AND one bit, so information
/// crosses lane boundaries. (A multiple of 64 would only permute lanes; a
/// pure intra-lane rotate would never let lane L talk to lane L+1 — that was
/// the defect in the previous `@splat(7)` implementation.) 257 is prime, which
/// keeps the permutation from having a small cycle that re-aligns the vector.
pub const BIND_ROT_BITS: usize = 257;

/// Initializes an orthogonal HyperVector using a deterministic PRNG.
pub fn generateLexicon(seed: u64) HyperVector {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    var arr: [LANES]u64 = undefined;
    for (&arr) |*ptr| {
        ptr.* = rng.int(u64);
    }
    return arr;
}

/// Computes the Hamming distance between two vectors.
/// Calculates the number of differing bits across the 4096-bit hyperspace.
pub fn hammingDistance(a: HyperVector, b: HyperVector) usize {
    const xor_res = a ^ b;
    var distance: usize = 0;
    const arr: [LANES]u64 = xor_res;
    // Unrolled loop for optimal compiler auto-vectorization of popcount
    inline for (0..LANES) |i| {
        distance += @popCount(arr[i]);
    }
    return distance;
}

/// Bundles (Superposes) multiple sibling vectors into a single geometric centroid.
/// Uses a majority-rule threshold to keep the vector bipolar dense.
pub fn bundle(vectors: []const HyperVector) HyperVector {
    if (vectors.len == 0) return @as(HyperVector, @splat(0));
    if (vectors.len == 1) return vectors[0];

    var result: [LANES]u64 = undefined;

    // Calculate the majority vote bit by bit
    for (0..LANES) |lane| {
        var merged: u64 = 0;
        for (0..64) |bit| {
            var ones: usize = 0;
            const mask: u64 = @as(u64, 1) << @intCast(bit);
            for (vectors) |v| {
                if ((v[lane] & mask) != 0) ones += 1;
            }
            if (ones > vectors.len / 2) {
                merged |= mask;
            }
        }
        result[lane] = merged;
    }
    return result;
}

/// Left-rotate the WHOLE 4096-bit vector by `k` bit positions, crossing lane
/// boundaries. This is the permutation `rho` that gives binding its asymmetry.
/// Implemented as a funnel shift: a `@shuffle`-based lane rotation supplies the
/// two source lanes, and vector shifts splice the sub-lane bit offset.
/// Invertible: `rotlBits(v, k)` is undone by `rotlBits(v, BITS - k)`.
pub fn rotlBits(v: HyperVector, comptime k: usize) HyperVector {
    const kb = k % BITS;
    if (kb == 0) return v;
    const lane_off = kb / 64;
    const bit_off: u6 = @intCast(kb % 64);

    // out[i] = v[(i - lane_off) mod 64]
    const mask_cur: @Vector(LANES, i32) = comptime blk: {
        var m: [LANES]i32 = undefined;
        for (0..LANES) |i| m[i] = @intCast((i + 2 * LANES - lane_off) % LANES);
        break :blk m;
    };
    const cur = @shuffle(u64, v, v, mask_cur);
    if (bit_off == 0) return cur;

    // The bit that rotates out of lane (i-lane_off-1) carries into lane i.
    const mask_prev: @Vector(LANES, i32) = comptime blk: {
        var m: [LANES]i32 = undefined;
        for (0..LANES) |i| m[i] = @intCast((i + 2 * LANES - lane_off - 1) % LANES);
        break :blk m;
    };
    const prev = @shuffle(u64, v, v, mask_prev);

    const hi = cur << @as(@Vector(LANES, u6), @splat(bit_off));
    const lo = prev >> @as(@Vector(LANES, u6), @splat(@intCast(64 - @as(u32, bit_off))));
    return hi | lo;
}

/// Binds a parent vector to a child vector.
/// Asymmetric binding: `rho(parent) XOR child`, where `rho` is a full-width
/// 4096-bit rotation (so the binding genuinely mixes information across lanes).
/// XOR makes the operation self-inverse given the same parent permutation.
pub fn bind(parent: HyperVector, child: HyperVector) HyperVector {
    return rotlBits(parent, BIND_ROT_BITS) ^ child;
}

/// Recover the child from a bound vector and the known parent.
/// child = rho(parent) XOR bound.
pub fn unbindChild(parent: HyperVector, bound: HyperVector) HyperVector {
    return rotlBits(parent, BIND_ROT_BITS) ^ bound;
}

/// Recover the parent from a bound vector and the known child.
/// rho(parent) = bound XOR child  =>  parent = rho^{-1}(bound XOR child).
pub fn unbindParent(bound: HyperVector, child: HyperVector) HyperVector {
    return rotlBits(bound ^ child, BITS - BIND_ROT_BITS);
}

/// Statistics of the Hamming-distance distribution over a sample of independent
/// hypervectors. Used to set the clustering threshold from data instead of a
/// magic constant.
pub const DistanceStats = struct {
    mean: f64,
    stddev: f64,
    samples: usize,

    /// Threshold = mean - k*sigma. A pair closer than this is `k` standard
    /// deviations nearer than two unrelated vectors would be by chance, so the
    /// probability of a false cluster falls off (roughly) with the normal tail
    /// of `k`.
    pub fn thresholdAt(self: DistanceStats, k_sigma: f64) usize {
        const t = self.mean - k_sigma * self.stddev;
        if (t < 0) return 0;
        return @intFromFloat(@round(t));
    }
};

/// Calibrate the distance distribution empirically: generate `n` independent
/// hypervectors from `seed_base` and measure all pairwise Hamming distances.
/// For truly random 4096-bit vectors the mean is ~2048 with stddev ~32; this
/// reports what THIS generator actually produces.
pub fn calibrate(seed_base: u64, n: usize) DistanceStats {
    std.debug.assert(n >= 2);
    var vecs: [256]HyperVector = undefined;
    const count = @min(n, vecs.len);
    for (0..count) |i| {
        vecs[i] = generateLexicon(seed_base +% @as(u64, @intCast(i)) *% 0x9E3779B97F4A7C15);
    }

    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    var pairs: usize = 0;
    for (0..count) |i| {
        for (i + 1..count) |j| {
            const d: f64 = @floatFromInt(hammingDistance(vecs[i], vecs[j]));
            sum += d;
            sum_sq += d * d;
            pairs += 1;
        }
    }
    const mean = sum / @as(f64, @floatFromInt(pairs));
    const variance = sum_sq / @as(f64, @floatFromInt(pairs)) - mean * mean;
    return .{
        .mean = mean,
        .stddev = @sqrt(@max(variance, 0)),
        .samples = pairs,
    };
}

test "rotlBits is invertible" {
    const v = generateLexicon(0xDEADBEEF);
    const rotated = rotlBits(v, BIND_ROT_BITS);
    const back = rotlBits(rotated, BITS - BIND_ROT_BITS);
    try std.testing.expect(@reduce(.And, v == back));
}

test "bind crosses lanes" {
    // A single bit set in lane 0 must, after binding, influence a DIFFERENT
    // lane. The old per-lane rotate could never do this.
    var parent_arr: [LANES]u64 = [_]u64{0} ** LANES;
    parent_arr[0] = 1;
    const parent: HyperVector = parent_arr;
    const child: HyperVector = @splat(0);
    const bound = bind(parent, child); // = rho(parent)
    const arr: [LANES]u64 = bound;
    // 257 bits left => bit lands in lane 4 (257/64 = 4), bit 1 (257%64 = 1).
    try std.testing.expect(arr[0] == 0);
    try std.testing.expectEqual(@as(u64, 1) << 1, arr[4]);
}

test "unbind recovers operands" {
    const parent = generateLexicon(1);
    const child = generateLexicon(2);
    const bound = bind(parent, child);
    try std.testing.expect(@reduce(.And, unbindChild(parent, bound) == child));
    try std.testing.expect(@reduce(.And, unbindParent(bound, child) == parent));
}

test "calibrate reports near-2048 mean for random vectors" {
    const stats = calibrate(0xC0FFEE, 64);
    // Random 4096-bit vectors: expected mean 2048.
    try std.testing.expect(stats.mean > 1990 and stats.mean < 2106);
    try std.testing.expect(stats.stddev > 10 and stats.stddev < 60);
}
