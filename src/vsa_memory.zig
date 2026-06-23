const std = @import("std");
const math = @import("vsa_math.zig");

// Re-export all math symbols for downstream consumers of vsa_core
pub usingnamespace math;

// Local aliases for internal use within this file
const HyperVector = math.HyperVector;
const hammingDistance = math.hammingDistance;
const calculateResonance = math.calculateResonance;
const computeSudhAddress = math.computeSudhAddress;
const generate = math.generate;
const SUDH_CPU_PROBES = math.SUDH_CPU_PROBES;
const SUDH_NEIGHBORHOOD_SIZE = math.SUDH_NEIGHBORHOOD_SIZE;

pub const GravityResult = struct {
    drift: u64 = 0,
    slot: ?u32 = null,
    inserted_new_slot: bool = false,
};

pub const MeaningMatrix = struct {
    data: []u32, // V28: 32-bit depth to support native atomicAdd and avoid packing stalls
    tags: ?[]u64 = null,

    /// SIMD-Optimized binary collapse.
    /// Converts 1024 32-bit accumulators into 1024 bits via thresholding.
    pub fn collapseToBinaryAtSlot(self: *const MeaningMatrix, slot: u32) HyperVector {
        const acc = self.data[slot * 1024 .. slot * 1024 + 1024];
        var res_bytes: [512]u8 = undefined;

        const threshold: @Vector(16, u32) = @splat(@as(u32, 2147483647));
        const powers: @Vector(16, u32) = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };

        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const chunk: @Vector(16, u32) = acc[i * 16 ..][0..16].*;
            const mask = @as(@Vector(16, u32), @select(u32, chunk > threshold, powers, @as(@Vector(16, u32), @splat(0))));

            // Sum the bits into two bytes
            const mask_arr: [16]u32 = mask;
            const low = @reduce(.Add, @as(@Vector(8, u32), mask_arr[0..8].*));
            const high = @reduce(.Add, @as(@Vector(8, u32), mask_arr[8..16].*));
            res_bytes[i * 2] = @as(u8, @intCast(low));
            res_bytes[i * 2 + 1] = @as(u8, @intCast(high));
        }
        return @bitCast(res_bytes);
    }

    pub fn collapseToBinary(self: *const MeaningMatrix, hash: u64) HyperVector {
        if (self.tags) |tags| {
            const num_slots = @as(u32, @intCast(tags.len));
            const addr = computeSudhAddress(@as(u32, @truncate(hash)), hash, num_slots);
            var p: u32 = 0;
            while (p < SUDH_CPU_PROBES) : (p += 1) {
                const slot = addr.probe(p, num_slots);
                if (slot >= num_slots) break;
                if (tags[slot] == hash) return self.collapseToBinaryAtSlot(slot);
                if (tags[slot] == 0) return @splat(0);
            }
        }
        return @splat(0);
    }

    /// V28: Surprise Routing. Returns true if resonance < threshold.
    pub fn isSurprising(self: *const MeaningMatrix, word_hash: u64, concept: HyperVector, threshold: u16) bool {
        const expectation = self.collapseToBinary(word_hash);
        const resonance = calculateResonance(expectation, concept);
        return resonance < threshold;
    }

    /// The Gravity Rule: Microscopic addition toward a concept neighborhood.
    /// Vectorized for AVX-2/AVX-512 (1024-bit saturation via @Vector).
    pub fn applyGravity(
        self: *MeaningMatrix,
        word_hash: u64,
        sentence_pool: HyperVector,
        hash_locked: bool,
        slot_lock_mask: u32,
    ) GravityResult {
        var slot_idx: ?u32 = null;
        var inserted_new_slot = false;
        if (hash_locked) return .{};
        if (self.tags) |tags| {
            const num_slots = @as(u32, @intCast(tags.len));
            const addr = computeSudhAddress(@as(u32, @truncate(word_hash)), word_hash, num_slots);
            var p: u32 = 0;
            while (p < SUDH_CPU_PROBES) : (p += 1) {
                const slot = addr.probe(p, num_slots);
                if (slot >= num_slots) break;
                const probe_mask = @as(u32, 1) << @as(u5, @intCast(p));
                if ((slot_lock_mask & probe_mask) != 0) return .{};
                if (tags[slot] == word_hash) {
                    slot_idx = slot;
                    break;
                }
                if (tags[slot] == 0) {
                    tags[slot] = word_hash;
                    slot_idx = slot;
                    inserted_new_slot = true;
                    break;
                }
            }
        }
        const sid = slot_idx orelse return .{};

        const acc_ptr = @as([*]u32, @ptrCast(@alignCast(&self.data[sid * 1024])));
        const pool_bytes: [512]u8 = @bitCast(sentence_pool);

        // Process in 512-bit chunks (16x u32) for AVX-512 or 2x 256-bit AVX-2 saturation.
        // SIMD bit extraction: use vector shift-right + AND instead of 16 scalar extractions.
        const shift_lut: @Vector(8, u32) = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
        var total_drift: u64 = 0;
        inline for (0..64) |byte_pair| {
            const byte_a = pool_bytes[byte_pair * 2];
            const byte_b = pool_bytes[byte_pair * 2 + 1];
            const base = byte_pair * 16;

            // SIMD bit expansion: broadcast each byte, shift by 0-7, mask to get individual bits
            const a_vec: @Vector(8, u32) = @splat(@as(u32, byte_a));
            const b_vec: @Vector(8, u32) = @splat(@as(u32, byte_b));
            const mask_a: @Vector(8, u32) = (a_vec >> shift_lut) & @as(@Vector(8, u32), @splat(1));
            const mask_b: @Vector(8, u32) = (b_vec >> shift_lut) & @as(@Vector(8, u32), @splat(1));
            const mask_bits: @Vector(16, u32) = @as([8]u32, mask_a) ++ @as([8]u32, mask_b);

            const ones: @Vector(16, u32) = @splat(1);
            const chunk: @Vector(16, u32) = acc_ptr[base..][0..16].*;
            const inc = chunk +| ones;
            const dec = chunk -| ones;

            var res = @select(u32, mask_bits == ones, inc, dec);

            // Saturation cap: lock accumulator at threshold 10,000 via MSB
            const threshold: @Vector(16, u32) = @splat(10000);
            const lock_bit: @Vector(16, u32) = @splat(0x80000000);
            res = @select(u32, res == threshold, res | lock_bit, res);

            acc_ptr[base..][0..16].* = res;
            total_drift += 16;
        }

        return .{
            .drift = total_drift,
            .slot = sid,
            .inserted_new_slot = inserted_new_slot,
        };
    }

    /// Bound gravity: XOR binds data to an agent mask before etching.
    pub fn applyBoundGravity(
        self: *MeaningMatrix,
        word_hash: u64,
        data: HyperVector,
        mask: HyperVector,
        hash_locked: bool,
        slot_lock_mask: u32,
    ) GravityResult {
        return self.applyGravity(word_hash, data ^ mask, hash_locked, slot_lock_mask);
    }

    /// Absolute Sigil Locking: Hardcoding a symbol into the matrix.
    pub fn hardLockSigil(self: *MeaningMatrix, hash: u64, char: u8) void {
        self.hardLockUniversalSigil(hash, @as(u32, char));
    }

    /// Universal Sigil Locking: Handles any 32-bit rune.
    pub fn hardLockUniversalSigil(self: *MeaningMatrix, hash: u64, rune: u32) void {
        var slot_idx: ?u32 = null;
        if (self.tags) |tags| {
            const num_slots = @as(u32, @intCast(tags.len));
            const addr = computeSudhAddress(@as(u32, @truncate(hash)), hash, num_slots);
            var p: u32 = 0;
            while (p < SUDH_CPU_PROBES) : (p += 1) {
                const slot = addr.probe(p, num_slots);
                if (slot >= num_slots) break;
                if (tags[slot] == hash) {
                    slot_idx = slot;
                    break;
                }
                if (tags[slot] == 0) {
                    tags[slot] = hash;
                    slot_idx = slot;
                    break;
                }
            }
        }
        const sid = slot_idx orelse return;
        const reality_bytes: [512]u8 = @bitCast(generate(@as(u64, rune)));
        var word_acc = self.data[sid * 1024 .. sid * 1024 + 1024];
        for (0..1024) |i| {
            const bit = (reality_bytes[i / 8] >> @as(u3, @intCast(i % 8))) & 1;
            word_acc[i] = if (bit == 1) 0xFFFFFFFF else 0;
        }
    }
};

/// Deterministic, infinite-context record-keeping.
/// Paged memory architecture supporting 4GB literal recall (1 billion runes).
/// Integrates a 64-wide SIMD sweep for instant Fractal Anchor (concept) retrieval.
pub const PagedPanopticon = struct {
    // 64 pages * 64MB (16M runes) = 4GB (1.024B runes)
    pub const PAGE_SIZE = 16 * 1024 * 1024;
    pub const MAX_PAGES = 64;
    pub const MAX_CONCEPTS = 1_000_000;
    pub const HNSW_WARMUP = 64; // Use linear scan until this many concepts are indexed

    pages: [MAX_PAGES]?[]u32,
    page_count: usize,
    rune_write: usize,

    // Fractal Anchors (Deep Lobe) indexing into the Literal Recall (Active Lobe)
    concepts: []HyperVector,
    concept_offsets: []u32,
    concepts_write: usize,

    // HNSW index for O(log N) approximate nearest-neighbor search
    hnsw: ?HnswIndex,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !PagedPanopticon {
        const concepts = try allocator.alloc(HyperVector, MAX_CONCEPTS);
        return .{
            .pages = [_]?[]u32{null} ** MAX_PAGES,
            .page_count = 0,
            .rune_write = 0,
            .concepts = concepts,
            .concept_offsets = try allocator.alloc(u32, MAX_CONCEPTS),
            .concepts_write = 0,
            .hnsw = HnswIndex.init(allocator, MAX_CONCEPTS, concepts) catch null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PagedPanopticon) void {
        for (self.pages) |page| {
            if (page) |p| self.allocator.free(p);
        }
        if (self.hnsw) |*h| h.deinit();
        self.allocator.free(self.concepts);
        self.allocator.free(self.concept_offsets);
    }

    pub fn pushRune(self: *PagedPanopticon, rune: u32) !void {
        const page_idx = self.rune_write / PAGE_SIZE;
        const page_off = self.rune_write % PAGE_SIZE;

        if (page_idx >= MAX_PAGES) return; // 4GB capacity reached

        if (self.pages[page_idx] == null) {
            self.pages[page_idx] = try self.allocator.alloc(u32, PAGE_SIZE);
            self.page_count += 1;
        }

        self.pages[page_idx].?[page_off] = rune;
        self.rune_write += 1;
    }

    pub fn markSentence(self: *PagedPanopticon, concept: HyperVector) void {
        if (self.concepts_write >= MAX_CONCEPTS) return;
        self.concepts[self.concepts_write] = concept;
        self.concept_offsets[self.concepts_write] = @intCast(self.rune_write);
        // Insert into HNSW index for O(log N) search
        if (self.hnsw) |*h| {
            h.insert(@intCast(self.concepts_write));
        }
        self.concepts_write += 1;
    }

    /// Approximate nearest-neighbor search over concept anchors.
    /// Uses HNSW for O(log N) search when the index is warm (>64 concepts).
    /// Falls back to linear scan for small datasets where HNSW overhead isn't worth it.
    pub fn sweepClosest(self: *PagedPanopticon, query: HyperVector) ?struct { index: usize, distance: u16, offset: u32 } {
        if (self.concepts_write == 0) return null;

        // HNSW path: O(log N) when the graph has enough nodes to be useful
        if (self.hnsw) |*h| {
            if (h.num_nodes >= HNSW_WARMUP) {
                if (h.search(query)) |result| {
                    return .{ .index = result.index, .distance = result.distance, .offset = self.concept_offsets[result.index] };
                }
            }
        }

        // Fallback: Linear scan for cold-start or when HNSW is unavailable
        var best_idx: usize = 0;
        var best_dist: u16 = 1025;
        const limit = self.concepts_write - (self.concepts_write % 4);
        var i: usize = 0;

        while (i < limit) : (i += 4) {
            const d0 = hammingDistance(query, self.concepts[i]);
            const d1 = hammingDistance(query, self.concepts[i + 1]);
            const d2 = hammingDistance(query, self.concepts[i + 2]);
            const d3 = hammingDistance(query, self.concepts[i + 3]);

            if (d0 < best_dist) {
                best_dist = d0;
                best_idx = i;
            }
            if (d1 < best_dist) {
                best_dist = d1;
                best_idx = i + 1;
            }
            if (d2 < best_dist) {
                best_dist = d2;
                best_idx = i + 2;
            }
            if (d3 < best_dist) {
                best_dist = d3;
                best_idx = i + 3;
            }
        }

        while (i < self.concepts_write) : (i += 1) {
            const d = hammingDistance(query, self.concepts[i]);
            if (d < best_dist) {
                best_dist = d;
                best_idx = i;
            }
        }

        return .{ .index = best_idx, .distance = best_dist, .offset = self.concept_offsets[best_idx] };
    }
};

// ══════════════════════════════════════════════════════════════════════════
//  V33: FlatGraph — Zero-Pointer SUDH-Accelerated Routing Table
// ══════════════════════════════════════════════════════════════════════════

/// Number of neighbor edges per node. Fixed at 16 to match GPU wavefront width.
pub const GRAPH_EDGES: u32 = 16;

/// Sentinel value meaning "this edge slot is empty."
pub const GRAPH_EMPTY: u32 = 0xFFFFFFFF;

/// V33: A single node in the zero-pointer graph.
/// Each node stores exactly 16 neighbor indices (64 bytes, exactly one cache line).
pub const GraphNode = struct {
    neighbors: [GRAPH_EDGES]u32,
};

/// V33: Zero-pointer flat adjacency table for the SUDH-Accelerated Flat Graph.
/// Lives in a host-mapped Vulkan SSBO at binding 9.
/// The GPU can read all 16 neighbors of any concept without pointer chasing.
pub const FlatGraph = struct {
    /// Flat edge array: allocated by VulkanEngine from the mapped SSBO.
    nodes: []GraphNode,
    /// Number of MeaningMatrix slots.
    num_slots: u32,

    /// Wrap a mapped SSBO pointer as a FlatGraph view. Zero-copy.
    pub fn fromMapped(ptr: [*]GraphNode, num_slots: u32) FlatGraph {
        return .{
            .nodes = ptr[0..num_slots],
            .num_slots = num_slots,
        };
    }

    /// Initialize all edge slots to GRAPH_EMPTY.
    pub fn clear(self: *FlatGraph) void {
        for (self.nodes) |*node| {
            @memset(&node.neighbors, GRAPH_EMPTY);
        }
    }

    /// Get a mutable slice of the 16 edge slots for a given node.
    pub inline fn edgesOf(self: *FlatGraph, slot: u32) []u32 {
        return self.nodes[slot].neighbors[0..];
    }

    /// Get a read-only slice of the 16 edge slots for a given node.
    pub inline fn edgesOfConst(self: *const FlatGraph, slot: u32) []const u32 {
        return self.nodes[slot].neighbors[0..];
    }

    /// Attempt to add `candidate` as a neighbor of `node`.
    pub fn maintainEdges(
        self: *FlatGraph,
        node: u32,
        node_vec: HyperVector,
        candidate: u32,
        candidate_vec: HyperVector,
        matrix: *const MeaningMatrix,
    ) void {
        if (node == candidate) return;
        if (node >= self.num_slots or candidate >= self.num_slots) return;

        const cand_dist = hammingDistance(node_vec, candidate_vec);
        const node_edges = self.edgesOf(node);

        var worst_idx: usize = 0;
        var worst_dist: u16 = 0;

        for (node_edges, 0..) |nb, i| {
            // Already present → no-op
            if (nb == candidate) return;
            // Empty slot → fill immediately, bidirectional update
            if (nb == GRAPH_EMPTY) {
                node_edges[i] = candidate;
                // Bidirectional: try to add node to candidate's edge list too
                self.maintainEdgesUnidirectional(candidate, candidate_vec, node, node_vec, matrix);
                return;
            }
            // Track worst existing neighbor
            const nb_vec = matrix.collapseToBinaryAtSlot(nb);
            const d = hammingDistance(node_vec, nb_vec);
            if (d > worst_dist) {
                worst_dist = d;
                worst_idx = i;
            }
        }

        // No empty slots. Replace worst if candidate is closer.
        if (cand_dist < worst_dist) {
            node_edges[worst_idx] = candidate;
            self.maintainEdgesUnidirectional(candidate, candidate_vec, node, node_vec, matrix);
        }
    }

    /// One-directional edge maintenance. Same logic as maintainEdges() but does
    /// not recurse back — prevents infinite mutual bidirectional recursion.
    fn maintainEdgesUnidirectional(
        self: *FlatGraph,
        node: u32,
        node_vec: HyperVector,
        candidate: u32,
        candidate_vec: HyperVector,
        matrix: *const MeaningMatrix,
    ) void {
        if (node == candidate) return;
        if (node >= self.num_slots or candidate >= self.num_slots) return;

        const cand_dist = hammingDistance(node_vec, candidate_vec);
        const node_edges = self.edgesOf(node);

        var worst_idx: usize = 0;
        var worst_dist: u16 = 0;

        for (node_edges, 0..) |nb, i| {
            if (nb == candidate) return;
            if (nb == GRAPH_EMPTY) {
                node_edges[i] = candidate;
                return;
            }
            const nb_vec = matrix.collapseToBinaryAtSlot(nb);
            const d = hammingDistance(node_vec, nb_vec);
            if (d > worst_dist) {
                worst_dist = d;
                worst_idx = i;
            }
        }

        if (cand_dist < worst_dist) {
            node_edges[worst_idx] = candidate;
        }
    }

    /// O(log N) approximate nearest-neighbor search using the flat graph.
    pub fn greedySearch(
        self: *const FlatGraph,
        query: HyperVector,
        entry_slot: u32,
        matrix: *const MeaningMatrix,
        max_hops: u32,
    ) struct { slot: u32, distance: u16 } {
        var current = entry_slot;
        var current_vec = matrix.collapseToBinaryAtSlot(current);
        var current_dist = hammingDistance(query, current_vec);

        var retry: u32 = 0;
        const MAX_RETRIES = 2;

        while (retry <= MAX_RETRIES) : (retry += 1) {
            var hop: u32 = 0;
            while (hop < max_hops) : (hop += 1) {
                const neighbors = self.edgesOfConst(current);
                var best_nb = current;
                var best_dist = current_dist;

                for (neighbors) |nb| {
                    if (nb == GRAPH_EMPTY or nb >= self.num_slots) continue;
                    const nb_vec = matrix.collapseToBinaryAtSlot(nb);
                    const d = hammingDistance(query, nb_vec);
                    if (d < best_dist) {
                        best_dist = d;
                        best_nb = nb;
                    }
                }

                // Convergence: no neighbor improved → we're at a local minimum
                if (best_nb == current) break;
                current = best_nb;
                current_vec = matrix.collapseToBinaryAtSlot(current);
                current_dist = best_dist;
            }

            // V33: The Ejection Seat — if resonance is still low (Hamming distance > 324),
            // trigger a SUDH Re-Roll to avoid a "Small World" dead-end trap.
            if (current_dist <= 324 or retry >= MAX_RETRIES) break;

            // Re-Roll: Shift the entry point to a different neighborhood using SUDH stride
            const word_hash = @as(u64, entry_slot) *% 0xbf58476d1ce4e5b9; // Deterministic re-seed
            const addr = computeSudhAddress(entry_slot ^ (retry +% 1), word_hash, self.num_slots);
            current = addr.probe(retry +% 1, self.num_slots);
            current_vec = matrix.collapseToBinaryAtSlot(current);
            current_dist = hammingDistance(query, current_vec);
        }

        return .{ .slot = current, .distance = current_dist };
    }
};

// ════════════════════════════════════════════════════════
//  HNSW Index — O(log N) approximate nearest-neighbor search
// ══════════════════════════════════════════════════════

pub const HnswIndex = struct {
    pub const M: u32 = 12; // Max neighbors per layer (layer 0 gets 2*M)
    pub const M0: u32 = 2 * M; // Max neighbors at layer 0
    pub const EF_CONSTRUCTION: u32 = 100;
    pub const EF_SEARCH: u32 = 50;
    pub const MAX_LEVEL: u8 = 16;

    // Per-node metadata
    levels: []u8, // max layer for each node
    // Flat neighbor storage: each node gets a header [count, ...neighbor_ids]
    // At layer 0: up to M0 neighbors. At layer L>0: up to M neighbors.
    // Layout: node_base[node_id] points to the start of that node's neighbor data.
    // We pre-allocate M0 + MAX_LEVEL * M slots per node.
    neighbors: []u32,
    neighbor_counts: []u8, // total neighbor count for each node (all layers packed)
    node_bases: []u32, // offset into neighbors[] for each node
    slots_per_node: u32,

    num_nodes: u32,
    entry_point: u32,
    max_level: u8,
    rng_state: u64,
    scratch_visited: []bool,

    concepts: []const HyperVector, // borrowed pointer to concept array
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_nodes: u32, concepts: []const HyperVector) !HnswIndex {
        const spn = M0 + @as(u32, MAX_LEVEL) * M; // worst case slots per node
        return .{
            .levels = try allocator.alloc(u8, max_nodes),
            .neighbors = try allocator.alloc(u32, @as(u64, spn) * @as(u64, max_nodes)),
            .neighbor_counts = try allocator.alloc(u8, max_nodes),
            .node_bases = try allocator.alloc(u32, max_nodes),
            .num_nodes = 0,
            .entry_point = 0,
            .max_level = 0,
            .rng_state = 0xdeadbeef12345678,
            .scratch_visited = try allocator.alloc(bool, max_nodes),
            .concepts = concepts,
            .allocator = allocator,
            .slots_per_node = spn,
        };
    }

    pub fn deinit(self: *HnswIndex) void {
        self.allocator.free(self.levels);
        self.allocator.free(self.neighbors);
        self.allocator.free(self.neighbor_counts);
        self.allocator.free(self.node_bases);
        self.allocator.free(self.scratch_visited);
    }

    fn randomLevel(self: *HnswIndex) u8 {
        // Exponential decay: P(level >= L) = (1/M)^L
        var level: u8 = 0;
        while (level < MAX_LEVEL) : (level += 1) {
            self.rng_state ^= self.rng_state << 13;
            self.rng_state ^= self.rng_state >> 7;
            self.rng_state ^= self.rng_state << 17;
            const threshold: u64 = std.math.maxInt(u64) / @as(u64, M);
            if (self.rng_state > threshold) break;
        }
        return level;
    }

    fn getNeighbors(self: *const HnswIndex, node_id: u32, layer: u8) []u32 {
        const base = self.node_bases[node_id];
        // Layer 0 gets first M0 slots, layer L gets next M slots each
        var offset: u32 = 0;
        if (layer == 0) {
            const count = @min(self.neighbor_counts[node_id], M0);
            return self.neighbors[base..][0..count];
        }
        offset = M0;
        var l: u8 = 1;
        while (l < layer) : (l += 1) {
            const layer_count = @min(@as(u32, self.neighbor_counts[node_id]) -| offset, M);
            offset += layer_count;
        }
        const remaining = @as(u32, self.neighbor_counts[node_id]) -| offset;
        const count = @min(remaining, M);
        return self.neighbors[base + offset ..][0..count];
    }

    fn distanceTo(self: *const HnswIndex, node_id: u32, query: HyperVector) u16 {
        return hammingDistance(self.concepts[node_id], query);
    }

    const SearchResult = struct { id: u32, dist: u16 };

    fn searchLayer(self: *HnswIndex, query: HyperVector, entry_points: []const u32, ef: u32, layer: u8) !std.ArrayListUnmanaged(SearchResult) {
        var candidates = std.ArrayListUnmanaged(SearchResult).empty;
        const visited = self.scratch_visited[0..self.num_nodes];
        @memset(visited, false);

        // Seed with entry points
        for (entry_points) |ep| {
            if (ep >= self.num_nodes) continue;
            if (visited[ep]) continue;
            visited[ep] = true;
            const d = self.distanceTo(ep, query);
            try candidates.append(self.allocator, .{ .id = ep, .dist = d });
        }

        // Expand: repeatedly take the closest unexpanded candidate and add its neighbors
        var expanded: u32 = 0;
        while (expanded < ef and expanded < candidates.items.len) : (expanded += 1) {
            // Find the closest unexpanded candidate
            const c = candidates.items[expanded];
            const neighbors = self.getNeighbors(c.id, layer);
            for (neighbors) |nid| {
                if (nid >= self.num_nodes or visited[nid]) continue;
                visited[nid] = true;
                const d = self.distanceTo(nid, query);
                // Insert into candidates sorted by distance if it improves the beam
                if (candidates.items.len < ef) {
                    try candidates.append(self.allocator, .{ .id = nid, .dist = d });
                    // Sort insertion point
                    var j = candidates.items.len - 1;
                    while (j > expanded + 1 and candidates.items[j].dist < candidates.items[j - 1].dist) : (j -= 1) {
                        const tmp = candidates.items[j];
                        candidates.items[j] = candidates.items[j - 1];
                        candidates.items[j - 1] = tmp;
                    }
                } else if (d < candidates.items[candidates.items.len - 1].dist) {
                    // Replace worst candidate
                    candidates.items[candidates.items.len - 1] = .{ .id = nid, .dist = d };
                    // Re-sort tail
                    var j = candidates.items.len - 1;
                    while (j > expanded + 1 and candidates.items[j].dist < candidates.items[j - 1].dist) : (j -= 1) {
                        const tmp = candidates.items[j];
                        candidates.items[j] = candidates.items[j - 1];
                        candidates.items[j - 1] = tmp;
                    }
                }
            }
        }

        return candidates;
    }

    pub fn insert(self: *HnswIndex, node_id: u32) void {
        if (node_id >= self.concepts.len) return;
        const query = self.concepts[node_id];
        const level = self.randomLevel();

        self.levels[node_id] = level;
        self.neighbor_counts[node_id] = 0;
        self.node_bases[node_id] = node_id * self.slots_per_node;
        self.num_nodes = @max(self.num_nodes, node_id + 1);

        if (self.num_nodes <= 1) {
            self.entry_point = 0;
            self.max_level = level;
            return;
        }

        // Phase 1: Greedy descent from top to (level + 1)
        var ep = self.entry_point;
        var cur_level = self.max_level;
        while (cur_level > level) : (cur_level -= 1) {
            var changed = true;
            var cur_dist = self.distanceTo(ep, query);
            while (changed) {
                changed = false;
                const neighbors = self.getNeighbors(ep, cur_level);
                for (neighbors) |nid| {
                    if (nid >= self.num_nodes) continue;
                    const d_new = self.distanceTo(nid, query);
                    if (d_new < cur_dist) {
                        ep = nid;
                        cur_dist = d_new;
                        changed = true;
                    }
                }
            }
        }

        // Phase 2: Beam search at each layer from min(level, max_level) down to 0
        const top_layer = @min(level, self.max_level);
        var l: i32 = @intCast(top_layer);
        while (l >= 0) : (l -= 1) {
            const layer_u8 = @as(u8, @intCast(l));
            const max_conn = if (layer_u8 == 0) M0 else M;
            const ep_slice = [_]u32{ep};
            var results = self.searchLayer(query, &ep_slice, EF_CONSTRUCTION, layer_u8) catch return;
            defer results.deinit(self.allocator);

            // Connect to closest neighbors (up to max_conn)
            const connect_count = @min(@as(u32, @intCast(results.items.len)), max_conn);
            const base = self.node_bases[node_id];
            for (0..connect_count) |i| {
                const neighbor_id = results.items[i].id;
                self.neighbors[base + i] = neighbor_id;
            }
            self.neighbor_counts[node_id] = @intCast(connect_count);

            // Add bidirectional links
            for (0..connect_count) |i| {
                self.addBidirectional(node_id, results.items[i].id, layer_u8);
            }

            // Update entry point for next layer
            if (results.items.len > 0) ep = results.items[0].id;
        }

        // Update global entry point if this node has the highest level
        if (level > self.max_level) {
            self.max_level = level;
            self.entry_point = node_id;
        }
    }

    fn addBidirectional(self: *HnswIndex, new_node: u32, existing_node: u32, layer: u8) void {
        const max_conn = if (layer == 0) M0 else M;
        const base = self.node_bases[existing_node];
        const count = @as(u32, self.neighbor_counts[existing_node]);

        // Check if already connected
        for (0..count) |i| {
            if (self.neighbors[base + i] == new_node) return;
        }

        if (count < max_conn) {
            // Room available: just append
            self.neighbors[base + count] = new_node;
            self.neighbor_counts[existing_node] = @intCast(count + 1);
        } else {
            // Full: replace the farthest neighbor if new_node is closer
            const query = self.concepts[existing_node];
            var worst_idx: u32 = 0;
            var worst_dist: u16 = 0;
            for (0..max_conn) |i| {
                const d = self.distanceTo(self.neighbors[base + i], query);
                if (d > worst_dist) {
                    worst_dist = d;
                    worst_idx = @intCast(i);
                }
            }
            const new_dist = self.distanceTo(new_node, query);
            if (new_dist < worst_dist) {
                self.neighbors[base + worst_idx] = new_node;
            }
        }
    }

    /// O(log N) approximate nearest-neighbor search.
    pub fn search(self: *const HnswIndex, query: HyperVector) ?struct { index: usize, distance: u16 } {
        if (self.num_nodes == 0) return null;

        var ep = self.entry_point;
        // Phase 1: Greedy descent from top layer to layer 1
        var cur_level: i32 = @intCast(self.max_level);
        var ep_dist = self.distanceTo(ep, query);
        while (cur_level > 0) : (cur_level -= 1) {
            const layer_u8 = @as(u8, @intCast(cur_level));
            var changed = true;
            while (changed) {
                changed = false;
                const neighbors = self.getNeighbors(ep, layer_u8);
                for (neighbors) |nid| {
                    if (nid >= self.num_nodes) continue;
                    const d_new = self.distanceTo(nid, query);
                    if (d_new < ep_dist) {
                        ep = nid;
                        ep_dist = d_new;
                        changed = true;
                    }
                }
            }
        }

        // Phase 2: Beam search at layer 0
        var best_id: u32 = ep;
        var best_dist: u16 = ep_dist;

        var beam = [_]u32{ep} ** 64;
        var beam_len: u32 = 1;
        const visited = self.scratch_visited[0..self.num_nodes];
        @memset(visited, false);
        visited[ep] = true;

        var iter: u32 = 0;
        while (iter < EF_SEARCH and iter < beam_len) : (iter += 1) {
            const current = beam[iter];
            if (current >= self.num_nodes) continue;
            const neighbors = self.getNeighbors(current, 0);
            for (neighbors) |nid| {
                if (nid >= self.num_nodes) continue;
                if (visited[nid]) continue;
                visited[nid] = true;
                const d = self.distanceTo(nid, query);
                if (d < best_dist) {
                    best_dist = d;
                    best_id = nid;
                }
                if (beam_len < 64) {
                    beam[beam_len] = nid;
                    beam_len += 1;
                }
            }
        }

        return .{ .index = best_id, .distance = best_dist };
    }
};
