const std = @import("std");

pub const ChamberCount = 512;
pub const ScarCount = 2048;
pub const LawCount = 1024;
pub const SequenceLen = 48;
pub const CandidateAttempts = 128;
pub const TextCandidateAttempts = 512;
pub const SignatureWords = 128;
pub const SampleCount = 2000;
pub const Kernel = 0x9F19CAEA95AD048E;
pub const PromptHash = 0x0DE7E4B4E9B4D825;

pub const Law = struct {
    a: usize,
    b: usize,
    ca: i128,
    cb: i128,
    t: i128,
};

pub const Flare = struct {
    mark: u64,
    heat: i128,
    phase: u32,
    scar: u64,
};

pub const InventionCandidate = struct {
    child_mark: u64,
    chamber_snapshot: [ChamberCount]i128,
    closure_before: u128,
    closure_after: u128,
    closure_delta: i128,
    scar: u64,
    trigger_edge: u8,
    generation: u32,
    signature: [SignatureWords]u64,
};

pub const FlameState = struct {
    chamber: [ChamberCount]i128,
    scar_bank: [ScarCount]u64,
    kernel: u64,
    closure_error: u128,

    pub fn init(seed: u64) FlameState {
        var state = FlameState{
            .chamber = [_]i128{0} ** ChamberCount,
            .scar_bank = [_]u64{0} ** ScarCount,
            .kernel = Kernel,
            .closure_error = 0,
        };
        var s = seed ^ Kernel;
        for (&state.chamber, 0..) |*slot, idx| {
            s = splitMix64(s +% @as(u64, @intCast(idx + 1)));
            slot.* = @as(i128, @intCast(s % 4096));
        }
        state.closure_error = closureError(&state);
        return state;
    }
};

const vsa = @import("vsa");

// PROCEDURAL SEMANTIC RESERVOIR GENERATION (Mark: 0x9F19CAEA95AD048E)
// We ground the laws in VSA bindings of real concept pairs.
pub const Laws = blk: {
    @setEvalBranchQuota(500000);
    var laws: [LawCount]Law = undefined;
    var s: u64 = Kernel;
    var i: usize = 0;
    while (i < LawCount) : (i += 1) {
        s = splitMix64(s +% i);
        
        // 1. Pick two semantic concepts based on the current state
        // Use full 20-concept enum so all VSA anchors seed laws (was % 10,
        // which left 11 of 20 concepts dormant — verified 2026-05-19 via
        // invention_global: HARDWARE/SOFTWARE/NETWORK/AETHER/VOID/TRUTH/
        // SHADOW/SIGNAL/NOISE/ORDER/CHAOS all had zero attractor basins).
        const c1 = @as(vsa.Concept, @enumFromInt(s % 20));
        const c2 = @as(vsa.Concept, @enumFromInt(splitMix64(s) % 20));
        
        // 2. Extract their VSA Hypervectors
        const hv1 = vsa.getConceptHV(c1);
        const hv2 = vsa.getConceptHV(c2);
        
        // 3. Bind them to find their semantic relationship
        const relationship = hv1.bind(hv2);
        
        // 4. Derive coefficients (ca, cb, t) from the hypervectors
        // ca = Bit Density of Concept 1
        // cb = Bit Density of Concept 2
        // t = Bit Density of the Relationship
        // This ensures the constraint solver solves for Semantic Consistency.
        laws[i].a = s % ChamberCount;
        laws[i].b = splitMix64(s) % ChamberCount;
        
        var d1: i128 = 0;
        var d2: i128 = 0;
        var dr: i128 = 0;
        for (hv1.data) |w| d1 += @popCount(w);
        for (hv2.data) |w| d2 += @popCount(w);
        for (relationship.data) |w| dr += @popCount(w);
        
        laws[i].ca = d1 - 512; // Center around zero
        laws[i].cb = d2 - 512;
        laws[i].t = (dr - 512) * 100; // Scaled target resonance
        // (Path A.2 tried adding ±64 magnitude floor here, made things
        // worse — collapsed to 2 attractors instead of 11. Reverted.)
        
        s = splitMix64(s ^ @as(u64, @intCast(dr)));
    }
    break :blk laws;
};

pub fn splitMix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub fn closureError(state: *const FlameState) u128 {
    var sum: u128 = 0;
    for (Laws) |law| {
        const got = law.ca * state.chamber[law.a] + law.cb * state.chamber[law.b];
        sum += @abs(got - law.t);
    }
    return sum;
}

pub fn relax(state: *FlameState, passes: usize) void {
    for (0..passes) |_| {
        for (Laws) |law| {
            const got = law.ca * state.chamber[law.a] + law.cb * state.chamber[law.b];
            const err = law.t - got;
            if (err == 0) continue;
            const denom = law.ca * law.ca + law.cb * law.cb;
            const da = @divTrunc(err * law.ca, denom);
            const db = @divTrunc(err * law.cb, denom);
            state.chamber[law.a] += @as(i128, @intCast(@max(-512, @min(512, da))));
            state.chamber[law.b] += @as(i128, @intCast(@max(-512, @min(512, db))));
        }
    }
    state.closure_error = closureError(state);
}

pub fn makeFlare(kernel: u64, mark: u64, phase: u32) Flare {
    var s = kernel ^ mark ^ @as(u64, phase);
    s = splitMix64(s);
    return .{
        .mark = mark,
        .heat = @as(i128, @intCast(s % 1024)) - 512,
        .phase = phase % ChamberCount,
        .scar = splitMix64(s ^ 0xACE),
    };
}

pub fn ingestSequence(state: *FlameState, seed: u64, len: usize) void {
    var s = seed;
    for (0..len) |i| {
        s = splitMix64(s ^ @as(u64, @intCast(i)));
        const flare = makeFlare(state.kernel, s, @as(u32, @intCast(i)));
        state.chamber[flare.phase] += flare.heat;
        state.scar_bank[flare.scar % ScarCount] ^= flare.scar;
    }
    state.closure_error = closureError(state);
}

pub fn improvementOf(before: u128, after: u128) u128 {
    if (after < before) return before - after;
    return 0;
}

pub fn isSignatureHealthy(sig: [SignatureWords]u64) bool {
    var p: u64 = 0;
    for (sig[0 .. SignatureWords - 1]) |word| p ^= word;
    return sig[SignatureWords - 1] == p;
}

pub fn signatureParity(sig: [SignatureWords]u64) u64 {
    var p: u64 = 0;
    for (sig[0 .. SignatureWords - 1]) |word| p ^= word;
    return p;
}

pub fn textHash(text: []const u8) u64 {
    var h: u64 = 0x811C9DC5;
    for (text) |b| {
        h = (h ^ @as(u64, b)) *% 0x01000193;
    }
    return h;
}

pub fn triggerActive(state: *const FlameState) bool {
    return state.closure_error > 1000000;
}

pub fn rawDemand(state: *const FlameState) struct { high_error: u128, low_error: u128 } {
    var high: u128 = 0;
    var low: u128 = ~@as(u128, 0);
    for (Laws) |law| {
        const got = law.ca * state.chamber[law.a] + law.cb * state.chamber[law.b];
        const err = @abs(got - law.t);
        if (err > high) high = err;
        if (err < low) low = err;
    }
    return .{ .high_error = high, .low_error = low };
}

pub fn inventionDemand(state: *const FlameState) ?struct { high_idx: u8, low_idx: u8 } {
    var high_err: u128 = 0;
    var low_err: u128 = ~@as(u128, 0);
    var high_idx: u8 = 0;
    var low_idx: u8 = 0;
    for (Laws, 0..) |law, i| {
        const got = law.ca * state.chamber[law.a] + law.cb * state.chamber[law.b];
        const err = @abs(got - law.t);
        if (err > high_err) {
            high_err = err;
            high_idx = @intCast(i);
        }
        if (err < low_err) {
            low_err = err;
            low_idx = @intCast(i);
        }
    }
    if (high_err < 540000) return null;
    return .{ .high_idx = high_idx, .low_idx = low_idx };
}

pub const WeirdRequest = struct { label: []const u8, text: []const u8 };
pub const WeirdRequests = [_]WeirdRequest{
    .{ .label = "typo-intent", .text = "build me an engine that works on hardeare consuemr" },
    .{ .label = "tiny-hardware", .text = "runs on 1mb ram and 1mhz cpu" },
    .{ .label = "anti-fragile", .text = "it should be impossible to break the logic" },
    .{ .label = "self-repair", .text = "the engine should fix its own errors" },
    .{ .label = "alien-basics", .text = "math that humans have not found yet" },
    .{ .label = "no-token-runes", .text = "ingest characters as runes not tokens" },
    .{ .label = "hardware-shape", .text = "the architecture is the physical chip" },
    .{ .label = "infinite-depth", .text = "recursive dimensions within the chamber" },
    .{ .label = "truth-nucleus", .text = "only store the absolute structural truth" },
    .{ .label = "spectral-void", .text = "ingest the web via bitwise resonance" },
    .{ .label = "recursive-inventor", .text = "an engine that invents better engines" },
    .{ .label = "human-parity", .text = "speak in perfect human English with logic" },
};
pub const WeirdTrials = 256;

pub fn textPreparedState(seed: u64, text: []const u8) FlameState {
    var state = FlameState.init(seed);
    const h = textHash(text);
    ingestSequence(&state, h, SequenceLen);
    relax(&state, 10);
    return state;
}

pub fn vsaIngestSignature(seed: u64) [SignatureWords]u64 {
    var sig: [SignatureWords]u64 = [_]u64{0} ** SignatureWords;
    var s = seed;
    for (&sig) |*word| {
        s = splitMix64(s);
        word.* = s;
    }
    return sig;
}

pub fn vsaIngestTextSignature(seed: u64, text: []const u8) [SignatureWords]u64 {
    return vsaIngestSignature(seed ^ textHash(text));
}

pub fn vsaInventFromState(sig: [SignatureWords]u64, state: *const FlameState, gen: u32) ?InventionCandidate {
    _ = sig; _ = state; _ = gen; return null;
}

pub fn vsaInventFromStateBudget(sig: [SignatureWords]u64, state: *const FlameState, gen: u32, budget: usize) ?InventionCandidate {
    _ = sig; _ = state; _ = gen; _ = budget; return null;
}

pub fn maybeInvent(state: *const FlameState, gen: u32) ?InventionCandidate {
    _ = state; _ = gen; return null;
}

pub fn maybeInventText(state: *const FlameState, text: []const u8, gen: u32) ?InventionCandidate {
    _ = state; _ = text; _ = gen; return null;
}

pub fn runRecursive(cand: InventionCandidate) ?InventionCandidate {
    _ = cand; return null;
}

pub fn shapeTextPressure(state: *FlameState, seed: u64, text: []const u8) void {
    const h = textHash(text) ^ splitMix64(seed);
    const edge: usize = @intCast(h % LawCount);
    const law = Laws[edge];
    const sign: i128 = if (((h >> 9) & 1) == 0) 1 else -1;
    const magnitude = @as(i128, @intCast(12_000 + (h % 24_000))) * sign;
    state.chamber[law.a] += magnitude;
    state.chamber[law.b] -= @divTrunc(magnitude * 5, 11);
    state.chamber[(law.b + 3) % ChamberCount] += @divTrunc(magnitude, 7);
    state.scar_bank[h % ScarCount] ^= splitMix64(h ^ PromptHash);
    state.closure_error = closureError(state);
}
