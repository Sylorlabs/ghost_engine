const std = @import("std");
const build_options = @import("build_options");
const vsa = @import("vsa_core.zig");
const semantic_encoder = @import("semantic_encoder.zig");
const lattice_mmap = @import("vsa/lattice_mmap.zig");
const mmap_hv = @import("vsa/hypervector.zig");

pub const LOCAL_STATE_SEED: u64 = 0x4652_4f4e_5441_4c31; // "FRONTAL1"
pub const LATTICE_CAPACITY: u32 = 4096;

pub const IntentRoute = enum {
    scalar,
    z3,
    vsa,
};

pub fn init(allocator: std.mem.Allocator) !void {
    _ = allocator;
}

pub fn deinit() void {}

pub const EncoderSource = enum {
    frontal_lobe,
    local_state_space,
};

pub const OffloadStatus = enum {
    skipped,
    written,
    lattice_full,
    unavailable,
};

pub const OffloadResult = struct {
    status: OffloadStatus,
    slot: ?u32 = null,
};

pub const Projection = struct {
    source: EncoderSource,
    route: IntentRoute,
    intent_vector: vsa.HyperVector,
    hidden_state: vsa.HyperVector,
    route_vector: vsa.HyperVector,
    scalar_score: u32,
    z3_score: u32,
    vsa_score: u32,
    confidence_per_mille: u16,
    state_hash: u64,
    offload: OffloadResult = .{ .status = .skipped },
};

// No more lazy bootstrap examples. Intent is now determined by pure semantic resonance
// against orthogonal route centroids.

pub fn projectLocalIntent(allocator: std.mem.Allocator, text: []const u8) !Projection {
    _ = allocator;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const hidden_state = try evolveHiddenState(trimmed);
    const concept_state = semantic_encoder.encodeDomainConcept(trimmed, "human_intent");
    const intent_vector = vsa.bundle(hidden_state, concept_state, semantic_encoder.encodeConceptString(trimmed));

    var scores = IntentScores{};
    // Calculate pure resonance against route centroids
    scores.scalar = @as(u32, vsa.resonanceScore(intent_vector, vsa.ROUTE_VEC_SCALAR));
    scores.z3 = @as(u32, vsa.resonanceScore(intent_vector, vsa.ROUTE_VEC_Z3));
    scores.vsa = @as(u32, vsa.resonanceScore(intent_vector, vsa.ROUTE_VEC_VSA));

    // Bias for structural signals to capture "human weirdness" (math symbols, etc.)
    scores.applyStructuralSignals(trimmed);

    const route = scores.selectRoute();
    return projectionFromRoute(.local_state_space, route, intent_vector, hidden_state, scores);
}

pub fn projectExternalIntent(text: []const u8, intent_vector: vsa.HyperVector) Projection {
    const hidden_state = evolveHiddenState(text) catch vsa.generate(LOCAL_STATE_SEED);
    var scores = IntentScores{};
    scores.scalar = 1024 -| vsa.hammingDistance(intent_vector, vsa.ROUTE_VEC_SCALAR);
    scores.z3 = 1024 -| vsa.hammingDistance(intent_vector, vsa.ROUTE_VEC_Z3);
    scores.vsa = 1024 -| vsa.hammingDistance(intent_vector, vsa.ROUTE_VEC_VSA);
    const route = scores.selectRoute();
    return projectionFromRoute(.frontal_lobe, route, intent_vector, hidden_state, scores);
}

pub fn offloadDefault(allocator: std.mem.Allocator, projection: *Projection) void {
    projection.offload = offloadToPath(allocator, defaultLatticePath(allocator) catch {
        projection.offload = .{ .status = .unavailable };
        return;
    }, projection.hidden_state) catch |err| switch (err) {
        error.LatticeFull => .{ .status = .lattice_full },
        else => .{ .status = .unavailable },
    };
}

pub fn offloadToPath(allocator: std.mem.Allocator, path: []const u8, vector: vsa.HyperVector) !OffloadResult {
    defer allocator.free(path);
    var lattice = try lattice_mmap.MmapLattice.initOrOpen(path, LATTICE_CAPACITY);
    defer lattice.deinit();
    const slot = try lattice.append(toMmapVector(vector));
    return .{ .status = .written, .slot = slot };
}

fn defaultLatticePath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "GHOST_FRONTAL_LOBE_LATTICE")) |path| {
        return path;
    } else |_| {}

    const state_dir = try std.fs.path.join(allocator, &.{ build_options.project_root, ".ghost" });
    defer allocator.free(state_dir);
    try std.fs.cwd().makePath(state_dir);
    return std.fs.path.join(allocator, &.{ state_dir, "frontal_lobe_vsa.bin" });
}

fn reviewedExamplesPath(allocator: std.mem.Allocator) !?[]const u8 {
    if (std.process.getEnvVarOwned(allocator, "GHOST_FRONTAL_LOBE_EXAMPLES")) |path| {
        return path;
    } else |_| {}

    const path = try std.fs.path.join(allocator, &.{ build_options.project_root, ".ghost", "frontal_lobe_routes.jsonl" });
    if (std.fs.accessAbsolute(path, .{})) |_| return path else |_| {
        allocator.free(path);
        return null;
    }
}

pub fn initAndRunInference(text: []const u8) !vsa.HyperVector {
    return try evolveHiddenState(text);
}

fn evolveHiddenState(text: []const u8) !vsa.HyperVector {
    return semantic_encoder.encodeConceptStringSeeded(text, LOCAL_STATE_SEED);
}

const IntentScores = struct {
    scalar: u32 = 0,
    z3: u32 = 0,
    vsa: u32 = 0,

    fn add(self: *IntentScores, route: IntentRoute, amount: u32) void {
        switch (route) {
            .scalar => self.scalar += amount,
            .z3 => self.z3 += amount,
            .vsa => self.vsa += amount,
        }
    }

    fn applyStructuralSignals(self: *IntentScores, text: []const u8) void {
        var z3_boost: u32 = 0;
        var vsa_boost: u32 = 0;
        var scalar_boost: u32 = 0;

        for (text) |byte| {
            if (byte == '+' or byte == '-' or byte == '*' or byte == '/' or byte == '=') {
                z3_boost += 200;
            }
        }
        if (std.mem.indexOf(u8, text, "prove") != null or std.mem.indexOf(u8, text, "Z3") != null) {
            z3_boost += 400;
        }

        if (std.mem.indexOf(u8, text, "what") != null or std.mem.indexOf(u8, text, "how") != null or std.mem.indexOf(u8, text, "why") != null) {
            vsa_boost += 200;
        }
        if (std.mem.indexOf(u8, text, "hypervector") != null or std.mem.indexOf(u8, text, "rune") != null or std.mem.indexOf(u8, text, "vsa") != null) {
            vsa_boost += 400;
        }

        if (std.mem.indexOf(u8, text, "hi") != null or std.mem.indexOf(u8, text, "hello") != null or std.mem.indexOf(u8, text, "hey") != null or std.mem.indexOf(u8, text, "thanks") != null or std.mem.indexOf(u8, text, "thank") != null) {
            scalar_boost += 300;
        }

        self.z3 += z3_boost;
        self.vsa += vsa_boost;
        self.scalar += scalar_boost;
    }

    fn selectRoute(self: IntentScores) IntentRoute {
        if (self.z3 > self.scalar and self.z3 > self.vsa) return .z3;
        if (self.scalar > self.vsa) return .scalar;
        return .vsa;
    }
};

fn scoreReviewedExamples(allocator: std.mem.Allocator, scores: *IntentScores, text: []const u8, query: vsa.HyperVector) !void {
    _ = allocator;
    _ = scores;
    _ = text;
    _ = query;
}

fn projectionFromRoute(source: EncoderSource, route: IntentRoute, intent_vector: vsa.HyperVector, hidden_state: vsa.HyperVector, scores: IntentScores) Projection {
    const route_vector = switch (route) {
        .scalar => vsa.ROUTE_VEC_SCALAR,
        .z3 => vsa.ROUTE_VEC_Z3,
        .vsa => vsa.ROUTE_VEC_VSA,
    };
    const confidence = confidencePerMille(route, scores);
    return .{
        .source = source,
        .route = route,
        .intent_vector = intent_vector,
        .hidden_state = hidden_state,
        .route_vector = route_vector,
        .scalar_score = scores.scalar,
        .z3_score = scores.z3,
        .vsa_score = scores.vsa,
        .confidence_per_mille = confidence,
        .state_hash = vsa.collapse(hidden_state),
    };
}

fn confidencePerMille(route: IntentRoute, scores: IntentScores) u16 {
    const selected = switch (route) {
        .scalar => scores.scalar,
        .z3 => scores.z3,
        .vsa => scores.vsa,
    };
    const total = scores.scalar + scores.z3 + scores.vsa;
    if (total == 0) return 0;
    return @intCast(@min(@as(u32, 1000), (selected * 1000) / total));
}

fn toMmapVector(vector: vsa.HyperVector) mmap_hv.HyperVector {
    // working vector is 4096-bit (64 lanes); mmap persistence is 1024-bit (16 lanes), so store the primary
    // 16 lanes (4096-bit migration: project at the mmap serialization boundary).
    const full: [64]u64 = vector;
    return .{ .lanes = full[0..16].* };
}

// Helpers removed. Using pure VSA resonance.

test "local frontal lobe projects fuzzy intent into VSA route space" {
    const allocator = std.testing.allocator;
    const scalar = try projectLocalIntent(allocator, "ready");
    const logic = try projectLocalIntent(allocator, "2+3");
    const memory = try projectLocalIntent(allocator, "find related memory in the semantic lattice");

    try std.testing.expectEqual(IntentRoute.scalar, scalar.route);
    try std.testing.expectEqual(IntentRoute.z3, logic.route);
    try std.testing.expectEqual(IntentRoute.vsa, memory.route);
    try std.testing.expectEqual(@as(u16, 0), vsa.hammingDistance(logic.route_vector, vsa.ROUTE_VEC_Z3));
    try std.testing.expect(logic.confidence_per_mille > 0);
}

test "frontal lobe offloads hidden state into locked mmap lattice" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "frontal.bin" });
    var projection = try projectLocalIntent(allocator, "remember this semantic state");
    const result = try offloadToPath(allocator, path, projection.hidden_state);
    projection.offload = result;

    try std.testing.expectEqual(OffloadStatus.written, projection.offload.status);
    try std.testing.expectEqual(@as(?u32, 0), projection.offload.slot);
}
