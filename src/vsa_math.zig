const std = @import("std");

/// 4096-bit HyperVector represented as 64x 64-bit integers.
/// Phase 2: Latent Expansion — shattering the 1024-bit ceiling.
/// The expanded coordinate space eliminates holographic interference
/// during dense synthetic concept compression.
pub const HyperVector = @Vector(64, u64);

/// Number of data lanes (excluding parity)
pub const DATA_LANES: usize = 63;

/// Total number of lanes
pub const TOTAL_LANES: usize = 64;

/// Total bit width of data payload
pub const DATA_BITS: usize = DATA_LANES * 64; // 4032 bits of data

/// Parity lane index
pub const PARITY_LANE: usize = 63;

pub const Boundary = enum(u32) { none = 0, word = 1, phrase = 2, paragraph = 3, soul = 4 };

/// V30: Syntactic Boundary Detection (The "Bracket-Aware" Engine)
/// Automatically identifies context shifts based on structural runes.
pub fn detectSyntacticBoundary(rune: u32) Boundary {
    return switch (rune) {
        '{', '}', '\x0C' => .paragraph, // Form feed or braces = block context shift
        ';', ':', '(', ')', '[', ']', '.', '!', '?' => .phrase, // Statement/expression boundaries
        ' ', '\t', '\n', '\r', ',', '<', '>', '/', '\\', '|', '&' => .word, // Tokens
        else => .none,
    };
}

/// Calculate checksum parity for the HyperVector.
/// Uses the first 63 slots to generate a 64-bit checksum in slot 63.
/// NOTE: Detection-only. Cannot correct errors — only flags corruption.
pub fn generateParity(v: HyperVector) u64 {
    @setEvalBranchQuota(100000);
    var parity: u64 = 0;
    inline for (0..DATA_LANES) |i| {
        // Non-linear combination to maximize error detection
        parity ^= std.math.rotl(u64, v[i], @as(u6, @intCast(i * 3 % 64)));
        parity = parity *% 0xbf58476d1ce4e5b9;
    }
    return parity;
}

/// Verify HyperVector integrity via checksum comparison.
/// Returns false if corruption is detected (checksum mismatch).
pub fn isHealthy(v: HyperVector) bool {
    return v[PARITY_LANE] == generateParity(v);
}

// ── Role-Filler Binding Constants (Orthogonal Identities) ──
pub const ROLE_SUBJECT = generate(0x1234_5678_9ABC_DEF0);
pub const ROLE_OBJECT = generate(0x0FED_CBA9_8765_4321);
pub const ROLE_PREDICATE = generate(0x5555_5555_AAAA_AAAA);

// ── Orthogonal Namespace Masks ──
pub const MASK_SCRIBE = generate(0x55AA_55AA_55AA_55AA);
pub const MASK_CRITIC = generate(0xAA55_AA55_AA55_AA55);

// ── V33: Intent Route Vectors (Semantic Resonance Hooks) ──
// These vectors define the orthogonal axes of our cognitive routing space.
// They are used by the NeuralGipPacket to determine if a query is logical,
// sub-symbolic, or trivial.
pub const ROUTE_VEC_Z3     = generate(0x5555_AAAA_5555_AAAA); // LOGIC (Z3 Bridge)
pub const ROUTE_VEC_VSA    = generate(0xAAAA_5555_AAAA_5555); // SUB-SYMBOLIC (VSA/Search)
pub const ROUTE_VEC_SCALAR = generate(0x1234_4321_1234_4321); // TRIVIAL (Scalar/Social)

/// Hardware-accelerated concept generator.
/// Fills 63 data lanes via a hash chain, then computes parity in lane 63.
pub fn generate(seed: u64) HyperVector {
    @setEvalBranchQuota(100000);
    var v: HyperVector = undefined;
    var s = seed ^ 0x60bee2bee120fc15;
    const c1 = 0xa3b195354a39b70d;
    const c2 = 0x123456789abcdef0;

    // Unrolled for maximum pipeline saturation (first 63 data slots)
    inline for (0..DATA_LANES) |i| {
        s = (s ^ (s >> 33)) *% c1;
        s = (s ^ (s >> 33)) *% c2;
        s = s ^ (s >> 33);
        v[i] = s;
    }
    // Slot 63 is dedicated to the integrity checksum
    v[PARITY_LANE] = generateParity(v);
    return v;
}

/// Bitwise Binding (XOR) - 100% Symmetrical
pub inline fn bind(a: HyperVector, b: HyperVector) HyperVector {
    @setEvalBranchQuota(100000);
    var res = a ^ b;
    res[PARITY_LANE] = generateParity(res);
    return res;
}

pub inline fn bundle(a: HyperVector, b: HyperVector, c: HyperVector) HyperVector {
    @setEvalBranchQuota(100000);
    var res = (a & b) | (b & c) | (c & a);
    res[PARITY_LANE] = generateParity(res);
    return res;
}

/// N-Way Bitwise Bundling (Majority Rule across N vectors)
/// Sums the active bits across every lane and thresholds to a single vector.
pub fn bundleN(vectors: []const HyperVector) HyperVector {
    var res: HyperVector = undefined;
    const threshold = vectors.len / 2;
    
    for (0..DATA_LANES) |i| {
        var lane_res: u64 = 0;
        var bit: u6 = 0;
        while (true) {
            var count: usize = 0;
            for (vectors) |v| {
                if (((v[i] >> bit) & 1) == 1) {
                    count += 1;
                }
            }
            if (count > threshold) {
                lane_res |= (@as(u64, 1) << bit);
            }
            if (bit == 63) break;
            bit += 1;
        }
        res[i] = lane_res;
    }
    res[PARITY_LANE] = generateParity(res);
    return res;
}

/// Circular Permutation (Shift logic)
pub inline fn permute(v: HyperVector) HyperVector {
    @setEvalBranchQuota(100000);
    var result: HyperVector = undefined;
    // Architecture optimization: use rotl if available natively
    inline for (0..DATA_LANES) |i| {
        result[i] = std.math.rotl(u64, v[i], 19);
    }
    result[PARITY_LANE] = generateParity(result);
    return result;
}

/// Rotate HyperVector elements by N positions (used for fractal/spell push)
pub inline fn rotate(v: HyperVector, comptime n: comptime_int) HyperVector {
    @setEvalBranchQuota(100000);
    var result: HyperVector = undefined;
    // Note: Rotate only the first 63 data slots to preserve parity slot integrity
    inline for (0..DATA_LANES) |i| {
        result[i] = v[(i + n) % DATA_LANES];
    }
    result[PARITY_LANE] = generateParity(result);
    return result;
}

/// Collapse 4096-bit HyperVector to a 64-bit hash via XOR folding
pub inline fn collapse(v: HyperVector) u64 {
    @setEvalBranchQuota(100000);
    var acc: u64 = v[0];
    inline for (1..TOTAL_LANES) |i| {
        acc ^= v[i];
    }
    return acc;
}

/// Project the 4096-bit HyperVector to a 32-bit Locality-Sensitive Hash.
///
/// Algorithm: Majority-Thresholded Segment Projection
///   - For a 4096-bit vector (64 lanes of 64 bits), we sample 32 segments.
///   - Each segment is 128 bits (2 lanes). Count the set bits.
///   - If more than 64 bits are set (majority = 1), the projection bit is 1.
pub fn projectSpatialSignature(v: HyperVector) u32 {
    @setEvalBranchQuota(100000);
    var result: u32 = 0;
    inline for (0..32) |seg| {
        const lane_a = v[seg * 2];
        const lane_b = v[seg * 2 + 1];
        const pop = @popCount(lane_a) + @popCount(lane_b);
        if (pop > 64) {
            result |= @as(u32, 1) << @as(u5, @intCast(seg));
        }
    }
    return result;
}


// ── V32: Semantic-Uniform Double Hashing (SUDH) ──
// Combines Locality-Sensitive spatial projection with uniform FNV-1a dispersion
// to address the MeaningMatrix without suffering from Zipf's Law clustering.
//
// Architecture:
//   1. PRIMARY ANCHOR — The u32 spatial signature (from HyperRotor.projectSpatialSignature)
//      maps the concept to an "Ideal Neighborhood" of SUDH_NEIGHBORHOOD_SIZE slots.
//   2. SPILLOVER STRIDE — If the neighborhood is saturated, a uniform FNV-1a hash
//      provides a large, pseudo-random stride to jump to a distant region.
//   3. PROBE SEQUENCE — Up to SUDH_MAX_NEIGHBORHOODS neighborhoods are checked
//      before declaring "matrix saturated" for this concept.
//
// This guarantees:
//   - Similar concepts land in the same neighborhood (semantic locality)
//   - Common tokens don't choke a single region (uniform spillover)
//   - O(1) amortized addressing (constant probe depth in practice)

pub const SUDH_NEIGHBORHOOD_SIZE: u32 = 256;
pub const SUDH_MAX_NEIGHBORHOODS: u32 = 4;
pub const SUDH_MAX_PROBES: u32 = SUDH_NEIGHBORHOOD_SIZE * SUDH_MAX_NEIGHBORHOODS;

/// CPU-side probe depth for MeaningMatrix lookups (applyGravity, collapseToBinary, etc.).
/// 8 probes = up to 2 neighborhoods worth of sweep. Matches the original hardcoded depth.
pub const SUDH_CPU_PROBES: u32 = 8;

/// Compute the SUDH probe sequence for a given semantic context.
///
/// Parameters:
///   - spatial_sig:  u32 from HyperRotor.projectSpatialSignature()
///   - uniform_hash: u64 from the existing FNV-1a rotor (lexical or semantic)
///   - total_slots:  Total number of slots in the MeaningMatrix tag array
///
/// Returns a SudhAddress containing the base index and stride for the
/// double-hashing probe sequence.
///
/// The algorithm:
///   1. Compute the Ideal Neighborhood base from the spatial signature.
///      We multiply the signature by NEIGHBORHOOD_SIZE and mask to total_slots.
///      This groups similar projections into the same 256-slot block.
///   2. Compute a Uniform Stride from the FNV-1a hash.
///      The stride is forced odd (| 1) and further constrained to be at least
///      NEIGHBORHOOD_SIZE to guarantee the spillover jump lands in a different
///      neighborhood, not just a different slot in the same block.
///   3. The caller probes: slot = (base + probe_idx * stride) % total_slots
///      for probe_idx in [0, SUDH_MAX_PROBES).
pub const SudhAddress = struct {
    base: u32,
    stride: u32,

    /// Get the slot index for a given probe step.
    /// The caller is responsible for bounds-checking and tag comparison.
    pub inline fn probe(self: SudhAddress, step: u32, total_slots: u32) u32 {
        return (self.base +% step *% self.stride) % total_slots;
    }
};

pub fn computeSudhAddress(spatial_sig: u32, uniform_hash: u64, total_slots: u32) SudhAddress {
    // ── Primary Anchor: Semantic Locality ──
    const wide = @as(u64, spatial_sig) *% @as(u64, total_slots);
    const raw_base = @as(u32, @truncate(wide >> 32));
    const alignment_mask = ~(SUDH_NEIGHBORHOOD_SIZE - 1);
    const base = raw_base & alignment_mask;

    // ── Spillover Stride: Uniform Dispersion ──
    const raw_stride = @as(u32, @truncate(uniform_hash >> 32));
    const stride = @max(raw_stride | 1, SUDH_NEIGHBORHOOD_SIZE + 1) | 1;

    return .{
        .base = base,
        .stride = stride,
    };
}

/// Resonance score: alias for calculateResonance (used by engine noise measurement)
pub inline fn resonanceScore(expectation: HyperVector, reality: HyperVector) u16 {
    return calculateResonance(expectation, reality);
}

/// Calculate Resonance (Hamming Proximity)
/// Optimized via hardware POPCNT instructions.
/// At 4096 bits, max resonance is 4096, max distance is 4096.
pub inline fn calculateResonance(expectation: HyperVector, reality: HyperVector) u16 {
    @setEvalBranchQuota(100000);
    const diff = expectation ^ reality;
    var dist: u32 = 0;
    inline for (0..TOTAL_LANES) |i| {
        dist += @popCount(diff[i]);
    }
    return @as(u16, @intCast(4096 -| dist));
}

/// Hamming Distance (Raw Drift)
pub inline fn hammingDistance(a: HyperVector, b: HyperVector) u16 {
    @setEvalBranchQuota(100000);
    const diff = a ^ b;
    var dist: u32 = 0;
    inline for (0..TOTAL_LANES) |i| {
        dist += @popCount(diff[i]);
    }
    return @as(u16, @intCast(dist));
}

/// Split-half consistency check: independently measures Hamming drift in the
/// lower and upper 32-bit halves of each u64 lane, then gates on dual thresholds.
pub fn dualDriftCheck(current: HyperVector, primary: HyperVector, manager_limit: u64, critic_limit: u64) struct { passed: bool, manager_drift: u16, critic_drift: u16 } {
    const lo_mask: HyperVector = @splat(@as(u64, 0x00000000FFFFFFFF));
    const hi_mask: HyperVector = @splat(@as(u64, 0xFFFFFFFF00000000));
    const manager_drift = hammingDistance(current & lo_mask, primary & lo_mask);
    const critic_drift = hammingDistance(current & hi_mask, primary & hi_mask);

    return .{
        .passed = (manager_drift <= manager_limit) and (critic_drift <= critic_limit),
        .manager_drift = manager_drift,
        .critic_drift = critic_drift,
    };
}
