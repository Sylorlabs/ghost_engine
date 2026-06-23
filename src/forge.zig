const std = @import("std");
const rank = @import("rank.zig"); // RuneRank + RANK_NOISE_TTL_MS — VSA-free, no triad/vsa pull
const sys = @import("sys.zig");
const slat = @import("invention/structured_lattice.zig");

// ══════════════════════════════════════════════════════════════════════════
//  THE FORGE — Rank-Based Training Without Weights, on the STRUCTURED lattice (no VSA)
// ══════════════════════════════════════════════════════════════════════════
// Patterns move through Rank 5→1 by observation frequency + verification; stale Rank-5 noise
// is pruned. The lattice is StructuredLattice (id-keyed frequency + cosine) — no HyperVector,
// no Hamming, no GPU. (The old VSA medic loop / dark-space XOR-unbind was deleted with the
// test cluster that exercised it.)
// ══════════════════════════════════════════════════════════════════════════

pub const ForgeConfig = struct {
    prune_interval_ms: u64 = 300_000,
    promotion_sweep_interval_ms: u64 = 60_000,
    log_promotions: bool = true,
    log_prunes: bool = true,
    query_min_rank: rank.RuneRank = .pattern,
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
            const dropped = self.store.prune(now_ms, rank.RANK_NOISE_TTL_MS);
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
    try std.testing.expectEqual(rank.RuneRank.verified, forge.search(42).?.rank);
}

test "ForgeEngine tick prunes stale noise" {
    var forge = ForgeEngine.init(std.testing.allocator, .{ .prune_interval_ms = 0, .log_prunes = false, .log_promotions = false });
    defer forge.deinit();
    _ = forge.observe(42, 0x1, 0);
    try std.testing.expectEqual(@as(usize, 1), forge.store.activeCount());
    forge.tick(rank.RANK_NOISE_TTL_MS + 1);
    try std.testing.expectEqual(@as(usize, 0), forge.store.activeCount());
    try std.testing.expect(forge.stats.total_pruned > 0);
}
