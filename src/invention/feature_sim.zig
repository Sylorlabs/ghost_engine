//! feature_sim.zig — NON-VSA structured similarity. Replaces the engine's XOR-VSA hypervector + Hamming-resonance
//! similarity (`rune_lattice`) with a transparent, inspectable representation: a sparse char-n-gram feature set,
//! compared by cosine (or Jaccard). No HyperVector, no XOR bind, no Hamming over bit-lanes — the same "find
//! similar" capability the engine's repair/intent/contradiction paths need, on a structured substrate.
//!
//! This is genuinely fuzzy similarity (what those consumers require) implemented without VSA: a feature is an
//! explicit n-gram with a count, and similarity is an explainable cosine over shared n-grams — you can read why
//! two items matched, unlike a 4096-bit resonance.
const std = @import("std");
pub const RuneRank = @import("../triad.zig").RuneRank;

const NGRAM: usize = 3; // character trigrams: language/code-agnostic, robust to small edits

pub const FeatureSet = struct {
    keys: []const u64, // sorted distinct n-gram hashes
    counts: []const u32, // parallel counts
    norm: f64, // sqrt(sum count^2) for cosine
    a: std.mem.Allocator,

    pub fn fromText(a: std.mem.Allocator, text: []const u8) FeatureSet {
        var map = std.AutoHashMap(u64, u32).init(a);
        defer map.deinit();
        if (text.len >= NGRAM) {
            var i: usize = 0;
            while (i + NGRAM <= text.len) : (i += 1) {
                const h = std.hash.Wyhash.hash(0x5EED, text[i .. i + NGRAM]); // content-addressing of an n-gram, not VSA binding
                const e = map.getOrPut(h) catch continue;
                if (!e.found_existing) e.value_ptr.* = 0;
                e.value_ptr.* += 1;
            }
        }
        const n = map.count();
        const keys = a.alloc(u64, n) catch return .{ .keys = &[_]u64{}, .counts = &[_]u32{}, .norm = 0, .a = a };
        const counts = a.alloc(u32, n) catch return .{ .keys = &[_]u64{}, .counts = &[_]u32{}, .norm = 0, .a = a };
        var it = map.iterator();
        var idx: usize = 0;
        while (it.next()) |kv| : (idx += 1) {
            keys[idx] = kv.key_ptr.*;
            counts[idx] = kv.value_ptr.*;
        }
        // sort keys (and counts in lockstep) for merge-based cosine
        const Ctx = struct {
            keys: []u64,
            counts: []u32,
            pub fn lessThan(s: @This(), x: usize, y: usize) bool {
                return s.keys[x] < s.keys[y];
            }
            pub fn swap(s: @This(), x: usize, y: usize) void {
                std.mem.swap(u64, &s.keys[x], &s.keys[y]);
                std.mem.swap(u32, &s.counts[x], &s.counts[y]);
            }
        };
        std.sort.heapContext(0, n, Ctx{ .keys = keys, .counts = counts });
        var sumsq: f64 = 0;
        for (counts) |c| sumsq += @as(f64, @floatFromInt(c)) * @as(f64, @floatFromInt(c));
        return .{ .keys = keys, .counts = counts, .norm = @sqrt(sumsq), .a = a };
    }
    pub fn deinit(self: *FeatureSet) void {
        self.a.free(self.keys);
        self.a.free(self.counts);
    }
    /// cosine similarity in [0,1] — explainable: it's the normalized count of shared n-grams.
    pub fn cosine(self: *const FeatureSet, other: *const FeatureSet) f64 {
        if (self.norm == 0 or other.norm == 0) return 0;
        var i: usize = 0;
        var j: usize = 0;
        var dot: f64 = 0;
        while (i < self.keys.len and j < other.keys.len) {
            if (self.keys[i] == other.keys[j]) {
                dot += @as(f64, @floatFromInt(self.counts[i])) * @as(f64, @floatFromInt(other.counts[j]));
                i += 1;
                j += 1;
            } else if (self.keys[i] < other.keys[j]) i += 1 else j += 1;
        }
        return dot / (self.norm * other.norm);
    }
};

/// A non-VSA similarity store: items carry a structured FeatureSet + a RuneRank, retrieved by cosine nearest —
/// the role rune_lattice played, without hypervectors/Hamming. `observe` adds/updates; `search` returns the best
/// match at or above a similarity floor and a minimum rank.
pub const SimStore = struct {
    pub const Item = struct { id: u64, features: FeatureSet, rank: RuneRank, payload: []const u8 = "" };
    pub const Hit = struct { id: u64, slot: usize, similarity: f64, rank: RuneRank, payload: []const u8 };
    items: std.ArrayList(Item),
    a: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) SimStore {
        return .{ .items = std.ArrayList(Item).init(a), .a = a };
    }
    pub fn deinit(self: *SimStore) void {
        for (self.items.items) |*it| it.features.deinit();
        self.items.deinit();
    }
    pub fn observe(self: *SimStore, id: u64, features: FeatureSet, rank: RuneRank, payload: []const u8) usize {
        const slot = self.items.items.len;
        self.items.append(.{ .id = id, .features = features, .rank = rank, .payload = payload }) catch return slot;
        return slot;
    }
    /// nearest by structured cosine (not Hamming resonance); returns null if nothing clears `min_similarity`.
    pub fn search(self: *const SimStore, query: *const FeatureSet, min_rank: RuneRank, min_similarity: f64) ?Hit {
        var best: ?Hit = null;
        for (self.items.items, 0..) |*it, slot| {
            if (@intFromEnum(it.rank) > @intFromEnum(min_rank)) continue; // lower enum = higher rank
            const s = query.cosine(&it.features);
            if (s < min_similarity) continue;
            if (best == null or s > best.?.similarity) best = .{ .id = it.id, .slot = slot, .similarity = s, .rank = it.rank, .payload = it.payload };
        }
        return best;
    }
};
