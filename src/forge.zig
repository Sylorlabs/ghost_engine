const std = @import("std");
const vsa = @import("vsa_core.zig"); // retained for medicLoop (converted in the test-cluster step)
const config = @import("config.zig");
const ghost_state = @import("ghost_state.zig");
const triad = @import("triad.zig");
const rune_lattice = @import("rune_lattice.zig"); // retained for medicLoop only
const sys = @import("sys.zig");
const slat = @import("invention/structured_lattice.zig");

// ══════════════════════════════════════════════════════════════════════════
//  THE FORGE: Rank-Based Training Without Weights  (de-VSA'd core: structured lattice)
// ══════════════════════════════════════════════════════════════════════════
//
// Patterns move through Rank 5→1 by observation frequency + verification, and stale Rank-5
// noise is pruned. The lattice is now structured (StructuredLattice: id-keyed frequency +
// cosine), NOT a hypervector lattice matched by Hamming on the GPU. Abstract runes (trainer
// rune indices) are observed by exact id — the VSA path only encoded that id into a vector.
// ══════════════════════════════════════════════════════════════════════════

pub const ForgeConfig = struct {
    prune_interval_ms: u64 = 300_000,
    promotion_sweep_interval_ms: u64 = 60_000,
    log_promotions: bool = true,
    log_prunes: bool = true,
    query_min_rank: triad.RuneRank = .pattern,
};

pub const ForgeStats = struct {
    total_observations: u64 = 0,
    total_promotions: u64 = 0,
    total_pruned: u64 = 0,
    total_verifications: u64 = 0,
    total_validations: u64 = 0,
    total_queries: u64 = 0,
    total_query_hits: u64 = 0,
    total_query_misses: u64 = 0,
    last_prune_ms: u64 = 0,
    rank_distribution: [5]u32 = .{ 0, 0, 0, 0, 0 },
};

pub const ForgeEngine = struct {
    store: slat.StructuredLattice,
    forge_config: ForgeConfig,
    stats: ForgeStats,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cfg: ForgeConfig) ForgeEngine {
        return .{ .store = slat.StructuredLattice.init(allocator), .forge_config = cfg, .stats = .{}, .allocator = allocator };
    }
    pub fn deinit(self: *ForgeEngine) void {
        self.store.deinit();
    }

    /// Observe a rune (by exact id) during training — the core Forge etching operation. Frequency-promotes the
    /// matching slot up the rank ladder (was: lattice.observe of a HyperVector).
    pub fn observe(self: *ForgeEngine, rune_id: u64, context_hash: u64, now_ms: u64) usize {
        self.stats.total_observations += 1;
        return self.store.observeKey(rune_id, context_hash, now_ms);
    }

    pub fn verify(self: *ForgeEngine, slot: usize, now_ms: u64) void {
        _ = now_ms;
        self.store.verify(slot);
        self.stats.total_verifications += 1;
        if (self.forge_config.log_promotions) sys.print("[FORGE] Slot {d} verified to Rank 1\n", .{slot});
    }
    pub fn validateSlot(self: *ForgeEngine, slot: usize, now_ms: u64) void {
        _ = now_ms;
        self.store.validate(slot);
        self.stats.total_validations += 1;
        if (self.forge_config.log_promotions) sys.print("[FORGE] Slot {d} validated to Rank 2\n", .{slot});
    }

    /// Periodic maintenance: prune stale Rank-5 noise.
    pub fn tick(self: *ForgeEngine, now_ms: u64) void {
        if (now_ms -| self.stats.last_prune_ms >= self.forge_config.prune_interval_ms) {
            const dropped = self.store.prune(now_ms, triad.RANK_NOISE_TTL_MS);
            self.stats.total_pruned += dropped;
            self.stats.last_prune_ms = now_ms;
            if (self.forge_config.log_prunes and dropped > 0) sys.print("[FORGE] Pruned {d} stale Noise runes\n", .{dropped});
        }
        self.stats.rank_distribution = self.store.rankDistribution();
    }

    pub fn getStats(self: *const ForgeEngine) ForgeStats {
        var stats = self.stats;
        stats.rank_distribution = self.store.rankDistribution();
        return stats;
    }

    /// Query by exact rune id (was a Hamming search over a HyperVector lattice).
    pub fn search(self: *ForgeEngine, rune_id: u64) ?slat.StructuredLattice.Hit {
        return self.store.searchKey(rune_id, self.forge_config.query_min_rank);
    }
};

// ══════════════════════════════════════════════════════════════════════════
//  MEDIC LOOP (0x8B): Logical Proof Fallback  — still VSA; converted in the test-cluster step.
// ══════════════════════════════════════════════════════════════════════════

pub const MedicDecision = struct {
    resolved: bool,
    rune_vector: ?vsa.HyperVector,
    slot: ?u32 = null,
    rank: triad.RuneRank = .noise,
    distance: u16 = 1024,
    dark_space: bool = false,
    confidence_per_mille: u16,
    confidence_indicator: []const u8 = "verified",
    probes: u32,
    silent: bool,
};

pub fn medicLoop(
    lattice: *const rune_lattice.RuneLattice,
    query: vsa.HyperVector,
    scout_state: *const triad.ScoutState,
) MedicDecision {
    _ = scout_state;
    const tau: u16 = config.V2_MEDIC_DISTANCE_TAU;
    var best_verified_slot: u32 = 0;
    var best_verified_dist: u16 = 1025;
    var found_verified = false;
    var best_noise_slot: u32 = 0;
    var best_noise_dist: u16 = 1025;
    var found_noise = false;
    var probes: u32 = 0;

    var i: u32 = 0;
    while (i < lattice.capacity) : (i += 1) {
        if (lattice.tags[i] == 0) continue;
        probes += 1;
        const d = vsa.hammingDistance(query, lattice.vectors[i]);
        switch (lattice.ranks[i]) {
            .verified => if (d < best_verified_dist) {
                best_verified_dist = d;
                best_verified_slot = i;
                found_verified = true;
            },
            .noise => if (d < best_noise_dist) {
                best_noise_dist = d;
                best_noise_slot = i;
                found_noise = true;
            },
            else => {},
        }
    }

    if (found_verified and best_verified_dist <= tau) {
        const max_dist = @as(u32, tau);
        const confidence = if (best_verified_dist < max_dist)
            @as(u16, @intCast(((max_dist - @as(u32, best_verified_dist)) * 1000) / max_dist))
        else
            0;
        return .{ .resolved = true, .rune_vector = lattice.vectors[best_verified_slot], .slot = best_verified_slot, .rank = .verified, .distance = best_verified_dist, .dark_space = false, .confidence_per_mille = confidence, .confidence_indicator = "rank1", .probes = probes, .silent = false };
    }
    if (!found_noise) {
        return .{ .resolved = false, .rune_vector = null, .confidence_per_mille = 0, .confidence_indicator = "unresolved", .probes = probes, .silent = true };
    }
    const unbound = vsa.bind(query, lattice.vectors[best_noise_slot]);
    const dark_confidence = @as(u16, @intCast(((@as(u32, config.HYPERVECTOR_BITS) - @as(u32, best_noise_dist)) * 250) / @as(u32, config.HYPERVECTOR_BITS)));
    return .{ .resolved = true, .rune_vector = unbound, .slot = best_noise_slot, .rank = .noise, .distance = best_noise_dist, .dark_space = true, .confidence_per_mille = dark_confidence, .confidence_indicator = "~dark-space~", .probes = probes, .silent = false };
}

// ══════════════════════════════════════════════════════════════════════════
//  TESTS
// ══════════════════════════════════════════════════════════════════════════

test "ForgeEngine init and deinit" {
    var forge = ForgeEngine.init(std.testing.allocator, .{});
    defer forge.deinit();
    try std.testing.expectEqual(@as(u64, 0), forge.getStats().total_observations);
}

test "ForgeEngine observe and search (id-keyed, structured)" {
    var forge = ForgeEngine.init(std.testing.allocator, .{ .query_min_rank = .noise });
    defer forge.deinit();
    const slot = forge.observe(42, 0x1234, 1000);
    const hit = forge.search(42);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(slot, hit.?.slot);
    try std.testing.expectEqual(@as(f64, 1.0), hit.?.similarity);
}

test "ForgeEngine verify promotes rank" {
    var forge = ForgeEngine.init(std.testing.allocator, .{ .query_min_rank = .noise });
    defer forge.deinit();
    const slot = forge.observe(42, 0x1234, 1000);
    forge.verify(slot, 2000);
    try std.testing.expectEqual(@as(u64, 1), forge.stats.total_verifications);
    try std.testing.expectEqual(triad.RuneRank.verified, forge.search(42).?.rank);
}

test "ForgeEngine tick prunes stale noise" {
    var forge = ForgeEngine.init(std.testing.allocator, .{ .prune_interval_ms = 0, .log_prunes = false, .log_promotions = false });
    defer forge.deinit();
    _ = forge.observe(42, 0x1, 0);
    try std.testing.expectEqual(@as(usize, 1), forge.store.activeCount());
    forge.tick(triad.RANK_NOISE_TTL_MS + 1);
    try std.testing.expectEqual(@as(usize, 0), forge.store.activeCount());
    try std.testing.expect(forge.stats.total_pruned > 0);
}

test "MedicLoop returns silent for empty lattice" {
    var lattice = try rune_lattice.RuneLattice.init(std.testing.allocator, 64, null);
    defer lattice.deinit();
    var scout = triad.ScoutState.init(ghost_state.GENESIS_SEED);
    const decision = medicLoop(&lattice, vsa.generate(42), &scout);
    try std.testing.expect(decision.silent);
    try std.testing.expect(!decision.resolved);
}

test "MedicLoop finds relaxed match" {
    var lattice = try rune_lattice.RuneLattice.init(std.testing.allocator, 64, null);
    defer lattice.deinit();
    const vec = vsa.generate(42);
    const slot = lattice.observe(vec, 0x1, 0).?;
    lattice.verify(slot, 0);
    var scout = triad.ScoutState.init(ghost_state.GENESIS_SEED);
    const decision = medicLoop(&lattice, vec, &scout);
    try std.testing.expect(decision.resolved);
    try std.testing.expectEqual(triad.RuneRank.verified, decision.rank);
}
