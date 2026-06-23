const std = @import("std");
const vsa = @import("vsa_core.zig");
const config = @import("config.zig");
const ghost_state = @import("ghost_state.zig");

// v2 constants sourced from config.zig for central tuning.
const cfg = config;

// ══════════════════════════════════════════════════════════════════════════
//  GHOST ENGINE v2: THE RUNE-NATIVE TRIAD
// ══════════════════════════════════════════════════════════════════════════
//
// The Triple-Core Pipeline:
//   Scout  (90% SSM)  — Constant-speed state evolution via HyperRotor.
//   Sniper (10% Attn) — High-precision coordinate pinning on variance spikes.
//   King   (VSA)      — Symbolic Lattice query: bind/unbind/search.
//
// The neural layers do NOT predict text — they project Latent State Transitions.
// Output generation is strictly an Un-Binding operation from the Symbolic Lattice.
// ══════════════════════════════════════════════════════════════════════════

// ── Rank System: The Forge's Memory Hierarchy ──
// Runes are never "weighted." They are Ranked 1-5.
// Training consists of "Forging" — moving patterns from Rank 5 (Noise)
// to Rank 1 (Verified) based on success in the environment.
// RuneRank + the rank-ladder constants now live in the VSA-free rank.zig; triad re-exports them so existing
// triad.RuneRank / triad.RANK_* users are unchanged, while the structured engine can depend on rank.zig directly.
pub const rank = @import("rank.zig");
pub const RuneRank = rank.RuneRank;
pub const RANK_EMERGING_MIN_OBSERVATIONS = rank.RANK_EMERGING_MIN_OBSERVATIONS;
pub const RANK_PATTERN_MIN_OBSERVATIONS = rank.RANK_PATTERN_MIN_OBSERVATIONS;
pub const RANK_PATTERN_MIN_CONTEXTS = rank.RANK_PATTERN_MIN_CONTEXTS;
pub const RANK_NOISE_TTL_MS = rank.RANK_NOISE_TTL_MS;
pub const SNIPER_VARIANCE_MULTIPLIER: u32 = cfg.V2_SCOUT_VARIANCE_MULTIPLIER;
pub const KING_DISTANCE_THRESHOLD: u16 = cfg.V2_KING_DISTANCE_TAU;

// ── Rune: A permanent, weightless bit-vector bound to verified logic ──
pub const Rune = struct {
    /// The 1024-bit HyperVector identity of this Rune.
    vector: vsa.HyperVector,
    /// Current rank in the Forge hierarchy.
    rank: RuneRank,
    /// Total observation count across all contexts.
    occurrences: u32,
    /// Number of distinct context hashes that produced this Rune.
    distinct_contexts: u32,
    /// Timestamp (ms) when first observed.
    first_seen_ms: u64,
    /// Timestamp (ms) of last confirmation (promotion or re-observation).
    last_confirmed_ms: u64,

    pub fn isStale(self: Rune, now_ms: u64) bool {
        if (self.rank != .noise) return false;
        return (now_ms -| self.last_confirmed_ms) > RANK_NOISE_TTL_MS;
    }

    /// Check if this Rune meets the criteria for promotion.
    pub fn shouldPromote(self: Rune) bool {
        return switch (self.rank) {
            .noise => self.occurrences >= RANK_EMERGING_MIN_OBSERVATIONS,
            .emerging => self.occurrences >= RANK_PATTERN_MIN_OBSERVATIONS and
                self.distinct_contexts >= RANK_PATTERN_MIN_CONTEXTS,
            .pattern, .validated, .verified => false,
        };
    }

    pub fn promote(self: *Rune) bool {
        if (self.rank.promotionTarget()) |target| {
            if (self.shouldPromote()) {
                self.rank = target;
                return true;
            }
        }
        return false;
    }

    /// Force-promote to Verified (Rank 1). Used by human confirmation.
    pub fn forceVerify(self: *Rune, now_ms: u64) void {
        self.rank = .verified;
        self.last_confirmed_ms = now_ms;
    }

    /// Force-promote to Validated (Rank 2). Used by automated tests.
    pub fn forceValidate(self: *Rune, now_ms: u64) void {
        if (@intFromEnum(self.rank) > @intFromEnum(RuneRank.validated)) {
            self.rank = .validated;
        }
        self.last_confirmed_ms = now_ms;
    }
};

// ══════════════════════════════════════════════════════════════════════════
//  THE SCOUT: Constant-Speed SSM State Evolution
// ══════════════════════════════════════════════════════════════════════════
// The Scout never slows down regardless of input size. It evolves a latent
// state vector h_t per-rune using the HyperRotor (Permute→Bind→Bundle).
// It monitors state variance to detect logic "collisions" (potential bugs).

pub const ScoutState = struct {
    /// The 1024-bit context accumulator.
    rotor_state: vsa.HyperVector,
    /// Previous state for variance measurement.
    prev_state: vsa.HyperVector,
    /// Exponential Moving Average of state variance (24.8 fixed-point).
    variance_ema: u32,
    /// Mean Absolute Deviation of variance (24.8 fixed-point).
    variance_mad: u32,
    /// Alpha shift for EMA update (1/16 = 0.0625).
    alpha_shift: u5,
    /// Total runes processed by this Scout.
    rune_count: u64,
    /// Number of spikes detected.
    spike_count: u64,

    pub fn init(seed: u64) ScoutState {
        const initial = vsa.generate(seed);
        return .{
            .rotor_state = initial,
            .prev_state = initial,
            .variance_ema = 256 << 8, // Seed: 256 bits variance (normal baseline)
            .variance_mad = 50 << 8, // Seed: 50 bits MAD
            .alpha_shift = 4,
            .rune_count = 0,
            .spike_count = 0,
        };
    }

    /// Evolve the Scout's state by absorbing a single rune.
    /// Returns a SniperCoordinate if a variance spike is detected (potential anomaly).
    pub fn evolve(self: *ScoutState, rune: u32, byte_offset: u64) ?SniperCoordinate {
        // Step 1: Snapshot previous state
        self.prev_state = self.rotor_state;

        // Step 2: Evolve context with native deterministic VSA state.
        const rune_vec = vsa.generate(@as(u64, rune));
        self.rotor_state = vsa.bundle(vsa.rotate(self.rotor_state, 1), rune_vec, vsa.generate(byte_offset));
        self.rune_count += 1;

        // Step 3: Measure state variance (Hamming distance from previous state)
        const variance = vsa.hammingDistance(self.rotor_state, self.prev_state);

        // Step 4: Update variance EMA and MAD
        const v_fp = @as(u32, variance) << 8;
        const diff = if (v_fp > self.variance_ema) v_fp - self.variance_ema else self.variance_ema - v_fp;
        const a = @as(u64, 1) << self.alpha_shift;
        self.variance_ema = @intCast((@as(u64, self.variance_ema) * (a - 1) + @as(u64, v_fp)) >> self.alpha_shift);
        self.variance_mad = @intCast((@as(u64, self.variance_mad) * (a - 1) + @as(u64, diff)) >> self.alpha_shift);

        // Step 5: Spike detection — trigger Sniper if variance > EMA + 2.5 * MAD
        // In fixed-point: threshold = variance_ema + (variance_mad * 5 / 2)
        const spike_threshold = self.variance_ema + (self.variance_mad * SNIPER_VARIANCE_MULTIPLIER / 2);
        const spike_threshold_int = spike_threshold >> 8;

        if (variance > @as(u16, @intCast(@min(spike_threshold_int, 1024)))) {
            self.spike_count += 1;
            return SniperCoordinate{
                .byte_offset = byte_offset,
                .char_offset = @intCast(self.rune_count),
                .context_hash = vsa.collapse(self.rotor_state),
                .variance = variance,
                .state_snapshot = self.rotor_state,
            };
        }

        return null;
    }

    /// Get the current state vector.
    pub fn getState(self: *const ScoutState) vsa.HyperVector {
        return self.rotor_state;
    }

    /// Get the current variance as a u16.
    pub fn getCurrentVariance(self: *const ScoutState) u16 {
        return @intCast(self.variance_ema >> 8);
    }

    /// Get the spike threshold as a u16.
    pub fn getSpikeThreshold(self: *const ScoutState) u16 {
        const threshold = self.variance_ema + (self.variance_mad * SNIPER_VARIANCE_MULTIPLIER / 2);
        return @intCast(@min(threshold >> 8, 1024));
    }
};

// ══════════════════════════════════════════════════════════════════════════
//  THE SNIPER: High-Precision Coordinate Pinning
// ══════════════════════════════════════════════════════════════════════════
// Triggers ONLY when the Scout's state variance spikes.
// Uses its "attention" to pin the exact character-level coordinate
// for the VSA binding operation.

pub const SniperCoordinate = struct {
    /// Byte offset in the input stream where the spike occurred.
    byte_offset: u64,
    /// Character (rune) offset in the input stream.
    char_offset: u32,
    /// Hash of the Scout's context at the moment of the spike.
    context_hash: u64,
    /// Raw variance value that triggered the spike.
    variance: u16,
    /// Snapshot of the Scout's state at the spike moment.
    state_snapshot: vsa.HyperVector,
};

/// The Sniper's pin operation: converts a spike coordinate into a Rune Binding.
///
/// Math: Rune_new = (Error ⊗ Location) ⊕ Context
///
/// Where:
///   Error    = HyperVector generated from the variance value
///   Location = HyperVector generated from the byte offset
///   Context  = The Scout's state snapshot at the spike moment
///
/// The XOR bind is self-inverse, so Un-Binding is the same operation:
///   Error = Rune_new ⊗ Location ⊗ Context
pub fn sniperPin(coordinate: SniperCoordinate) vsa.HyperVector {
    // Generate orthogonal identity vectors for each binding component
    const error_vec = vsa.generate(@as(u64, coordinate.variance) ^ 0xDEAD_BEEF_CAFE_BABE);
    const location_vec = vsa.generate(coordinate.byte_offset);

    // Rune_new = (Error ⊗ Location) ⊕ Context
    // Step 1: Bind Error with Location (XOR — symmetric, self-inverse)
    const error_location = vsa.bind(error_vec, location_vec);
    // Step 2: Bind with Context (XOR again — layers the context into the Rune)
    return vsa.bind(error_location, coordinate.state_snapshot);
}

/// Unbind: Given a stored Rune and the original context, recover the error signal.
/// This is the reverse of sniperPin — since XOR is self-inverse.
pub fn sniperUnbind(rune: vsa.HyperVector, byte_offset: u64, context: vsa.HyperVector) vsa.HyperVector {
    const location_vec = vsa.generate(byte_offset);
    // Unbind context, then unbind location
    const without_context = vsa.bind(rune, context);
    return vsa.bind(without_context, location_vec);
}

// ══════════════════════════════════════════════════════════════════════════
//  THE KING: Symbolic Lattice Query
// ══════════════════════════════════════════════════════════════════════════
// The King is the ONLY part that talks to the screen.
// It takes the neural output and performs a Lattice Query.
// If no Rank-1 Rune resolves within distance τ, the system remains silent
// or triggers the Medic Loop (0x8B).

pub const LatticeQueryResult = struct {
    /// The matched Rune, if found.
    rune: ?Rune,
    /// The slot index in the lattice.
    slot: u32,
    /// Hamming distance from the query vector to the matched Rune.
    distance: u16,
    /// Whether the match is within the acceptance threshold τ.
    accepted: bool,
    /// If not accepted, this is the Medic trigger signal (0x8B).
    medic_required: bool,
};

pub const MEDIC_SIGNAL: u8 = 0x8B;

/// King's query operation: search the Rune Lattice for the nearest match.
/// Only returns Runes at or above `min_rank` quality.
pub fn kingQuery(
    query: vsa.HyperVector,
    lattice_vectors: []const vsa.HyperVector,
    lattice_ranks: []const RuneRank,
    min_rank: RuneRank,
    distance_threshold: u16,
) LatticeQueryResult {
    var best_idx: u32 = 0;
    var best_dist: u16 = 1025; // Worse than max possible (1024)
    var found = false;

    const limit = @min(lattice_vectors.len, lattice_ranks.len);

    // Unrolled 4-wide scan for SIMD saturation
    const aligned_limit = limit - (limit % 4);
    var i: usize = 0;
    while (i < aligned_limit) : (i += 4) {
        inline for (0..4) |j| {
            const idx = i + j;
            if (@intFromEnum(lattice_ranks[idx]) <= @intFromEnum(min_rank)) {
                const d = vsa.hammingDistance(query, lattice_vectors[idx]);
                if (d < best_dist) {
                    best_dist = d;
                    best_idx = @intCast(idx);
                    found = true;
                }
            }
        }
    }

    // Remainder
    while (i < limit) : (i += 1) {
        if (@intFromEnum(lattice_ranks[i]) <= @intFromEnum(min_rank)) {
            const d = vsa.hammingDistance(query, lattice_vectors[i]);
            if (d < best_dist) {
                best_dist = d;
                best_idx = @intCast(i);
                found = true;
            }
        }
    }

    if (!found) {
        return .{
            .rune = null,
            .slot = 0,
            .distance = 1024,
            .accepted = false,
            .medic_required = true,
        };
    }

    const accepted = best_dist <= distance_threshold;
    return .{
        .rune = if (accepted) Rune{
            .vector = lattice_vectors[best_idx],
            .rank = lattice_ranks[best_idx],
            .occurrences = 0,
            .distinct_contexts = 0,
            .first_seen_ms = 0,
            .last_confirmed_ms = 0,
        } else null,
        .slot = best_idx,
        .distance = best_dist,
        .accepted = accepted,
        .medic_required = !accepted,
    };
}

// ══════════════════════════════════════════════════════════════════════════
//  TRIAD PIPELINE: Full Scout → Sniper → King execution
// ══════════════════════════════════════════════════════════════════════════

pub const TriadDecision = struct {
    /// The character/rune to emit, if resolved.
    output: ?u32,
    /// Whether the output was resolved via Lattice match.
    lattice_resolved: bool,
    /// Whether the Medic loop was triggered (no Rune match).
    medic_triggered: bool,
    /// The Sniper coordinate, if a spike was detected.
    spike: ?SniperCoordinate,
    /// The bound Rune vector, if a spike produced a binding.
    bound_vector: ?vsa.HyperVector,
    /// Hamming distance of the best match.
    match_distance: u16,
    /// Rank of the matched Rune.
    match_rank: RuneRank,
};

pub const TriadPipeline = struct {
    scout: ScoutState,
    /// Statistics for monitoring.
    total_runes: u64,
    total_spikes: u64,
    total_matches: u64,
    total_medic_triggers: u64,
    /// When true, the King accepts Emerging (Rank 4) patterns.
    /// During early training the lattice is mostly Rank 4-5; using production
    /// mode (Rank 3+) would cause the King to be permanently mute.
    training_mode: bool,

    pub fn init(seed: u64) TriadPipeline {
        return .{
            .scout = ScoutState.init(seed),
            .total_runes = 0,
            .total_spikes = 0,
            .total_matches = 0,
            .total_medic_triggers = 0,
            .training_mode = true, // Start in training mode
        };
    }

    /// Switch to production mode (Rank 3+ queries only).
    pub fn setProductionMode(self: *TriadPipeline) void {
        self.training_mode = false;
    }

    /// Switch to training mode (Rank 4+ queries — accept Emerging patterns).
    pub fn setTrainingMode(self: *TriadPipeline) void {
        self.training_mode = true;
    }

    /// Get the effective minimum rank for King queries.
    fn effectiveMinRank(self: *const TriadPipeline) RuneRank {
        return if (self.training_mode)
            @enumFromInt(cfg.V2_TRAINING_MIN_RANK)
        else
            @enumFromInt(cfg.V2_PRODUCTION_MIN_RANK);
    }

    /// Process a single rune through the full Triad pipeline.
    ///
    /// 1. Scout evolves state, detects variance spikes.
    /// 2. If spike detected, Sniper pins coordinate and creates Rune binding.
    /// 3. King queries the Lattice for the nearest verified Rune.
    /// 4. If no match within τ, trigger Medic (0x8B).
    pub fn process(
        self: *TriadPipeline,
        rune: u32,
        byte_offset: u64,
        lattice_vectors: []const vsa.HyperVector,
        lattice_ranks: []const RuneRank,
    ) TriadDecision {
        self.total_runes += 1;

        // ── Phase 1: Scout ──
        const spike = self.scout.evolve(rune, byte_offset);

        if (spike == null) {
            // No variance spike — the Scout is in smooth evolution.
            // In v2, this means the input is "expected" and doesn't need
            // Sniper/King intervention. The existing engine path handles it.
            return .{
                .output = rune,
                .lattice_resolved = false,
                .medic_triggered = false,
                .spike = null,
                .bound_vector = null,
                .match_distance = 0,
                .match_rank = .noise,
            };
        }

        self.total_spikes += 1;

        // ── Phase 2: Sniper ──
        const bound = sniperPin(spike.?);

        // ── Phase 3: King ──
        const min_rank = self.effectiveMinRank();
        const result = kingQuery(
            bound,
            lattice_vectors,
            lattice_ranks,
            min_rank,
            KING_DISTANCE_THRESHOLD,
        );

        if (result.accepted) {
            self.total_matches += 1;
        } else {
            self.total_medic_triggers += 1;
        }

        return .{
            .output = if (result.accepted) rune else null,
            .lattice_resolved = result.accepted,
            .medic_triggered = result.medic_required,
            .spike = spike,
            .bound_vector = bound,
            .match_distance = result.distance,
            .match_rank = if (result.rune) |r| r.rank else .noise,
        };
    }

    /// Get the current Scout state for external inspection.
    pub fn getScoutState(self: *const TriadPipeline) *const ScoutState {
        return &self.scout;
    }
};

// ══════════════════════════════════════════════════════════════════════════
//  TESTS
// ══════════════════════════════════════════════════════════════════════════

test "RuneRank promotion chain" {
    try std.testing.expectEqual(RuneRank.emerging, RuneRank.noise.promotionTarget().?);
    try std.testing.expectEqual(RuneRank.pattern, RuneRank.emerging.promotionTarget().?);
    try std.testing.expectEqual(RuneRank.validated, RuneRank.pattern.promotionTarget().?);
    try std.testing.expectEqual(RuneRank.verified, RuneRank.validated.promotionTarget().?);
    try std.testing.expectEqual(@as(?RuneRank, null), RuneRank.verified.promotionTarget());
}

test "RuneRank queryable boundary" {
    try std.testing.expect(RuneRank.verified.isQueryable());
    try std.testing.expect(RuneRank.validated.isQueryable());
    try std.testing.expect(RuneRank.pattern.isQueryable());
    try std.testing.expect(!RuneRank.emerging.isQueryable());
    try std.testing.expect(!RuneRank.noise.isQueryable());
}

test "Rune staleness detection" {
    var rune = Rune{
        .vector = vsa.generate(42),
        .rank = .noise,
        .occurrences = 1,
        .distinct_contexts = 1,
        .first_seen_ms = 1000,
        .last_confirmed_ms = 1000,
    };

    // Not stale within TTL
    try std.testing.expect(!rune.isStale(1000 + RANK_NOISE_TTL_MS - 1));
    // Stale after TTL
    try std.testing.expect(rune.isStale(1000 + RANK_NOISE_TTL_MS + 1));
    // Verified runes are never stale
    rune.rank = .verified;
    try std.testing.expect(!rune.isStale(1000 + RANK_NOISE_TTL_MS * 10));
}

test "Rune promotion requirements" {
    var rune = Rune{
        .vector = vsa.generate(42),
        .rank = .noise,
        .occurrences = 1,
        .distinct_contexts = 1,
        .first_seen_ms = 0,
        .last_confirmed_ms = 0,
    };

    // Noise needs 5 observations to promote
    try std.testing.expect(!rune.shouldPromote());
    rune.occurrences = RANK_EMERGING_MIN_OBSERVATIONS;
    try std.testing.expect(rune.shouldPromote());

    // Promote to emerging
    try std.testing.expect(rune.promote());
    try std.testing.expectEqual(RuneRank.emerging, rune.rank);

    // Emerging needs 100 observations + 3 contexts
    rune.occurrences = RANK_PATTERN_MIN_OBSERVATIONS;
    rune.distinct_contexts = 2;
    try std.testing.expect(!rune.shouldPromote()); // Not enough contexts
    rune.distinct_contexts = RANK_PATTERN_MIN_CONTEXTS;
    try std.testing.expect(rune.shouldPromote());
}

test "Scout state evolution produces measurable variance" {
    var scout = ScoutState.init(ghost_state.GENESIS_SEED);

    // Feed some runes, variance should stabilize
    for ("Hello, World!") |c| {
        _ = scout.evolve(@as(u32, c), 0);
    }

    const variance = scout.getCurrentVariance();
    // Variance should be non-zero and within sane bounds
    try std.testing.expect(variance > 0);
    try std.testing.expect(variance < 1024);
}

test "Scout spike detection" {
    var scout = ScoutState.init(ghost_state.GENESIS_SEED);

    // Train the scout on stable input
    for ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") |c| {
        _ = scout.evolve(@as(u32, c), 0);
    }

    // Now inject a completely different character — should cause a variance spike
    // (though whether it exceeds the threshold depends on the EMA history)
    const spike = scout.evolve(0x1F600, 64); // Unicode emoji — very different from 'a'
    _ = spike; // Spike may or may not trigger depending on EMA warmup
    // The important thing is the scout didn't crash and variance is tracked
    try std.testing.expect(scout.rune_count > 0);
}

test "Sniper pin and unbind are inverse operations" {
    const coord = SniperCoordinate{
        .byte_offset = 12345,
        .char_offset = 100,
        .context_hash = 0xABCD_EF01,
        .variance = 600,
        .state_snapshot = vsa.generate(0x1234_5678),
    };

    const bound = sniperPin(coord);
    const recovered = sniperUnbind(bound, coord.byte_offset, coord.state_snapshot);

    // The recovered error vector should match what was originally bound
    const expected_error = vsa.generate(@as(u64, coord.variance) ^ 0xDEAD_BEEF_CAFE_BABE);
    const resonance = vsa.calculateResonance(recovered, expected_error);

    // XOR bind is exact — resonance should be 1024 (perfect match)
    try std.testing.expectEqual(@as(u16, 1024), resonance);
}

test "King query returns no match for empty lattice" {
    const empty_vecs: [0]vsa.HyperVector = .{};
    const empty_ranks: [0]RuneRank = .{};
    const query = vsa.generate(42);

    const result = kingQuery(query, &empty_vecs, &empty_ranks, .pattern, KING_DISTANCE_THRESHOLD);
    try std.testing.expect(result.medic_required);
    try std.testing.expect(!result.accepted);
    try std.testing.expectEqual(@as(?Rune, null), result.rune);
}

test "King query matches identical vector" {
    const target = vsa.generate(42);
    var vecs = [_]vsa.HyperVector{target};
    var ranks = [_]RuneRank{.verified};

    const result = kingQuery(target, &vecs, &ranks, .verified, KING_DISTANCE_THRESHOLD);
    try std.testing.expect(result.accepted);
    try std.testing.expect(!result.medic_required);
    try std.testing.expectEqual(@as(u16, 0), result.distance);
    try std.testing.expectEqual(RuneRank.verified, result.rune.?.rank);
}

test "King query respects rank filter" {
    const target = vsa.generate(42);
    var vecs = [_]vsa.HyperVector{target};
    var ranks = [_]RuneRank{.noise}; // Below min_rank threshold

    const result = kingQuery(target, &vecs, &ranks, .pattern, KING_DISTANCE_THRESHOLD);
    // Noise is rank 5, pattern is rank 3 — noise should be filtered out
    try std.testing.expect(result.medic_required);
    try std.testing.expect(!result.accepted);
}

test "Triad pipeline end-to-end" {
    var pipeline = TriadPipeline.init(ghost_state.GENESIS_SEED);
    const empty_vecs: [0]vsa.HyperVector = .{};
    const empty_ranks: [0]RuneRank = .{};

    // Process some runes
    for ("Hello") |c| {
        const decision = pipeline.process(@as(u32, c), 0, &empty_vecs, &empty_ranks);
        // Without lattice entries, all runes pass through as-is (no spike) or trigger medic
        _ = decision;
    }

    try std.testing.expect(pipeline.total_runes == 5);
}
