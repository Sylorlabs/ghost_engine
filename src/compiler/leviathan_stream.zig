//! Phase 8 — Demand-Driven Synthesis ("Skim and Expand").
//!
//! HONEST DESCRIPTION (read before believing any hype):
//!
//! This is a two-speed pipeline, NOT a way around SMT's complexity:
//!
//!   * SKIM (cheap, always-on): ingest byte chunks, encode each into a 4096-bit
//!     VSA hypervector using the SAME bind/bundle/Hamming primitives the Tier-1
//!     cartographer uses, and reject geometric duplicates. This is a streaming
//!     deduplicating sieve. It touches no SMT and calls no solver. It reduces
//!     HOW OFTEN we pay the verifier cost; it does not change the cost of any
//!     single query, and it cannot "bypass P vs NP".
//!
//!   * EXPAND (expensive, on-demand): only when a node is explicitly flagged do
//!     we hand its semantic kernel to REAL libz3. A node is expandable only if
//!     it carries an `smt_body` (an actual verifiable term). Raw byte geometry
//!     has no property to prove, so `smt_body == null` and expansion refuses —
//!     we do not fabricate a verdict for bytes we cannot lower.
//!
//! The Expand gate runs a NON-VACUITY (liveness) query: does the island's output
//! actually depend on its primary input? SAT => live (taint can propagate);
//! UNSAT => the island ignores its input (inert). This is deliberately a real,
//! non-trivial question — a constant/dead island returns UNSAT, so the gate is
//! shown to DISCRIMINATE rather than rubber-stamp. Z3 remains the sole soundness
//! authority; the SMT grammar is engineer-given (this is verification, not
//! abductive synthesis).

const std = @import("std");
const vsa_tensor = @import("vsa_tensor.zig");
const tier1 = @import("tier1_sketcher.zig");
const HyperVector = vsa_tensor.HyperVector;

const c = @cImport({
    @cInclude("z3.h");
});

fn z3SilentErrorHandler(_: c.Z3_context, _: c.Z3_error_code) callconv(.C) void {}

pub const Verdict = enum { sat, unsat, unknown, err };

pub const VsaTopologyNode = struct {
    id: usize,
    /// The 4096-bit geometric fingerprint of this node.
    vec: HyperVector,
    /// How many ingested chunks collapsed onto this geometry. Redundant noise
    /// inflates this counter instead of allocating new nodes.
    frequency: u64 = 1,
    /// Set once the node has been handed to Tier-2.
    is_expanded: bool = false,
    /// The verifiable SMT kernel, if this node has one. Raw byte-stream nodes
    /// are `null` and therefore not expandable.
    smt_body: ?[]const u8 = null,
    /// Result of the last expansion, if any.
    last_verdict: ?Verdict = null,
};

pub const IngestResult = struct {
    node_id: usize,
    /// false => this chunk's geometry duplicated an existing node (rejected).
    is_new: bool,
};

pub const LeviathanStream = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(VsaTopologyNode),
    /// A new chunk within this Hamming distance of an existing node is treated
    /// as the same geometry. Derived from the encoder's measured distribution.
    dedup_threshold: usize,
    /// Aggregate counters for an honest end-of-run report.
    chunks_seen: u64 = 0,
    duplicates_rejected: u64 = 0,
    expansions: u64 = 0,

    /// `k_sigma` widens the duplicate tolerance: a chunk folds onto a node if it
    /// is within `mean_perturb + k_sigma*sigma_perturb` bits — i.e. no farther
    /// than a few-byte corruption of the same content would land. This is
    /// anchored at the DUPLICATE end (near 0), not below the independent mean,
    /// so genuinely different-but-similar inputs stay distinct.
    pub fn init(allocator: std.mem.Allocator, k_sigma: f64) LeviathanStream {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(VsaTopologyNode).init(allocator),
            .dedup_threshold = calibrateDedup(allocator, k_sigma),
        };
    }

    pub fn deinit(self: *LeviathanStream) void {
        for (self.nodes.items) |n| {
            if (n.smt_body) |b| self.allocator.free(b);
        }
        self.nodes.deinit();
    }

    // --- SKIM ----------------------------------------------------------------

    fn encodeChunk(self: *LeviathanStream, bytes: []const u8) HyperVector {
        return encode(self.allocator, bytes);
    }

    /// Ingest one chunk: encode, then either fold onto the nearest existing node
    /// (duplicate geometry) or admit a new topology node.
    pub fn ingestChunk(self: *LeviathanStream, bytes: []const u8) IngestResult {
        self.chunks_seen += 1;
        const v = self.encodeChunk(bytes);

        var best_id: ?usize = null;
        var best_dist: usize = std.math.maxInt(usize);
        for (self.nodes.items) |node| {
            const d = vsa_tensor.hammingDistance(v, node.vec);
            if (d < best_dist) {
                best_dist = d;
                best_id = node.id;
            }
        }

        if (best_id != null and best_dist < self.dedup_threshold) {
            self.nodes.items[best_id.?].frequency += 1;
            self.duplicates_rejected += 1;
            return .{ .node_id = best_id.?, .is_new = false };
        }

        const id = self.nodes.items.len;
        self.nodes.append(.{ .id = id, .vec = v }) catch unreachable;
        return .{ .node_id = id, .is_new = true };
    }

    /// Register a node that carries a verifiable kernel (e.g. a Tier-1 island).
    /// Its geometry is the encoding of the SMT text so it still participates in
    /// dedup, and `smt_body` makes it eligible for Expand.
    pub fn registerIsland(self: *LeviathanStream, smt_body: []const u8) usize {
        const v = self.encodeChunk(smt_body);
        const id = self.nodes.items.len;
        const owned = self.allocator.dupe(u8, smt_body) catch unreachable;
        self.nodes.append(.{ .id = id, .vec = v, .smt_body = owned }) catch unreachable;
        return id;
    }

    // --- EXPAND --------------------------------------------------------------

    /// On-demand trigger. Lowers the flagged island to a real SMT query and asks
    /// libz3 whether the island's output depends on its primary input.
    /// Returns error.NotExpandable for raw byte-geometry nodes (no kernel).
    pub fn expandIsland(self: *LeviathanStream, node_id: usize) !Verdict {
        if (node_id >= self.nodes.items.len) return error.NoSuchNode;
        const node = &self.nodes.items[node_id];
        const body = node.smt_body orelse return error.NotExpandable;

        const query = try std.fmt.allocPrint(self.allocator,
            \\(define-fun M ((in_0 (_ BitVec 64)) (in_1 (_ BitVec 64))) (_ BitVec 64) {s})
            \\(declare-const a0 (_ BitVec 64))
            \\(declare-const a1 (_ BitVec 64))
            \\(declare-const b (_ BitVec 64))
            \\;; SAT iff two values of in_0 yield different outputs (same in_1):
            \\;; i.e. the island genuinely processes its primary input (LIVE).
            \\(assert (distinct (M a0 b) (M a1 b)))
            \\(check-sat)
        , .{body});
        defer self.allocator.free(query);

        const verdict = runZ3(self.allocator, query);
        node.is_expanded = true;
        node.last_verdict = verdict;
        self.expansions += 1;
        return verdict;
    }

    pub fn report(self: *LeviathanStream) void {
        std.debug.print("\n[Leviathan] chunks seen={d}, topology nodes={d}, duplicates rejected={d}, Z3 expansions={d}\n", .{
            self.chunks_seen, self.nodes.items.len, self.duplicates_rejected, self.expansions,
        });
        std.debug.print("[Leviathan] dedup threshold = {d} bits\n", .{self.dedup_threshold});
    }
};

/// Positional VSA encoding: bind each byte's value vector to its position
/// vector, then bundle. Unlike a plain hash this is locality-aware — chunks that
/// share byte content at shared offsets land geometrically near each other,
/// which is what makes Hamming-distance dedup meaningful. Identical content
/// always encodes to an identical vector (distance 0).
pub fn encode(allocator: std.mem.Allocator, bytes: []const u8) HyperVector {
    if (bytes.len == 0) return @as(HyperVector, @splat(0));
    const window: usize = 64;
    var bound = std.ArrayList(HyperVector).init(allocator);
    defer bound.deinit();
    for (bytes, 0..) |b, i| {
        const pos_vec = vsa_tensor.generateLexicon(0x9051_0000 + @as(u64, @intCast(i % window)));
        const val_vec = vsa_tensor.generateLexicon(0x7A1E_0000 + @as(u64, b));
        bound.append(vsa_tensor.bind(pos_vec, val_vec)) catch unreachable;
    }
    return vsa_tensor.bundle(bound.items);
}

/// Calibrate the dedup threshold from PERTURBATION distance: how far does the
/// geometry move when a few bytes of a chunk are corrupted? The threshold is
/// `mean + k_sigma*sigma` of that distribution — chunks closer than this are
/// "as similar as a small edit of the same content" and fold. Anchored near 0,
/// so two genuinely different chunks (which sit ~10x farther) stay distinct.
fn calibrateDedup(allocator: std.mem.Allocator, k_sigma: f64) usize {
    var prng = std.Random.DefaultPrng.init(0xCA11B_DA7A);
    const rng = prng.random();
    const trials: usize = 96;

    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    for (0..trials) |_| {
        const len = 16 + rng.uintLessThan(usize, 32); // 16..47 bytes
        var buf: [64]u8 = undefined;
        for (0..len) |i| buf[i] = rng.int(u8);
        const v0 = encode(allocator, buf[0..len]);

        // Corrupt 1-2 bytes.
        const edits = 1 + rng.uintLessThan(usize, 2);
        for (0..edits) |_| {
            const pos = rng.uintLessThan(usize, len);
            buf[pos] = rng.int(u8);
        }
        const v1 = encode(allocator, buf[0..len]);

        const d: f64 = @floatFromInt(vsa_tensor.hammingDistance(v0, v1));
        sum += d;
        sum_sq += d * d;
    }
    const mean = sum / @as(f64, @floatFromInt(trials));
    const variance = sum_sq / @as(f64, @floatFromInt(trials)) - mean * mean;
    const sigma = @sqrt(@max(variance, 0));
    const t = mean + k_sigma * sigma;
    return if (t < 0) 0 else @intFromFloat(@round(t));
}

/// Real libz3 call via the SMT-LIB2 eval entrypoint — the same path
/// autonomous_guard.zig uses. Verdict is the first solver token.
fn runZ3(allocator: std.mem.Allocator, smt_text: []const u8) Verdict {
    const cfg = c.Z3_mk_config() orelse return .err;
    defer c.Z3_del_config(cfg);
    c.Z3_set_param_value(cfg, "timeout", "5000");

    const ctx = c.Z3_mk_context(cfg) orelse return .err;
    defer c.Z3_del_context(ctx);
    c.Z3_set_error_handler(ctx, z3SilentErrorHandler);

    const text_z = allocator.dupeZ(u8, smt_text) catch return .err;
    defer allocator.free(text_z);

    const out_z = c.Z3_eval_smtlib2_string(ctx, text_z.ptr);
    if (out_z == null) return .err;
    const out = std.mem.span(out_z);

    var lines = std.mem.tokenizeAny(u8, out, "\n\r");
    const first = lines.next() orelse "";
    if (std.mem.startsWith(u8, first, "unsat")) return .unsat;
    if (std.mem.startsWith(u8, first, "sat")) return .sat;
    if (std.mem.startsWith(u8, first, "unknown")) return .unknown;
    return .err;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== GHOST ENGINE: Leviathan Stream (Skim + Expand) ===\n\n", .{});

    var stream = LeviathanStream.init(allocator, 6.0);
    defer stream.deinit();

    // --- SKIM: stream raw byte chunks, reject geometric duplicates. ---------
    std.debug.print("[SKIM] Ingesting raw byte chunks...\n", .{});
    const chunks = [_][]const u8{
        "GET /index.html HTTP/1.1",
        "GET /index.html HTTP/1.1", // exact duplicate -> folded
        "GET /index.html HTTP/1.1", // exact duplicate -> folded
        "POST /api/login HTTP/1.1", // distinct geometry -> new node
        "\x00\x01\x02\x03\x04\x05\x06\x07", // binary trace -> new node
    };
    for (chunks) |ch| {
        const r = stream.ingestChunk(ch);
        std.debug.print("  chunk {s:<28} -> node {d} ({s})\n", .{
            if (ch.len <= 28) ch else ch[0..28],
            r.node_id,
            if (r.is_new) "NEW" else "duplicate, folded",
        });
    }

    // --- Register REAL Tier-1 islands (these carry verifiable kernels). -----
    std.debug.print("\n[BRIDGE] Pulling islands from the Tier-1 cartographer...\n", .{});
    const payload = tier1.generateSketch();
    var island_node_ids = std.ArrayList(usize).init(allocator);
    defer island_node_ids.deinit();
    for (payload.islands) |isl| {
        const id = stream.registerIsland(isl.smt_body);
        try island_node_ids.append(id);
        std.debug.print("  registered island {d} as node {d}\n", .{ isl.id, id });
    }

    // A deliberately DEAD island (constant output) to prove the gate discriminates.
    const dead_id = stream.registerIsland("#x0000000000000000");
    std.debug.print("  registered DEAD control island as node {d}\n", .{dead_id});

    // --- EXPAND: hand only the flagged nodes to real Z3. --------------------
    std.debug.print("\n[EXPAND] On-demand Tier-2 verification (real libz3):\n", .{});
    for (island_node_ids.items) |id| {
        const v = try stream.expandIsland(id);
        std.debug.print("  node {d}: {s}  ->  {s}\n", .{ id, verdictWord(v), liveness(v) });
    }
    const dv = try stream.expandIsland(dead_id);
    std.debug.print("  node {d} (DEAD control): {s}  ->  {s}\n", .{ dead_id, verdictWord(dv), liveness(dv) });

    // Prove the refusal path: a raw byte node has no kernel to verify.
    if (stream.expandIsland(0)) |_| {
        std.debug.print("  node 0 (raw bytes): unexpectedly expandable!\n", .{});
    } else |err| {
        std.debug.print("  node 0 (raw bytes): expand refused -> {s}\n", .{@errorName(err)});
    }

    stream.report();
}

fn verdictWord(v: Verdict) []const u8 {
    return switch (v) {
        .sat => "SAT",
        .unsat => "UNSAT",
        .unknown => "UNKNOWN",
        .err => "ERR",
    };
}

fn liveness(v: Verdict) []const u8 {
    return switch (v) {
        .sat => "LIVE (output depends on input)",
        .unsat => "INERT (output ignores input)",
        else => "indeterminate",
    };
}
