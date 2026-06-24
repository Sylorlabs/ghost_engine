//! exact_lattice.zig — the rune lattice + sigil surface made EXACT. The VSA organs swapped out:
//!   identity   : content-addressed exact canonical form  (was: 4096-bit HyperVector)
//!   match      : structural EQUALITY, O(1) by content id  (was: Hamming resonance / nearest-neighbour)
//!   promotion  : the SOUND verifier on the rank.RuneRank ladder (was: observation-frequency counting)
//!   sigil ops  : scan / lock / etch over exact runes      (was: bind/etch over a MeaningMatrix HyperVector)
//! No HyperVector, no Hamming, no XOR bind anywhere — the framework's bones (rank ladder, shards, sigil verbs)
//! kept, running on the substrate its proof gates were always reaching for.
const std = @import("std");
const ghost = @import("ghost_core");
pub const RuneRank = ghost.rank.RuneRank; // VSA-free rank ladder

pub const Rune = struct {
    canonical: []const u8, // the exact statement — this IS the identity
    id: u64, // content hash of canonical (exact addressing, not a hypervector)
    rank: RuneRank,
    certificate: []const u8,
    locked: bool = false,
};

pub fn idOf(canonical: []const u8) u64 {
    return std.hash.Wyhash.hash(0xC0FFEE, canonical); // content addressing for exact identity (not VSA binding)
}
fn better(a: RuneRank, b: RuneRank) bool {
    return @intFromEnum(a) < @intFromEnum(b); // lower enum value = higher rank (verified=1)
}

pub const ExactLattice = struct {
    runes: std.ArrayList(Rune),
    index: std.AutoHashMap(u64, usize), // id -> slot (exact O(1) lookup; no Hamming scan)
    a: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) ExactLattice {
        return .{ .runes = std.ArrayList(Rune).init(a), .index = std.AutoHashMap(u64, usize).init(a), .a = a };
    }
    pub fn deinit(self: *ExactLattice) void {
        self.runes.deinit();
        self.index.deinit();
    }

    /// sigil ETCH — commit a rune by exact identity; promote toward `verified` (and `verified` is never demoted,
    /// matching triad's contract). Returns the slot index.
    pub fn etch(self: *ExactLattice, canonical: []const u8, rank: RuneRank, certificate: []const u8) !usize {
        const id = idOf(canonical);
        if (self.index.get(id)) |slot| {
            if (self.runes.items[slot].rank != .verified and better(rank, self.runes.items[slot].rank)) {
                self.runes.items[slot].rank = rank;
                self.runes.items[slot].certificate = certificate;
            }
            return slot;
        }
        const slot = self.runes.items.len;
        try self.runes.append(.{ .canonical = canonical, .id = id, .rank = rank, .certificate = certificate });
        try self.index.put(id, slot);
        return slot;
    }

    /// sigil SCAN — EXACT lookup by canonical form (structural equality). A near-miss returns null; it does NOT
    /// resonate. O(1) by content id, then a byte-equality guard against hash collision.
    pub fn scan(self: *ExactLattice, canonical: []const u8) ?*Rune {
        const id = idOf(canonical);
        if (self.index.get(id)) |slot| {
            if (std.mem.eql(u8, self.runes.items[slot].canonical, canonical)) return &self.runes.items[slot];
        }
        return null;
    }

    /// sigil LOCK — pin a verified rune so it can never be pruned (the top of the ladder, made permanent).
    pub fn lock(self: *ExactLattice, canonical: []const u8) bool {
        if (self.scan(canonical)) |r| {
            if (r.rank == .verified) {
                r.locked = true;
                return true;
            }
        }
        return false;
    }

    /// PRUNE — drop refuted/unverified runes (noise). Verified runes survive; this is the ladder's bottom rung
    /// being cleared, exactly (no TTL/decay needed — refutation is definite).
    pub fn pruneNoise(self: *ExactLattice) usize {
        var dropped: usize = 0;
        var w: usize = 0;
        for (self.runes.items) |r| {
            if (r.rank == .noise) {
                dropped += 1;
                continue;
            }
            self.runes.items[w] = r;
            w += 1;
        }
        self.runes.shrinkRetainingCapacity(w);
        self.index.clearRetainingCapacity();
        for (self.runes.items, 0..) |r, i| self.index.put(r.id, i) catch {};
        return dropped;
    }

    /// persist verified runes as a shard (plain structured records — no hypervectors).
    pub fn persistShard(self: *ExactLattice, path: []const u8) !usize {
        if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
        var f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        const w = f.writer();
        try w.print("# ghost rune shard — exact certified knowledge atoms (no VSA, no XOR)\n", .{});
        var n: usize = 0;
        for (self.runes.items) |r| {
            if (r.rank != .verified) continue;
            try w.print("{s}\t{X:0>16}\t{s}\t{s}\t{s}\n", .{ r.rank.label(), r.id, if (r.locked) "LOCKED" else "open", r.canonical, r.certificate });
            n += 1;
        }
        return n;
    }
};
