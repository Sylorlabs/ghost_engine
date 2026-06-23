//! structured_lattice.zig — STEP 1 of the VSA-core rearchitecture: a structured replacement for rune_lattice.
//! Same behaviour the engine's core relies on — rank-laddered pattern memory (observe → frequency-promote →
//! nearest-match search → prune) — but the rune is a structured FeatureSet and the match is cosine, not a
//! HyperVector matched by Hamming on the GPU. No VSA, no XOR, no shaders. The triad pipeline and forge repoint
//! onto this in subsequent steps; rune_lattice / vsa_math / the GPU search shaders retire once nothing imports them.
//! Build: in the ghost_core CLI list as `ghost_structured_lattice`. Run: ./zig-out/bin/ghost_structured_lattice
const std = @import("std");
const fsim = @import("feature_sim.zig");
const ghost = @import("ghost_core");
const RuneRank = ghost.triad.RuneRank;

const MERGE_SIM: f64 = 0.92; // cosine above which a new observation is the SAME pattern (was: small Hamming radius)
const EMERGING_MIN_OBS: u32 = 5; // mirrors triad's frequency ladder (noise→emerging→pattern→validated)
const PATTERN_MIN_OBS: u32 = 100;
const PATTERN_MIN_CTX: u32 = 3;

pub const StructuredLattice = struct {
    pub const Slot = struct {
        id: u64,
        features: fsim.FeatureSet,
        rank: RuneRank = .noise,
        observations: u32 = 0,
        contexts: std.AutoHashMap(u64, void), // distinct contexts (for pattern promotion)
        last_seen_ms: u64 = 0,
        label: []const u8 = "",
    };
    pub const Hit = struct { slot: usize, id: u64, similarity: f64, rank: RuneRank, label: []const u8 };
    slots: std.ArrayList(Slot),
    a: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) StructuredLattice {
        return .{ .slots = std.ArrayList(Slot).init(a), .a = a };
    }
    pub fn deinit(self: *StructuredLattice) void {
        for (self.slots.items) |*s| {
            s.features.deinit();
            s.contexts.deinit();
        }
        self.slots.deinit();
    }

    fn autoPromote(s: *Slot) void {
        if (s.rank == .verified or s.rank == .validated) return; // never auto-demote a confirmed rune
        const ctx = s.contexts.count();
        if (s.observations >= PATTERN_MIN_OBS and ctx >= PATTERN_MIN_CTX) {
            s.rank = .pattern;
        } else if (s.observations >= EMERGING_MIN_OBS) {
            s.rank = .emerging;
        }
    }

    /// observe a pattern: merge into the nearest existing slot if cosine ≥ MERGE_SIM (frequency promotion on the
    /// rank ladder), else allocate a new `noise` slot. Replaces rune_lattice.observe (content-hash + Hamming).
    pub fn observe(self: *StructuredLattice, text: []const u8, context_hash: u64, now_ms: u64, label: []const u8) usize {
        var feats = fsim.FeatureSet.fromText(self.a, text);
        var best: ?usize = null;
        var best_sim: f64 = 0;
        for (self.slots.items, 0..) |*s, i| {
            const sim = feats.cosine(&s.features);
            if (sim >= MERGE_SIM and sim > best_sim) {
                best_sim = sim;
                best = i;
            }
        }
        if (best) |i| {
            feats.deinit(); // duplicate pattern — fold into the existing slot
            var s = &self.slots.items[i];
            s.observations += 1;
            s.contexts.put(context_hash, {}) catch {};
            s.last_seen_ms = now_ms;
            autoPromote(s);
            return i;
        }
        const slot = self.slots.items.len;
        var ctx = std.AutoHashMap(u64, void).init(self.a);
        ctx.put(context_hash, {}) catch {};
        self.slots.append(.{ .id = std.hash.Wyhash.hash(0x1A77, text), .features = feats, .rank = .noise, .observations = 1, .contexts = ctx, .last_seen_ms = now_ms, .label = label }) catch return slot;
        return slot;
    }

    /// nearest-match by cosine (was Hamming resonance). Returns the best slot at/above min_rank clearing min_sim.
    pub fn search(self: *const StructuredLattice, query_text: []const u8, min_rank: RuneRank, min_sim: f64) ?Hit {
        var q = fsim.FeatureSet.fromText(self.a, query_text);
        defer q.deinit();
        var best: ?Hit = null;
        for (self.slots.items, 0..) |*s, i| {
            if (@intFromEnum(s.rank) > @intFromEnum(min_rank)) continue;
            const sim = q.cosine(&s.features);
            if (sim < min_sim) continue;
            if (best == null or sim > best.?.similarity) best = .{ .slot = i, .id = s.id, .similarity = sim, .rank = s.rank, .label = s.label };
        }
        return best;
    }

    pub fn verify(self: *StructuredLattice, slot: usize) void {
        if (slot < self.slots.items.len) self.slots.items[slot].rank = .verified;
    }
    pub fn validate(self: *StructuredLattice, slot: usize) void {
        if (slot < self.slots.items.len) self.slots.items[slot].rank = .validated;
    }
    /// prune stale noise (definite — refutation/decay), mirrors lattice.prune.
    pub fn prune(self: *StructuredLattice, now_ms: u64, ttl_ms: u64) usize {
        var dropped: usize = 0;
        var w: usize = 0;
        for (self.slots.items) |*s| {
            if (s.rank == .noise and now_ms -| s.last_seen_ms > ttl_ms) {
                s.features.deinit();
                s.contexts.deinit();
                dropped += 1;
                continue;
            }
            self.slots.items[w] = s.*;
            w += 1;
        }
        self.slots.shrinkRetainingCapacity(w);
        return dropped;
    }
    pub fn rankDistribution(self: *const StructuredLattice) [5]u32 {
        var d = [_]u32{0} ** 5;
        for (self.slots.items) |s| d[@intFromEnum(s.rank) - 1] += 1; // verified=1..noise=5
        return d;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const A = gpa.allocator();
    const o = std.io.getStdOut().writer();
    try o.print("=== STRUCTURED LATTICE — rune_lattice replacement, no VSA/Hamming/GPU (core step 1) ===\n\n", .{});

    var lat = StructuredLattice.init(A);
    defer lat.deinit();

    // observe a recurring pattern across distinct contexts → frequency-promotes up the rank ladder
    const pat = "fn main() !void { try stdout.print }";
    var c: u64 = 0;
    while (c < 6) : (c += 1) _ = lat.observe(pat, 1000 + c, 100, "zig-main-idiom"); // 6 obs, 6 contexts
    _ = lat.observe("let x = require('fs')", 9001, 100, "node-require"); // a different pattern (1 obs → noise)

    const d = lat.rankDistribution();
    try o.print("── observe (frequency promotion): ranks [verified={d} validated={d} pattern={d} emerging={d} noise={d}]\n", .{ d[0], d[1], d[2], d[3], d[4] });
    try o.print("   the 6×-seen idiom promoted to EMERGING by observation count; the 1×-seen line stayed NOISE.\n\n", .{});

    // nearest-match search by cosine (was Hamming resonance) — a near-variant still matches; an unrelated query doesn't
    if (lat.search("fn main() void { try stdout.print(x) }", .noise, 0.3)) |h|
        try o.print("── search near-variant of the idiom → HIT [{s}] sim={d:.2} ({s})\n", .{ h.rank.label(), h.similarity, h.label });
    if (lat.search("SELECT * FROM users WHERE id = 1", .noise, 0.3) == null)
        try o.print("── search unrelated SQL → miss (cosine below floor — structured, explainable, not a 4096-bit resonance)\n", .{});

    try o.print("\n  Step 1 done: rank-laddered pattern memory on a structured substrate (FeatureSet + cosine), no\n", .{});
    try o.print("  HyperVector / Hamming / GPU shader. Next: repoint triad.TriadPipeline + forge onto this, then retire\n", .{});
    try o.print("  rune_lattice / vsa_math / the GPU search shaders once nothing imports them.\n", .{});
}
