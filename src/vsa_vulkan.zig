const std = @import("std");
const build_options = @import("build_options");
const vl = @import("vulkan_loader.zig");
const vk = vl.vk; // Types & constants only — no link-time dependency
const builtin = @import("builtin");
const config = @import("config.zig");
const sys = @import("sys.zig");
const vsa_core = @import("vsa_core.zig");
const gemma_config = @import("gemma/config.zig");
const sigil_runtime = @import("sigil_runtime.zig");
const gpu_lattice = @import("gpu/vulkan_init.zig");
const vk_device = @import("vsa_vulkan/device.zig");
const vk_resonance = @import("vsa_vulkan/resonance.zig");
const vk_runtime = @import("vsa_vulkan/runtime.zig");

// --- GHOST ENGINE: VULKAN CORE ---
// Multi-GPU Sovereign Fleet.

pub const FRAME_COUNT = 3;
pub const INF_LANE_COUNT = 5; // Parallel inference streams for Monte Carlo
pub const ROTOR_STRIDE = 18; // 16x u64 spatial + 2x u64 (lexical, semantic)
pub const LAYER2A_MAX_CANDIDATES = config.BEAM_NUM_LANES;
pub const LAYER2A_NO_WINNER: u32 = 0xFFFFFFFF;
pub const GHOST_INDEX_BLOCK_BYTES: usize = 1024 * 1024;
pub const GHOST_INDEX_SKIP_THRESHOLD_PER_MILLE: u16 = 500;
pub const CORPUS_SCAN_MAX_ENTRIES: usize = 65_536;
pub const CORPUS_SCAN_MAX_TERMS: usize = 4;
pub const CORPUS_SCAN_TERM_BYTES: usize = 16;
pub const LatticeQueryRune = gpu_lattice.GreRune;
pub const GEMMA_FORWARD_STAGES_PER_BLOCK: u32 = 14;
const DESCRIPTOR_BINDING_COUNT: u32 = 15;
const GEMMA_DESCRIPTOR_BINDING_COUNT: u32 = 6; // weights, inA, inB, matrix, scores, rune_ids
const GEMMA_DESCRIPTOR_SET_COUNT: u32 = 6;
const FENCE_TIMEOUT_NS: u64 = 2_000_000_000;
const SHUTDOWN_FENCE_TIMEOUT_NS: u64 = 5 * std.time.ns_per_s;
const VALIDATION_LAYER_NAME: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";
const DEBUG_UTILS_EXTENSION_NAME: [*:0]const u8 = "VK_EXT_debug_utils";
const UPLOAD_STAGING_SLOTS = vk_device.DEFAULT_UPLOAD_STAGING_SLOTS;

pub const OperationalTier = vk_runtime.OperationalTier;
pub const parseOperationalTierAlias = vk_runtime.parseOperationalTierAlias;
pub const tierNameFromValue = vk_runtime.tierNameFromValue;

pub const RoleBoundVector = vk_resonance.RoleBoundVector;
pub const FrameKind = vk_resonance.FrameKind;
pub const FrameRole = vk_resonance.FrameRole;
pub const SemanticFrameVector = vk_resonance.SemanticFrameVector;
pub const FRAME_ROLE_DIMS = vk_resonance.FRAME_ROLE_DIMS;
pub const SpoVector = vk_resonance.SpoVector;
pub const OntologySignal = vk_resonance.OntologySignal;
pub const DynamicToolKind = vk_resonance.DynamicToolKind;
pub const DynamicToolBinding = vk_resonance.DynamicToolBinding;
pub const extractFrameVector = vk_resonance.extractFrameVector;
pub const extractSpoVector = vk_resonance.extractSpoVector;
pub const bindDynamicAxioms = vk_resonance.bindDynamicAxioms;
pub const relationScorePerMille = vk_resonance.relationScorePerMille;
pub const relationPenaltyPerMille = vk_resonance.relationPenaltyPerMille;
pub const graphIsomorphismScorePerMille = vk_resonance.graphIsomorphismScorePerMille;
pub const ByteBoundary = vk_resonance.ByteBoundary;
pub const paragraphBoundary = vk_resonance.paragraphBoundary;
pub const isStrictParagraphBounded = vk_resonance.isStrictParagraphBounded;
pub const SPO_DIRECT_MATCH_BONUS = vk_resonance.SPO_DIRECT_MATCH_BONUS;
pub const SPO_PARTIAL_MATCH_BONUS = vk_resonance.SPO_PARTIAL_MATCH_BONUS;
pub const SPO_INVERSE_MATCH_PENALTY_PER_MILLE = vk_resonance.SPO_INVERSE_MATCH_PENALTY_PER_MILLE;

pub const SemanticSpace = enum {
    none,
    entertainment,
    computing,
    biography,
};

pub fn contextualRelationScorePerMille(query: SpoVector, context: SpoVector, candidate: SpoVector) u16 {
    const direct = relationScorePerMille(query, candidate);
    if (direct >= 1000) return direct;
    const context_score = relationScorePerMille(context, candidate);
    return @max(direct, context_score);
}

pub fn detectSemanticSpace(text: []const u8) SemanticSpace {
    if (containsAsciiFold(text, "simpsons") or containsAsciiFold(text, "television") or containsAsciiFold(text, "episode")) return .entertainment;
    if (containsAsciiFold(text, "computer") or containsAsciiFold(text, "software") or containsAsciiFold(text, "program")) return .computing;
    if (containsAsciiFold(text, "born") or containsAsciiFold(text, "physicist") or containsAsciiFold(text, "biography")) return .biography;
    return .none;
}

pub fn murmur3Bytes64(bytes: []const u8) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(bytes);
    return hasher.final();
}

fn containsAsciiFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return true;
    }
    return false;
}

pub fn runtimeLogsEnabled() bool {
    return envFlag("GHOST_ENGINE_DEBUG") or
        envFlag("GHOST_ENGINE_VERBOSE") or
        envFlag("GHOST_DEBUG") or
        envFlag("GHOST_VERBOSE");
}

var debug_validation_requested = std.atomic.Value(bool).init(false);

pub fn enableDebugValidationForProcess() void {
    debug_validation_requested.store(true, .release);
}

pub const NEGATIVE_SIGNAL_COLOR_PROFILE = "subtle_red_gray";
pub const NEGATIVE_SIGNAL_SIGIL_OPACITY_PER_MILLE: u16 = 420;

pub const NegativeSignalSnapshot = struct {
    active: bool = false,
    count: u64 = 0,
    last_query_hash: u64 = 0,
    color_profile: []const u8 = NEGATIVE_SIGNAL_COLOR_PROFILE,
    sigil_opacity_per_mille: u16 = NEGATIVE_SIGNAL_SIGIL_OPACITY_PER_MILLE,
};

pub const GemmaPushConstants = struct {
    rows_or_count: u32 = 0,
    cols_or_len: u32 = 0,
    row_offset: u32 = 0,
    flags: u32 = 0,
    weight_offset: u64 = 0,
};

pub const GemmaInferenceState = struct {
    weights: ResidentBuffer = .{},
    hidden: [2]ResidentBuffer = [_]ResidentBuffer{.{}} ** 2, // Ping-pong activations
    q: ResidentBuffer = .{},
    k: ResidentBuffer = .{},
    v: ResidentBuffer = .{},
    scores: ResidentBuffer = .{},
    embeddings: ResidentBuffer = .{},
    context_rune_ids: ResidentBuffer = .{},
    tensor_offsets: std.StringHashMap(u64),
    
    pub fn deinit(self: *GemmaInferenceState, engine: *const VulkanEngine) void {
        engine.destroyResidentBuffer(&self.weights);
        engine.destroyResidentBuffer(&self.hidden[0]);
        engine.destroyResidentBuffer(&self.hidden[1]);
        engine.destroyResidentBuffer(&self.q);
        engine.destroyResidentBuffer(&self.k);
        engine.destroyResidentBuffer(&self.v);
        engine.destroyResidentBuffer(&self.scores);
        engine.destroyResidentBuffer(&self.embeddings);
        engine.destroyResidentBuffer(&self.context_rune_ids);
        self.tensor_offsets.deinit();
    }
};

pub const GemmaForwardScheduleConfig = struct {
    block_count: u32 = @intCast(gemma_config.default_block_count),
    embedding_len: u32 = @intCast(gemma_config.default_embedding_length),
    rune_count: u32 = 1,
    top_k: u32 = @intCast(gemma_config.default_attention_top_k),
    attention_head_count: u32 = @intCast(gemma_config.default_attention_head_count),
    attention_head_count_kv: u32 = @intCast(gemma_config.default_attention_head_count_kv),
    attention_key_length: u32 = @intCast(gemma_config.default_attention_key_length),
    attention_key_length_swa: u32 = @intCast(gemma_config.default_attention_key_length_swa),
    attention_value_length: u32 = @intCast(gemma_config.default_attention_value_length),
    attention_value_length_swa: u32 = @intCast(gemma_config.default_attention_value_length_swa),

    pub fn ffnDim(self: GemmaForwardScheduleConfig, layer_idx: u32) !u32 {
        _ = self;
        if (layer_idx >= gemma_config.default_ffn_dim_by_layer.len) return error.GemmaLayerOutOfRange;
        return @intCast(gemma_config.default_ffn_dim_by_layer[layer_idx]);
    }

    pub fn fullAttention(self: GemmaForwardScheduleConfig, layer_idx: u32) bool {
        _ = self;
        return layer_idx % 5 == 4;
    }
};

var global_negative_signal_count = std.atomic.Value(u64).init(0);
var global_negative_signal_hash = std.atomic.Value(u64).init(0);

fn envFlag(name: []const u8) bool {
    const value = std.posix.getenv(name) orelse return false;
    return value.len != 0 and
        !std.mem.eql(u8, value, "0") and
        !std.ascii.eqlIgnoreCase(value, "false") and
        !std.ascii.eqlIgnoreCase(value, "no");
}

const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

fn ghostCopy(comptime T: type, dest: []T, source: []const T) void {
    if (comptime builtin.zig_version.minor >= 14 or builtin.zig_version.major > 0) {
        @call(.always_inline, std.mem.copyForwards, .{ T, dest, source });
    } else {
        @call(.always_inline, std.mem.copy, .{ T, dest, source });
    }
}

pub const DiagnosticState = struct {
    dropped_runes: u32 = 0,
    collision_stalls: u32 = 0,
};

pub const EngineConfig = struct {
    rotor_stride: u32,
    rotor_offset: u32,
    batch_size: u32,
};

pub const Layer2aContradictionSummary = struct {
    winner_index: u32,
    winner_char: u32,
    best_score: u32,
    runner_up_score: u32,
    contradiction: bool,
    contradiction_checks: u32,
    candidate_count: u32,
    survivor_count: u32,
};

pub const GhostIndexBlock = struct {
    byte_start: usize,
    byte_end: usize,
    simhash: u64,
    feature_count: usize,
};

pub const GhostIndexPruneSummary = struct {
    scanned_blocks: usize = 0,
    skipped_blocks: usize = 0,
    retained_blocks: usize = 0,
};

pub const ResidentBuffer = struct {
    buffer: vk.VkBuffer = null,
    memory: vk.VkDeviceMemory = null,
    size_bytes: usize = 0,
    device_local: bool = false,
    epoch: vk_device.ResidentEpoch = .{},
};

pub const CorpusScanEntry = extern struct {
    byte_offset: u32 = 0,
    byte_len: u32 = 0,
    search_hash_lo: u32 = 0,
    search_hash_hi: u32 = 0,
    semantic_hash_lo: u32 = 0,
    semantic_hash_hi: u32 = 0,
    flags: u32 = 0,
    reserved: u32 = 0,
    relation_hash_lo: u32 = 0,
    relation_hash_hi: u32 = 0,
    inverse_relation_hash_lo: u32 = 0,
    inverse_relation_hash_hi: u32 = 0,
};

pub const GLOBAL_RUNE_RESONANCE_OVERRIDE_PER_MILLE: u16 = 850;

pub const GlobalRuneHit = struct {
    label: []const u8 = "",
    score_per_mille: u16 = 0,
};

pub const GlobalRuneMatch = struct {
    command: GlobalRuneHit = .{},
    content: GlobalRuneHit = .{},
    command_target: []const u8 = "",
    simultaneous_hits: u8 = 0,

    pub fn contentOverridesEntropy(self: GlobalRuneMatch) bool {
        return self.content.score_per_mille >= GLOBAL_RUNE_RESONANCE_OVERRIDE_PER_MILLE;
    }

    pub fn commandOverridesTokenizer(self: GlobalRuneMatch) bool {
        return self.command.score_per_mille >= GLOBAL_RUNE_RESONANCE_OVERRIDE_PER_MILLE and self.command_target.len != 0;
    }
};

const RuneConcept = enum {
    command,
    command_target,
    content,
};

const RuneMetadata = struct {
    rune: []const u8,
    concept: RuneConcept,
    label: []const u8,
    target: []const u8 = "",
};

const ENGLISH_CORE_RUNE_METADATA = [_]RuneMetadata{
    .{ .rune = "say", .concept = .command, .label = "command_lobe:say" },
    .{ .rune = "speak", .concept = .command, .label = "command_lobe:say" },
    .{ .rune = "ghost", .concept = .command_target, .label = "command_lobe:ghost", .target = "ghost" },
    .{ .rune = "code", .concept = .content, .label = "english_core:programming" },
    .{ .rune = "programming", .concept = .content, .label = "english_core:programming" },
    .{ .rune = "program", .concept = .content, .label = "english_core:programming" },
    .{ .rune = "software", .concept = .content, .label = "english_core:programming" },
};

/// Shader-compatible global rune match.
///
/// The Vulkan corpus shader performs the full resident-shard scoring loop.
/// This helper keeps the same integer-only resonance contract available to
/// CPU-side intent gating and tests, so compact inputs such as "sayghost" are
/// evaluated as overlapping rune segments instead of a single low-information
/// token.
pub fn globalRuneMatch(input: []const u8) GlobalRuneMatch {
    var result = GlobalRuneMatch{};
    var command_seen = false;
    var target_seen = false;
    var content_seen = false;

    for (ENGLISH_CORE_RUNE_METADATA) |entry| {
        const score = segmentResonancePerMille(input, entry.rune);
        if (score < GLOBAL_RUNE_RESONANCE_OVERRIDE_PER_MILLE) continue;
        result.simultaneous_hits +|= 1;
        switch (entry.concept) {
            .command => {
                command_seen = true;
                if (score > result.command.score_per_mille) {
                    result.command = .{ .label = entry.label, .score_per_mille = score };
                }
            },
            .command_target => {
                target_seen = true;
                if (result.command_target.len == 0 or score > result.command.score_per_mille) {
                    result.command_target = entry.target;
                }
            },
            .content => {
                content_seen = true;
                if (score > result.content.score_per_mille) {
                    result.content = .{ .label = entry.label, .score_per_mille = score };
                }
            },
        }
    }

    if (command_seen and target_seen and result.command.score_per_mille == 0) {
        result.command = .{ .label = "command_lobe:compound", .score_per_mille = GLOBAL_RUNE_RESONANCE_OVERRIDE_PER_MILLE };
    }
    if (!(command_seen and target_seen)) result.command_target = "";
    if (!content_seen) result.content = .{};
    return result;
}

pub fn contentRuneResonancePerMille(input: []const u8) u16 {
    return globalRuneMatch(input).content.score_per_mille;
}

fn segmentResonancePerMille(input: []const u8, rune: []const u8) u16 {
    if (rune.len == 0) return 0;
    var start: usize = 0;
    while (start < input.len) : (start += 1) {
        if (foldedByte(input[start]) != rune[0]) continue;
        var cursor = start;
        var matched: usize = 0;
        while (cursor < input.len and matched < rune.len) : (cursor += 1) {
            const byte = input[cursor];
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') continue;
            if (foldedByte(byte) != rune[matched]) break;
            matched += 1;
        }
        if (matched == rune.len) return 1000;
        if (matched >= 3 and matched * 1000 / rune.len >= GLOBAL_RUNE_RESONANCE_OVERRIDE_PER_MILLE) {
            return @intCast((matched * 1000) / rune.len);
        }
    }
    return 0;
}

fn foldedByte(byte: u8) u8 {
    return std.ascii.toLower(byte);
}

pub fn buildGhostIndex(allocator: std.mem.Allocator, bytes: []const u8) ![]GhostIndexBlock {
    const block_count = @max(@as(usize, 1), (bytes.len + GHOST_INDEX_BLOCK_BYTES - 1) / GHOST_INDEX_BLOCK_BYTES);
    const blocks = try allocator.alloc(GhostIndexBlock, block_count);
    for (blocks, 0..) |*block, idx| {
        const start = idx * GHOST_INDEX_BLOCK_BYTES;
        const end = @min(bytes.len, start + GHOST_INDEX_BLOCK_BYTES);
        const slice = if (start < bytes.len) bytes[start..end] else bytes[0..0];
        block.* = .{
            .byte_start = start,
            .byte_end = end,
            .simhash = simHashBlock64(slice, idx),
            .feature_count = if (slice.len == 0) 0 else 1,
        };
    }
    return blocks;
}

pub fn ghostIndexDistance(lhs: u64, rhs: u64) u7 {
    return @intCast(@popCount(lhs ^ rhs));
}

pub fn ghostIndexNearnessPerMille(lhs: u64, rhs: u64) u16 {
    const distance = ghostIndexDistance(lhs, rhs);
    const remaining: u16 = 64 - @as(u16, distance);
    return @intCast((@as(u32, remaining) * 1000) / 64);
}

pub fn shouldSkipGhostIndexBlock(input_hash: u64, block: GhostIndexBlock) bool {
    if (block.feature_count == 0) return false;
    return ghostIndexNearnessPerMille(input_hash, block.simhash) < GHOST_INDEX_SKIP_THRESHOLD_PER_MILLE;
}

pub fn pruneGhostIndexBlocks(input_hash: u64, blocks: []const GhostIndexBlock, scan_blocks: []bool) !GhostIndexPruneSummary {
    if (scan_blocks.len < blocks.len) return error.OutputTooSmall;
    var summary = GhostIndexPruneSummary{ .scanned_blocks = blocks.len };
    for (blocks, 0..) |block, idx| {
        const skip = shouldSkipGhostIndexBlock(input_hash, block);
        scan_blocks[idx] = !skip;
        if (skip) {
            summary.skipped_blocks += 1;
        } else {
            summary.retained_blocks += 1;
        }
    }
    return summary;
}

fn simHashBlock64(bytes: []const u8, block_index: usize) u64 {
    var weights = [_]i32{0} ** 64;
    var has_feature = false;
    var offset: usize = 0;
    while (offset < bytes.len) {
        while (offset < bytes.len and !isGhostIndexByte(bytes[offset])) : (offset += 1) {}
        const start = offset;
        while (offset < bytes.len and isGhostIndexByte(bytes[offset])) : (offset += 1) {}
        if (offset == start) continue;
        has_feature = true;
        addGhostIndexFeature(&weights, bytes[start..offset], block_index);
    }
    if (!has_feature) addGhostIndexFeature(&weights, bytes, block_index);

    var hash: u64 = 0;
    for (weights, 0..) |weight, bit| {
        if (weight >= 0) hash |= @as(u64, 1) << @intCast(bit);
    }
    return hash;
}

fn isGhostIndexByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn addGhostIndexFeature(weights: *[64]i32, bytes: []const u8, block_index: usize) void {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(bytes);
    var index_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &index_bytes, @intCast(block_index), .little);
    hasher.update(&index_bytes);
    const hash = hasher.final();
    for (0..64) |bit| {
        const mask = @as(u64, 1) << @intCast(bit);
        if ((hash & mask) != 0) {
            weights[bit] += 1;
        } else {
            weights[bit] -= 1;
        }
    }
}

fn check(result: vk.VkResult) !void {
    if (result != vk.VK_SUCCESS) {
        sys.print("[VULKAN] API Error: {d}\n", .{result});
        return error.VulkanError;
    }
}

const InstanceBootstrap = struct {
    instance: vk.VkInstance,
    validation_enabled: bool,
    debug_utils_enabled: bool,
};

const QueueFamilySelection = struct {
    family: u32,
    queue_count: u32,
    dedicated_compute: bool,
};

const RankedPhysicalDevice = struct {
    pdev: vk.VkPhysicalDevice,
    physical_index: u32,
    score: u64,
    device_type: vk.VkPhysicalDeviceType,
    queue: QueueFamilySelection,
};

fn fixedCStringEquals(buf: []const u8, expected: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return std.mem.eql(u8, buf[0..end], expected);
}

fn trimDeviceName(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return std.mem.trim(u8, buf[0..end], " \r\n\t");
}

fn beginGpuSubmit(self: *VulkanEngine) void {
    _ = self.active_gpu_submits.fetchAdd(1, .acq_rel);
}

fn endGpuSubmit(self: *VulkanEngine) void {
    _ = self.active_gpu_submits.fetchSub(1, .release);
}

pub fn getActiveGpuSubmitCount(self: *const VulkanEngine) u32 {
    return self.active_gpu_submits.load(.acquire);
}

pub fn waitForGpuWorkersDrained(self: *VulkanEngine) void {
    while (getActiveGpuSubmitCount(self) != 0) {
        sys.sleep(1);
    }
}

fn waitForAllHardwareInterruptsWithTimeout(self: *VulkanEngine, timeout_ns: u64) !void {
    for (0..FRAME_COUNT) |i| try self.waitForHardwareInterruptWithTimeout(i, timeout_ns);
}

fn hasInstanceLayer(ctx: *vl.VulkanCtx, allocator: std.mem.Allocator, layer_name: []const u8) !bool {
    var count: u32 = 0;
    try check(ctx.vkEnumerateInstanceLayerProperties.?(&count, null));
    if (count == 0) return false;

    const props = try allocator.alloc(vk.VkLayerProperties, count);
    defer allocator.free(props);
    try check(ctx.vkEnumerateInstanceLayerProperties.?(&count, props.ptr));

    for (props[0..count]) |prop| {
        if (fixedCStringEquals(prop.layerName[0..], layer_name)) return true;
    }
    return false;
}

fn hasInstanceExtension(ctx: *vl.VulkanCtx, allocator: std.mem.Allocator, extension_name: []const u8) !bool {
    var count: u32 = 0;
    try check(ctx.vkEnumerateInstanceExtensionProperties.?(null, &count, null));
    if (count == 0) return false;

    const props = try allocator.alloc(vk.VkExtensionProperties, count);
    defer allocator.free(props);
    try check(ctx.vkEnumerateInstanceExtensionProperties.?(null, &count, props.ptr));

    for (props[0..count]) |prop| {
        if (fixedCStringEquals(prop.extensionName[0..], extension_name)) return true;
    }
    return false;
}

fn shouldEnableValidation() bool {
    return debug_validation_requested.load(.acquire) or
        envFlag("GHOST_VULKAN_VALIDATION") or
        envFlag("GHOST_DEBUG_VULKAN");
}

fn selectComputeQueueFamily(
    ctx: *vl.VulkanCtx,
    allocator: std.mem.Allocator,
    pdev: vk.VkPhysicalDevice,
) !?QueueFamilySelection {
    var qf_count: u32 = 0;
    ctx.vkGetPhysicalDeviceQueueFamilyProperties.?(pdev, &qf_count, null);
    if (qf_count == 0) return null;

    const qfs = try allocator.alloc(vk.VkQueueFamilyProperties, qf_count);
    defer allocator.free(qfs);
    ctx.vkGetPhysicalDeviceQueueFamilyProperties.?(pdev, &qf_count, qfs.ptr);

    var fallback: ?QueueFamilySelection = null;
    for (qfs, 0..) |qf, i| {
        if ((qf.queueFlags & vk.VK_QUEUE_COMPUTE_BIT) == 0) continue;
        const selection = QueueFamilySelection{
            .family = @intCast(i),
            .queue_count = @min(qf.queueCount, 8),
            .dedicated_compute = (qf.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) == 0,
        };
        if (selection.dedicated_compute) return selection;
        if (fallback == null) fallback = selection;
    }
    return fallback;
}

fn computePhysicalDeviceScore(
    ctx: *vl.VulkanCtx,
    allocator: std.mem.Allocator,
    pdev: vk.VkPhysicalDevice,
) !?struct { score: u64, queue: QueueFamilySelection } {
    const queue = try selectComputeQueueFamily(ctx, allocator, pdev) orelse return null;

    var props: vk.VkPhysicalDeviceProperties = undefined;
    ctx.vkGetPhysicalDeviceProperties.?(pdev, &props);

    var mem_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
    ctx.vkGetPhysicalDeviceMemoryProperties.?(pdev, &mem_props);

    var device_local_bytes: u64 = 0;
    for (mem_props.memoryHeaps[0..mem_props.memoryHeapCount]) |heap| {
        if ((heap.flags & vk.VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) != 0) {
            device_local_bytes += heap.size;
        }
    }

    var score: u64 = switch (props.deviceType) {
        vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 4_000_000,
        vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 2_000_000,
        vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 1_000_000,
        else => 100_000,
    };
    score += device_local_bytes / (256 * 1024 * 1024);
    score += @as(u64, props.limits.maxComputeWorkGroupInvocations) * 128;
    score += @as(u64, props.limits.maxComputeSharedMemorySize) / 1024;
    score += @as(u64, props.limits.maxBoundDescriptorSets) * 32;
    score += @as(u64, queue.queue_count) * 512;
    if (queue.dedicated_compute) score += 50_000;

    return .{ .score = score, .queue = queue };
}

fn rankPhysicalDevices(
    ctx: *vl.VulkanCtx,
    allocator: std.mem.Allocator,
    pdevs: []const vk.VkPhysicalDevice,
) ![]RankedPhysicalDevice {
    const scratch = try allocator.alloc(RankedPhysicalDevice, pdevs.len);
    defer allocator.free(scratch);

    var count: usize = 0;
    var non_cpu_count: usize = 0;
    for (pdevs, 0..) |pdev, i| {
        const scored = try computePhysicalDeviceScore(ctx, allocator, pdev) orelse continue;

        var props: vk.VkPhysicalDeviceProperties = undefined;
        ctx.vkGetPhysicalDeviceProperties.?(pdev, &props);
        scratch[count] = .{
            .pdev = pdev,
            .physical_index = @intCast(i),
            .score = scored.score,
            .device_type = props.deviceType,
            .queue = scored.queue,
        };
        if (props.deviceType != vk.VK_PHYSICAL_DEVICE_TYPE_CPU) non_cpu_count += 1;
        count += 1;
    }
    if (count == 0) return error.NoComputeQueue;

    if (non_cpu_count > 0) {
        var write_idx: usize = 0;
        for (scratch[0..count]) |ranked| {
            if (ranked.device_type == vk.VK_PHYSICAL_DEVICE_TYPE_CPU) continue;
            scratch[write_idx] = ranked;
            write_idx += 1;
        }
        count = write_idx;
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        var j: usize = i + 1;
        while (j < count) : (j += 1) {
            if (scratch[j].score > scratch[i].score) {
                const tmp = scratch[i];
                scratch[i] = scratch[j];
                scratch[j] = tmp;
            }
        }
    }

    return try allocator.dupe(RankedPhysicalDevice, scratch[0..count]);
}

fn createInstance(ctx: *vl.VulkanCtx, allocator: std.mem.Allocator, app_name: [*:0]const u8, engine_name: [*:0]const u8) !InstanceBootstrap {
    var appInfo = std.mem.zeroes(vk.VkApplicationInfo);
    appInfo.sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    appInfo.pApplicationName = app_name;
    appInfo.applicationVersion = vk.VK_MAKE_VERSION(1, 0, 0);
    appInfo.pEngineName = engine_name;
    appInfo.engineVersion = vk.VK_MAKE_VERSION(1, 0, 0);
    appInfo.apiVersion = vk.VK_API_VERSION_1_2;

    const validation_allowed = shouldEnableValidation();
    const validation_enabled = validation_allowed and try hasInstanceLayer(ctx, allocator, std.mem.span(VALIDATION_LAYER_NAME));
    const debug_utils_enabled = validation_enabled and try hasInstanceExtension(ctx, allocator, std.mem.span(DEBUG_UTILS_EXTENSION_NAME));

    if (validation_enabled) {
        if (runtimeLogsEnabled()) std.debug.print("[VULKAN] Validation layer enabled.\n", .{});
    } else if (validation_allowed) {
        if (runtimeLogsEnabled()) std.debug.print("[VULKAN] Validation layer unavailable; continuing without Khronos diagnostics.\n", .{});
    } else {
        if (runtimeLogsEnabled()) std.debug.print("[VULKAN] Validation disabled for production/headless runtime.\n", .{});
    }

    var layers = [_][*:0]const u8{VALIDATION_LAYER_NAME};
    var extensions = [_][*:0]const u8{DEBUG_UTILS_EXTENSION_NAME};

    var createInfo = std.mem.zeroes(vk.VkInstanceCreateInfo);
    createInfo.sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    createInfo.pApplicationInfo = &appInfo;
    if (validation_enabled) {
        createInfo.enabledLayerCount = layers.len;
        createInfo.ppEnabledLayerNames = &layers;
    }
    if (debug_utils_enabled) {
        createInfo.enabledExtensionCount = extensions.len;
        createInfo.ppEnabledExtensionNames = &extensions;
    }

    var instance: vk.VkInstance = null;
    try check(ctx.vkCreateInstance.?(&createInfo, null, &instance));
    return .{
        .instance = instance,
        .validation_enabled = validation_enabled,
        .debug_utils_enabled = debug_utils_enabled,
    };
}

fn debugSeverityLabel(severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT) []const u8 {
    if ((severity & vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0) return "ERROR";
    if ((severity & vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) != 0) return "WARN";
    if ((severity & vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) != 0) return "INFO";
    return "VERBOSE";
}

fn validationCallback(
    severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
    _: vk.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.VkDebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    const message = if (callback_data) |data|
        if (data.pMessage != null) std.mem.span(data.pMessage) else "<no message>"
    else
        "<null callback>";
    sys.print("[VULKAN VALIDATION][{s}] {s}\n", .{ debugSeverityLabel(severity), message });
    return vk.VK_FALSE;
}

pub const VulkanEngine = struct {
    allocator: std.mem.Allocator,
    vk_ctx: vl.VulkanCtx,
    instance: vk.VkInstance = null,
    debug_messenger: vk.VkDebugUtilsMessengerEXT = null,
    validation_enabled: bool = false,
    pdev: vk.VkPhysicalDevice = null,
    dev: vk.VkDevice = null,
    queues: [8]vk.VkQueue = [_]vk.VkQueue{null} ** 8,
    num_queues: u32 = 0,
    queue_family: u32 = 0,
    queue: vk.VkQueue = null,

    // Performance Profiles
    vram_size: usize = 0,
    is_discrete: bool = false,
    performance_score: u32 = 0,
    device_index: u32 = 0,
    device_name: [256]u8 = [_]u8{0} ** 256,
    max_workgroup_invocations: u32 = 0,
    supports_int16: bool = false,
    max_alloc_count: u32 = 0,
    device_profile: vk_device.DeviceProfile = .{},

    // Pipeline Objects
    descriptor_set_layout: vk.VkDescriptorSetLayout = null,
    pipeline_layout: vk.VkPipelineLayout = null,
    compute_pipeline: vk.VkPipeline = null,
    candidate_score_pipeline: vk.VkPipeline = null,
    neighborhood_score_pipeline: vk.VkPipeline = null,
    contradiction_filter_pipeline: vk.VkPipeline = null,
    semantic_hash_pipeline: vk.VkPipeline = null,
    corpus_scan_pipeline: vk.VkPipeline = null,
    lattice_query_pipeline: vk.VkPipeline = null,
    etch_pipeline: vk.VkPipeline = null,
    prune_pipeline: vk.VkPipeline = null,
    lookahead_pipeline: vk.VkPipeline = null,
    lattice_pipeline: vk.VkPipeline = null,
    rune_search_pipeline: vk.VkPipeline = null, // v2: Rune Lattice XOR search
    gemma_rune_embed_pipeline: vk.VkPipeline = null,
    gemma_matmul_q4k_pipeline: vk.VkPipeline = null,
    gemma_matmul_q8_0_pipeline: vk.VkPipeline = null,
    gemma_rms_norm_pipeline: vk.VkPipeline = null,
    gemma_swiglu_pipeline: vk.VkPipeline = null,
    gemma_attention_pipeline: vk.VkPipeline = null,
    gemma_rune_project_pipeline: vk.VkPipeline = null,

    // Gemma Sovereign Inference (V2)
    gemma_descriptor_set_layout: vk.VkDescriptorSetLayout = null,
    gemma_pipeline_layout: vk.VkPipelineLayout = null,
    gemma_descriptor_sets: [6]vk.VkDescriptorSet = [_]vk.VkDescriptorSet{null} ** 6,
    gemma_state: ?*GemmaInferenceState = null,

    // Synchronization
    timeline_semaphore: vk.VkSemaphore = null,
    timeline_value: u64 = 0,
    dispatch_mutex: Mutex = .{},
    frame_idx: u32 = 0,
    active_gpu_submits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fences: [FRAME_COUNT]vk.VkFence = [_]vk.VkFence{null} ** FRAME_COUNT,
    frame_generations: [FRAME_COUNT]u64 = [_]u64{0} ** FRAME_COUNT,

    // ── Dedicated Transfer Queue (V29) ──
    has_dedicated_transfer: bool = false,
    transfer_queue_family: u32 = 0,
    transfer_queue: vk.VkQueue = null,
    transfer_pool: vk.VkCommandPool = null,
    transfer_buffers: [FRAME_COUNT]vk.VkCommandBuffer = [_]vk.VkCommandBuffer{null} ** FRAME_COUNT,
    transfer_fences: [FRAME_COUNT]vk.VkFence = [_]vk.VkFence{null} ** FRAME_COUNT,
    transfer_semaphores: [FRAME_COUNT]vk.VkSemaphore = [_]vk.VkSemaphore{null} ** FRAME_COUNT,

    // Global Silicon Lobe (Monolith)
    matrix_buffer: vk.VkBuffer = null,
    matrix_memory: vk.VkDeviceMemory = null,
    mapped_matrix: ?[*]u32 = null,
    matrix_slots: u32 = 0,
    gpu_matrix_size: usize = 0,
    matrix_flags: vk.VkMemoryPropertyFlags = 0,

    tag_buffer: vk.VkBuffer = null,
    tag_memory: vk.VkDeviceMemory = null,
    mapped_tags: ?[*]u64 = null,

    lattice_buffer: vk.VkBuffer = null,
    lattice_memory: vk.VkDeviceMemory = null,
    mapped_lattice: ?[*]u16 = null,
    gpu_lattice_size: usize = 0,
    lattice_quarter: u32 = 0,

    rune_rank_buffer: vk.VkBuffer = null,
    rune_rank_memory: vk.VkDeviceMemory = null,
    mapped_rune_ranks: ?[*]u8 = null,

    // Phantom Lobe (Sigil Cartridge)
    sigil_buffer: vk.VkBuffer = null,
    sigil_memory: vk.VkDeviceMemory = null,
    mapped_sigil: ?[*]u16 = null,
    sigil_capacity: usize = 0,

    // Diagnostic Lobe (Telemetry SSBO)
    diag_buffer: vk.VkBuffer = null,
    diag_memory: vk.VkDeviceMemory = null,
    mapped_diag: ?*DiagnosticState = null,

    // Hardware lock mask for Sigil slot freezes
    lock_mask_buffer: vk.VkBuffer = null,
    lock_mask_memory: vk.VkDeviceMemory = null,
    mapped_lock_mask: ?[*]u32 = null,
    lock_mask_words: usize = 0,

    // V33: Panopticon Flat Graph
    panopticon_buffer: vk.VkBuffer = null,
    panopticon_memory: vk.VkDeviceMemory = null,
    mapped_edges: ?[*]u32 = null,

    // V34: General Ingest Lobe (Non-code data)
    general_ingest_buffer: vk.VkBuffer = null,
    general_ingest_memory: vk.VkDeviceMemory = null,
    mapped_general_ingest: ?[*]u32 = null,
    general_ingest_size: usize = 0,

    // Immutable publication staging arena. Uploads copy through these
    // preallocated slots, then publish a new resident epoch via timeline
    // semaphore. Query-time uploads must fit here instead of allocating memory.
    upload_staging_buffers: [UPLOAD_STAGING_SLOTS]vk.VkBuffer = [_]vk.VkBuffer{null} ** UPLOAD_STAGING_SLOTS,
    upload_staging_memories: [UPLOAD_STAGING_SLOTS]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** UPLOAD_STAGING_SLOTS,
    mapped_upload_staging: [UPLOAD_STAGING_SLOTS]?[*]u8 = [_]?[*]u8{null} ** UPLOAD_STAGING_SLOTS,
    upload_staging_slot_bytes: usize = vk_device.DEFAULT_UPLOAD_STAGING_BYTES,
    upload_staging_flags: vk.VkMemoryPropertyFlags = 0,
    upload_staging_slot: usize = 0,
    next_resident_epoch: u64 = 0,
    upload_arena_telemetry: vk_device.UploadArenaTelemetry = .{},

    // Batch Ring Buffers
    rotor_buffers: [FRAME_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** FRAME_COUNT,
    rotor_memories: [FRAME_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** FRAME_COUNT,
    mapped_rotors: [FRAME_COUNT]?[*]u64 = [_]?[*]u64{null} ** FRAME_COUNT,

    char_buffers: [FRAME_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** FRAME_COUNT,
    char_memories: [FRAME_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** FRAME_COUNT,
    mapped_chars: [FRAME_COUNT]?[*]u32 = [_]?[*]u32{null} ** FRAME_COUNT,

    index_buffers: [FRAME_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** FRAME_COUNT,
    index_memories: [FRAME_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** FRAME_COUNT,
    mapped_index: [FRAME_COUNT]?[*]u32 = [_]?[*]u32{null} ** FRAME_COUNT,

    energy_buffers: [FRAME_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** FRAME_COUNT,
    energy_memories: [FRAME_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** FRAME_COUNT,
    mapped_energy: [FRAME_COUNT]?[*]u32 = [_]?[*]u32{null} ** FRAME_COUNT,

    corpus_entry_buffers: [FRAME_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** FRAME_COUNT,
    corpus_entry_memories: [FRAME_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** FRAME_COUNT,
    mapped_corpus_entries: [FRAME_COUNT]?[*]CorpusScanEntry = [_]?[*]CorpusScanEntry{null} ** FRAME_COUNT,

    config_buffers: [FRAME_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** FRAME_COUNT,
    config_memories: [FRAME_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** FRAME_COUNT,
    mapped_config: [FRAME_COUNT]?*EngineConfig = [_]?*EngineConfig{null} ** FRAME_COUNT,

    descriptor_pool: vk.VkDescriptorPool = null,
    descriptor_sets: [FRAME_COUNT]vk.VkDescriptorSet = [_]vk.VkDescriptorSet{null} ** FRAME_COUNT,
    command_pools: [FRAME_COUNT]vk.VkCommandPool = [_]vk.VkCommandPool{null} ** FRAME_COUNT,
    command_buffers: [FRAME_COUNT]vk.VkCommandBuffer = [_]vk.VkCommandBuffer{null} ** FRAME_COUNT,

    // Multi-GPU Shared States (cached to avoid re-sync)
    host_matrix: ?[]u32 = null,
    host_tags: ?[]u64 = null,
    host_ranks: ?[]u8 = null,
    host_lattice: ?[]u16 = null,

    result_buffer: []u32,
    batch_flags: vk.VkMemoryPropertyFlags = 0,
    tier: OperationalTier = .standard,

    // ── Inference Resources (Monte Carlo Ring) ──
    inf_rotor_buffers: [INF_LANE_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** INF_LANE_COUNT,
    inf_rotor_memories: [INF_LANE_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** INF_LANE_COUNT,
    inf_mapped_rotors: [INF_LANE_COUNT]?[*]u64 = [_]?[*]u64{null} ** INF_LANE_COUNT,

    inf_energy_buffers: [INF_LANE_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** INF_LANE_COUNT,
    inf_energy_memories: [INF_LANE_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** INF_LANE_COUNT,
    inf_mapped_energy: [INF_LANE_COUNT]?[*]u32 = [_]?[*]u32{null} ** INF_LANE_COUNT,

    inf_config_buffers: [INF_LANE_COUNT]vk.VkBuffer = [_]vk.VkBuffer{null} ** INF_LANE_COUNT,
    inf_config_memories: [INF_LANE_COUNT]vk.VkDeviceMemory = [_]vk.VkDeviceMemory{null} ** INF_LANE_COUNT,
    inf_mapped_config: [INF_LANE_COUNT]?*EngineConfig = [_]?*EngineConfig{null} ** INF_LANE_COUNT,

    inf_descriptor_sets: [INF_LANE_COUNT]vk.VkDescriptorSet = [_]vk.VkDescriptorSet{null} ** INF_LANE_COUNT,
    inf_command_pools: [INF_LANE_COUNT]vk.VkCommandPool = [_]vk.VkCommandPool{null} ** INF_LANE_COUNT,
    inf_command_buffers: [INF_LANE_COUNT]vk.VkCommandBuffer = [_]vk.VkCommandBuffer{null} ** INF_LANE_COUNT,
    inf_fences: [INF_LANE_COUNT]vk.VkFence = [_]vk.VkFence{null} ** INF_LANE_COUNT,

    pub fn init(allocator: std.mem.Allocator) !*VulkanEngine {
        var ctx = try vl.VulkanCtx.load();
        const boot = try createInstance(&ctx, allocator, "Ghost-Sovereign", "Ghost-VSA");
        try ctx.loadInstance(boot.instance);

        var pdevCount: u32 = 0;
        try check(ctx.vkEnumeratePhysicalDevices.?(boot.instance, &pdevCount, null));
        if (pdevCount == 0) return error.NoGpuFound;
        const pdevs = try allocator.alloc(vk.VkPhysicalDevice, pdevCount);
        defer allocator.free(pdevs);
        try check(ctx.vkEnumeratePhysicalDevices.?(boot.instance, &pdevCount, pdevs.ptr));
        const ranked = try rankPhysicalDevices(&ctx, allocator, pdevs[0..pdevCount]);
        defer allocator.free(ranked);
        const best = ranked[0];

        const engine = try allocator.create(VulkanEngine);
        engine.* = .{
            .allocator = allocator,
            .vk_ctx = ctx,
            .instance = boot.instance,
            .validation_enabled = boot.validation_enabled,
            .pdev = best.pdev,
            .device_index = 0,
            .queue_family = best.queue.family,
            .num_queues = best.queue.queue_count,
            .result_buffer = try allocator.alloc(u32, 65536),
        };

        try engine.initDebugMessenger(boot.debug_utils_enabled);

        return try engine.initCommon();
    }

    pub fn initForDevice(allocator: std.mem.Allocator, device_index: u32) !VulkanEngine {
        var ctx = try vl.VulkanCtx.load();
        const boot = try createInstance(&ctx, allocator, "Ghost-Sovereign-Multi", "Ghost-VSA");
        try ctx.loadInstance(boot.instance);

        var pdevCount: u32 = 0;
        try check(ctx.vkEnumeratePhysicalDevices.?(boot.instance, &pdevCount, null));
        const pdevs = try allocator.alloc(vk.VkPhysicalDevice, pdevCount);
        defer allocator.free(pdevs);
        try check(ctx.vkEnumeratePhysicalDevices.?(boot.instance, &pdevCount, pdevs.ptr));

        const ranked = try rankPhysicalDevices(&ctx, allocator, pdevs[0..pdevCount]);
        defer allocator.free(ranked);
        if (device_index >= ranked.len) return error.DeviceIndexOutOfBounds;
        const selected = ranked[device_index];

        var engine = VulkanEngine{
            .allocator = allocator,
            .vk_ctx = ctx,
            .instance = boot.instance,
            .validation_enabled = boot.validation_enabled,
            .pdev = selected.pdev,
            .device_index = device_index,
            .queue_family = selected.queue.family,
            .num_queues = selected.queue.queue_count,
            .result_buffer = try allocator.alloc(u32, 65536),
        };

        try engine.initDebugMessenger(boot.debug_utils_enabled);

        _ = try engine.initCommon();
        return engine;
    }

    fn initDebugMessenger(self: *VulkanEngine, debug_utils_enabled: bool) !void {
        if (!self.validation_enabled or !debug_utils_enabled) return;
        const create_fn = self.vk_ctx.vkCreateDebugUtilsMessengerEXT orelse return;

        var create_info = std.mem.zeroes(vk.VkDebugUtilsMessengerCreateInfoEXT);
        create_info.sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
        create_info.messageSeverity =
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
        create_info.messageType =
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        create_info.pfnUserCallback = validationCallback;

        try check(create_fn(self.instance, &create_info, null, &self.debug_messenger));
        sys.printOut("[VULKAN] Debug utils messenger online.\n");
    }

    fn detectHardware(self: *VulkanEngine) !void {
        var deviceFeatures: vk.VkPhysicalDeviceFeatures = undefined;
        self.vk_ctx.vkGetPhysicalDeviceFeatures.?(self.pdev, &deviceFeatures);
        self.supports_int16 = deviceFeatures.shaderInt16 == vk.VK_TRUE;

        var devProps: vk.VkPhysicalDeviceProperties = undefined;
        self.vk_ctx.vkGetPhysicalDeviceProperties.?(self.pdev, &devProps);
        self.max_workgroup_invocations = devProps.limits.maxComputeWorkGroupInvocations;
        self.max_alloc_count = devProps.limits.maxMemoryAllocationCount;
        self.is_discrete = devProps.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;

        var score: u32 = 0;
        if (self.is_discrete) score += 5000;
        score += self.max_workgroup_invocations;
        score += @intCast(devProps.limits.maxBoundDescriptorSets * 10);
        self.performance_score = score;

        for (devProps.deviceName, 0..) |c, i| {
            if (i >= 255) break;
            self.device_name[i] = c;
        }

        var memProps: vk.VkPhysicalDeviceMemoryProperties = undefined;
        self.vk_ctx.vkGetPhysicalDeviceMemoryProperties.?(self.pdev, &memProps);
        self.vram_size = 0;
        for (memProps.memoryHeaps[0..memProps.memoryHeapCount]) |heap| {
            if ((heap.flags & vk.VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) != 0) {
                self.vram_size += heap.size;
            }
        }

        var subgroupSize: u32 = 32; // Default fallback
        if (self.vk_ctx.vkGetPhysicalDeviceProperties2 != null) {
            var subgroupProps = std.mem.zeroes(vk.VkPhysicalDeviceSubgroupProperties);
            subgroupProps.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES;
            var devProps2 = std.mem.zeroes(vk.VkPhysicalDeviceProperties2);
            devProps2.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
            devProps2.pNext = &subgroupProps;
            self.vk_ctx.vkGetPhysicalDeviceProperties2.?(self.pdev, &devProps2);
            if (subgroupProps.subgroupSize > 0) {
                subgroupSize = subgroupProps.subgroupSize;
            }
        }

        self.device_profile = .{
            .max_compute_workgroup_invocations = self.max_workgroup_invocations,
            .subgroup_size = subgroupSize,
            .total_memory = self.vram_size,
        };

        if (runtimeLogsEnabled()) {
            std.debug.print("[VULKAN-{d}] Selected Device: {s}\n", .{ self.device_index, trimDeviceName(devProps.deviceName[0..]) });
            std.debug.print("[VULKAN-{d}] VRAM Detect: {d} MB | Parallel Streams: {d}\n", .{ self.device_index, self.vram_size / 1048576, self.num_queues });
            std.debug.print("[VULKAN-{d}] Headless compute mode active. Perf score: {d}\n", .{ self.device_index, self.performance_score });
            std.debug.print("[VULKAN-{d}] Device Profile: max_wg={d}, subgroup={d}\n", .{ self.device_index, self.device_profile.max_compute_workgroup_invocations, self.device_profile.subgroup_size });
        }

        var qfCount: u32 = 0;
        self.vk_ctx.vkGetPhysicalDeviceQueueFamilyProperties.?(self.pdev, &qfCount, null);
        const qfs = try self.allocator.alloc(vk.VkQueueFamilyProperties, qfCount);
        defer self.allocator.free(qfs);
        self.vk_ctx.vkGetPhysicalDeviceQueueFamilyProperties.?(self.pdev, &qfCount, qfs.ptr);

        var transfer_family: ?u32 = null;
        for (qfs, 0..) |qf, i| {
            const idx = @as(u32, @intCast(i));
            if (idx == self.queue_family) continue;
            if ((qf.queueFlags & vk.VK_QUEUE_TRANSFER_BIT) != 0 and
                (qf.queueFlags & vk.VK_QUEUE_COMPUTE_BIT) == 0 and
                (qf.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) == 0)
            {
                transfer_family = idx;
                break;
            }
        }
        if (transfer_family == null) {
            for (qfs, 0..) |qf, i| {
                const idx = @as(u32, @intCast(i));
                if (idx == self.queue_family) continue;
                if ((qf.queueFlags & vk.VK_QUEUE_TRANSFER_BIT) != 0 and
                    (qf.queueFlags & vk.VK_QUEUE_COMPUTE_BIT) == 0)
                {
                    transfer_family = idx;
                    break;
                }
            }
        }

        if (transfer_family) |tf| {
            self.has_dedicated_transfer = true;
            self.transfer_queue_family = tf;
            if (runtimeLogsEnabled()) std.debug.print("[VULKAN-{d}] Dedicated Transfer Queue: Family {d}\n", .{ self.device_index, tf });
        } else {
            self.has_dedicated_transfer = false;
            self.transfer_queue_family = self.queue_family;
            if (runtimeLogsEnabled()) std.debug.print("[VULKAN-{d}] No dedicated transfer queue - using compute queue\n", .{self.device_index});
        }
    }

    fn setupLogicalDevice(self: *VulkanEngine) !void {
        const qPriorities = [_]f32{1.0} ** 8;
        var queue_create_infos: [2]vk.VkDeviceQueueCreateInfo = undefined;
        var queue_create_count: u32 = 1;

        queue_create_infos[0] = std.mem.zeroes(vk.VkDeviceQueueCreateInfo);
        queue_create_infos[0].sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_create_infos[0].queueFamilyIndex = self.queue_family;
        queue_create_infos[0].queueCount = self.num_queues;
        queue_create_infos[0].pQueuePriorities = &qPriorities;

        if (self.has_dedicated_transfer) {
            queue_create_infos[1] = std.mem.zeroes(vk.VkDeviceQueueCreateInfo);
            queue_create_infos[1].sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queue_create_infos[1].queueFamilyIndex = self.transfer_queue_family;
            queue_create_infos[1].queueCount = 1;
            queue_create_infos[1].pQueuePriorities = &qPriorities;
            queue_create_count = 2;
        }

        var features11 = std.mem.zeroes(vk.VkPhysicalDeviceVulkan11Features);
        features11.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES;
        features11.storageBuffer16BitAccess = vk.VK_TRUE;
        features11.uniformAndStorageBuffer16BitAccess = vk.VK_TRUE;

        var features12 = std.mem.zeroes(vk.VkPhysicalDeviceVulkan12Features);
        features12.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
        features12.timelineSemaphore = vk.VK_TRUE;
        features12.shaderBufferInt64Atomics = vk.VK_TRUE;
        features12.pNext = &features11;

        var features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures2);
        features.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
        features.features.shaderInt64 = vk.VK_TRUE;
        features.features.shaderInt16 = vk.VK_TRUE;
        features.pNext = &features12;

        var dCreateInfo = std.mem.zeroes(vk.VkDeviceCreateInfo);
        dCreateInfo.sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        dCreateInfo.queueCreateInfoCount = queue_create_count;
        dCreateInfo.pQueueCreateInfos = &queue_create_infos[0];
        dCreateInfo.pNext = &features;
        try check(self.vk_ctx.vkCreateDevice.?(self.pdev, &dCreateInfo, null, &self.dev));

        for (0..self.num_queues) |i| {
            self.vk_ctx.vkGetDeviceQueue.?(self.dev, self.queue_family, @intCast(i), &self.queues[i]);
        }
        if (self.has_dedicated_transfer) {
            self.vk_ctx.vkGetDeviceQueue.?(self.dev, self.transfer_queue_family, 0, &self.transfer_queue);
        } else {
            self.transfer_queue = self.queues[0];
        }
    }

    fn findMemoryType(self: *const VulkanEngine, typeFilter: u32, properties: vk.VkMemoryPropertyFlags) !u32 {
        var memProperties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        self.vk_ctx.vkGetPhysicalDeviceMemoryProperties.?(self.pdev, &memProperties);
        var i: u32 = 0;
        while (i < memProperties.memoryTypeCount) : (i += 1) {
            if ((typeFilter & (@as(u32, 1) << @intCast(i))) != 0 and (memProperties.memoryTypes[i].propertyFlags & properties) == properties) {
                return i;
            }
        }
        return error.MemoryTypeNotFound;
    }

    fn createBuffer(self: *VulkanEngine, size: usize, usage: vk.VkBufferUsageFlags, properties: vk.VkMemoryPropertyFlags, buffer: *vk.VkBuffer, memory: *vk.VkDeviceMemory) !?*anyopaque {
        var bCreateInfo = std.mem.zeroes(vk.VkBufferCreateInfo);
        bCreateInfo.sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bCreateInfo.size = size;
        bCreateInfo.usage = usage;
        bCreateInfo.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;

        try check(self.vk_ctx.vkCreateBuffer.?(self.dev, &bCreateInfo, null, buffer));

        var memReqs: vk.VkMemoryRequirements = undefined;
        self.vk_ctx.vkGetBufferMemoryRequirements.?(self.dev, buffer.*, &memReqs);

        var allocInfo = std.mem.zeroes(vk.VkMemoryAllocateInfo);
        allocInfo.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocInfo.allocationSize = memReqs.size;
        allocInfo.memoryTypeIndex = try self.findMemoryType(memReqs.memoryTypeBits, properties);

        try check(self.vk_ctx.vkAllocateMemory.?(self.dev, &allocInfo, null, memory));
        try check(self.vk_ctx.vkBindBufferMemory.?(self.dev, buffer.*, memory.*, 0));

        if ((properties & vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0) {
            var data: ?*anyopaque = null;
            try check(self.vk_ctx.vkMapMemory.?(self.dev, memory.*, 0, size, 0, &data));
            return data;
        }
        return null;
    }

    fn allocateBuffers(self: *VulkanEngine) !void {
        const usable = if (self.vram_size > config.VRAM_HIGH_TIER_THRESHOLD) self.vram_size * config.VRAM_HIGH_TIER_USABLE_PERCENT / 100 else self.vram_size * config.VRAM_LOW_TIER_USABLE_PERCENT / 100;
        const max_matrix = if (self.is_discrete)
            @min(config.IDEAL_MATRIX_SIZE, usable * config.VRAM_MATRIX_BUDGET_PERCENT / 100)
        else
            config.SEMANTIC_SIZE_BYTES;
        const max_lattice = if (self.is_discrete)
            @min(config.IDEAL_LATTICE_SIZE, usable * config.VRAM_LATTICE_BUDGET_PERCENT / 100)
        else
            config.UNIFIED_SIZE_BYTES;

        const raw_slots = max_matrix / (config.SLOTS_PER_VECTOR * 4);
        var slots: u32 = 1;
        while (slots * 2 <= raw_slots) : (slots *= 2) {}
        self.matrix_slots = @min(@as(u32, @intCast(config.SEMANTIC_SLOTS)), @min(config.MAX_MATRIX_SLOTS, slots));

        self.gpu_matrix_size = @as(usize, self.matrix_slots) * 1024 * 4;
        self.gpu_lattice_size = max_lattice;
        self.lattice_quarter = @intCast(self.gpu_lattice_size / 8);

        self.matrix_flags = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if (self.is_discrete and self.vram_size > config.VRAM_HIGH_TIER_THRESHOLD) {
            self.matrix_flags |= vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
        }
        self.batch_flags = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

        const matrix_usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT;

        self.mapped_matrix = @ptrCast(@alignCast(try self.createBuffer(self.gpu_matrix_size, matrix_usage, self.matrix_flags, &self.matrix_buffer, &self.matrix_memory) orelse return error.VulkanError));
        self.mapped_tags = @ptrCast(@alignCast(try self.createBuffer(@as(usize, self.matrix_slots) * 8, matrix_usage, self.matrix_flags, &self.tag_buffer, &self.tag_memory) orelse return error.VulkanError));
        self.mapped_lattice = @ptrCast(@alignCast(try self.createBuffer(self.gpu_lattice_size, matrix_usage, self.matrix_flags, &self.lattice_buffer, &self.lattice_memory) orelse return error.VulkanError));

        self.mapped_rune_ranks = @ptrCast(try self.createBuffer(self.matrix_slots, matrix_usage, self.matrix_flags, &self.rune_rank_buffer, &self.rune_rank_memory) orelse return error.VulkanError);
        @memset(self.mapped_rune_ranks.?[0..self.matrix_slots], @intFromEnum(@import("triad.zig").RuneRank.noise));

        for (0..FRAME_COUNT) |i| {
            self.mapped_rotors[i] = @ptrCast(@alignCast(try self.createBuffer(20480 * 144, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.rotor_buffers[i], &self.rotor_memories[i]) orelse return error.VulkanError));
            self.mapped_chars[i] = @ptrCast(@alignCast(try self.createBuffer(config.MAX_STREAMS * 4, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.char_buffers[i], &self.char_memories[i]) orelse return error.VulkanError));
            self.mapped_index[i] = @ptrCast(@alignCast(try self.createBuffer(config.MAX_STREAMS * 4, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.index_buffers[i], &self.index_memories[i]) orelse return error.VulkanError));
            self.mapped_energy[i] = @ptrCast(@alignCast(try self.createBuffer(65536 * 4, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.energy_buffers[i], &self.energy_memories[i]) orelse return error.VulkanError));
            self.mapped_corpus_entries[i] = @ptrCast(@alignCast(try self.createBuffer(CORPUS_SCAN_MAX_ENTRIES * @sizeOf(CorpusScanEntry), vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.corpus_entry_buffers[i], &self.corpus_entry_memories[i]) orelse return error.VulkanError));
            self.mapped_config[i] = @ptrCast(@alignCast(try self.createBuffer(@sizeOf(EngineConfig), vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.config_buffers[i], &self.config_memories[i]) orelse return error.VulkanError));
        }

        for (0..INF_LANE_COUNT) |i| {
            self.inf_mapped_rotors[i] = @ptrCast(@alignCast(try self.createBuffer(config.BMP_SPACE_SIZE * 16, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.inf_rotor_buffers[i], &self.inf_rotor_memories[i]) orelse return error.VulkanError));
            self.inf_mapped_energy[i] = @ptrCast(@alignCast(try self.createBuffer(config.BMP_SPACE_SIZE * 4, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.inf_energy_buffers[i], &self.inf_energy_memories[i]) orelse return error.VulkanError));
            self.inf_mapped_config[i] = @ptrCast(@alignCast(try self.createBuffer(@sizeOf(EngineConfig), vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, self.batch_flags, &self.inf_config_buffers[i], &self.inf_config_memories[i]) orelse return error.VulkanError));
        }

        self.sigil_capacity = 4096;
        self.mapped_sigil = @ptrCast(@alignCast(try self.createBuffer(self.sigil_capacity, matrix_usage, self.matrix_flags, &self.sigil_buffer, &self.sigil_memory) orelse return error.VulkanError));
        self.mapped_diag = @ptrCast(@alignCast(try self.createBuffer(@sizeOf(DiagnosticState), matrix_usage, self.batch_flags, &self.diag_buffer, &self.diag_memory) orelse return error.VulkanError));
        self.lock_mask_words = (self.matrix_slots + 31) / 32;
        self.mapped_lock_mask = @ptrCast(@alignCast(try self.createBuffer(self.lock_mask_words * @sizeOf(u32), matrix_usage, self.batch_flags, &self.lock_mask_buffer, &self.lock_mask_memory) orelse return error.VulkanError));
        @memset(std.mem.sliceAsBytes(self.mapped_lock_mask.?[0..self.lock_mask_words]), 0);

        const panop_size = @as(usize, self.matrix_slots) * 16 * 4; // GRAPH_EDGES = 16
        self.mapped_edges = @ptrCast(@alignCast(try self.createBuffer(panop_size, matrix_usage, self.matrix_flags, &self.panopticon_buffer, &self.panopticon_memory) orelse return error.VulkanError));
        var graph = vsa_core.FlatGraph.fromMapped(@as([*]vsa_core.GraphNode, @ptrCast(@alignCast(self.mapped_edges.?))), self.matrix_slots);
        graph.clear();

        self.general_ingest_size = 16 * 1024 * 1024; // 16MB default
        self.mapped_general_ingest = @ptrCast(@alignCast(try self.createBuffer(self.general_ingest_size, matrix_usage, self.matrix_flags, &self.general_ingest_buffer, &self.general_ingest_memory) orelse return error.VulkanError));
        @memset(std.mem.sliceAsBytes(self.mapped_general_ingest.?[0 .. self.general_ingest_size / 4]), 0);

        self.upload_staging_slot_bytes = vk_device.DEFAULT_UPLOAD_STAGING_BYTES;
        self.upload_staging_flags = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        self.upload_arena_telemetry = .{
            .slots = UPLOAD_STAGING_SLOTS,
            .slot_bytes = self.upload_staging_slot_bytes,
            .fallback_allocations = 0,
        };
        for (0..UPLOAD_STAGING_SLOTS) |i| {
            const ptr = try self.createBuffer(
                self.upload_staging_slot_bytes,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                self.upload_staging_flags,
                &self.upload_staging_buffers[i],
                &self.upload_staging_memories[i],
            ) orelse return error.VulkanError;
            self.mapped_upload_staging[i] = @ptrCast(ptr);
        }
    }

    fn createComputePipeline(self: *VulkanEngine, spv: []const u8, spec_info: ?*const vk.VkSpecializationInfo, layout: vk.VkPipelineLayout) !vk.VkPipeline {
        const spv_u32 = try self.allocator.alloc(u32, spv.len / 4);
        defer self.allocator.free(spv_u32);
        @memcpy(std.mem.sliceAsBytes(spv_u32), spv);

        var smCreateInfo = std.mem.zeroes(vk.VkShaderModuleCreateInfo);
        smCreateInfo.sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        smCreateInfo.codeSize = spv.len;
        smCreateInfo.pCode = spv_u32.ptr;
        var module: vk.VkShaderModule = null;
        try check(self.vk_ctx.vkCreateShaderModule.?(self.dev, &smCreateInfo, null, &module));
        defer self.vk_ctx.vkDestroyShaderModule.?(self.dev, module, null);

        var stageInfo = std.mem.zeroes(vk.VkPipelineShaderStageCreateInfo);
        stageInfo.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stageInfo.stage = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        stageInfo.module = module;
        stageInfo.pName = "main";
        stageInfo.pSpecializationInfo = spec_info;

        var pipelineInfo = std.mem.zeroes(vk.VkComputePipelineCreateInfo);
        pipelineInfo.sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        pipelineInfo.stage = stageInfo;
        pipelineInfo.layout = layout;

        var pipeline: vk.VkPipeline = null;
        try check(self.vk_ctx.vkCreateComputePipelines.?(self.dev, null, 1, &pipelineInfo, null, &pipeline));
        return pipeline;
    }

    fn createComputePipelineFromPath(self: *VulkanEngine, path: []const u8, layout: vk.VkPipelineLayout) !vk.VkPipeline {
        const spv = try std.fs.cwd().readFileAlloc(self.allocator, path, 4 * 1024 * 1024);
        defer self.allocator.free(spv);
        return self.createComputePipeline(spv, null, layout);
    }

    fn setupPipelines(self: *VulkanEngine) !void {
        var pcRange = std.mem.zeroes(vk.VkPushConstantRange);
        pcRange.stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        pcRange.size = 64;

        var bindings = [_]vk.VkDescriptorSetLayoutBinding{std.mem.zeroes(vk.VkDescriptorSetLayoutBinding)} ** DESCRIPTOR_BINDING_COUNT;
        for (&bindings, 0..) |*b, i| {
            b.binding = @intCast(i);
            b.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            b.descriptorCount = 1;
            b.stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        }

        var dslCreateInfo = std.mem.zeroes(vk.VkDescriptorSetLayoutCreateInfo);
        dslCreateInfo.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        dslCreateInfo.bindingCount = DESCRIPTOR_BINDING_COUNT;
        dslCreateInfo.pBindings = &bindings[0];
        try check(self.vk_ctx.vkCreateDescriptorSetLayout.?(self.dev, &dslCreateInfo, null, &self.descriptor_set_layout));

        var plCreateInfo = std.mem.zeroes(vk.VkPipelineLayoutCreateInfo);
        plCreateInfo.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        plCreateInfo.setLayoutCount = 1;
        plCreateInfo.pSetLayouts = &self.descriptor_set_layout;
        plCreateInfo.pushConstantRangeCount = 1;
        plCreateInfo.pPushConstantRanges = &pcRange;
        try check(self.vk_ctx.vkCreatePipelineLayout.?(self.dev, &plCreateInfo, null, &self.pipeline_layout));

        // ── Gemma Layout ──
        var gemma_bindings = [_]vk.VkDescriptorSetLayoutBinding{std.mem.zeroes(vk.VkDescriptorSetLayoutBinding)} ** GEMMA_DESCRIPTOR_BINDING_COUNT;
        for (&gemma_bindings, 0..) |*b, i| {
            b.binding = @intCast(i);
            b.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            b.descriptorCount = 1;
            b.stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT;
        }
        var gdslCreateInfo = std.mem.zeroes(vk.VkDescriptorSetLayoutCreateInfo);
        gdslCreateInfo.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        gdslCreateInfo.bindingCount = GEMMA_DESCRIPTOR_BINDING_COUNT;
        gdslCreateInfo.pBindings = &gemma_bindings[0];
        try check(self.vk_ctx.vkCreateDescriptorSetLayout.?(self.dev, &gdslCreateInfo, null, &self.gemma_descriptor_set_layout));

        var gplCreateInfo = std.mem.zeroes(vk.VkPipelineLayoutCreateInfo);
        gplCreateInfo.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        gplCreateInfo.setLayoutCount = 1;
        gplCreateInfo.pSetLayouts = &self.gemma_descriptor_set_layout;
        gplCreateInfo.pushConstantRangeCount = 1;
        gplCreateInfo.pPushConstantRanges = &pcRange;
        try check(self.vk_ctx.vkCreatePipelineLayout.?(self.dev, &gplCreateInfo, null, &self.gemma_pipeline_layout));

        self.compute_pipeline = try self.createComputePipeline(@embedFile("shaders/resonance_query.spv"), null, self.pipeline_layout);
        self.candidate_score_pipeline = try self.createComputePipeline(@embedFile("shaders/candidate_score.spv"), null, self.pipeline_layout);
        self.neighborhood_score_pipeline = try self.createComputePipeline(@embedFile("shaders/neighborhood_score.spv"), null, self.pipeline_layout);
        self.contradiction_filter_pipeline = try self.createComputePipeline(@embedFile("shaders/contradiction_filter.spv"), null, self.pipeline_layout);
        self.semantic_hash_pipeline = try self.createComputePipeline(@embedFile("shaders/semantic_hash.spv"), null, self.pipeline_layout);
        const corpus_scan_spv = try std.fs.cwd().readFileAlloc(self.allocator, build_options.corpus_scan_spv_path, 1024 * 1024);
        defer self.allocator.free(corpus_scan_spv);
        self.corpus_scan_pipeline = try self.createComputePipeline(corpus_scan_spv, null, self.pipeline_layout);
        const lattice_query_spv = try std.fs.cwd().readFileAlloc(self.allocator, build_options.lattice_query_spv_path, 1024 * 1024);
        defer self.allocator.free(lattice_query_spv);
        self.lattice_query_pipeline = try self.createComputePipeline(lattice_query_spv, null, self.pipeline_layout);

        var etch_wg_size: u32 = @min(1024, self.max_workgroup_invocations);
        var spec_map = vk.VkSpecializationMapEntry{ .constantID = 0, .offset = 0, .size = @sizeOf(u32) };
        var etch_spec = vk.VkSpecializationInfo{ .mapEntryCount = 1, .pMapEntries = &spec_map, .dataSize = @sizeOf(u32), .pData = &etch_wg_size };
        self.etch_pipeline = try self.createComputePipeline(@embedFile("shaders/genesis_etch.spv"), &etch_spec, self.pipeline_layout);

        self.prune_pipeline = try self.createComputePipeline(@embedFile("shaders/thermal_prune.spv"), null, self.pipeline_layout);
        self.lookahead_pipeline = try self.createComputePipeline(@embedFile("shaders/recursive_lookahead.spv"), null, self.pipeline_layout);

        var lattice_wg_size: u32 = @min(1024, self.max_workgroup_invocations);
        var lattice_spec = vk.VkSpecializationInfo{ .mapEntryCount = 1, .pMapEntries = &spec_map, .dataSize = @sizeOf(u32), .pData = &lattice_wg_size };
        self.lattice_pipeline = try self.createComputePipeline(@embedFile("shaders/lattice_etch.spv"), &lattice_spec, self.pipeline_layout);

        self.rune_search_pipeline = try self.createComputePipeline(@embedFile("shaders/rune_search.spv"), null, self.pipeline_layout);

        self.gemma_rune_embed_pipeline = try self.createComputePipelineFromPath(build_options.gemma_rune_embed_spv_path, self.gemma_pipeline_layout);
        self.gemma_matmul_q4k_pipeline = try self.createComputePipelineFromPath(build_options.gemma_matmul_q4k_spv_path, self.gemma_pipeline_layout);
        self.gemma_matmul_q8_0_pipeline = try self.createComputePipelineFromPath(build_options.gemma_matmul_q8_0_spv_path, self.gemma_pipeline_layout);
        self.gemma_rms_norm_pipeline = try self.createComputePipelineFromPath(build_options.gemma_rms_norm_spv_path, self.gemma_pipeline_layout);
        self.gemma_swiglu_pipeline = try self.createComputePipelineFromPath(build_options.gemma_swiglu_spv_path, self.gemma_pipeline_layout);
        self.gemma_attention_pipeline = try self.createComputePipelineFromPath(build_options.gemma_attention_spv_path, self.gemma_pipeline_layout);
        self.gemma_rune_project_pipeline = try self.createComputePipelineFromPath(build_options.gemma_rune_project_spv_path, self.gemma_pipeline_layout);
    }

    fn updateDescriptorSets(self: *VulkanEngine, f: u32) void {
        var info = [_]vk.VkDescriptorBufferInfo{std.mem.zeroes(vk.VkDescriptorBufferInfo)} ** DESCRIPTOR_BINDING_COUNT;
        info[0] = .{ .buffer = self.matrix_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[1] = .{ .buffer = self.rotor_buffers[f], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[2] = .{ .buffer = self.char_buffers[f], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[3] = .{ .buffer = self.index_buffers[f], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[4] = .{ .buffer = self.tag_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[5] = .{ .buffer = self.lattice_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[6] = .{ .buffer = self.energy_buffers[f], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[7] = .{ .buffer = self.sigil_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[8] = .{ .buffer = self.diag_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[9] = .{ .buffer = self.panopticon_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[10] = .{ .buffer = self.config_buffers[f], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[11] = .{ .buffer = self.lock_mask_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[12] = .{ .buffer = self.general_ingest_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[13] = .{ .buffer = self.corpus_entry_buffers[f], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[14] = .{ .buffer = self.rune_rank_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };

        var write = std.mem.zeroes(vk.VkWriteDescriptorSet);
        write.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = self.descriptor_sets[f];
        write.dstBinding = 0;
        write.descriptorCount = DESCRIPTOR_BINDING_COUNT;
        write.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write.pBufferInfo = &info[0];
        self.vk_ctx.vkUpdateDescriptorSets.?(self.dev, 1, &write, 0, null);
    }

    fn updateInferenceDescriptors(self: *VulkanEngine, l: u32) void {
        var info = [_]vk.VkDescriptorBufferInfo{std.mem.zeroes(vk.VkDescriptorBufferInfo)} ** 12;
        info[0] = .{ .buffer = self.matrix_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[1] = .{ .buffer = self.inf_rotor_buffers[l], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[2] = .{ .buffer = self.char_buffers[0], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[3] = .{ .buffer = self.index_buffers[0], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[4] = .{ .buffer = self.tag_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[5] = .{ .buffer = self.lattice_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[6] = .{ .buffer = self.inf_energy_buffers[l], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[7] = .{ .buffer = self.sigil_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[8] = .{ .buffer = self.diag_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[9] = .{ .buffer = self.panopticon_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[10] = .{ .buffer = self.inf_config_buffers[l], .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[11] = .{ .buffer = self.lock_mask_buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };

        var write = std.mem.zeroes(vk.VkWriteDescriptorSet);
        write.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = self.inf_descriptor_sets[l];
        write.dstBinding = 0;
        write.descriptorCount = 12;
        write.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write.pBufferInfo = &info[0];
        self.vk_ctx.vkUpdateDescriptorSets.?(self.dev, 1, &write, 0, null);
    }

    fn setupDescriptorPool(self: *VulkanEngine) !void {
        var poolSize = std.mem.zeroes(vk.VkDescriptorPoolSize);
        poolSize.type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        poolSize.descriptorCount = DESCRIPTOR_BINDING_COUNT * (FRAME_COUNT + INF_LANE_COUNT) + (GEMMA_DESCRIPTOR_BINDING_COUNT * GEMMA_DESCRIPTOR_SET_COUNT);
        var dpCreateInfo = std.mem.zeroes(vk.VkDescriptorPoolCreateInfo);
        dpCreateInfo.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        dpCreateInfo.poolSizeCount = 1;
        dpCreateInfo.pPoolSizes = &poolSize;
        dpCreateInfo.maxSets = FRAME_COUNT + INF_LANE_COUNT + GEMMA_DESCRIPTOR_SET_COUNT;
        try check(self.vk_ctx.vkCreateDescriptorPool.?(self.dev, &dpCreateInfo, null, &self.descriptor_pool));

        const dsls = try self.allocator.alloc(vk.VkDescriptorSetLayout, FRAME_COUNT + INF_LANE_COUNT);
        defer self.allocator.free(dsls);
        for (dsls) |*d| d.* = self.descriptor_set_layout;

        var dsAllocInfo = std.mem.zeroes(vk.VkDescriptorSetAllocateInfo);
        dsAllocInfo.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        dsAllocInfo.descriptorPool = self.descriptor_pool;
        dsAllocInfo.descriptorSetCount = FRAME_COUNT + INF_LANE_COUNT;
        dsAllocInfo.pSetLayouts = dsls.ptr;

        var all_sets = try self.allocator.alloc(vk.VkDescriptorSet, FRAME_COUNT + INF_LANE_COUNT);
        defer self.allocator.free(all_sets);
        try check(self.vk_ctx.vkAllocateDescriptorSets.?(self.dev, &dsAllocInfo, all_sets.ptr));

        @memcpy(self.descriptor_sets[0..FRAME_COUNT], all_sets[0..FRAME_COUNT]);
        @memcpy(self.inf_descriptor_sets[0..INF_LANE_COUNT], all_sets[FRAME_COUNT .. FRAME_COUNT + INF_LANE_COUNT]);

        for (0..FRAME_COUNT) |i| self.updateDescriptorSets(@intCast(i));
        for (0..INF_LANE_COUNT) |i| self.updateInferenceDescriptors(@intCast(i));
    }

    fn createCommandSlot(self: *VulkanEngine, qf: u32, pool: *vk.VkCommandPool, buffer: *vk.VkCommandBuffer, fence: *vk.VkFence) !void {
        var cpCreateInfo = std.mem.zeroes(vk.VkCommandPoolCreateInfo);
        cpCreateInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cpCreateInfo.queueFamilyIndex = qf;
        cpCreateInfo.flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try check(self.vk_ctx.vkCreateCommandPool.?(self.dev, &cpCreateInfo, null, pool));

        var cbAllocInfo = std.mem.zeroes(vk.VkCommandBufferAllocateInfo);
        cbAllocInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cbAllocInfo.commandPool = pool.*;
        cbAllocInfo.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cbAllocInfo.commandBufferCount = 1;
        try check(self.vk_ctx.vkAllocateCommandBuffers.?(self.dev, &cbAllocInfo, buffer));

        var fCreateInfo = std.mem.zeroes(vk.VkFenceCreateInfo);
        fCreateInfo.sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fCreateInfo.flags = vk.VK_FENCE_CREATE_SIGNALED_BIT;
        try check(self.vk_ctx.vkCreateFence.?(self.dev, &fCreateInfo, null, fence));
    }

    fn setupCommandInfrastructure(self: *VulkanEngine) !void {
        for (0..FRAME_COUNT) |i| {
            try self.createCommandSlot(self.queue_family, &self.command_pools[i], &self.command_buffers[i], &self.fences[i]);
        }
        for (0..INF_LANE_COUNT) |i| {
            try self.createCommandSlot(self.queue_family, &self.inf_command_pools[i], &self.inf_command_buffers[i], &self.inf_fences[i]);
        }

        if (self.has_dedicated_transfer) {
            var tPoolInfo = std.mem.zeroes(vk.VkCommandPoolCreateInfo);
            tPoolInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
            tPoolInfo.queueFamilyIndex = self.transfer_queue_family;
            tPoolInfo.flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
            try check(self.vk_ctx.vkCreateCommandPool.?(self.dev, &tPoolInfo, null, &self.transfer_pool));

            var tAllocInfo = std.mem.zeroes(vk.VkCommandBufferAllocateInfo);
            tAllocInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            tAllocInfo.commandPool = self.transfer_pool;
            tAllocInfo.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            tAllocInfo.commandBufferCount = 1;

            for (0..FRAME_COUNT) |i| {
                try check(self.vk_ctx.vkAllocateCommandBuffers.?(self.dev, &tAllocInfo, &self.transfer_buffers[i]));
                var tfCreateInfo = std.mem.zeroes(vk.VkFenceCreateInfo);
                tfCreateInfo.sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
                tfCreateInfo.flags = vk.VK_FENCE_CREATE_SIGNALED_BIT;
                try check(self.vk_ctx.vkCreateFence.?(self.dev, &tfCreateInfo, null, &self.transfer_fences[i]));
                var tsCreateInfo = std.mem.zeroes(vk.VkSemaphoreCreateInfo);
                tsCreateInfo.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
                try check(self.vk_ctx.vkCreateSemaphore.?(self.dev, &tsCreateInfo, null, &self.transfer_semaphores[i]));
            }
        }

        var timeline_info = std.mem.zeroes(vk.VkSemaphoreTypeCreateInfo);
        timeline_info.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
        timeline_info.semaphoreType = vk.VK_SEMAPHORE_TYPE_TIMELINE;
        var sCreateInfo = std.mem.zeroes(vk.VkSemaphoreCreateInfo);
        sCreateInfo.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        sCreateInfo.pNext = &timeline_info;
        try check(self.vk_ctx.vkCreateSemaphore.?(self.dev, &sCreateInfo, null, &self.timeline_semaphore));
    }

    fn initCommon(self: *VulkanEngine) !*VulkanEngine {
        try self.detectHardware();
        try self.setupLogicalDevice();
        try self.allocateBuffers();
        try self.setupPipelines();
        try self.setupDescriptorPool();
        try self.setupCommandInfrastructure();

        self.vk_ctx.vkGetDeviceQueue.?(self.dev, self.queue_family, 0, &self.queue);
        return self;
    }


    fn destroyBuffer(self: *const VulkanEngine, buffer: *vk.VkBuffer, memory: *vk.VkDeviceMemory, mapped_ptr: ?*anyopaque) void {
        if (buffer.* == null) return;
        if (mapped_ptr != null) {
            self.vk_ctx.vkUnmapMemory.?(self.dev, memory.*);
        }
        self.vk_ctx.vkDestroyBuffer.?(self.dev, buffer.*, null);
        self.vk_ctx.vkFreeMemory.?(self.dev, memory.*, null);
        buffer.* = null;
        memory.* = null;
    }

    pub fn uploadGemmaWeights(self: *VulkanEngine, loader: *const @import("gemma/weights.zig").GGUFLoader) !void {
        if (self.gemma_state == null) {
            self.gemma_state = try self.allocator.create(GemmaInferenceState);
            self.gemma_state.?.* = .{
                .tensor_offsets = std.StringHashMap(u64).init(self.allocator),
            };
        }
        const state = self.gemma_state.?;

        var total_bytes: usize = 0;
        var it = loader.tensors.iterator();
        while (it.next()) |entry| {
            total_bytes += entry.value_ptr.byte_len;
            total_bytes = (total_bytes + 255) & ~@as(usize, 255); // Align to 256 bytes for Vulkan offsets
        }

        if (state.weights.buffer != null) self.destroyResidentBuffer(&state.weights);
        state.weights = try self.createResidentBufferSize(total_bytes);

        it = loader.tensors.iterator();
        var current_offset: u64 = 0;
        while (it.next()) |entry| {
            const tensor = try loader.getTensor(entry.key_ptr.*);
            var chunk_offset: usize = 0;
            while (chunk_offset < tensor.bytes.len) {
                const chunk_len = @min(tensor.bytes.len - chunk_offset, self.upload_staging_slot_bytes);
                try self.uploadResidentBufferBytes(&state.weights, @intCast(current_offset + chunk_offset), tensor.bytes[chunk_offset .. chunk_offset + chunk_len]);
                chunk_offset += chunk_len;
            }
            try state.tensor_offsets.put(entry.key_ptr.*, current_offset);
            current_offset += @as(u64, @intCast(((tensor.bytes.len + 255) & ~@as(usize, 255))));
        }
        
        // Initialize activation buffers (2x 64MB should be plenty for Gemma-2B layer pass)
        if (state.hidden[0].buffer == null) state.hidden[0] = try self.createResidentBufferSize(64 * 1024 * 1024);
        if (state.hidden[1].buffer == null) state.hidden[1] = try self.createResidentBufferSize(64 * 1024 * 1024);
        if (state.q.buffer == null) state.q = try self.createResidentBufferSize(4 * 1024 * 1024);
        if (state.k.buffer == null) state.k = try self.createResidentBufferSize(4 * 1024 * 1024);
        if (state.v.buffer == null) state.v = try self.createResidentBufferSize(4 * 1024 * 1024);
        if (state.scores.buffer == null) state.scores = try self.createResidentBufferSize(1 * 1024 * 1024);
        if (state.embeddings.buffer == null) state.embeddings = try self.createResidentBufferSize(8 * 1024 * 1024);
        if (state.context_rune_ids.buffer == null) state.context_rune_ids = try self.createResidentBufferSize(1 * 1024 * 1024);
        
        try self.updateGemmaDescriptorSet();
    }

    fn updateGemmaDescriptorSet(self: *VulkanEngine) !void {
        const state = self.gemma_state orelse return error.GemmaStateNotInitialized;
        
        if (self.gemma_descriptor_sets[0] == null) {
            var dsAllocInfo = std.mem.zeroes(vk.VkDescriptorSetAllocateInfo);
            dsAllocInfo.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            dsAllocInfo.descriptorPool = self.descriptor_pool;
            dsAllocInfo.descriptorSetCount = 6;
            dsAllocInfo.pSetLayouts = &[_]vk.VkDescriptorSetLayout{ self.gemma_descriptor_set_layout } ** 6;
            try check(self.vk_ctx.vkAllocateDescriptorSets.?(self.dev, &dsAllocInfo, &self.gemma_descriptor_sets));
        }

        var info = [_]vk.VkDescriptorBufferInfo{std.mem.zeroes(vk.VkDescriptorBufferInfo)} ** GEMMA_DESCRIPTOR_BINDING_COUNT;
        info[0] = .{ .buffer = state.weights.buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[3] = .{ .buffer = state.embeddings.buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[4] = .{ .buffer = state.scores.buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[5] = .{ .buffer = state.context_rune_ids.buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };

        // --- Set 0: hidden[0] -> hidden[1] ---
        info[1] = .{ .buffer = state.hidden[0].buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[2] = .{ .buffer = state.hidden[1].buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        var write0 = std.mem.zeroes(vk.VkWriteDescriptorSet);
        write0.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write0.dstSet = self.gemma_descriptor_sets[0];
        write0.descriptorCount = GEMMA_DESCRIPTOR_BINDING_COUNT;
        write0.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write0.pBufferInfo = &info[0];
        self.vk_ctx.vkUpdateDescriptorSets.?(self.dev, 1, &write0, 0, null);

        // --- Set 1: hidden[0] -> q ---
        info[2] = .{ .buffer = state.q.buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        var write1 = std.mem.zeroes(vk.VkWriteDescriptorSet);
        write1.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write1.dstSet = self.gemma_descriptor_sets[1];
        write1.descriptorCount = GEMMA_DESCRIPTOR_BINDING_COUNT;
        write1.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write1.pBufferInfo = &info[0];
        self.vk_ctx.vkUpdateDescriptorSets.?(self.dev, 1, &write1, 0, null);

        // --- Set 2: embeddings -> k ---
        info[1] = .{ .buffer = state.embeddings.buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[2] = .{ .buffer = state.k.buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        var write2 = std.mem.zeroes(vk.VkWriteDescriptorSet);
        write2.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write2.dstSet = self.gemma_descriptor_sets[2];
        write2.descriptorCount = GEMMA_DESCRIPTOR_BINDING_COUNT;
        write2.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write2.pBufferInfo = &info[0];
        self.vk_ctx.vkUpdateDescriptorSets.?(self.dev, 1, &write2, 0, null);

        // --- Set 3: embeddings -> v ---
        info[2] = .{ .buffer = state.v.buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        var write3 = std.mem.zeroes(vk.VkWriteDescriptorSet);
        write3.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write3.dstSet = self.gemma_descriptor_sets[3];
        write3.descriptorCount = GEMMA_DESCRIPTOR_BINDING_COUNT;
        write3.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write3.pBufferInfo = &info[0];
        self.vk_ctx.vkUpdateDescriptorSets.?(self.dev, 1, &write3, 0, null);

        // --- Set 4: q -> hidden[1] ---
        info[1] = .{ .buffer = state.q.buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[2] = .{ .buffer = state.hidden[1].buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        var write4 = std.mem.zeroes(vk.VkWriteDescriptorSet);
        write4.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write4.dstSet = self.gemma_descriptor_sets[4];
        write4.descriptorCount = GEMMA_DESCRIPTOR_BINDING_COUNT;
        write4.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write4.pBufferInfo = &info[0];
        self.vk_ctx.vkUpdateDescriptorSets.?(self.dev, 1, &write4, 0, null);

        // --- Set 5: hidden[1] -> hidden[0] ---
        info[1] = .{ .buffer = state.hidden[1].buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        info[2] = .{ .buffer = state.hidden[0].buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
        var write5 = std.mem.zeroes(vk.VkWriteDescriptorSet);
        write5.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write5.dstSet = self.gemma_descriptor_sets[5];
        write5.descriptorCount = GEMMA_DESCRIPTOR_BINDING_COUNT;
        write5.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write5.pBufferInfo = &info[0];
        self.vk_ctx.vkUpdateDescriptorSets.?(self.dev, 1, &write5, 0, null);
    }

    pub fn executeGemmaForward(
        self: *VulkanEngine,
        context_embeddings: []const f32,
        context_resonance: []const f32,
    ) !vsa_core.HyperVector {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        const state = self.gemma_state orelse return error.GemmaStateNotInitialized;
        
        // 1. Upload context data for attention
        try self.uploadResidentBufferBytes(&state.embeddings, 0, std.mem.sliceAsBytes(context_embeddings));
        try self.uploadResidentBufferBytes(&state.scores, 0, std.mem.sliceAsBytes(context_resonance));
        
        // 2. Refresh all 6 descriptor sets to ensure context is current
        try self.updateGemmaDescriptorSet();

        // 3. Record and submit
        const f = try self.acquireFrameSlot();
        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        const schedule_config = GemmaForwardScheduleConfig{
            .rune_count = 1,
            .top_k = @intCast(context_resonance.len),
        };
        _ = try self.recordGemmaForwardSchedule(self.command_buffers[f], schedule_config);

        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
        try self.waitForHardwareInterrupt(f);

        // 4. Download result from hidden[1] (Binding 2)
        var result_rune: vsa_core.HyperVector = @splat(@as(u64, 0));
        try self.downloadResidentBufferBytes(&state.hidden[1], 0, @as([*]u8, @ptrCast(&result_rune))[0..@sizeOf(vsa_core.HyperVector)]);
        return result_rune;
    }

    pub fn downloadResidentBufferBytes(self: *VulkanEngine, resident: *const ResidentBuffer, offset: usize, dest: []u8) !void {
        if (dest.len == 0) return;
        if (offset + dest.len > resident.size_bytes) return error.BufferOverflow;

        var staging_buffer: vk.VkBuffer = null;
        var staging_memory: vk.VkDeviceMemory = null;
        const staging_ptr = try self.createBuffer(
            dest.len,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        ) orelse return error.VulkanError;
        defer self.destroyBuffer(&staging_buffer, &staging_memory, staging_ptr);

        const f = self.frame_idx;
        try self.recycleHardwareFenceWithTimeout(f, SHUTDOWN_FENCE_TIMEOUT_NS);

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        var region = std.mem.zeroes(vk.VkBufferCopy);
        region.srcOffset = offset;
        region.size = dest.len;
        self.vk_ctx.vkCmdCopyBuffer.?(self.command_buffers[f], resident.buffer, staging_buffer, 1, &region);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        try self.waitForHardwareInterruptWithTimeout(f, SHUTDOWN_FENCE_TIMEOUT_NS);
        
        const staging_bytes: [*]const u8 = @ptrCast(staging_ptr);
        @memcpy(dest, staging_bytes[0..dest.len]);
    }

    pub fn createResidentBufferFromBytes(self: *VulkanEngine, bytes: []const u8) !ResidentBuffer {
        if (bytes.len == 0) return .{};

        var staging_buffer: vk.VkBuffer = null;
        var staging_memory: vk.VkDeviceMemory = null;
        const staging_ptr = try self.createBuffer(
            bytes.len,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        ) orelse return error.VulkanError;
        defer self.destroyBuffer(&staging_buffer, &staging_memory, staging_ptr);

        const staging_bytes: [*]u8 = @ptrCast(staging_ptr);
        @memcpy(staging_bytes[0..bytes.len], bytes);

        var resident = ResidentBuffer{
            .size_bytes = bytes.len,
            .device_local = true,
        };
        errdefer self.destroyResidentBuffer(&resident);
        _ = try self.createBuffer(
            bytes.len,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            &resident.buffer,
            &resident.memory,
        );

        const f = self.frame_idx;
        try self.recycleHardwareFenceWithTimeout(f, SHUTDOWN_FENCE_TIMEOUT_NS);

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        var region = std.mem.zeroes(vk.VkBufferCopy);
        region.size = bytes.len;
        self.vk_ctx.vkCmdCopyBuffer.?(self.command_buffers[f], staging_buffer, resident.buffer, 1, &region);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        try self.waitForHardwareInterruptWithTimeout(f, SHUTDOWN_FENCE_TIMEOUT_NS);
        self.frame_idx = (self.frame_idx + 1) % FRAME_COUNT;
        resident.epoch = self.publishResidentEpoch(0);

        return resident;
    }

    pub fn createResidentBufferSize(self: *VulkanEngine, size: usize) !ResidentBuffer {
        if (size == 0) return .{};
        var resident = ResidentBuffer{
            .size_bytes = size,
            .device_local = true,
        };
        errdefer self.destroyResidentBuffer(&resident);
        _ = try self.createBuffer(
            size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            &resident.buffer,
            &resident.memory,
        );
        resident.epoch = self.publishResidentEpoch(0);
        return resident;
    }

    fn publishResidentEpoch(self: *VulkanEngine, timeline_ticket: u64) vk_device.ResidentEpoch {
        self.next_resident_epoch +%= 1;
        if (self.next_resident_epoch == 0) self.next_resident_epoch = 1;
        return .{
            .active_epoch = self.next_resident_epoch,
            .published_timeline_value = timeline_ticket,
        };
    }

    fn flushUploadStagingRange(self: *VulkanEngine, slot: usize) !void {
        if ((self.upload_staging_flags & vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0) return;
        const flush_fn = self.vk_ctx.vkFlushMappedMemoryRanges orelse return error.VulkanError;
        var range = std.mem.zeroes(vk.VkMappedMemoryRange);
        range.sType = vk.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
        range.memory = self.upload_staging_memories[slot];
        range.offset = 0;
        range.size = vk.VK_WHOLE_SIZE;
        try check(flush_fn(self.dev, 1, &range));
    }

    pub fn uploadResidentBufferBytes(self: *VulkanEngine, resident: *ResidentBuffer, offset: usize, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (resident.buffer == null or offset > resident.size_bytes or bytes.len > resident.size_bytes - offset) return error.ResidentUploadOutOfBounds;
        if (bytes.len > self.upload_staging_slot_bytes) return error.UploadExceedsPreallocatedStagingArena;

        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const staging_slot = self.upload_staging_slot;
        self.upload_staging_slot = (self.upload_staging_slot + 1) % UPLOAD_STAGING_SLOTS;
        const staging_buffer = self.upload_staging_buffers[staging_slot];
        const staging_bytes = self.mapped_upload_staging[staging_slot] orelse return error.VulkanError;
        @memcpy(staging_bytes[0..bytes.len], bytes);
        try self.flushUploadStagingRange(staging_slot);

        const f = try self.acquireFrameSlotNonBlocking() orelse return error.GpuBusy;
        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        var region = std.mem.zeroes(vk.VkBufferCopy);
        region.srcOffset = 0;
        region.dstOffset = offset;
        region.size = bytes.len;
        self.vk_ctx.vkCmdCopyBuffer.?(self.command_buffers[f], staging_buffer, resident.buffer, 1, &region);

        var barrier = std.mem.zeroes(vk.VkBufferMemoryBarrier);
        barrier.sType = vk.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
        barrier.srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;
        barrier.srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
        barrier.buffer = resident.buffer;
        barrier.offset = offset;
        barrier.size = bytes.len;
        self.vk_ctx.vkCmdPipelineBarrier.?(
            self.command_buffers[f],
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            0,
            null,
            1,
            &barrier,
            0,
            null,
        );

        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        self.timeline_value += 1;
        const ticket = self.timeline_value;
        var timeline_submit = std.mem.zeroes(vk.VkTimelineSemaphoreSubmitInfo);
        timeline_submit.sType = vk.VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO;
        timeline_submit.signalSemaphoreValueCount = 1;
        timeline_submit.pSignalSemaphoreValues = &ticket;

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.pNext = &timeline_submit;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        submitInfo.signalSemaphoreCount = 1;
        submitInfo.pSignalSemaphores = &self.timeline_semaphore;
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
        try self.waitForHardwareInterrupt(f);
        resident.epoch = self.publishResidentEpoch(ticket);
    }

    pub fn destroyResidentBuffer(self: *const VulkanEngine, resident: *ResidentBuffer) void {
        self.destroyBuffer(&resident.buffer, &resident.memory, null);
        resident.* = .{};
    }

    pub fn deinit(self: *VulkanEngine) void {
        self.allocator.free(self.result_buffer);

        waitForGpuWorkersDrained(self);
        waitForAllHardwareInterruptsWithTimeout(self, SHUTDOWN_FENCE_TIMEOUT_NS) catch |err| {
            sys.print("[WARN] Final hardware drain before deinit failed: {any}\n", .{err});
        };
        for (0..INF_LANE_COUNT) |i| {
            self.waitForInferenceInterrupt(i) catch |err| {
                sys.print("[WARN] Final inference drain before deinit failed on lane {d}: {any}\n", .{ i, err });
            };
        }
        if (self.has_dedicated_transfer) {
            for (0..FRAME_COUNT) |i| {
                if (self.transfer_fences[i] != null) self.vk_ctx.vkDestroyFence.?(self.dev, self.transfer_fences[i], null);
                if (self.transfer_semaphores[i] != null) self.vk_ctx.vkDestroySemaphore.?(self.dev, self.transfer_semaphores[i], null);
            }
            if (self.transfer_pool != null) self.vk_ctx.vkDestroyCommandPool.?(self.dev, self.transfer_pool, null);
        }

        for (0..FRAME_COUNT) |i| {
            if (self.fences[i] != null) self.vk_ctx.vkDestroyFence.?(self.dev, self.fences[i], null);
            if (self.command_pools[i] != null) self.vk_ctx.vkDestroyCommandPool.?(self.dev, self.command_pools[i], null);

            self.destroyBuffer(&self.rotor_buffers[i], &self.rotor_memories[i], self.mapped_rotors[i]);
            self.destroyBuffer(&self.char_buffers[i], &self.char_memories[i], self.mapped_chars[i]);
            self.destroyBuffer(&self.index_buffers[i], &self.index_memories[i], self.mapped_index[i]);
            self.destroyBuffer(&self.energy_buffers[i], &self.energy_memories[i], self.mapped_energy[i]);
            self.destroyBuffer(&self.corpus_entry_buffers[i], &self.corpus_entry_memories[i], self.mapped_corpus_entries[i]);
            self.destroyBuffer(&self.config_buffers[i], &self.config_memories[i], self.mapped_config[i]);
        }

        for (0..INF_LANE_COUNT) |i| {
            if (self.inf_fences[i] != null) self.vk_ctx.vkDestroyFence.?(self.dev, self.inf_fences[i], null);
            if (self.inf_command_pools[i] != null) self.vk_ctx.vkDestroyCommandPool.?(self.dev, self.inf_command_pools[i], null);
            self.destroyBuffer(&self.inf_rotor_buffers[i], &self.inf_rotor_memories[i], self.inf_mapped_rotors[i]);
            self.destroyBuffer(&self.inf_energy_buffers[i], &self.inf_energy_memories[i], self.inf_mapped_energy[i]);
            self.destroyBuffer(&self.inf_config_buffers[i], &self.inf_config_memories[i], self.inf_mapped_config[i]);
        }

        if (self.descriptor_pool != null) self.vk_ctx.vkDestroyDescriptorPool.?(self.dev, self.descriptor_pool, null);

        const pipelines = [_]*vk.VkPipeline{
            &self.etch_pipeline,
            &self.prune_pipeline,
            &self.lookahead_pipeline,
            &self.compute_pipeline,
            &self.candidate_score_pipeline,
            &self.neighborhood_score_pipeline,
            &self.contradiction_filter_pipeline,
            &self.semantic_hash_pipeline,
            &self.corpus_scan_pipeline,
            &self.lattice_query_pipeline,
            &self.lattice_pipeline,
            &self.rune_search_pipeline,
            &self.gemma_rune_embed_pipeline,
            &self.gemma_matmul_q4k_pipeline,
            &self.gemma_matmul_q8_0_pipeline,
            &self.gemma_rms_norm_pipeline,
            &self.gemma_swiglu_pipeline,
            &self.gemma_attention_pipeline,
            &self.gemma_rune_project_pipeline,
        };
        for (pipelines) |p| if (p.* != null) self.vk_ctx.vkDestroyPipeline.?(self.dev, p.*, null);

        if (self.gemma_pipeline_layout != null) self.vk_ctx.vkDestroyPipelineLayout.?(self.dev, self.gemma_pipeline_layout, null);
        if (self.gemma_descriptor_set_layout != null) self.vk_ctx.vkDestroyDescriptorSetLayout.?(self.dev, self.gemma_descriptor_set_layout, null);
        if (self.gemma_state) |state| {
            state.deinit(self);
            self.allocator.destroy(state);
            self.gemma_state = null;
        }

        if (self.pipeline_layout != null) self.vk_ctx.vkDestroyPipelineLayout.?(self.dev, self.pipeline_layout, null);
        if (self.descriptor_set_layout != null) self.vk_ctx.vkDestroyDescriptorSetLayout.?(self.dev, self.descriptor_set_layout, null);
        if (self.timeline_semaphore != null) self.vk_ctx.vkDestroySemaphore.?(self.dev, self.timeline_semaphore, null);

        self.destroyBuffer(&self.sigil_buffer, &self.sigil_memory, self.mapped_sigil);
        self.destroyBuffer(&self.diag_buffer, &self.diag_memory, self.mapped_diag);
        self.destroyBuffer(&self.lock_mask_buffer, &self.lock_mask_memory, self.mapped_lock_mask);
        self.destroyBuffer(&self.panopticon_buffer, &self.panopticon_memory, self.mapped_edges);
        self.destroyBuffer(&self.general_ingest_buffer, &self.general_ingest_memory, self.mapped_general_ingest);
        for (0..UPLOAD_STAGING_SLOTS) |i| {
            self.destroyBuffer(&self.upload_staging_buffers[i], &self.upload_staging_memories[i], self.mapped_upload_staging[i]);
        }
        self.destroyBuffer(&self.lattice_buffer, &self.lattice_memory, @ptrCast(self.mapped_lattice));
        self.destroyBuffer(&self.tag_buffer, &self.tag_memory, self.mapped_tags);
        self.destroyBuffer(&self.rune_rank_buffer, &self.rune_rank_memory, self.mapped_rune_ranks);
        self.destroyBuffer(&self.matrix_buffer, &self.matrix_memory, self.mapped_matrix);

        if (self.dev != null) self.vk_ctx.vkDestroyDevice.?(self.dev, null);
        if (self.debug_messenger != null and self.vk_ctx.vkDestroyDebugUtilsMessengerEXT != null) {
            self.vk_ctx.vkDestroyDebugUtilsMessengerEXT.?(self.instance, self.debug_messenger, null);
        }
        if (self.instance != null) self.vk_ctx.vkDestroyInstance.?(self.instance, null);
    }

    pub fn dispatchBatch(self: *VulkanEngine, batch_size: u32) !GpuJob {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlotNonBlocking() orelse return error.GpuBusy;

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo)) catch |err| {
            sys.print("[VULKAN] Error beginning command buffer: {any}\n", .{err});
            return error.VulkanError;
        };

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.compute_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ batch_size, 0, self.matrix_slots - 1, self.lattice_quarter };

        self.mapped_config[f].?.* = .{ .rotor_stride = ROTOR_STRIDE, .rotor_offset = 16, .batch_size = batch_size };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size = @min(1024, self.max_workgroup_invocations);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (batch_size + (wg_size - 1)) / wg_size, 1, 1);
        check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f])) catch |err| {
            sys.print("[VULKAN] Error ending command buffer: {any}\n", .{err});
            return error.VulkanError;
        };

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f])) catch |err| {
            sys.print("[VULKAN] Error submitting queue: {any}\n", .{err});
            return error.VulkanError;
        };
        self.advanceFrameSlot();
        return GpuJob{ .frame_idx = f, .kind = .batch, .result_len = batch_size };
    }

    pub fn waitBatch(self: *VulkanEngine, job: GpuJob, batch_size: u32) ![]u32 {
        try self.waitForHardwareInterrupt(job.frame_idx);
        ghostCopy(u32, self.result_buffer[0..batch_size], self.mapped_energy[job.frame_idx].?[0..batch_size]);
        return self.result_buffer[0..batch_size];
    }

    pub fn dispatchResonance(self: *VulkanEngine, lexical_rotor: u64, semantic_rotor: u64) !GpuJob {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlotNonBlocking() orelse return error.GpuBusy;

        self.mapped_rotors[f].?[0] = lexical_rotor;
        self.mapped_rotors[f].?[1] = semantic_rotor;
        self.mapped_config[f].?.* = .{ .rotor_stride = 2, .rotor_offset = 0, .batch_size = 1 };

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo)) catch |err| {
            sys.print("[VULKAN] Error beginning command buffer in dispatchResonance: {any}\n", .{err});
            return error.VulkanError;
        };

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.compute_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ 1, 1, self.matrix_slots - 1, self.lattice_quarter };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size = @min(1024, self.max_workgroup_invocations);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (256 + (wg_size - 1)) / wg_size, 1, 1);
        check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f])) catch |err| {
            sys.print("[VULKAN] Error ending command buffer in dispatchResonance: {any}\n", .{err});
            return error.VulkanError;
        };

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f])) catch |err| {
            sys.print("[VULKAN] Error submitting queue in dispatchResonance: {any}\n", .{err});
            return error.VulkanError;
        };
        self.advanceFrameSlot();
        return GpuJob{ .frame_idx = f, .kind = .resonance, .result_len = 256 };
    }

    pub fn waitResonance(self: *VulkanEngine, job: GpuJob) ![]u32 {
        try self.waitForHardwareInterrupt(job.frame_idx);
        ghostCopy(u32, self.result_buffer[0..256], self.mapped_energy[job.frame_idx].?[0..256]);
        return self.result_buffer[0..256];
    }

    pub fn gemmaPipelinesReady(self: *const VulkanEngine) bool {
        return self.gemma_rune_embed_pipeline != null and
            self.gemma_matmul_q8_0_pipeline != null and
            self.gemma_rms_norm_pipeline != null and
            self.gemma_swiglu_pipeline != null and
            self.gemma_attention_pipeline != null and
            self.gemma_rune_project_pipeline != null;
    }

    pub fn recordGemmaForwardSchedule(
        self: *VulkanEngine,
        command_buffer: vk.VkCommandBuffer,
        schedule_config: GemmaForwardScheduleConfig,
    ) !u32 {
        if (!self.gemmaPipelinesReady()) return error.GemmaPipelinesUnavailable;
        const state = self.gemma_state orelse return error.GemmaStateNotInitialized;

        var recorded: u32 = 0;
        
        // ── 0. Rune Embedding ──
        // Binding 0: Weights (contains token_embd.weight)
        // Binding 1: hidden[0] (Output)
        // Binding 2: hidden[1] (Not used)
        // Binding 5: context_rune_ids (Input)
        try self.cmdGemmaDispatchInvocations(
            command_buffer,
            self.gemma_rune_embed_pipeline,
            .{ .rows_or_count = schedule_config.rune_count, .cols_or_len = schedule_config.embedding_len, .weight_offset = state.tensor_offsets.get("token_embd.weight") orelse 0 },
            schedule_config.rune_count * schedule_config.embedding_len,
            64,
            0,
        );
        recorded += 1;

        var layer: u32 = 0;
        while (layer < schedule_config.block_count) : (layer += 1) {
            const ffn_dim = try schedule_config.ffnDim(layer);
            const q_width: u32 = 2048;
            const kv_width: u32 = 2048;

            // Names for this layer
            var name_buf: [64]u8 = undefined;
            const q_name = try std.fmt.bufPrint(&name_buf, "blk.{d}.attn_q.weight", .{layer});
            const q_off = state.tensor_offsets.get(q_name) orelse 0;
            const k_name = try std.fmt.bufPrint(&name_buf, "blk.{d}.attn_k.weight", .{layer});
            const k_off = state.tensor_offsets.get(k_name) orelse 0;
            const v_name = try std.fmt.bufPrint(&name_buf, "blk.{d}.attn_v.weight", .{layer});
            const v_off = state.tensor_offsets.get(v_name) orelse 0;
            const out_name = try std.fmt.bufPrint(&name_buf, "blk.{d}.attn_output.weight", .{layer});
            const out_off = state.tensor_offsets.get(out_name) orelse 0;
            const up_name = try std.fmt.bufPrint(&name_buf, "blk.{d}.ffn_up.weight", .{layer});
            const up_off = state.tensor_offsets.get(up_name) orelse 0;
            const gate_name = try std.fmt.bufPrint(&name_buf, "blk.{d}.ffn_gate.weight", .{layer});
            const gate_off = state.tensor_offsets.get(gate_name) orelse 0;
            const down_name = try std.fmt.bufPrint(&name_buf, "blk.{d}.ffn_down.weight", .{layer});
            const down_off = state.tensor_offsets.get(down_name) orelse 0;
            const norm_name = try std.fmt.bufPrint(&name_buf, "blk.{d}.attn_norm.weight", .{layer});
            const norm_off = state.tensor_offsets.get(norm_name) orelse 0;
            const ffn_norm_name = try std.fmt.bufPrint(&name_buf, "blk.{d}.ffn_norm.weight", .{layer});
            const ffn_norm_off = state.tensor_offsets.get(ffn_norm_name) orelse 0;

            // 1. RMSNorm (Pre-attention)
            try self.cmdGemmaDispatchGroups(command_buffer, self.gemma_rms_norm_pipeline, .{ .rows_or_count = 1, .cols_or_len = schedule_config.embedding_len, .weight_offset = norm_off }, 1, 0);
            
            // 2. Projection Q (hidden[0] -> q)
            try self.cmdGemmaDispatchInvocations(command_buffer, self.gemma_matmul_q8_0_pipeline, .{ .rows_or_count = q_width, .cols_or_len = schedule_config.embedding_len, .row_offset = 0, .weight_offset = q_off }, q_width, 64, 1);
            
            // 3. Projection K (context -> k) 
            try self.cmdGemmaDispatchInvocations(command_buffer, self.gemma_matmul_q8_0_pipeline, .{ .rows_or_count = kv_width, .cols_or_len = schedule_config.embedding_len, .row_offset = 0, .weight_offset = k_off }, kv_width, 64, 2);
            
            // 4. Projection V (context -> v)
            try self.cmdGemmaDispatchInvocations(command_buffer, self.gemma_matmul_q8_0_pipeline, .{ .rows_or_count = kv_width, .cols_or_len = schedule_config.embedding_len, .row_offset = 0, .weight_offset = v_off }, kv_width, 64, 3);
            
            // 5. Attention (Sovereign Resonance Weighted) (q -> hidden[1])
            try self.cmdGemmaDispatchInvocations(command_buffer, self.gemma_attention_pipeline, .{ .rows_or_count = schedule_config.top_k, .cols_or_len = schedule_config.embedding_len }, schedule_config.embedding_len, 64, 4);
            
            // 6. Matmul Output + Residual Add (hidden[1] -> hidden[0])
            try self.cmdGemmaDispatchInvocations(command_buffer, self.gemma_matmul_q8_0_pipeline, .{ .rows_or_count = schedule_config.embedding_len, .cols_or_len = q_width, .row_offset = 0, .weight_offset = out_off, .flags = 1 }, schedule_config.embedding_len, 64, 5);

            // 7. RMSNorm (Pre-FFN)
            try self.cmdGemmaDispatchGroups(command_buffer, self.gemma_rms_norm_pipeline, .{ .rows_or_count = 1, .cols_or_len = schedule_config.embedding_len, .weight_offset = ffn_norm_off }, 1, 0);

            // 8. FFN Up & Gate (hidden[0] -> hidden[1])
            try self.cmdGemmaDispatchInvocations(command_buffer, self.gemma_matmul_q8_0_pipeline, .{ .rows_or_count = ffn_dim, .cols_or_len = schedule_config.embedding_len, .row_offset = 0, .weight_offset = up_off }, ffn_dim, 64, 0);
            try self.cmdGemmaDispatchInvocations(command_buffer, self.gemma_matmul_q8_0_pipeline, .{ .rows_or_count = ffn_dim, .cols_or_len = schedule_config.embedding_len, .row_offset = ffn_dim, .weight_offset = gate_off }, ffn_dim, 64, 0);
            
            // 9. SwiGLU (hidden[1] -> hidden[1])
            try self.cmdGemmaDispatchInvocations(command_buffer, self.gemma_swiglu_pipeline, .{ .rows_or_count = ffn_dim, .row_offset = ffn_dim, .flags = 0, .weight_offset = 0 }, ffn_dim, 64, 0);
            
            // 10. FFN Down + Residual Add (hidden[1] -> hidden[0])
            try self.cmdGemmaDispatchInvocations(command_buffer, self.gemma_matmul_q8_0_pipeline, .{ .rows_or_count = schedule_config.embedding_len, .cols_or_len = ffn_dim, .weight_offset = down_off, .flags = 1 }, schedule_config.embedding_len, 64, 5);

            recorded += GEMMA_FORWARD_STAGES_PER_BLOCK;
        }

        // ── Final Rune Projection ──
        const head_seed: u64 = 0x6765_6d6d_615f_6864;
        try self.cmdGemmaDispatchGroups(command_buffer, self.gemma_rune_project_pipeline, .{
            .rows_or_count = schedule_config.embedding_len,
            .cols_or_len = 16,
            .weight_offset = head_seed,
        }, 1, 0);
        recorded += 1;
        return recorded;
    }

    fn cmdGemmaDispatchInvocations(
        self: *VulkanEngine,
        command_buffer: vk.VkCommandBuffer,
        pipeline: vk.VkPipeline,
        pc: GemmaPushConstants,
        invocations: u32,
        local_size: u32,
        set_idx: u32,
    ) !void {
        const groups = (invocations + (local_size - 1)) / local_size;
        try self.cmdGemmaDispatchGroups(command_buffer, pipeline, pc, groups, set_idx);
    }

    fn cmdGemmaDispatchGroups(
        self: *VulkanEngine,
        command_buffer: vk.VkCommandBuffer,
        pipeline: vk.VkPipeline,
        pc: GemmaPushConstants,
        groups: u32,
        set_idx: u32,
    ) !void {
        if (pipeline == null) return error.GemmaPipelinesUnavailable;
        self.vk_ctx.vkCmdBindPipeline.?(command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.gemma_pipeline_layout, 0, 1, &self.gemma_descriptor_sets[set_idx], 0, null);
        self.vk_ctx.vkCmdPushConstants.?(command_buffer, self.gemma_pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(GemmaPushConstants), &pc);
        self.vk_ctx.vkCmdDispatch.?(command_buffer, @max(groups, 1), 1, 1);
        self.cmdGemmaBarrier(command_buffer);
    }

    fn cmdGemmaBarrier(self: *VulkanEngine, command_buffer: vk.VkCommandBuffer) void {
        var barrier = std.mem.zeroes(vk.VkMemoryBarrier);
        barrier.sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT;
        barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT | vk.VK_ACCESS_SHADER_WRITE_BIT;
        self.vk_ctx.vkCmdPipelineBarrier.?(
            command_buffer,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            1,
            &barrier,
            0,
            null,
            0,
            null,
        );
    }

    pub fn dispatchResonanceBatched(self: *VulkanEngine, num_lanes: u32, rotor_pairs: []const u64) !GpuJob {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const actual: u32 = @min(num_lanes, @min(@as(u32, INF_LANE_COUNT), @as(u32, @intCast(self.result_buffer.len / 256))));
        const wg_size = @min(1024, self.max_workgroup_invocations);

        for (0..actual) |lane| {
            try self.recycleInferenceFence(lane);

            self.inf_mapped_rotors[lane].?[0] = rotor_pairs[lane * 2];
            self.inf_mapped_rotors[lane].?[1] = rotor_pairs[lane * 2 + 1];
            self.inf_mapped_config[lane].?.* = .{ .rotor_stride = 2, .rotor_offset = 0, .batch_size = 1 };

            var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
            beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
            try check(self.vk_ctx.vkBeginCommandBuffer.?(self.inf_command_buffers[lane], &beginInfo));

            self.vk_ctx.vkCmdBindPipeline.?(self.inf_command_buffers[lane], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.compute_pipeline);
            self.vk_ctx.vkCmdBindDescriptorSets.?(self.inf_command_buffers[lane], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.inf_descriptor_sets[lane], 0, null);
            const pc = [_]u32{ 1, 1, self.matrix_slots - 1, self.lattice_quarter };
            self.vk_ctx.vkCmdPushConstants.?(self.inf_command_buffers[lane], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
            self.vk_ctx.vkCmdDispatch.?(self.inf_command_buffers[lane], (256 + (wg_size - 1)) / wg_size, 1, 1);
            try check(self.vk_ctx.vkEndCommandBuffer.?(self.inf_command_buffers[lane]));

            var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
            submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
            submitInfo.commandBufferCount = 1;
            submitInfo.pCommandBuffers = &self.inf_command_buffers[lane];
            const submit_res = self.vk_ctx.vkQueueSubmit.?(self.queues[lane % self.num_queues], 1, &submitInfo, self.inf_fences[lane]);
            if (submit_res != vk.VK_SUCCESS) {
                sys.print("[FATAL] dispatchResonanceBatched vkQueueSubmit failed on lane {d}: {d}\n", .{ lane, submit_res });
                return error.QueueSubmitFailed;
            }
        }

        return GpuJob{ .frame_idx = 0, .kind = .inference_batch, .result_len = actual };
    }

    pub fn waitResonanceBatched(self: *VulkanEngine, job: GpuJob) ![]u32 {
        const actual = @as(u32, @intCast(job.result_len));
        for (0..actual) |lane| try self.waitForInferenceInterrupt(lane);
        for (0..actual) |lane| ghostCopy(u32, self.result_buffer[lane * 256 .. (lane + 1) * 256], self.inf_mapped_energy[lane].?[0..256]);

        return self.result_buffer[0 .. actual * 256];
    }

    pub fn dispatchLayer2aCandidateScores(
        self: *VulkanEngine,
        lexical_rotor: u64,
        semantic_rotor: u64,
        candidates: []const u32,
    ) !GpuJob {
        // Layer 2a kernels only accelerate bounded scoring/filter sub-operations.
        // CPU Layer 2b remains authoritative for branch-heavy reasoning and all
        // final decisions, so callers must treat this as an accelerator only.
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        if (candidates.len > LAYER2A_MAX_CANDIDATES) return error.TooManyCandidates;

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlot();
        self.mapped_rotors[f].?[0] = lexical_rotor;
        self.mapped_rotors[f].?[1] = semantic_rotor;
        ghostCopy(u32, self.mapped_chars[f].?[0..candidates.len], candidates);
        self.mapped_config[f].?.* = .{ .rotor_stride = 2, .rotor_offset = 0, .batch_size = @intCast(candidates.len) };

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.candidate_score_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ @intCast(candidates.len), 0, self.matrix_slots - 1, self.lattice_quarter };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size: u32 = 64;
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (@as(u32, @intCast(candidates.len)) + (wg_size - 1)) / wg_size, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
        return GpuJob{ .frame_idx = f, .kind = .layer2a_score, .result_len = candidates.len };
    }

    pub fn waitLayer2aCandidateScores(self: *VulkanEngine, job: GpuJob) ![]const u32 {
        try self.waitForHardwareInterrupt(job.frame_idx);
        ghostCopy(u32, self.result_buffer[0..job.result_len], self.mapped_energy[job.frame_idx].?[0..job.result_len]);
        return self.result_buffer[0..job.result_len];
    }

    pub fn dispatchLayer2aNeighborhoodScores(
        self: *VulkanEngine,
        lexical_rotor: u64,
        semantic_rotor: u64,
        candidates: []const u32,
    ) ![]const u32 {
        // This dispatch is bounded helper work only. Callers must keep policy,
        // contradiction adjudication, and stop semantics on the CPU.
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        if (candidates.len > LAYER2A_MAX_CANDIDATES) return error.TooManyCandidates;

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlot();
        self.mapped_rotors[f].?[0] = lexical_rotor;
        self.mapped_rotors[f].?[1] = semantic_rotor;
        ghostCopy(u32, self.mapped_chars[f].?[0..candidates.len], candidates);
        self.mapped_config[f].?.* = .{ .rotor_stride = 2, .rotor_offset = 0, .batch_size = @intCast(candidates.len) };

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.neighborhood_score_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ @intCast(candidates.len), 0, self.matrix_slots - 1, self.lattice_quarter };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size: u32 = 64;
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (@as(u32, @intCast(candidates.len)) + (wg_size - 1)) / wg_size, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
        try self.waitForHardwareInterrupt(f);

        const word_count = candidates.len * 4;
        ghostCopy(u32, self.result_buffer[0..word_count], self.mapped_energy[f].?[0..word_count]);
        return self.result_buffer[0..word_count];
    }

    pub fn dispatchLayer2aContradictionFilter(
        self: *VulkanEngine,
        candidate_chars: []const u32,
        candidate_scores: []const u32,
    ) !Layer2aContradictionSummary {
        // This fast-path only summarizes a compact candidate set. CPU logic is
        // still the source of truth for contradiction handling and final output.
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        if (candidate_chars.len != candidate_scores.len) return error.LengthMismatch;
        if (candidate_chars.len > LAYER2A_MAX_CANDIDATES) return error.TooManyCandidates;

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlot();
        ghostCopy(u32, self.mapped_chars[f].?[0..candidate_chars.len], candidate_chars);
        ghostCopy(u32, self.mapped_index[f].?[0..candidate_scores.len], candidate_scores);
        self.mapped_config[f].?.* = .{ .rotor_stride = 0, .rotor_offset = 0, .batch_size = @intCast(candidate_chars.len) };

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.contradiction_filter_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ @intCast(candidate_chars.len), 0, self.matrix_slots - 1, self.lattice_quarter };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], 1, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
        try self.waitForHardwareInterrupt(f);

        ghostCopy(u32, self.result_buffer[0..8], self.mapped_energy[f].?[0..8]);
        return .{
            .winner_index = self.result_buffer[0],
            .winner_char = self.result_buffer[1],
            .best_score = self.result_buffer[2],
            .runner_up_score = self.result_buffer[3],
            .contradiction = self.result_buffer[4] != 0,
            .contradiction_checks = self.result_buffer[5],
            .candidate_count = self.result_buffer[6],
            .survivor_count = self.result_buffer[7],
        };
    }

    pub fn dispatchSemanticHashBatch(self: *VulkanEngine, block_seeds: []const u64) !GpuJob {
        // Hash acceleration is metadata-only helper work for ingest/search
        // indexing. CPU verification and final corpus authority remain outside
        // this Vulkan dispatch.
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        if (block_seeds.len == 0) return GpuJob{ .frame_idx = std.math.maxInt(usize), .kind = .empty };
        if (block_seeds.len * 2 > self.result_buffer.len) return error.TooManyHashBlocks;

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlot();
        ghostCopy(u64, self.mapped_rotors[f].?[0..block_seeds.len], block_seeds);
        self.mapped_config[f].?.* = .{ .rotor_stride = 1, .rotor_offset = 0, .batch_size = @intCast(block_seeds.len) };

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.semantic_hash_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ @intCast(block_seeds.len), 0, self.matrix_slots - 1, self.lattice_quarter };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size: u32 = 64;
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (@as(u32, @intCast(block_seeds.len)) + (wg_size - 1)) / wg_size, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
        return GpuJob{ .frame_idx = f, .kind = .semantic_hash, .result_len = block_seeds.len * 2 };
    }

    pub fn waitSemanticHashBatch(self: *VulkanEngine, job: GpuJob) ![]const u32 {
        if (job.frame_idx == std.math.maxInt(usize)) return self.result_buffer[0..0];
        try self.waitForHardwareInterrupt(job.frame_idx);
        ghostCopy(u32, self.result_buffer[0..job.result_len], self.mapped_energy[job.frame_idx].?[0..job.result_len]);
        return self.result_buffer[0..job.result_len];
    }

    pub fn dispatchLatticeQuery(self: *VulkanEngine, query_words: [gpu_lattice.VECTOR_WORDS]u32, runes: []const LatticeQueryRune) !GpuJob {
        // LATTICE_QUERY is a routing primitive only. The shader returns raw
        // Hamming distances; proof, support, and answer authority stay in the
        // caller's CPU-side verifier.
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        if (runes.len == 0) return GpuJob{ .frame_idx = std.math.maxInt(usize), .kind = .empty };
        if (runes.len > self.result_buffer.len) return error.TooManyLatticeRunes;
        if (runes.len * @sizeOf(LatticeQueryRune) > self.general_ingest_size) return error.TooManyLatticeRunes;

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlot();
        const query_dst: [*]u32 = @ptrCast(@alignCast(self.mapped_rotors[f].?));
        ghostCopy(u32, query_dst[0..gpu_lattice.VECTOR_WORDS], query_words[0..]);

        const rune_dst: [*]LatticeQueryRune = @ptrCast(@alignCast(self.mapped_general_ingest.?));
        ghostCopy(LatticeQueryRune, rune_dst[0..runes.len], runes);
        self.mapped_config[f].?.* = .{ .rotor_stride = 0, .rotor_offset = 0, .batch_size = @intCast(runes.len) };

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.lattice_query_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ @intCast(runes.len), 0, self.matrix_slots - 1, self.lattice_quarter };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size: u32 = 64;
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (@as(u32, @intCast(runes.len)) + (wg_size - 1)) / wg_size, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
        return GpuJob{ .frame_idx = f, .kind = .lattice_query, .result_len = runes.len };
    }

    pub fn waitLatticeQuery(self: *VulkanEngine, job: GpuJob) ![]const u32 {
        if (job.frame_idx == std.math.maxInt(usize)) return self.result_buffer[0..0];
        try self.waitForHardwareInterrupt(job.frame_idx);
        ghostCopy(u32, self.result_buffer[0..job.result_len], self.mapped_energy[job.frame_idx].?[0..job.result_len]);
        return self.result_buffer[0..job.result_len];
    }

    pub const GpuJob = struct {
        frame_idx: usize,
        kind: GpuJobKind = .unknown,
        result_len: usize = 0,
    };

    pub const GpuJobKind = enum {
        unknown,
        empty,
        batch,
        resonance,
        resonance_batched,
        inference_batch,
        semantic_hash,
        lattice_query,
        rune_search,
        corpus_scan,
        layer2a_score,
    };

    pub const RuneSearchResult = struct {
        slot: u32,
        distance: u32,
        candidates_checked: u32,
    };

    pub const GpuState = union(enum) {
        Pending,
        Empty,
        RuneSearchReady: RuneSearchResult,
        CorpusScanReady: []const u32,
    };

    pub fn dispatchRuneSearchAsync(self: *VulkanEngine, query: vsa_core.HyperVector, min_rank: u32, distance_threshold: u32) !GpuJob {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlotNonBlocking() orelse return error.GpuBusy;

        // 1. Write query vector to rotor_buffers[f] (Binding 1)
        const query_dst: [*]u32 = @ptrCast(@alignCast(self.mapped_rotors[f].?));
        ghostCopy(u32, query_dst[0..32], @as([*]const u32, @ptrCast(&query))[0..32]);

        // 2. Clear index_buffers[f] (Binding 3) for results
        // Results struct: best_slot, best_distance, candidates_checked
        const result_dst: [*]u32 = @ptrCast(@alignCast(self.mapped_index[f].?));
        result_dst[0] = 0xFFFFFFFF; // best_slot
        result_dst[1] = 0xFFFFFFFF; // best_distance
        result_dst[2] = 0; // candidates_checked

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.rune_search_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);

        // Push constants: start_slot, slot_count, min_rank, distance_threshold
        const pc = [_]u32{ 0, self.matrix_slots, min_rank, distance_threshold };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        // Dispatch (256 threads per workgroup)
        const wg_size: u32 = 256;
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (self.matrix_slots + (wg_size - 1)) / wg_size, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();

        return GpuJob{ .frame_idx = f, .kind = .rune_search, .result_len = 3 };
    }

    pub fn waitRuneSearch(self: *VulkanEngine, job: GpuJob) !RuneSearchResult {
        try self.waitForHardwareInterrupt(job.frame_idx);

        const result_dst: [*]u32 = @ptrCast(@alignCast(self.mapped_index[job.frame_idx].?));
        return RuneSearchResult{
            .slot = result_dst[0],
            .distance = result_dst[1],
            .candidates_checked = result_dst[2],
        };
    }

    pub fn pollRuneSearch(self: *VulkanEngine, job: GpuJob) !?RuneSearchResult {
        return switch (try self.checkGpuStatus(job)) {
            .Pending, .Empty, .CorpusScanReady => null,
            .RuneSearchReady => |result| result,
        };
    }

    pub fn checkGpuStatus(self: *VulkanEngine, job: GpuJob) !GpuState {
        if (job.kind == .empty or job.frame_idx == std.math.maxInt(usize)) return .Empty;
        if (job.frame_idx >= FRAME_COUNT) return error.InvalidGpuJob;

        const status = self.vk_ctx.vkGetFenceStatus.?(self.dev, self.fences[job.frame_idx]);
        if (status == vk.VK_NOT_READY) return .Pending;
        if (status != vk.VK_SUCCESS) return error.HardwareSyncFailed;

        return switch (job.kind) {
            .rune_search => blk: {
                const result_dst: [*]u32 = @ptrCast(@alignCast(self.mapped_index[job.frame_idx].?));
                break :blk GpuState{ .RuneSearchReady = .{
                    .slot = result_dst[0],
                    .distance = result_dst[1],
                    .candidates_checked = result_dst[2],
                } };
            },
            .corpus_scan => blk: {
                ghostCopy(u32, self.result_buffer[0..job.result_len], self.mapped_energy[job.frame_idx].?[0..job.result_len]);
                self.updateDescriptorSets(@intCast(job.frame_idx));
                break :blk GpuState{ .CorpusScanReady = self.result_buffer[0..job.result_len] };
            },
            .empty => .Empty,
            .batch, .resonance, .resonance_batched, .inference_batch, .layer2a_score, .semantic_hash, .lattice_query, .unknown => error.InvalidGpuJob,
        };
    }

    pub fn dispatchRuneSearch(self: *VulkanEngine, query: vsa_core.HyperVector, min_rank: u32, distance_threshold: u32) !GpuJob {
        return try self.dispatchRuneSearchAsync(query, min_rank, distance_threshold);
    }

    pub fn dispatchCorpusScanAsync(
        self: *VulkanEngine,
        resident: *const ResidentBuffer,
        entries: []const CorpusScanEntry,
        terms: []const []const u8,
        query_hash: u64,
        bias_hash: u64,
        bias_multiplier_per_mille: u32,
        query_relation_hash: u64,
        inverse_relation_hash: u64,
    ) !GpuJob {
        // GPU corpus scan ranks resident shard entries by deterministic
        // SimHash resonance. CPU callers may render snippets and enforce
        // policy, but should not perform the hot full-shard scoring loop.
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        if (resident.buffer == null or resident.size_bytes == 0) return error.EmptyResidentCorpus;
        if (entries.len == 0) return GpuJob{ .frame_idx = std.math.maxInt(usize), .kind = .empty };
        if (entries.len > CORPUS_SCAN_MAX_ENTRIES) return error.TooManyCorpusEntries;
        if (entries.len > self.result_buffer.len) return error.TooManyCorpusEntries;

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlotNonBlocking() orelse return error.GpuBusy;
        ghostCopy(CorpusScanEntry, self.mapped_corpus_entries[f].?[0..entries.len], entries);
        var term_lens = [_]u32{0} ** CORPUS_SCAN_MAX_TERMS;
        const query_word_count = (CORPUS_SCAN_MAX_TERMS * CORPUS_SCAN_TERM_BYTES + @sizeOf(u64) - 1) / @sizeOf(u64);
        const query_bytes = std.mem.sliceAsBytes(self.mapped_rotors[f].?[0..query_word_count]);
        @memset(query_bytes, 0);
        const packed_terms = @min(terms.len, CORPUS_SCAN_MAX_TERMS);
        for (terms[0..packed_terms], 0..) |term, term_idx| {
            const len = @min(term.len, CORPUS_SCAN_TERM_BYTES);
            term_lens[term_idx] = @intCast(len);
            @memcpy(query_bytes[term_idx * CORPUS_SCAN_TERM_BYTES .. term_idx * CORPUS_SCAN_TERM_BYTES + len], term[0..len]);
        }
        self.mapped_config[f].?.* = .{ .rotor_stride = 0, .rotor_offset = 0, .batch_size = @intCast(entries.len) };

        var corpus_info = std.mem.zeroes(vk.VkDescriptorBufferInfo);
        corpus_info.buffer = resident.buffer;
        corpus_info.offset = 0;
        corpus_info.range = resident.size_bytes;

        var corpus_write = std.mem.zeroes(vk.VkWriteDescriptorSet);
        corpus_write.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        corpus_write.dstSet = self.descriptor_sets[f];
        corpus_write.dstBinding = 12;
        corpus_write.descriptorCount = 1;
        corpus_write.descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        corpus_write.pBufferInfo = &corpus_info;
        self.vk_ctx.vkUpdateDescriptorSets.?(self.dev, 1, &corpus_write, 0, null);

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.corpus_scan_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{
            @intCast(entries.len),
            bias_multiplier_per_mille,
            @intCast(query_hash & 0xFFFF_FFFF),
            @intCast(query_hash >> 32),
            @intCast(bias_hash & 0xFFFF_FFFF),
            @intCast(bias_hash >> 32),
            @intCast(@min(resident.size_bytes, std.math.maxInt(u32))),
            @intCast(packed_terms),
            term_lens[0],
            term_lens[1],
            term_lens[2],
            term_lens[3],
            @intCast(query_relation_hash & 0xFFFF_FFFF),
            @intCast(query_relation_hash >> 32),
            @intCast(inverse_relation_hash & 0xFFFF_FFFF),
            @intCast(inverse_relation_hash >> 32),
        };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 64, &pc);

        const wg_size: u32 = 64;
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (@as(u32, @intCast(entries.len)) + (wg_size - 1)) / wg_size, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();

        return GpuJob{ .frame_idx = f, .kind = .corpus_scan, .result_len = entries.len };
    }

    pub fn waitCorpusScan(self: *VulkanEngine, job: GpuJob, entries_len: usize) ![]const u32 {
        if (job.frame_idx == std.math.maxInt(usize)) return self.result_buffer[0..0];
        try self.waitForHardwareInterrupt(job.frame_idx);

        ghostCopy(u32, self.result_buffer[0..entries_len], self.mapped_energy[job.frame_idx].?[0..entries_len]);
        self.updateDescriptorSets(@intCast(job.frame_idx));
        return self.result_buffer[0..entries_len];
    }

    pub fn pollCorpusScan(self: *VulkanEngine, job: GpuJob, entries_len: usize) !?[]const u32 {
        if (job.frame_idx == std.math.maxInt(usize)) return self.result_buffer[0..0];
        const is_ready = try self.pollHardwareInterrupt(job.frame_idx);
        if (!is_ready) return null;

        ghostCopy(u32, self.result_buffer[0..entries_len], self.mapped_energy[job.frame_idx].?[0..entries_len]);
        self.updateDescriptorSets(@intCast(job.frame_idx));
        return self.result_buffer[0..entries_len];
    }

    pub fn dispatchCorpusScan(
        self: *VulkanEngine,
        resident: *const ResidentBuffer,
        entries: []const CorpusScanEntry,
        terms: []const []const u8,
        query_hash: u64,
        bias_hash: u64,
        bias_multiplier_per_mille: u32,
        query_relation_hash: u64,
        inverse_relation_hash: u64,
    ) ![]const u32 {
        const job = try self.dispatchCorpusScanAsync(resident, entries, terms, query_hash, bias_hash, bias_multiplier_per_mille, query_relation_hash, inverse_relation_hash);
        return self.waitCorpusScan(job, entries.len);
    }

    pub fn dispatchEtch(self: *VulkanEngine, batch_size: u32) !void {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();
        self.refreshLockMaskFromControl();

        const f = try self.acquireFrameSlot();

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.etch_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ batch_size, 1, self.matrix_slots - 1, self.lattice_quarter };

        self.mapped_config[f].?.* = .{ .rotor_stride = ROTOR_STRIDE, .rotor_offset = 16, .batch_size = batch_size };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size = @min(1024, self.max_workgroup_invocations);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (batch_size + (wg_size - 1)) / wg_size, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
    }

    pub fn dispatchMergedEtch(self: *VulkanEngine, batch_size: u32, num_streams: u32) !void {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();
        self.refreshLockMaskFromControl();

        const f = try self.acquireFrameSlot();

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        const wg_size = @min(1024, self.max_workgroup_invocations);
        const num_workgroups = (batch_size + (wg_size - 1)) / wg_size;
        const pc = [_]u32{ batch_size, num_streams, self.matrix_slots - 1, self.lattice_quarter };

        self.mapped_config[f].?.* = .{ .rotor_stride = ROTOR_STRIDE, .rotor_offset = 16, .batch_size = batch_size };

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.lattice_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], num_workgroups, 1, 1);

        var barrier = std.mem.zeroes(vk.VkMemoryBarrier);
        barrier.sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT;
        barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT | vk.VK_ACCESS_SHADER_WRITE_BIT;
        self.vk_ctx.vkCmdPipelineBarrier.?(self.command_buffers[f], vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.etch_pipeline);
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], num_workgroups, 1, 1);

        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
    }

    pub fn dispatchPrune(self: *VulkanEngine) !void {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlot();

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.prune_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const lattice_uints = @as(u32, @intCast(self.gpu_lattice_size / 4));
        const pc = [_]u32{ lattice_uints, 0, self.matrix_slots - 1, self.lattice_quarter };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);

        const wg_size = @min(1024, self.max_workgroup_invocations);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], (lattice_uints + (wg_size - 1)) / wg_size, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
    }

    pub fn dispatchRecursiveLookahead(self: *VulkanEngine, num_rotors: u32, depth: u32) !u64 {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        const f = try self.acquireFrameSlot();

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.lookahead_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        const pc = [_]u32{ num_rotors, depth, self.matrix_slots - 1, self.lattice_quarter };

        self.mapped_config[f].?.* = .{ .rotor_stride = ROTOR_STRIDE, .rotor_offset = 16, .batch_size = num_rotors };
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], num_rotors, 1, 1);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        self.timeline_value += 1;
        const ticket = self.timeline_value;
        var timeline_submit = std.mem.zeroes(vk.VkTimelineSemaphoreSubmitInfo);
        timeline_submit.sType = vk.VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO;
        timeline_submit.signalSemaphoreValueCount = 1;
        timeline_submit.pSignalSemaphoreValues = &ticket;

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.pNext = &timeline_submit;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        submitInfo.signalSemaphoreCount = 1;
        submitInfo.pSignalSemaphores = &self.timeline_semaphore;

        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.frame_generations[f] = ticket;
        const receipt = (ticket << 8) | @as(u64, f);
        self.advanceFrameSlot();
        return receipt;
    }

    pub fn collectLookaheadResults(self: *VulkanEngine, receipt: u64, num_rotors: u32) []u32 {
        const f: u32 = @intCast(receipt & 0xFF);
        const ticket = receipt >> 8;

        var waitInfo = std.mem.zeroes(vk.VkSemaphoreWaitInfo);
        waitInfo.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
        waitInfo.semaphoreCount = 1;
        waitInfo.pSemaphores = &self.timeline_semaphore;
        waitInfo.pValues = &ticket;
        _ = self.vk_ctx.vkWaitSemaphores.?(self.dev, &waitInfo, std.math.maxInt(u64));

        if (self.frame_generations[f] != ticket) return self.result_buffer[0..0];
        ghostCopy(u32, self.result_buffer[0..num_rotors], self.mapped_energy[f].?[0..num_rotors]);
        return self.result_buffer[0..num_rotors];
    }

    pub fn getMatrixData(self: *VulkanEngine) []u32 {
        return self.mapped_matrix.?[0 .. self.matrix_slots * 1024];
    }

    pub fn getTagsData(self: *VulkanEngine) []u64 {
        return self.mapped_tags.?[0..self.matrix_slots];
    }

    pub fn getRanksData(self: *VulkanEngine) []u8 {
        return self.mapped_rune_ranks.?[0..self.matrix_slots];
    }

    pub fn getLatticeData(self: *VulkanEngine) []u16 {
        return self.mapped_lattice.?[0 .. self.gpu_lattice_size / @sizeOf(u16)];
    }

    pub fn getSigilData(self: *const VulkanEngine) []const u16 {
        const sigil = self.mapped_sigil orelse return &.{};
        return sigil[0 .. self.sigil_capacity / @sizeOf(u16)];
    }

    pub fn getSigilDataMutable(self: *VulkanEngine) []u16 {
        const sigil = self.mapped_sigil orelse return &.{};
        return sigil[0 .. self.sigil_capacity / @sizeOf(u16)];
    }

    pub fn applyNegativeSignal(self: *VulkanEngine, query_hash: u64) void {
        const sigil = self.getSigilDataMutable();
        if (sigil.len < 4) return;
        sigil[0] = 0;
        sigil[1] = NEGATIVE_SIGNAL_SIGIL_OPACITY_PER_MILLE;
        sigil[2] = @truncate(query_hash);
        sigil[3] = @truncate(query_hash >> 16);
    }

    pub fn getPanopticonEdges(self: *const VulkanEngine) []const u32 {
        const edges = self.mapped_edges orelse return &.{};
        return edges[0 .. @as(usize, self.matrix_slots) * 16];
    }

    pub fn getPanopticonEdgesMutable(self: *VulkanEngine) []u32 {
        const edges = self.mapped_edges orelse return &.{};
        return edges[0 .. @as(usize, self.matrix_slots) * 16];
    }

    pub fn bindHostState(self: *VulkanEngine, host_matrix: []u32, host_tags: []u64, host_ranks: []u8, host_lattice: []u16) void {
        self.host_matrix = host_matrix;
        self.host_tags = host_tags;
        self.host_ranks = host_ranks;
        self.host_lattice = host_lattice;

        if (self.mapped_rune_ranks) |dst| {
            const len = @min(host_ranks.len, self.matrix_slots);
            if (@intFromPtr(dst) != @intFromPtr(host_ranks.ptr)) {
                @memcpy(dst[0..len], host_ranks[0..len]);
            }
        }

        if (self.mapped_matrix) |dst| {
            const len = @min(host_matrix.len, self.matrix_slots * 1024);
            if (@intFromPtr(dst) != @intFromPtr(host_matrix.ptr)) {
                ghostCopy(u32, dst[0..len], host_matrix[0..len]);
            }
        }
        if (self.mapped_tags) |dst| {
            const len = @min(host_tags.len, self.matrix_slots);
            if (@intFromPtr(dst) != @intFromPtr(host_tags.ptr)) {
                ghostCopy(u64, dst[0..len], host_tags[0..len]);
            }
        }
        if (self.mapped_lattice) |dst| {
            const len = @min(host_lattice.len, self.gpu_lattice_size / @sizeOf(u16));
            if (@intFromPtr(dst) != @intFromPtr(host_lattice.ptr)) {
                ghostCopy(u16, dst[0..len], host_lattice[0..len]);
            }
        }
        self.refreshLockMaskFromControl();
    }

    fn refreshLockMaskFromControl(self: *VulkanEngine) void {
        const mask = self.mapped_lock_mask orelse return;
        @memset(std.mem.sliceAsBytes(mask[0..self.lock_mask_words]), 0);
        const control = sigil_runtime.getActiveControl() orelse return;
        control.fillLockedSlotMask(mask[0..self.lock_mask_words], self.matrix_slots);
    }

    pub fn etch(self: *VulkanEngine, total_batch: u32, num_streams: u32, rotors: []const u64, chars: []const u32, indices: []const u32) !void {
        beginGpuSubmit(self);
        defer endGpuSubmit(self);

        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        self.refreshLockMaskFromControl();
        const f = try self.acquireFrameSlot();
        ghostCopy(u64, self.mapped_rotors[f].?[0..rotors.len], rotors);
        ghostCopy(u32, self.mapped_chars[f].?[0..chars.len], chars);
        ghostCopy(u32, self.mapped_index[f].?[0..indices.len], indices);

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        const wg_size = @min(1024, self.max_workgroup_invocations);
        const num_workgroups = (total_batch + (wg_size - 1)) / wg_size;
        const pc = [_]u32{ total_batch, num_streams, self.matrix_slots - 1, self.lattice_quarter };

        self.mapped_config[f].?.* = .{ .rotor_stride = ROTOR_STRIDE, .rotor_offset = 16, .batch_size = total_batch };

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.lattice_pipeline);
        self.vk_ctx.vkCmdBindDescriptorSets.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[f], 0, null);
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], num_workgroups, 1, 1);

        var barrier = std.mem.zeroes(vk.VkMemoryBarrier);
        barrier.sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT;
        barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT | vk.VK_ACCESS_SHADER_WRITE_BIT;
        self.vk_ctx.vkCmdPipelineBarrier.?(self.command_buffers[f], vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);

        self.vk_ctx.vkCmdBindPipeline.?(self.command_buffers[f], vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.etch_pipeline);
        self.vk_ctx.vkCmdPushConstants.?(self.command_buffers[f], self.pipeline_layout, vk.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        self.vk_ctx.vkCmdDispatch.?(self.command_buffers[f], num_workgroups, 1, 1);

        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        self.advanceFrameSlot();
    }

    fn transferLatticeToHostWithTimeout(self: *VulkanEngine, host_lattice: []u16, timeout_ns: u64) !void {
        const copy_bytes = @min(self.gpu_lattice_size, host_lattice.len * @sizeOf(u16));
        if (copy_bytes == 0) return;

        for (0..FRAME_COUNT) |i| try self.waitForHardwareInterruptWithTimeout(i, timeout_ns);

        var staging_buffer: vk.VkBuffer = null;
        var staging_memory: vk.VkDeviceMemory = null;
        const staging_ptr = try self.createBuffer(
            copy_bytes,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        ) orelse return error.VulkanError;
        defer self.destroyBuffer(&staging_buffer, &staging_memory, staging_ptr);

        const f = self.frame_idx;
        try self.recycleHardwareFenceWithTimeout(f, timeout_ns);

        var beginInfo = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        beginInfo.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(self.vk_ctx.vkBeginCommandBuffer.?(self.command_buffers[f], &beginInfo));

        var region = std.mem.zeroes(vk.VkBufferCopy);
        region.size = copy_bytes;
        self.vk_ctx.vkCmdCopyBuffer.?(self.command_buffers[f], self.lattice_buffer, staging_buffer, 1, &region);
        try check(self.vk_ctx.vkEndCommandBuffer.?(self.command_buffers[f]));

        var submitInfo = std.mem.zeroes(vk.VkSubmitInfo);
        submitInfo.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.command_buffers[f];
        try check(self.vk_ctx.vkQueueSubmit.?(self.queue, 1, &submitInfo, self.fences[f]));
        try self.waitForHardwareInterruptWithTimeout(f, timeout_ns);

        const src: [*]const u16 = @ptrCast(@alignCast(staging_ptr));
        const word_count = copy_bytes / @sizeOf(u16);
        @memcpy(host_lattice[0..word_count], src[0..word_count]);
        self.frame_idx = (self.frame_idx + 1) % FRAME_COUNT;
    }

    pub fn transferLattice(self: *VulkanEngine) !void {
        const host_lattice = self.host_lattice orelse return error.HostLatticeNotBound;
        try self.transferLatticeToHostWithTimeout(host_lattice, FENCE_TIMEOUT_NS);
    }

    pub fn syncDeviceToHost(self: *VulkanEngine, host_matrix: []u32, host_tags: []u64, host_ranks: []u8, host_lattice: []u16) !void {
        waitForGpuWorkersDrained(self);
        try waitForAllHardwareInterruptsWithTimeout(self, SHUTDOWN_FENCE_TIMEOUT_NS);
        if (self.mapped_matrix) |src| {
            const len = @min(host_matrix.len, self.matrix_slots * 1024);
            @memcpy(host_matrix[0..len], src[0..len]);
        }
        if (self.mapped_tags) |src| {
            const len = @min(host_tags.len, self.matrix_slots);
            @memcpy(host_tags[0..len], src[0..len]);
        }
        if (self.mapped_rune_ranks) |src| {
            const len = @min(host_ranks.len, self.matrix_slots);
            @memcpy(host_ranks[0..len], src[0..len]);
        }
        self.host_matrix = host_matrix;
        self.host_tags = host_tags;
        self.host_ranks = host_ranks;
        self.host_lattice = host_lattice;
        try self.transferLatticeToHostWithTimeout(host_lattice, SHUTDOWN_FENCE_TIMEOUT_NS);
        if (builtin.os.tag == .linux) {
            try sys.flushMappedSlice(std.mem.sliceAsBytes(host_lattice));
        }
    }

    pub fn ensureSigilCapacity(self: *VulkanEngine, needed: usize) !void {
        if (needed <= self.sigil_capacity) return;
        const target = @min(needed, 128 * 1024 * 1024);
        const aligned = (target + 4095) & ~@as(usize, 4095);
        for (0..FRAME_COUNT) |i| try self.waitForHardwareInterrupt(i);
        self.destroyBuffer(&self.sigil_buffer, &self.sigil_memory, self.mapped_sigil);
        self.mapped_sigil = @ptrCast(@alignCast(try self.createBuffer(aligned, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT, self.matrix_flags, &self.sigil_buffer, &self.sigil_memory) orelse return error.VulkanError));
        self.sigil_capacity = aligned;
        for (0..FRAME_COUNT) |i| self.updateDescriptorSets(@intCast(i));
    }

    pub fn setTier(self: *VulkanEngine, tier_val: u32) void {
        const enum_tier = @as(OperationalTier, @enumFromInt(tier_val));
        self.tier = enum_tier;
        sys.print("[VULKAN] Operational tier set: {s}\n", .{@tagName(enum_tier)});
    }

    pub fn warmRestart(self: *VulkanEngine) !void {
        const h_matrix = self.host_matrix;
        const h_tags = self.host_tags;
        const h_lattice = self.host_lattice;
        const target_device = self.device_index;
        const alloc = self.allocator;
        self.deinit();
        self.* = try VulkanEngine.initForDevice(alloc, target_device);
        if (h_matrix != null and h_tags != null and h_lattice != null) {
            self.bindHostState(h_matrix.?, h_tags.?, h_lattice.?);
        } else {
            self.host_matrix = h_matrix;
            self.host_tags = h_tags;
            self.host_lattice = h_lattice;
        }
        sys.print("[VULKAN] Warm Restart Complete.\n", .{});
    }

    /// Sovereign Hardware Sleep: Halts the CPU thread at 0% utilization until
    /// the GPU PCIe interrupt fires, signaling the frame/batch is complete.
    /// This wait does not reset the fence; callers that plan to reuse the slot
    /// must explicitly recycle it first.
    fn waitForHardwareInterruptWithTimeout(self: *VulkanEngine, f_idx: usize, timeout_ns: u64) !void {
        const wait_res = self.vk_ctx.vkWaitForFences.?(
            self.dev,
            1,
            &self.fences[f_idx],
            vk.VK_TRUE,
            timeout_ns,
        );

        if (wait_res != vk.VK_SUCCESS) {
            sys.print("[FATAL] Vulkan Driver failed to sync PCIe interrupt on frame {d}: {d}\n", .{ f_idx, wait_res });
            return error.HardwareSyncFailed;
        }
    }

    pub fn waitForHardwareInterrupt(self: *VulkanEngine, f_idx: usize) !void {
        try self.waitForHardwareInterruptWithTimeout(f_idx, FENCE_TIMEOUT_NS);
    }

    pub fn pollHardwareInterrupt(self: *VulkanEngine, f_idx: usize) !bool {
        const status = self.vk_ctx.vkGetFenceStatus.?(self.dev, self.fences[f_idx]);
        if (status == vk.VK_SUCCESS) {
            return true;
        } else if (status == vk.VK_NOT_READY) {
            return false;
        } else {
            return error.HardwareSyncFailed;
        }
    }

    fn recycleHardwareFence(self: *VulkanEngine, f_idx: usize) !void {
        try self.waitForHardwareInterrupt(f_idx);
        const reset_res = self.vk_ctx.vkResetFences.?(self.dev, 1, &self.fences[f_idx]);
        if (reset_res != vk.VK_SUCCESS) return error.FenceResetFailed;
    }

    fn recycleHardwareFenceWithTimeout(self: *VulkanEngine, f_idx: usize, timeout_ns: u64) !void {
        try self.waitForHardwareInterruptWithTimeout(f_idx, timeout_ns);
        const reset_res = self.vk_ctx.vkResetFences.?(self.dev, 1, &self.fences[f_idx]);
        if (reset_res != vk.VK_SUCCESS) return error.FenceResetFailed;
    }

    /// Inference-specific fence wait. Like the frame wait above, this leaves the
    /// fence signaled so post-submit waits do not wipe the slot state.
    pub fn waitForInferenceInterrupt(self: *VulkanEngine, lane_idx: usize) !void {
        const wait_res = self.vk_ctx.vkWaitForFences.?(self.dev, 1, &self.inf_fences[lane_idx], vk.VK_TRUE, FENCE_TIMEOUT_NS);
        if (wait_res != vk.VK_SUCCESS) {
            sys.print("[FATAL] Inference fence wait failed on lane {d}: {d}\n", .{ lane_idx, wait_res });
            return error.HardwareSyncFailed;
        }
    }

    fn recycleInferenceFence(self: *VulkanEngine, lane_idx: usize) !void {
        try self.waitForInferenceInterrupt(lane_idx);
        const reset_res = self.vk_ctx.vkResetFences.?(self.dev, 1, &self.inf_fences[lane_idx]);
        if (reset_res != vk.VK_SUCCESS) return error.FenceResetFailed;
    }

    fn acquireFrameSlot(self: *VulkanEngine) !usize {
        const f: usize = self.frame_idx;
        try self.recycleHardwareFence(f);
        return f;
    }

    fn acquireFrameSlotNonBlocking(self: *VulkanEngine) !?usize {
        var attempts: usize = 0;
        while (attempts < FRAME_COUNT) : (attempts += 1) {
            const f: usize = (self.frame_idx + attempts) % FRAME_COUNT;
            const status = self.vk_ctx.vkGetFenceStatus.?(self.dev, self.fences[f]);
            if (status == vk.VK_NOT_READY) continue;
            if (status != vk.VK_SUCCESS) return error.HardwareSyncFailed;
            const reset_res = self.vk_ctx.vkResetFences.?(self.dev, 1, &self.fences[f]);
            if (reset_res != vk.VK_SUCCESS) return error.FenceResetFailed;
            self.frame_idx = @intCast(f);
            return f;
        }
        return null;
    }

    fn advanceFrameSlot(self: *VulkanEngine) void {
        self.frame_idx = (self.frame_idx + 1) % FRAME_COUNT;
    }
};

pub const MultiGPU = struct {
    allocator: std.mem.Allocator,
    engines: []VulkanEngine,
    primary: *VulkanEngine,
    engine_count: u32,
    total_score: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !MultiGPU {
        var ctx = try vl.VulkanCtx.load();
        const boot = try createInstance(&ctx, allocator, "Ghost-Sovereign-Fleet", "Ghost-VSA");
        const instance: vk.VkInstance = boot.instance;
        try ctx.loadInstance(instance);
        defer ctx.vkDestroyInstance.?(instance, null);

        var pdevCount: u32 = 0;
        try check(ctx.vkEnumeratePhysicalDevices.?(instance, &pdevCount, null));
        const pdevs = try allocator.alloc(vk.VkPhysicalDevice, pdevCount);
        defer allocator.free(pdevs);
        try check(ctx.vkEnumeratePhysicalDevices.?(instance, &pdevCount, pdevs.ptr));

        const ranked = try rankPhysicalDevices(&ctx, allocator, pdevs[0..pdevCount]);
        defer allocator.free(ranked);

        var engines = try allocator.alloc(VulkanEngine, ranked.len);
        for (0..ranked.len) |i| engines[i] = try VulkanEngine.initForDevice(allocator, @intCast(i));
        return MultiGPU{ .allocator = allocator, .engines = engines, .primary = &engines[0], .engine_count = @intCast(ranked.len) };
    }

    pub fn deinit(self: *MultiGPU) void {
        for (self.engines) |*e| e.deinit();
        self.allocator.free(self.engines);
    }
};

var global_fleet: ?MultiGPU = null;
var global_instance: ?*VulkanEngine = null;
threadlocal var thread_engine: ?*VulkanEngine = null;

pub fn setThreadEngine(e: ?*VulkanEngine) void {
    thread_engine = e;
}
pub fn getEngine() ?*VulkanEngine {
    return thread_engine orelse global_instance;
}
pub fn getFleet() ?*MultiGPU {
    return if (global_fleet) |*fleet| fleet else null;
}

pub fn emitNegativeSignal(query: []const u8) NegativeSignalSnapshot {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(query);
    const query_hash = hasher.final();
    const count = global_negative_signal_count.fetchAdd(1, .acq_rel) + 1;
    global_negative_signal_hash.store(query_hash, .release);
    if (getEngine()) |engine| engine.applyNegativeSignal(query_hash);
    return .{
        .active = true,
        .count = count,
        .last_query_hash = query_hash,
    };
}

pub fn getNegativeSignalSnapshot() NegativeSignalSnapshot {
    const count = global_negative_signal_count.load(.acquire);
    return .{
        .active = count > 0,
        .count = count,
        .last_query_hash = global_negative_signal_hash.load(.acquire),
    };
}

pub fn initRuntime(allocator: std.mem.Allocator) !*VulkanEngine {
    if (config.FLEET_MODE) {
        global_fleet = initFleet(allocator) catch |err| {
            if (runtimeLogsEnabled()) std.debug.print("[MULTI-GPU] Fleet init failed ({any}), falling back to single engine\n", .{err});
            global_instance = try VulkanEngine.init(allocator);
            return global_instance.?;
        };
        global_instance = global_fleet.?.primary;
        return global_instance.?;
    }

    global_instance = try VulkanEngine.init(allocator);
    return global_instance.?;
}

pub fn initFleet(allocator: std.mem.Allocator) !MultiGPU {
    return MultiGPU.init(allocator);
}

pub fn deinitRuntime() void {
    if (global_fleet) |*f| f.deinit();
    if (global_fleet == null and global_instance != null) global_instance.?.deinit();
    global_fleet = null;
    global_instance = null;
    thread_engine = null;
}

test "ghost index pruning skips far simhash blocks" {
    const allocator = std.testing.allocator;
    const text = "silicon computers use semiconductor logic. vulkan pipelines are unrelated to the bakery ledger.";
    const blocks = try buildGhostIndex(allocator, text);
    defer allocator.free(blocks);
    try std.testing.expect(blocks.len >= 1);

    const query_hash = blocks[0].simhash;
    const scan = try allocator.alloc(bool, blocks.len);
    defer allocator.free(scan);
    const summary = try pruneGhostIndexBlocks(query_hash, blocks, scan);
    try std.testing.expectEqual(blocks.len, summary.scanned_blocks);
    try std.testing.expect(summary.retained_blocks >= 1);
    try std.testing.expect(!shouldSkipGhostIndexBlock(query_hash, blocks[0]));
    try std.testing.expect(ghostIndexNearnessPerMille(0, std.math.maxInt(u64)) < GHOST_INDEX_SKIP_THRESHOLD_PER_MILLE);
}

test "Gemma Vulkan forward recorder rejects missing pipelines before command recording" {
    var engine: VulkanEngine = undefined;
    engine.gemma_rune_embed_pipeline = null;
    engine.gemma_matmul_q4k_pipeline = null;
    engine.gemma_matmul_q8_0_pipeline = null;
    engine.gemma_rms_norm_pipeline = null;
    engine.gemma_swiglu_pipeline = null;
    engine.gemma_attention_pipeline = null;
    engine.gemma_rune_project_pipeline = null;
    try std.testing.expect(!engine.gemmaPipelinesReady());
    try std.testing.expectError(error.GemmaPipelinesUnavailable, engine.recordGemmaForwardSchedule(null, .{}));
}

test "SPO vectorization distinguishes directed inverse relations" {
    const query = extractSpoVector("Does the CPU control the RAM?");
    const direct = extractSpoVector("The CPU controls the RAM.");
    const inverse = extractSpoVector("The RAM controls the CPU.");

    try std.testing.expect(query.valid);
    try std.testing.expect(direct.valid);
    try std.testing.expect(inverse.valid);
    try std.testing.expect(query.directMatch(direct));
    try std.testing.expect(query.inverseMatch(inverse));
    try std.testing.expectEqual(@as(u16, 1000), relationScorePerMille(query, direct));
    try std.testing.expect(relationPenaltyPerMille(query, inverse) >= 800);
}
