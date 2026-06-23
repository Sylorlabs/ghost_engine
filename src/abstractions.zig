const std = @import("std");
const config = @import("config.zig");
const ghost_state = @import("ghost_state.zig");
const knowledge_pack_store = @import("knowledge_pack_store.zig");
const shards = @import("shards.zig");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");

pub const MAX_SOURCE_SPECS: usize = 8;
pub const MAX_EXAMPLES: usize = 12;
pub const MAX_PATTERNS: usize = 16;
pub const MAX_TOKENS: usize = 24;
pub const MAX_REGION_LINES: u32 = 96;
pub const MAX_REGION_BYTES: usize = 16 * 1024;
pub const MAX_CATALOG_BYTES: usize = 64 * 1024 * 1024;

const MAGIC_LINE = "GABS1";
const REUSE_MAGIC_LINE = "GABR1";
const CODE_INTEL_FILE_REL = "code_intel/last_result.json";
const CODE_INTEL_CONTEXT_RADIUS: u32 = 2;
const MIN_COMMIT_RESONANCE: u16 = 560;
const MAX_PARENT_CHAIN_DEPTH: usize = 4;
const MAX_SCORE: u16 = 1000;
const MAX_PROVENANCE_ENTRIES: usize = 16;
const MAX_PRUNE_RESULTS: usize = 32;
const REUSE_LIVE_FILE_NAME = "reuse.gabr";
const REUSE_STAGED_FILE_NAME = "reuse_staged.gabr";
const REUSE_SLOT_FILE_NAME = "reuse.gabr";
const STATE_MAGIC_LINE = "GABS2";
const STATE_FILE_NAME = "lineage.gabs";
const STATE_SLOT_FILE_NAME = "lineage.gabs";
pub const COMMIT_COMMAND_NAME = "/commit_abstractions";
pub const REUSE_COMMAND_NAME = "/reuse_abstractions";
pub const MERGE_COMMAND_NAME = "/merge_abstractions";
pub const PRUNE_COMMAND_NAME = "/prune_abstractions";

pub const Tier = enum(u8) {
    pattern,
    convention,
    logic,
    contract,
};

pub const Category = enum(u8) {
    structural,
    procedural,
    relational,
    boundary,
    state,
    invariant,
};

pub const Family = enum(u8) {
    distilled,
    parser_sketch,
    grounding_schema,
    route_suppressor,
    claim_template,
    intent_interpretation,
    action_surface,
    verifier_pattern,
};

pub const SelectionMode = enum(u8) {
    direct,
    promoted,
    fallback,
};

pub const ReuseDecision = enum(u8) {
    none,
    adopt,
    reject,
    promote,
};

pub const ReuseResolution = enum(u8) {
    local,
    imported,
    adopted,
    local_override,
    rejected,
    conflict_refused,
};

pub const ConflictKind = enum(u8) {
    none,
    incompatible,
    explicit_reject,
};

pub const TrustClass = enum(u8) {
    exploratory,
    project,
    promoted,
    core,
};

pub const DecayState = enum(u8) {
    active,
    stale,
    prunable,
    protected,
};

pub const MergeMode = enum(u8) {
    adopt,
    promote,
};

pub const LineageOperation = enum(u8) {
    distilled,
    reuse_adopt,
    reuse_reject,
    reuse_promote,
    merge_adopt,
    merge_promote,
    prune_mark_stale,
    prune_mark_prunable,
    prune_refresh,
    prune_collect,
    reinforce_observe,
    reinforce_promote,
    reinforce_demote,
};

pub const ReinforcementOutcome = enum(u8) {
    success,
    failure,
    ambiguous,
    contradicted,
};

pub const ReinforcementEvent = struct {
    family: Family,
    key: []const u8,
    case_id: []const u8,
    tier: Tier = .pattern,
    category: Category,
    outcome: ReinforcementOutcome,
    source_specs: []const []const u8 = &.{},
    tokens: []const []const u8 = &.{},
    patterns: []const []const u8 = &.{},
    detail: ?[]const u8 = null,
};

pub const ReinforcementApplyOptions = struct {
    max_events: usize = 8,
    max_new_records: usize = 4,
};

pub const FamilyLookupOptions = struct {
    family: Family,
    rel_paths: []const []const u8 = &.{},
    tokens: []const []const u8 = &.{},
    patterns: []const []const u8 = &.{},
    max_items: usize = 4,
    include_staged: bool = false,
    pack_routing_stage: PackRoutingStage = .family,
    pack_routing: ?*PackRoutingCollector = null,
    pack_routing_caps: PackRoutingCaps = .{},
    pack_conflict_policy: PackConflictPolicy = .{},
};

const ReinforcementStats = struct {
    success_count: u32 = 0,
    failure_count: u32 = 0,
    ambiguity_count: u32 = 0,
    contradiction_count: u32 = 0,
    independent_case_count: u32 = 0,
};

pub const LookupOptions = struct {
    rel_paths: []const []const u8,
    tokens: []const []const u8 = &.{},
    patterns: []const []const u8 = &.{},
    max_items: usize = 4,
    include_staged: bool = false,
    prefer_higher_tiers: bool = true,
    category_hint: ?Category = null,
    pack_routing_stage: PackRoutingStage = .support,
    pack_routing: ?*PackRoutingCollector = null,
    pack_routing_caps: PackRoutingCaps = .{},
    pack_conflict_policy: PackConflictPolicy = .{},
};

pub const GroundingOptions = struct {
    rel_paths: []const []const u8 = &.{},
    tokens: []const []const u8,
    patterns: []const []const u8 = &.{},
    max_items: usize = 4,
    include_staged: bool = false,
    prefer_higher_tiers: bool = true,
    category_hint: ?Category = null,
    pack_routing_stage: PackRoutingStage = .grounding,
    pack_routing: ?*PackRoutingCollector = null,
    pack_routing_caps: PackRoutingCaps = .{},
    pack_conflict_policy: PackConflictPolicy = .{},
};

pub const PackRoutingStage = enum {
    support,
    grounding,
    reverse_grounding,
    family,
};

pub const PackConflictCategory = enum {
    none,
    same_concept_incompatible,
    same_anchor_competing,
    trust_mismatch,
    stale_pack,
    incompatible_pack_family,
};

pub const PackCompetitionPolicy = enum {
    refuse_all_competing,
    prefer_higher_trust_only,
    deterministic_winner,
};

pub const PackConflictPolicy = struct {
    competition: PackCompetitionPolicy = .refuse_all_competing,
};

pub const PackRoutingStatus = enum {
    activated,
    skipped,
    suppressed,
    conflict_refused,
    stale_blocked,
    trust_blocked,
};

pub const PackRoutingCaps = struct {
    max_considered_per_query: usize = 6,
    max_activated_per_query: usize = 3,
    max_candidate_surfaces_per_query: usize = 6,
};

pub const PackRoutingTrace = struct {
    allocator: std.mem.Allocator,
    stage: PackRoutingStage,
    pack_id: []u8,
    pack_version: []u8,
    owner_id: []u8,
    status: PackRoutingStatus,
    reason: []u8,
    policy: PackConflictPolicy = .{},
    conflict_category: PackConflictCategory = .none,
    trust_class: TrustClass = .exploratory,
    freshness_state: knowledge_pack_store.PackFreshness = .active,
    score: u32 = 0,
    support_potential_upper_bound: u16 = 0,
    call_id: u16 = 0,
    considered_rank: u16 = 0,
    activation_rank: u16 = 0,
    path_hits: u16 = 0,
    symbol_hits: u16 = 0,
    domain_hits: u16 = 0,
    file_family_hits: u16 = 0,
    candidate_surfaces: u16 = 0,
    suppressed_candidates: u16 = 0,
    conflict_refused: bool = false,
    local_truth_won: bool = false,

    pub fn deinit(self: *PackRoutingTrace) void {
        self.allocator.free(self.pack_id);
        self.allocator.free(self.pack_version);
        self.allocator.free(self.owner_id);
        self.allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const PackRoutingCollector = struct {
    allocator: std.mem.Allocator,
    traces: std.ArrayList(PackRoutingTrace),
    next_call_id: u16 = 1,

    pub fn init(allocator: std.mem.Allocator) PackRoutingCollector {
        return .{
            .allocator = allocator,
            .traces = std.ArrayList(PackRoutingTrace).init(allocator),
        };
    }

    pub fn deinit(self: *PackRoutingCollector) void {
        for (self.traces.items) |*trace| trace.deinit();
        self.traces.deinit();
        self.* = undefined;
    }

    pub fn toOwnedSlice(self: *PackRoutingCollector) ![]PackRoutingTrace {
        return self.traces.toOwnedSlice();
    }

    fn append(self: *PackRoutingCollector, trace: PackRoutingTrace) !void {
        try self.traces.append(trace);
    }

    pub fn beginCall(self: *PackRoutingCollector) u16 {
        const call_id = self.next_call_id;
        self.next_call_id +%= 1;
        if (self.next_call_id == 0) self.next_call_id = 1;
        return call_id;
    }

    pub fn noteCandidateSurfaces(
        self: *PackRoutingCollector,
        stage: PackRoutingStage,
        owner_id: []const u8,
        kept: usize,
        suppressed: usize,
    ) void {
        var idx = self.traces.items.len;
        while (idx > 0) {
            idx -= 1;
            const trace = &self.traces.items[idx];
            if (trace.stage != stage) continue;
            if (!std.mem.eql(u8, trace.owner_id, owner_id)) continue;
            trace.candidate_surfaces = @intCast(@min(kept, std.math.maxInt(u16)));
            trace.suppressed_candidates = @intCast(@min(suppressed, std.math.maxInt(u16)));
            return;
        }
    }

    pub fn noteConflict(
        self: *PackRoutingCollector,
        stage: PackRoutingStage,
        owner_id: []const u8,
        status: PackRoutingStatus,
        category: PackConflictCategory,
        local_truth_won: bool,
    ) void {
        var idx = self.traces.items.len;
        while (idx > 0) {
            idx -= 1;
            const trace = &self.traces.items[idx];
            if (trace.stage != stage) continue;
            if (!std.mem.eql(u8, trace.owner_id, owner_id)) continue;
            trace.status = status;
            trace.conflict_refused = trace.conflict_refused or status == .conflict_refused;
            trace.conflict_category = category;
            trace.local_truth_won = trace.local_truth_won or local_truth_won;
        }
    }
};

pub const Record = struct {
    allocator: std.mem.Allocator,
    concept_id: []u8,
    family: Family = .distilled,
    tier: Tier = .pattern,
    category: Category = .structural,
    parent_concept_id: ?[]u8 = null,
    example_count: u32,
    threshold_examples: u32,
    retained_token_count: u32,
    retained_pattern_count: u32,
    average_resonance: u16,
    min_resonance: u16,
    quality_score: u16 = 0,
    confidence_score: u16 = 0,
    reuse_score: u16 = 0,
    support_score: u16 = 0,
    promotion_ready: bool = false,
    consensus_hash: u64,
    valid_to_commit: bool,
    vector: vsa.HyperVector,
    lineage_id: []u8 = &.{},
    lineage_version: u32 = 0,
    trust_class: TrustClass = .exploratory,
    decay_state: DecayState = .active,
    success_count: u32 = 0,
    failure_count: u32 = 0,
    ambiguity_count: u32 = 0,
    contradiction_count: u32 = 0,
    independent_case_count: u32 = 0,
    first_revision: u32 = 0,
    last_revision: u32 = 0,
    last_review_revision: u32 = 0,
    sources: [][]u8 = &.{},
    tokens: [][]u8 = &.{},
    patterns: [][]u8 = &.{},
    schema_entity_signals: [][]u8 = &.{},
    schema_relation_signals: [][]u8 = &.{},
    obligation_signals: [][]u8 = &.{},
    anchor_signals: [][]u8 = &.{},
    verifier_hint_signals: [][]u8 = &.{},
    schema_signals: [][]u8 = &.{},
    provenance: [][]u8 = &.{},

    pub fn deinit(self: *Record) void {
        self.allocator.free(self.concept_id);
        if (self.parent_concept_id) |parent_concept_id| self.allocator.free(parent_concept_id);
        if (self.lineage_id.len > 0) self.allocator.free(self.lineage_id);
        for (self.sources) |item| self.allocator.free(item);
        for (self.tokens) |item| self.allocator.free(item);
        for (self.patterns) |item| self.allocator.free(item);
        for (self.schema_entity_signals) |item| self.allocator.free(item);
        for (self.schema_relation_signals) |item| self.allocator.free(item);
        for (self.obligation_signals) |item| self.allocator.free(item);
        for (self.anchor_signals) |item| self.allocator.free(item);
        for (self.verifier_hint_signals) |item| self.allocator.free(item);
        for (self.schema_signals) |item| self.allocator.free(item);
        for (self.provenance) |item| self.allocator.free(item);
        self.allocator.free(self.sources);
        self.allocator.free(self.tokens);
        self.allocator.free(self.patterns);
        self.allocator.free(self.schema_entity_signals);
        self.allocator.free(self.schema_relation_signals);
        self.allocator.free(self.obligation_signals);
        self.allocator.free(self.anchor_signals);
        self.allocator.free(self.verifier_hint_signals);
        self.allocator.free(self.schema_signals);
        if (self.provenance.len > 0) self.allocator.free(self.provenance);
        self.* = undefined;
    }

    pub fn clone(self: *const Record, allocator: std.mem.Allocator) !Record {
        var out = Record{
            .allocator = allocator,
            .concept_id = try allocator.dupe(u8, self.concept_id),
            .family = self.family,
            .tier = self.tier,
            .category = self.category,
            .parent_concept_id = if (self.parent_concept_id) |parent_concept_id| try allocator.dupe(u8, parent_concept_id) else null,
            .example_count = self.example_count,
            .threshold_examples = self.threshold_examples,
            .retained_token_count = self.retained_token_count,
            .retained_pattern_count = self.retained_pattern_count,
            .average_resonance = self.average_resonance,
            .min_resonance = self.min_resonance,
            .quality_score = self.quality_score,
            .confidence_score = self.confidence_score,
            .reuse_score = self.reuse_score,
            .support_score = self.support_score,
            .promotion_ready = self.promotion_ready,
            .consensus_hash = self.consensus_hash,
            .valid_to_commit = self.valid_to_commit,
            .vector = self.vector,
            .lineage_id = if (self.lineage_id.len > 0) try allocator.dupe(u8, self.lineage_id) else &.{},
            .lineage_version = self.lineage_version,
            .trust_class = self.trust_class,
            .decay_state = self.decay_state,
            .success_count = self.success_count,
            .failure_count = self.failure_count,
            .ambiguity_count = self.ambiguity_count,
            .contradiction_count = self.contradiction_count,
            .independent_case_count = self.independent_case_count,
            .first_revision = self.first_revision,
            .last_revision = self.last_revision,
            .last_review_revision = self.last_review_revision,
            .sources = try cloneStringSlice(allocator, self.sources),
            .tokens = try cloneStringSlice(allocator, self.tokens),
            .patterns = try cloneStringSlice(allocator, self.patterns),
            .schema_entity_signals = try cloneStringSlice(allocator, self.schema_entity_signals),
            .schema_relation_signals = try cloneStringSlice(allocator, self.schema_relation_signals),
            .obligation_signals = try cloneStringSlice(allocator, self.obligation_signals),
            .anchor_signals = try cloneStringSlice(allocator, self.anchor_signals),
            .verifier_hint_signals = try cloneStringSlice(allocator, self.verifier_hint_signals),
            .schema_signals = try cloneStringSlice(allocator, self.schema_signals),
            .provenance = try cloneStringSlice(allocator, self.provenance),
        };
        errdefer out.deinit();
        return out;
    }

    pub fn validityExplanation(self: *const Record, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{d}/{d} examples agreed on {d} shared patterns and {d} shared tokens; min resonance {d}.",
            .{
                self.threshold_examples,
                self.example_count,
                self.retained_pattern_count,
                self.retained_token_count,
                self.min_resonance,
            },
        );
    }
};

pub const SupportReference = struct {
    concept_id: []u8,
    family: Family = .distilled,
    source_spec: []u8,
    staged: bool,
    tier: Tier,
    category: Category,
    trust_class: TrustClass = .exploratory,
    decay_state: DecayState = .active,
    owner_kind: shards.Kind,
    owner_id: []u8,
    lineage_id: []u8 = &.{},
    lineage_version: u32 = 0,
    parent_concept_id: ?[]u8 = null,
    supporting_concept_id: ?[]u8 = null,
    quality_score: u16 = 0,
    confidence_score: u16 = 0,
    lookup_score: u16 = 0,
    direct_support_count: u16 = 0,
    lineage_support_count: u16 = 0,
    token_support_count: u16 = 0,
    pattern_support_count: u16 = 0,
    structured_support_count: u16 = 0,
    source_support_count: u16 = 0,
    selection_mode: SelectionMode = .direct,
    consensus_hash: u64 = 0,
    usable: bool = true,
    reuse_decision: ReuseDecision = .none,
    resolution: ReuseResolution = .local,
    conflict_kind: ConflictKind = .none,
    conflict_concept_id: ?[]u8 = null,
    conflict_owner_kind: ?shards.Kind = null,
    conflict_owner_id: ?[]u8 = null,
    pack_outcome: PackRoutingStatus = .skipped,
    pack_conflict_category: PackConflictCategory = .none,
};

pub const ReverseLinkReference = struct {
    concept_id: []u8,
    family: Family = .distilled,
    matched_source_spec: []u8,
    symbolic_source_spec: []u8,
    staged: bool,
    tier: Tier,
    category: Category,
    trust_class: TrustClass = .exploratory,
    decay_state: DecayState = .active,
    owner_kind: shards.Kind,
    owner_id: []u8,
    lineage_id: []u8 = &.{},
    lineage_version: u32 = 0,
    parent_concept_id: ?[]u8 = null,
    supporting_concept_id: ?[]u8 = null,
    quality_score: u16 = 0,
    confidence_score: u16 = 0,
    lookup_score: u16 = 0,
    direct_support_count: u16 = 0,
    lineage_support_count: u16 = 0,
    token_support_count: u16 = 0,
    pattern_support_count: u16 = 0,
    structured_support_count: u16 = 0,
    source_support_count: u16 = 0,
    selection_mode: SelectionMode = .direct,
    consensus_hash: u64 = 0,
    usable: bool = true,
    resolution: ReuseResolution = .local,
    conflict_kind: ConflictKind = .none,
    conflict_concept_id: ?[]u8 = null,
    conflict_owner_kind: ?shards.Kind = null,
    conflict_owner_id: ?[]u8 = null,
    pack_outcome: PackRoutingStatus = .skipped,
    pack_conflict_category: PackConflictCategory = .none,
};

pub const ReuseEntry = struct {
    allocator: std.mem.Allocator,
    decision: ReuseDecision,
    source_kind: shards.Kind,
    source_id: []u8,
    source_concept_id: []u8,
    source_consensus_hash: u64,
    source_lineage_id: []u8,
    source_lineage_version: u32 = 0,
    source_trust_class: TrustClass = .exploratory,
    local_concept_id: ?[]u8 = null,
    local_consensus_hash: u64 = 0,
    local_lineage_id: ?[]u8 = null,
    local_lineage_version: u32 = 0,
    local_trust_class: ?TrustClass = null,

    pub fn deinit(self: *ReuseEntry) void {
        self.allocator.free(self.source_id);
        self.allocator.free(self.source_concept_id);
        self.allocator.free(self.source_lineage_id);
        if (self.local_concept_id) |local_concept_id| self.allocator.free(local_concept_id);
        if (self.local_lineage_id) |local_lineage_id| self.allocator.free(local_lineage_id);
        self.* = undefined;
    }

    pub fn clone(self: *const ReuseEntry, allocator: std.mem.Allocator) !ReuseEntry {
        return .{
            .allocator = allocator,
            .decision = self.decision,
            .source_kind = self.source_kind,
            .source_id = try allocator.dupe(u8, self.source_id),
            .source_concept_id = try allocator.dupe(u8, self.source_concept_id),
            .source_consensus_hash = self.source_consensus_hash,
            .source_lineage_id = try allocator.dupe(u8, self.source_lineage_id),
            .source_lineage_version = self.source_lineage_version,
            .source_trust_class = self.source_trust_class,
            .local_concept_id = if (self.local_concept_id) |local_concept_id| try allocator.dupe(u8, local_concept_id) else null,
            .local_consensus_hash = self.local_consensus_hash,
            .local_lineage_id = if (self.local_lineage_id) |local_lineage_id| try allocator.dupe(u8, local_lineage_id) else null,
            .local_lineage_version = self.local_lineage_version,
            .local_trust_class = self.local_trust_class,
        };
    }
};

pub const ReuseStageResult = struct {
    allocator: std.mem.Allocator,
    entry: ReuseEntry,
    source_tier: Tier,
    source_category: Category,
    local_tier: ?Tier = null,
    local_category: ?Category = null,

    pub fn deinit(self: *ReuseStageResult) void {
        self.entry.deinit();
        self.* = undefined;
    }
};

pub const MergeStageResult = struct {
    allocator: std.mem.Allocator,
    mode: MergeMode,
    source_kind: shards.Kind,
    source_id: []u8,
    source_concept_id: []u8,
    source_lineage_id: []u8,
    source_lineage_version: u32,
    source_trust_class: TrustClass,
    destination_kind: shards.Kind,
    destination_id: []u8,
    destination_concept_id: []u8,
    destination_lineage_id: []u8,
    destination_lineage_version: u32,
    destination_trust_class: TrustClass,
    staged_conflict: bool = false,

    pub fn deinit(self: *MergeStageResult) void {
        self.allocator.free(self.source_id);
        self.allocator.free(self.source_concept_id);
        self.allocator.free(self.source_lineage_id);
        self.allocator.free(self.destination_id);
        self.allocator.free(self.destination_concept_id);
        self.allocator.free(self.destination_lineage_id);
        self.* = undefined;
    }
};

pub const PruneMode = enum(u8) {
    mark_stale,
    mark_prunable,
    refresh,
    collect,
};

pub const ExportState = enum {
    live,
    staged,
};

pub const PruneStageResult = struct {
    allocator: std.mem.Allocator,
    mode: PruneMode,
    affected_concepts: [][]u8,
    next_state: DecayState,

    pub fn deinit(self: *PruneStageResult) void {
        for (self.affected_concepts) |item| self.allocator.free(item);
        self.allocator.free(self.affected_concepts);
        self.* = undefined;
    }
};

const CatalogState = struct {
    revision: u32 = 0,
    default_trust: TrustClass = .project,
    last_merge_revision: u32 = 0,
    last_prune_revision: u32 = 0,
};

const Example = struct {
    allocator: std.mem.Allocator,
    source_spec: []u8,
    tokens: [][]u8,
    patterns: [][]u8,

    fn deinit(self: *Example) void {
        self.allocator.free(self.source_spec);
        for (self.tokens) |token| self.allocator.free(token);
        for (self.patterns) |pattern| self.allocator.free(pattern);
        self.allocator.free(self.tokens);
        self.allocator.free(self.patterns);
        self.* = undefined;
    }
};

const CountedText = struct {
    text: []u8,
    count: u32,
};

const RegionSpec = struct {
    rel_path: []u8,
    start_line: u32,
    end_line: u32,

    fn deinit(self: *RegionSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.rel_path);
        self.* = undefined;
    }
};

const MountedPackCatalog = struct {
    allocator: std.mem.Allocator,
    owner_id: []u8,
    records: []Record,

    fn deinit(self: *MountedPackCatalog) void {
        self.allocator.free(self.owner_id);
        for (self.records) |*record| record.deinit();
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

const PackRequestFamily = enum {
    code,
    docs,
    config,
    tests,
    logs,
    other,
};

const MountedPackCandidate = struct {
    mount_index: usize,
    score: u32 = 0,
    path_hits: u16 = 0,
    symbol_hits: u16 = 0,
    domain_hits: u16 = 0,
    file_family_hits: u16 = 0,
    trust_class: TrustClass = .exploratory,
    freshness_state: knowledge_pack_store.PackFreshness = .active,
    eligible: bool = false,
    compatible: bool = true,
    conflict_category: PackConflictCategory = .none,
    reason: []const u8 = "",
};

const RoutedMountLoad = struct {
    mounts: []knowledge_pack_store.ResolvedMount,
    traces: []PackRoutingTrace,

    fn deinit(self: *RoutedMountLoad, allocator: std.mem.Allocator) void {
        for (self.mounts) |*mount| mount.deinit();
        allocator.free(self.mounts);
        for (self.traces) |*trace| trace.deinit();
        allocator.free(self.traces);
        self.* = undefined;
    }
};

pub const LookupProfile = struct {
    pack_mount_resolve_ms: u64 = 0,
    pack_manifest_preview_load_ms: u64 = 0,
    pack_routing_ms: u64 = 0,
    pack_catalog_load_ms: u64 = 0,
};

const MAX_CATALOG_CACHE_ENTRIES: usize = 16;

const CatalogCacheEntry = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,
    size_bytes: u64,
    mtime_ns: i128,
    records: []Record,

    fn deinit(self: *CatalogCacheEntry) void {
        self.allocator.free(self.abs_path);
        for (self.records) |*record| record.deinit();
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

var lookup_profile: LookupProfile = .{};
var catalog_cache: ?std.ArrayList(CatalogCacheEntry) = null;

pub fn resetLookupProfile() void {
    lookup_profile = .{};
}

pub fn readLookupProfile() LookupProfile {
    return lookup_profile;
}

fn catalogCache() *std.ArrayList(CatalogCacheEntry) {
    if (catalog_cache == null) {
        catalog_cache = std.ArrayList(CatalogCacheEntry).init(std.heap.page_allocator);
    }
    return &catalog_cache.?;
}

fn cloneCatalogRecords(allocator: std.mem.Allocator, records: []const Record) !std.ArrayList(Record) {
    var out = std.ArrayList(Record).init(allocator);
    errdefer deinitCatalog(&out);
    try out.ensureTotalCapacity(records.len);
    for (records) |*record| {
        try out.append(try record.clone(allocator));
    }
    return out;
}

pub fn isCommand(script: []const u8) bool {
    const trimmed = std.mem.trim(u8, script, " \r\n\t");
    return std.mem.startsWith(u8, trimmed, COMMIT_COMMAND_NAME) or
        std.mem.startsWith(u8, trimmed, REUSE_COMMAND_NAME) or
        std.mem.startsWith(u8, trimmed, MERGE_COMMAND_NAME) or
        std.mem.startsWith(u8, trimmed, PRUNE_COMMAND_NAME);
}

pub fn tierName(tier: Tier) []const u8 {
    return switch (tier) {
        .pattern => "pattern",
        .convention => "convention",
        .logic => "logic",
        .contract => "contract",
    };
}

pub fn categoryName(category: Category) []const u8 {
    return switch (category) {
        .structural => "structural",
        .procedural => "procedural",
        .relational => "relational",
        .boundary => "boundary",
        .state => "state",
        .invariant => "invariant",
    };
}

pub fn familyName(family: Family) []const u8 {
    return switch (family) {
        .distilled => "distilled",
        .parser_sketch => "parser_sketch",
        .grounding_schema => "grounding_schema",
        .route_suppressor => "route_suppressor",
        .claim_template => "claim_template",
        .intent_interpretation => "intent_interpretation",
        .action_surface => "action_surface",
        .verifier_pattern => "verifier_pattern",
    };
}

pub fn selectionModeName(mode: SelectionMode) []const u8 {
    return switch (mode) {
        .direct => "direct",
        .promoted => "promoted",
        .fallback => "fallback",
    };
}

pub fn reuseDecisionName(decision: ReuseDecision) []const u8 {
    return switch (decision) {
        .none => "none",
        .adopt => "adopt",
        .reject => "reject",
        .promote => "promote",
    };
}

pub fn reuseResolutionName(resolution: ReuseResolution) []const u8 {
    return switch (resolution) {
        .local => "local",
        .imported => "imported",
        .adopted => "adopted",
        .local_override => "local_override",
        .rejected => "rejected",
        .conflict_refused => "conflict_refused",
    };
}

pub fn packConflictCategoryName(category: PackConflictCategory) []const u8 {
    return @tagName(category);
}

pub fn packCompetitionPolicyName(policy: PackCompetitionPolicy) []const u8 {
    return @tagName(policy);
}

pub fn packRoutingStatusName(status: PackRoutingStatus) []const u8 {
    return @tagName(status);
}

pub fn conflictKindName(kind: ConflictKind) []const u8 {
    return switch (kind) {
        .none => "none",
        .incompatible => "incompatible",
        .explicit_reject => "explicit_reject",
    };
}

pub fn trustClassName(class: TrustClass) []const u8 {
    return switch (class) {
        .exploratory => "exploratory",
        .project => "project",
        .promoted => "promoted",
        .core => "core",
    };
}

pub fn parseTrustClassName(text: []const u8) ?TrustClass {
    return parseTrustClass(text);
}

pub fn decayStateName(state: DecayState) []const u8 {
    return switch (state) {
        .active => "active",
        .stale => "stale",
        .prunable => "prunable",
        .protected => "protected",
    };
}

pub fn mergeModeName(mode: MergeMode) []const u8 {
    return switch (mode) {
        .adopt => "adopt",
        .promote => "promote",
    };
}

pub fn pruneModeName(mode: PruneMode) []const u8 {
    return switch (mode) {
        .mark_stale => "mark_stale",
        .mark_prunable => "mark_prunable",
        .refresh => "refresh",
        .collect => "collect",
    };
}

fn lineageOperationName(operation: LineageOperation) []const u8 {
    return switch (operation) {
        .distilled => "distilled",
        .reuse_adopt => "reuse_adopt",
        .reuse_reject => "reuse_reject",
        .reuse_promote => "reuse_promote",
        .merge_adopt => "merge_adopt",
        .merge_promote => "merge_promote",
        .prune_mark_stale => "prune_mark_stale",
        .prune_mark_prunable => "prune_mark_prunable",
        .prune_refresh => "prune_refresh",
        .prune_collect => "prune_collect",
        .reinforce_observe => "reinforce_observe",
        .reinforce_promote => "reinforce_promote",
        .reinforce_demote => "reinforce_demote",
    };
}

fn reinforcementOutcomeName(outcome: ReinforcementOutcome) []const u8 {
    return switch (outcome) {
        .success => "success",
        .failure => "failure",
        .ambiguous => "ambiguous",
        .contradicted => "contradicted",
    };
}

pub fn clearStaged(allocator: std.mem.Allocator, paths: *const shards.Paths) !void {
    deleteFileIfExists(paths.abstractions_staged_abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const staged_reuse_path = try reuseStagedPath(allocator, paths);
    defer allocator.free(staged_reuse_path);
    deleteFileIfExists(staged_reuse_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn applyStaged(allocator: std.mem.Allocator, paths: *const shards.Paths) !void {
    var staged = try loadCatalog(allocator, paths.abstractions_staged_abs_path);
    try normalizeCatalogRecords(allocator, staged.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&staged);
    var live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&live);
    var state = try loadCatalogState(allocator, paths);
    const had_catalog_changes = staged.items.len > 0;
    if (had_catalog_changes) {
        state.revision +|= 1;
    }
    var saw_merge = false;
    var saw_prune = false;
    for (staged.items) |*record| {
        if (recordHasLineageOperation(record, .merge_adopt) or recordHasLineageOperation(record, .merge_promote)) {
            saw_merge = true;
        }
        if (recordHasLineageOperation(record, .prune_mark_stale) or
            recordHasLineageOperation(record, .prune_mark_prunable) or
            recordHasLineageOperation(record, .prune_refresh) or
            recordHasLineageOperation(record, .prune_collect))
        {
            saw_prune = true;
        }
        try finalizeStagedRecord(allocator, record, live.items, paths.metadata.kind, paths.metadata.id, state.revision);
        try upsertRecord(&live, try record.clone(allocator));
    }
    if (had_catalog_changes) {
        try persistCatalog(allocator, paths.abstractions_live_abs_path, live.items);
        if (saw_merge) state.last_merge_revision = state.revision;
        if (saw_prune) state.last_prune_revision = state.revision;
        try persistCatalogState(allocator, paths, state);
    }

    const staged_reuse_path = try reuseStagedPath(allocator, paths);
    defer allocator.free(staged_reuse_path);
    const live_reuse_path = try reuseLivePath(allocator, paths);
    defer allocator.free(live_reuse_path);
    var staged_reuse = try loadReuseCatalog(allocator, staged_reuse_path);
    try normalizeReuseEntries(allocator, staged_reuse.items, paths.metadata.kind, paths.metadata.id, live.items);
    defer deinitReuseCatalog(&staged_reuse);
    var live_reuse = try loadReuseCatalog(allocator, live_reuse_path);
    try normalizeReuseEntries(allocator, live_reuse.items, paths.metadata.kind, paths.metadata.id, live.items);
    defer deinitReuseCatalog(&live_reuse);
    for (staged_reuse.items) |*entry| {
        try upsertReuseEntry(&live_reuse, try entry.clone(allocator));
    }
    if (staged_reuse.items.len > 0) {
        if (!had_catalog_changes) {
            state.revision +|= 1;
            state.last_merge_revision = state.revision;
            try persistCatalogState(allocator, paths, state);
        }
        try persistReuseCatalog(allocator, live_reuse_path, live_reuse.items);
    }

    try clearStaged(allocator, paths);
}

pub fn replaceImportedLiveRecords(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    concept_prefix: []const u8,
    imported_records: []const Record,
) !void {
    var live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&live);

    if (concept_prefix.len > 0) {
        var idx: usize = 0;
        while (idx < live.items.len) {
            if (!std.mem.startsWith(u8, live.items[idx].concept_id, concept_prefix)) {
                idx += 1;
                continue;
            }
            var removed = live.orderedRemove(idx);
            removed.deinit();
        }
    }

    var state = try loadCatalogState(allocator, paths);
    const revision = state.revision + 1;
    var changed = false;

    for (imported_records) |record| {
        if (!record.valid_to_commit) return error.AbstractionBelowThreshold;
        if (record.concept_id.len == 0 or record.sources.len == 0) return error.InvalidAbstractionCatalog;
        if (record.tokens.len == 0 and record.patterns.len == 0) return error.InvalidAbstractionCatalog;

        var next = try record.clone(allocator);
        errdefer next.deinit();
        if (next.lineage_id.len == 0) next.lineage_id = try makeLineageId(allocator, paths.metadata.kind, paths.metadata.id, next.concept_id);
        if (next.lineage_version == 0) next.lineage_version = 1;
        if (next.provenance.len == 0) {
            const extra = try std.fmt.allocPrint(allocator, "hash={d}", .{next.consensus_hash});
            defer allocator.free(extra);
            try appendRecordProvenance(&next, allocator, try buildOperationProvenance(
                allocator,
                .distilled,
                paths.metadata.kind,
                paths.metadata.id,
                next.concept_id,
                next.lineage_id,
                next.lineage_version,
                next.trust_class,
                extra,
            ));
        }
        try finalizeStagedRecord(allocator, &next, live.items, paths.metadata.kind, paths.metadata.id, revision);
        try upsertRecord(&live, next);
        changed = true;
    }

    if (changed or concept_prefix.len > 0) {
        state.revision = revision;
        try persistCatalog(allocator, paths.abstractions_live_abs_path, live.items);
        try persistCatalogState(allocator, paths, state);
    }
}

pub fn writeLiveToSlot(allocator: std.mem.Allocator, paths: *const shards.Paths, slot_dir: []const u8) !void {
    const slot_path = try std.fs.path.join(allocator, &.{ slot_dir, config.ABSTRACTION_SLOT_FILE_NAME });
    defer allocator.free(slot_path);
    try copyMaybeFile(allocator, paths.abstractions_live_abs_path, slot_path);

    const live_reuse_path = try reuseLivePath(allocator, paths);
    defer allocator.free(live_reuse_path);
    const slot_reuse_path = try std.fs.path.join(allocator, &.{ slot_dir, REUSE_SLOT_FILE_NAME });
    defer allocator.free(slot_reuse_path);
    try copyMaybeFile(allocator, live_reuse_path, slot_reuse_path);

    const live_state_path = try stateLivePath(allocator, paths);
    defer allocator.free(live_state_path);
    const slot_state_path = try std.fs.path.join(allocator, &.{ slot_dir, STATE_SLOT_FILE_NAME });
    defer allocator.free(slot_state_path);
    try copyMaybeFile(allocator, live_state_path, slot_state_path);
}

pub fn exportCatalogBundle(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    state: ExportState,
    dst_root: []const u8,
) !void {
    const catalog_src = switch (state) {
        .live => paths.abstractions_live_abs_path,
        .staged => paths.abstractions_staged_abs_path,
    };
    const catalog_dst = try std.fs.path.join(allocator, &.{ dst_root, config.ABSTRACTION_SLOT_FILE_NAME });
    defer allocator.free(catalog_dst);
    try copyMaybeFile(allocator, catalog_src, catalog_dst);

    const reuse_src = switch (state) {
        .live => try reuseLivePath(allocator, paths),
        .staged => try reuseStagedPath(allocator, paths),
    };
    defer allocator.free(reuse_src);
    const reuse_dst = try std.fs.path.join(allocator, &.{ dst_root, REUSE_SLOT_FILE_NAME });
    defer allocator.free(reuse_dst);
    try copyMaybeFile(allocator, reuse_src, reuse_dst);

    const state_src = try stateLivePath(allocator, paths);
    defer allocator.free(state_src);
    const state_dst = try std.fs.path.join(allocator, &.{ dst_root, STATE_SLOT_FILE_NAME });
    defer allocator.free(state_dst);
    try copyMaybeFile(allocator, state_src, state_dst);
}

pub fn loadLiveRecordSnapshot(allocator: std.mem.Allocator, paths: *const shards.Paths) ![]Record {
    var live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    errdefer deinitCatalog(&live);
    try normalizeCatalogRecords(allocator, live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    return try live.toOwnedSlice();
}

pub fn loadCatalogSnapshotFromPath(allocator: std.mem.Allocator, abs_path: []const u8) ![]Record {
    var records = try loadCatalog(allocator, abs_path);
    errdefer deinitCatalog(&records);
    return try records.toOwnedSlice();
}

pub fn deinitRecordSlice(records: []Record) void {
    if (records.len == 0) return;
    const allocator = records[0].allocator;
    for (records) |*record| record.deinit();
    allocator.free(records);
}

pub fn saveCatalogSnapshotToPath(allocator: std.mem.Allocator, abs_path: []const u8, records: []const Record) !void {
    try persistCatalog(allocator, abs_path, records);
}

pub fn restoreLiveFromSlot(allocator: std.mem.Allocator, paths: *const shards.Paths, slot_dir: []const u8) !void {
    const slot_path = try std.fs.path.join(allocator, &.{ slot_dir, config.ABSTRACTION_SLOT_FILE_NAME });
    defer allocator.free(slot_path);
    try copyMaybeFile(allocator, slot_path, paths.abstractions_live_abs_path);

    const slot_reuse_path = try std.fs.path.join(allocator, &.{ slot_dir, REUSE_SLOT_FILE_NAME });
    defer allocator.free(slot_reuse_path);
    const live_reuse_path = try reuseLivePath(allocator, paths);
    defer allocator.free(live_reuse_path);
    try copyMaybeFile(allocator, slot_reuse_path, live_reuse_path);

    const slot_state_path = try std.fs.path.join(allocator, &.{ slot_dir, STATE_SLOT_FILE_NAME });
    defer allocator.free(slot_state_path);
    const live_state_path = try stateLivePath(allocator, paths);
    defer allocator.free(live_state_path);
    try copyMaybeFile(allocator, slot_state_path, live_state_path);
}

pub fn stageFromCommand(allocator: std.mem.Allocator, paths: *const shards.Paths, script: []const u8) !Record {
    var request = try parseCommand(allocator, script);
    defer request.deinit();

    var examples = std.ArrayList(Example).init(allocator);
    defer {
        for (examples.items) |*example| example.deinit();
        examples.deinit();
    }

    for (request.source_specs) |spec| {
        try collectExamplesFromSpec(allocator, paths, spec, &examples);
    }
    if (examples.items.len < 2) return error.NotEnoughExamples;
    if (examples.items.len > MAX_EXAMPLES) return error.TooManyExamples;

    var record = try distillRecord(
        allocator,
        request.concept_id,
        request.tier,
        request.category,
        request.parent_concept_id,
        examples.items,
    );
    errdefer record.deinit();
    try applyInitialRecordMetadata(allocator, &record, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind), .distilled);

    var staged = try loadCatalog(allocator, paths.abstractions_staged_abs_path);
    try normalizeCatalogRecords(allocator, staged.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&staged);
    var live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&live);
    try inheritExistingRecordIdentity(&record, staged.items, live.items, paths.metadata.kind, paths.metadata.id);
    try upsertRecord(&staged, try record.clone(allocator));
    try persistCatalog(allocator, paths.abstractions_staged_abs_path, staged.items);
    return record;
}

pub fn stageReuseFromCommand(allocator: std.mem.Allocator, paths: *const shards.Paths, script: []const u8) !ReuseStageResult {
    if (paths.metadata.kind != .project) return error.CrossShardReuseRequiresProjectShard;

    var request = try parseReuseCommand(allocator, script);
    defer request.deinit();

    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();

    var core_live = try loadCatalog(allocator, core_paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, core_live.items, core_paths.metadata.kind, core_paths.metadata.id, defaultTrustForKind(core_paths.metadata.kind));
    defer deinitCatalog(&core_live);
    const source_record = findRecordByConcept(core_live.items, request.source_concept_id) orelse return error.AbstractionSourceNotFound;

    var local_live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, local_live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&local_live);
    var local_staged = try loadCatalog(allocator, paths.abstractions_staged_abs_path);
    try normalizeCatalogRecords(allocator, local_staged.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&local_staged);

    const conflicting_local = findRecordByConcept(local_staged.items, request.source_concept_id) orelse findRecordByConcept(local_live.items, request.source_concept_id);
    if (request.decision == .adopt and conflictingLocalConflict(conflicting_local, source_record)) {
        return error.CrossShardConflictRequiresPromoteOrReject;
    }

    const local_record = if (request.local_concept_id) |local_concept_id|
        findRecordByConcept(local_staged.items, local_concept_id) orelse findRecordByConcept(local_live.items, local_concept_id) orelse return error.AbstractionSourceNotFound
    else
        null;

    if (request.decision == .promote and local_record == null) return error.AbstractionSourceNotFound;

    var entry = ReuseEntry{
        .allocator = allocator,
        .decision = request.decision,
        .source_kind = .core,
        .source_id = try allocator.dupe(u8, core_paths.metadata.id),
        .source_concept_id = try allocator.dupe(u8, source_record.concept_id),
        .source_consensus_hash = source_record.consensus_hash,
        .source_lineage_id = try allocator.dupe(u8, source_record.lineage_id),
        .source_lineage_version = source_record.lineage_version,
        .source_trust_class = source_record.trust_class,
        .local_concept_id = if (local_record) |record| try allocator.dupe(u8, record.concept_id) else null,
        .local_consensus_hash = if (local_record) |record| record.consensus_hash else 0,
        .local_lineage_id = if (local_record) |record| try allocator.dupe(u8, record.lineage_id) else null,
        .local_lineage_version = if (local_record) |record| record.lineage_version else 0,
        .local_trust_class = if (local_record) |record| record.trust_class else null,
    };
    errdefer entry.deinit();

    const staged_reuse_path = try reuseStagedPath(allocator, paths);
    defer allocator.free(staged_reuse_path);
    var staged_reuse = try loadReuseCatalog(allocator, staged_reuse_path);
    try normalizeReuseEntries(allocator, staged_reuse.items, paths.metadata.kind, paths.metadata.id, local_staged.items);
    defer deinitReuseCatalog(&staged_reuse);
    try upsertReuseEntry(&staged_reuse, try entry.clone(allocator));
    try persistReuseCatalog(allocator, staged_reuse_path, staged_reuse.items);

    return .{
        .allocator = allocator,
        .entry = entry,
        .source_tier = source_record.tier,
        .source_category = source_record.category,
        .local_tier = if (local_record) |record| record.tier else null,
        .local_category = if (local_record) |record| record.category else null,
    };
}

pub fn stageMergeFromCommand(allocator: std.mem.Allocator, paths: *const shards.Paths, script: []const u8) !MergeStageResult {
    var request = try parseMergeCommand(allocator, script);
    defer request.deinit();

    const default_trust = defaultTrustForKind(paths.metadata.kind);
    var source_metadata = switch (request.source_kind) {
        .core => try shards.resolveCoreMetadata(allocator),
        .project => try shards.resolveProjectMetadata(allocator, request.source_id),
        .scratch => return error.InvalidAbstractionCommand,
    };
    defer source_metadata.deinit();
    if (source_metadata.metadata.kind == paths.metadata.kind and std.mem.eql(u8, source_metadata.metadata.id, paths.metadata.id)) {
        return error.SelfMergeNotAllowed;
    }
    var source_paths = try shards.resolvePaths(allocator, source_metadata.metadata);
    defer source_paths.deinit();

    var source_live = try loadCatalog(allocator, source_paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, source_live.items, source_paths.metadata.kind, source_paths.metadata.id, defaultTrustForKind(source_paths.metadata.kind));
    defer deinitCatalog(&source_live);
    const source_record = findRecordByConcept(source_live.items, request.source_concept_id) orelse return error.AbstractionSourceNotFound;

    if (request.mode == .promote) {
        if (trustRank(default_trust, DEFAULT_TRUST_POLICY) <= trustRank(source_record.trust_class, DEFAULT_TRUST_POLICY)) return error.TrustPromotionRequiresHigherDestination;
        if (source_record.decay_state == .prunable) return error.PrunableContentCannotBePromoted;
    } else if (trustRank(default_trust, DEFAULT_TRUST_POLICY) > trustRank(source_record.trust_class, DEFAULT_TRUST_POLICY)) {
        return error.UsePromoteForHigherTrustDestination;
    }

    var live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&live);
    var staged = try loadCatalog(allocator, paths.abstractions_staged_abs_path);
    try normalizeCatalogRecords(allocator, staged.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&staged);

    const target_concept_id = request.target_concept_id orelse source_record.concept_id;
    const existing_record = findRecordByConcept(staged.items, target_concept_id) orelse findRecordByConcept(live.items, target_concept_id);
    if (existing_record) |current| {
        if (!recordsCompatible(current, source_record)) return error.MergeConflictRefused;
        if (!provenanceMergeAllowed(current, source_record, request.mode, default_trust)) return error.MergeProvenanceRefused;
    }

    var merged = if (existing_record) |current|
        try mergeCompatibleRecord(allocator, current, source_record, source_paths.metadata.kind, source_paths.metadata.id, paths.metadata.kind, paths.metadata.id, request.mode)
    else
        try adoptSourceRecord(allocator, source_record, source_paths.metadata.kind, source_paths.metadata.id, target_concept_id, paths.metadata.kind, paths.metadata.id, request.mode);
    defer merged.deinit();

    try upsertRecord(&staged, try merged.clone(allocator));
    try persistCatalog(allocator, paths.abstractions_staged_abs_path, staged.items);

    return .{
        .allocator = allocator,
        .mode = request.mode,
        .source_kind = source_paths.metadata.kind,
        .source_id = try allocator.dupe(u8, source_paths.metadata.id),
        .source_concept_id = try allocator.dupe(u8, source_record.concept_id),
        .source_lineage_id = try allocator.dupe(u8, source_record.lineage_id),
        .source_lineage_version = source_record.lineage_version,
        .source_trust_class = source_record.trust_class,
        .destination_kind = paths.metadata.kind,
        .destination_id = try allocator.dupe(u8, paths.metadata.id),
        .destination_concept_id = try allocator.dupe(u8, merged.concept_id),
        .destination_lineage_id = try allocator.dupe(u8, merged.lineage_id),
        .destination_lineage_version = merged.lineage_version,
        .destination_trust_class = merged.trust_class,
        .staged_conflict = existing_record != null,
    };
}

pub fn stagePruneFromCommand(allocator: std.mem.Allocator, paths: *const shards.Paths, script: []const u8) !PruneStageResult {
    var request = try parsePruneCommand(allocator, script);
    defer request.deinit();

    var live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&live);
    var staged = try loadCatalog(allocator, paths.abstractions_staged_abs_path);
    try normalizeCatalogRecords(allocator, staged.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&staged);
    const state = try loadCatalogState(allocator, paths);

    var affected = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (affected.items) |item| allocator.free(item);
        affected.deinit();
    }

    switch (request.mode) {
        .mark_stale, .mark_prunable, .refresh => {
            const target = findMutableRecord(staged.items, request.target_concept_id.?) orelse blk: {
                const from_live = findRecordByConcept(live.items, request.target_concept_id.?) orelse return error.AbstractionSourceNotFound;
                const cloned = try from_live.clone(allocator);
                try staged.append(cloned);
                break :blk &staged.items[staged.items.len - 1];
            };
            const next_state: DecayState = switch (request.mode) {
                .mark_stale => .stale,
                .mark_prunable => .prunable,
                .refresh => .active,
                .collect => unreachable,
            };
            target.decay_state = next_state;
            if (request.mode == .refresh) {
                target.last_review_revision = state.revision + 1;
            }
            try appendRecordProvenance(target, allocator, try buildOperationProvenance(
                allocator,
                switch (request.mode) {
                    .mark_stale => .prune_mark_stale,
                    .mark_prunable => .prune_mark_prunable,
                    .refresh => .prune_refresh,
                    .collect => unreachable,
                },
                paths.metadata.kind,
                paths.metadata.id,
                target.concept_id,
                target.lineage_id,
                target.lineage_version + 1,
                target.trust_class,
                null,
            ));
            try affected.append(try allocator.dupe(u8, target.concept_id));
        },
        .collect => {
            for (live.items) |*record| {
                if (affected.items.len >= MAX_PRUNE_RESULTS) break;
                if (!pruneCollectEligible(record, state, request.collect_gap, request.collect_quality, request.collect_confidence, request.collect_trust)) continue;
                const target = findMutableRecord(staged.items, record.concept_id) orelse blk: {
                    const cloned = try record.clone(allocator);
                    try staged.append(cloned);
                    break :blk &staged.items[staged.items.len - 1];
                };
                target.decay_state = .prunable;
                try appendRecordProvenance(target, allocator, try buildOperationProvenance(
                    allocator,
                    .prune_collect,
                    paths.metadata.kind,
                    paths.metadata.id,
                    target.concept_id,
                    target.lineage_id,
                    target.lineage_version + 1,
                    target.trust_class,
                    null,
                ));
                try affected.append(try allocator.dupe(u8, target.concept_id));
            }
        },
    }

    if (affected.items.len > 0) {
        try persistCatalog(allocator, paths.abstractions_staged_abs_path, staged.items);
    }

    return .{
        .allocator = allocator,
        .mode = request.mode,
        .affected_concepts = try affected.toOwnedSlice(),
        .next_state = switch (request.mode) {
            .mark_stale => .stale,
            .mark_prunable, .collect => .prunable,
            .refresh => .active,
        },
    };
}

pub fn renderJson(allocator: std.mem.Allocator, record: *const Record) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    const explanation = try record.validityExplanation(allocator);
    defer allocator.free(explanation);

    try out.appendSlice("{\"concept\":\"");
    try appendEscapedJson(&out, record.concept_id);
    try out.appendSlice("\",\"family\":\"");
    try appendEscapedJson(&out, familyName(record.family));
    try out.appendSlice("\",\"tier\":\"");
    try appendEscapedJson(&out, tierName(record.tier));
    try out.appendSlice("\",\"category\":\"");
    try appendEscapedJson(&out, categoryName(record.category));
    try out.appendSlice("\"");
    if (record.parent_concept_id) |parent_concept_id| {
        try out.appendSlice(",\"parent\":\"");
        try appendEscapedJson(&out, parent_concept_id);
        try out.appendSlice("\"");
    }
    try out.appendSlice(",\"exampleCount\":");
    try appendIntJson(&out, record.example_count);
    try out.appendSlice(",\"thresholdExamples\":");
    try appendIntJson(&out, record.threshold_examples);
    try out.appendSlice(",\"retainedTokens\":");
    try appendStringArrayJson(&out, record.tokens);
    try out.appendSlice(",\"retainedPatterns\":");
    try appendStringArrayJson(&out, record.patterns);
    try out.appendSlice(",\"sources\":");
    try appendStringArrayJson(&out, record.sources);
    try out.appendSlice(",\"consensusHash\":");
    try appendIntJson(&out, record.consensus_hash);
    try out.appendSlice(",\"averageResonance\":");
    try appendIntJson(&out, record.average_resonance);
    try out.appendSlice(",\"minResonance\":");
    try appendIntJson(&out, record.min_resonance);
    try out.appendSlice(",\"qualityScore\":");
    try appendIntJson(&out, record.quality_score);
    try out.appendSlice(",\"confidenceScore\":");
    try appendIntJson(&out, record.confidence_score);
    try out.appendSlice(",\"reuseScore\":");
    try appendIntJson(&out, record.reuse_score);
    try out.appendSlice(",\"supportScore\":");
    try appendIntJson(&out, record.support_score);
    try out.appendSlice(",\"promotionReady\":");
    try out.appendSlice(if (record.promotion_ready) "true" else "false");
    try out.appendSlice(",\"lineage\":{\"id\":\"");
    try appendEscapedJson(&out, record.lineage_id);
    try out.appendSlice("\",\"version\":");
    try appendIntJson(&out, record.lineage_version);
    try out.appendSlice(",\"trust\":\"");
    try appendEscapedJson(&out, trustClassName(record.trust_class));
    try out.appendSlice("\",\"decay\":\"");
    try appendEscapedJson(&out, decayStateName(record.decay_state));
    try out.appendSlice("\",\"successCount\":");
    try appendIntJson(&out, record.success_count);
    try out.appendSlice(",\"failureCount\":");
    try appendIntJson(&out, record.failure_count);
    try out.appendSlice(",\"ambiguityCount\":");
    try appendIntJson(&out, record.ambiguity_count);
    try out.appendSlice(",\"contradictionCount\":");
    try appendIntJson(&out, record.contradiction_count);
    try out.appendSlice(",\"independentCaseCount\":");
    try appendIntJson(&out, record.independent_case_count);
    try out.appendSlice(",\"firstRevision\":");
    try appendIntJson(&out, record.first_revision);
    try out.appendSlice(",\"lastRevision\":");
    try appendIntJson(&out, record.last_revision);
    try out.appendSlice(",\"lastReviewRevision\":");
    try appendIntJson(&out, record.last_review_revision);
    try out.appendSlice(",\"provenance\":");
    try appendStringArrayJson(&out, record.provenance);
    try out.append('}');
    try out.appendSlice(",\"validToCommit\":");
    try out.appendSlice(if (record.valid_to_commit) "true" else "false");
    try out.appendSlice(",\"explanation\":\"");
    try appendEscapedJson(&out, explanation);
    try out.appendSlice("\"}");
    return out.toOwnedSlice();
}

pub fn renderReuseJson(allocator: std.mem.Allocator, result: *const ReuseStageResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    try out.appendSlice("{\"decision\":\"");
    try appendEscapedJson(&out, reuseDecisionName(result.entry.decision));
    try out.appendSlice("\",\"source\":{\"kind\":\"");
    try appendEscapedJson(&out, @tagName(result.entry.source_kind));
    try out.appendSlice("\",\"id\":\"");
    try appendEscapedJson(&out, result.entry.source_id);
    try out.appendSlice("\",\"concept\":\"");
    try appendEscapedJson(&out, result.entry.source_concept_id);
    try out.appendSlice("\",\"tier\":\"");
    try appendEscapedJson(&out, tierName(result.source_tier));
    try out.appendSlice("\",\"category\":\"");
    try appendEscapedJson(&out, categoryName(result.source_category));
    try out.appendSlice("\",\"consensusHash\":");
    try appendIntJson(&out, result.entry.source_consensus_hash);
    try out.appendSlice(",\"lineageId\":\"");
    try appendEscapedJson(&out, result.entry.source_lineage_id);
    try out.appendSlice("\",\"lineageVersion\":");
    try appendIntJson(&out, result.entry.source_lineage_version);
    try out.appendSlice(",\"trust\":\"");
    try appendEscapedJson(&out, trustClassName(result.entry.source_trust_class));
    try out.appendSlice("}");
    if (result.entry.local_concept_id) |local_concept_id| {
        try out.appendSlice(",\"local\":{\"concept\":\"");
        try appendEscapedJson(&out, local_concept_id);
        try out.appendSlice("\",\"tier\":\"");
        try appendEscapedJson(&out, tierName(result.local_tier.?));
        try out.appendSlice("\",\"category\":\"");
        try appendEscapedJson(&out, categoryName(result.local_category.?));
        try out.appendSlice("\",\"consensusHash\":");
        try appendIntJson(&out, result.entry.local_consensus_hash);
        if (result.entry.local_lineage_id) |local_lineage_id| {
            try out.appendSlice(",\"lineageId\":\"");
            try appendEscapedJson(&out, local_lineage_id);
            try out.appendSlice("\",\"lineageVersion\":");
            try appendIntJson(&out, result.entry.local_lineage_version);
        }
        if (result.entry.local_trust_class) |local_trust_class| {
            try out.appendSlice(",\"trust\":\"");
            try appendEscapedJson(&out, trustClassName(local_trust_class));
            try out.append('"');
        }
        try out.appendSlice("}");
    }
    try out.appendSlice("}");
    return out.toOwnedSlice();
}

pub fn renderMergeJson(allocator: std.mem.Allocator, result: *const MergeStageResult) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"mode\":\"{s}\",\"source\":{{\"kind\":\"{s}\",\"id\":\"{s}\",\"concept\":\"{s}\",\"lineageId\":\"{s}\",\"lineageVersion\":{d},\"trust\":\"{s}\"}},\"destination\":{{\"kind\":\"{s}\",\"id\":\"{s}\",\"concept\":\"{s}\",\"lineageId\":\"{s}\",\"lineageVersion\":{d},\"trust\":\"{s}\"}},\"stagedConflict\":{s}}}",
        .{
            mergeModeName(result.mode),
            @tagName(result.source_kind),
            result.source_id,
            result.source_concept_id,
            result.source_lineage_id,
            result.source_lineage_version,
            trustClassName(result.source_trust_class),
            @tagName(result.destination_kind),
            result.destination_id,
            result.destination_concept_id,
            result.destination_lineage_id,
            result.destination_lineage_version,
            trustClassName(result.destination_trust_class),
            if (result.staged_conflict) "true" else "false",
        },
    );
}

pub fn renderPruneJson(allocator: std.mem.Allocator, result: *const PruneStageResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    try out.appendSlice("{\"mode\":\"");
    try appendEscapedJson(&out, pruneModeName(result.mode));
    try out.appendSlice("\",\"nextState\":\"");
    try appendEscapedJson(&out, decayStateName(result.next_state));
    try out.appendSlice("\",\"affectedConcepts\":");
    try appendStringArrayJson(&out, result.affected_concepts);
    try out.append('}');
    return out.toOwnedSlice();
}

pub fn collectSupportingConcepts(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    rel_paths: []const []const u8,
    max_items: usize,
) ![]SupportReference {
    return lookupConcepts(allocator, paths, .{
        .rel_paths = rel_paths,
        .max_items = max_items,
        .include_staged = true,
        .prefer_higher_tiers = true,
        .category_hint = null,
    });
}

pub fn lookupGroundingConcepts(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    options: GroundingOptions,
) ![]SupportReference {
    var live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&live);
    var staged = std.ArrayList(Record).init(allocator);
    defer deinitCatalog(&staged);
    if (options.include_staged) {
        staged = try loadCatalog(allocator, paths.abstractions_staged_abs_path);
        try normalizeCatalogRecords(allocator, staged.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    }

    var local_refs = std.ArrayList(SupportReference).init(allocator);
    defer {
        for (local_refs.items) |item| deinitSupportReferenceItem(allocator, item);
        local_refs.deinit();
    }
    try collectGroundingLookup(allocator, paths.metadata.kind, paths.metadata.id, live.items, staged.items, options, &local_refs);

    if (paths.metadata.kind != .project) {
        return local_refs.toOwnedSlice();
    }

    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();
    var core_live = try loadCatalog(allocator, core_paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, core_live.items, core_paths.metadata.kind, core_paths.metadata.id, defaultTrustForKind(core_paths.metadata.kind));
    defer deinitCatalog(&core_live);

    var core_refs = std.ArrayList(SupportReference).init(allocator);
    defer {
        for (core_refs.items) |item| deinitSupportReferenceItem(allocator, item);
        core_refs.deinit();
    }
    try collectGroundingLookup(allocator, core_paths.metadata.kind, core_paths.metadata.id, core_live.items, &.{}, options, &core_refs);

    const live_reuse_path = try reuseLivePath(allocator, paths);
    defer allocator.free(live_reuse_path);
    var reuse_live = try loadReuseCatalog(allocator, live_reuse_path);
    try normalizeReuseEntries(allocator, reuse_live.items, paths.metadata.kind, paths.metadata.id, live.items);
    defer deinitReuseCatalog(&reuse_live);
    var reuse_staged = std.ArrayList(ReuseEntry).init(allocator);
    defer deinitReuseCatalog(&reuse_staged);
    if (options.include_staged) {
        const staged_reuse_path = try reuseStagedPath(allocator, paths);
        defer allocator.free(staged_reuse_path);
        reuse_staged = try loadReuseCatalog(allocator, staged_reuse_path);
        try normalizeReuseEntries(allocator, reuse_staged.items, paths.metadata.kind, paths.metadata.id, staged.items);
    }

    var out = std.ArrayList(SupportReference).init(allocator);
    errdefer {
        for (out.items) |item| deinitSupportReferenceItem(allocator, item);
        out.deinit();
    }
    try mergeCrossShardSupport(allocator, local_refs.items, core_refs.items, reuse_live.items, reuse_staged.items, &out);
    try mergeMountedPackGroundingReferences(allocator, paths, options, &out);
    trimSupportReferenceList(allocator, &out, options.max_items);
    return out.toOwnedSlice();
}

pub fn lookupConcepts(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    options: LookupOptions,
) ![]SupportReference {
    var live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&live);
    var staged = std.ArrayList(Record).init(allocator);
    defer deinitCatalog(&staged);
    if (options.include_staged) {
        staged = try loadCatalog(allocator, paths.abstractions_staged_abs_path);
        try normalizeCatalogRecords(allocator, staged.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    }

    var local_refs = std.ArrayList(SupportReference).init(allocator);
    defer {
        for (local_refs.items) |item| deinitSupportReferenceItem(allocator, item);
        local_refs.deinit();
    }
    try collectSupportLookup(allocator, paths.metadata.kind, paths.metadata.id, live.items, staged.items, options, &local_refs);

    if (paths.metadata.kind != .project) {
        return local_refs.toOwnedSlice();
    }

    var core_metadata = try shards.resolveCoreMetadata(allocator);
    defer core_metadata.deinit();
    var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
    defer core_paths.deinit();
    var core_live = try loadCatalog(allocator, core_paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, core_live.items, core_paths.metadata.kind, core_paths.metadata.id, defaultTrustForKind(core_paths.metadata.kind));
    defer deinitCatalog(&core_live);

    var core_refs = std.ArrayList(SupportReference).init(allocator);
    defer {
        for (core_refs.items) |item| deinitSupportReferenceItem(allocator, item);
        core_refs.deinit();
    }
    try collectSupportLookup(allocator, core_paths.metadata.kind, core_paths.metadata.id, core_live.items, &.{}, options, &core_refs);

    const live_reuse_path = try reuseLivePath(allocator, paths);
    defer allocator.free(live_reuse_path);
    var reuse_live = try loadReuseCatalog(allocator, live_reuse_path);
    try normalizeReuseEntries(allocator, reuse_live.items, paths.metadata.kind, paths.metadata.id, live.items);
    defer deinitReuseCatalog(&reuse_live);
    var reuse_staged = std.ArrayList(ReuseEntry).init(allocator);
    defer deinitReuseCatalog(&reuse_staged);
    if (options.include_staged) {
        const staged_reuse_path = try reuseStagedPath(allocator, paths);
        defer allocator.free(staged_reuse_path);
        reuse_staged = try loadReuseCatalog(allocator, staged_reuse_path);
        try normalizeReuseEntries(allocator, reuse_staged.items, paths.metadata.kind, paths.metadata.id, staged.items);
    }

    var out = std.ArrayList(SupportReference).init(allocator);
    errdefer {
        for (out.items) |item| deinitSupportReferenceItem(allocator, item);
        out.deinit();
    }
    try mergeCrossShardSupport(allocator, local_refs.items, core_refs.items, reuse_live.items, reuse_staged.items, &out);
    try mergeMountedPackSupportReferences(allocator, paths, options, &out);
    return out.toOwnedSlice();
}

pub fn deinitSupportReferences(allocator: std.mem.Allocator, items: []SupportReference) void {
    for (items) |item| deinitSupportReferenceItem(allocator, item);
    allocator.free(items);
}

pub fn lookupReverseSymbolicLinks(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    options: LookupOptions,
) ![]ReverseLinkReference {
    var support_options = options;
    support_options.pack_routing = null;
    const support_refs = try lookupConcepts(allocator, paths, support_options);
    defer deinitSupportReferences(allocator, support_refs);

    var local_live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, local_live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&local_live);

    var local_staged = std.ArrayList(Record).init(allocator);
    defer deinitCatalog(&local_staged);
    if (options.include_staged) {
        local_staged = try loadCatalog(allocator, paths.abstractions_staged_abs_path);
        try normalizeCatalogRecords(allocator, local_staged.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    }

    var core_live = std.ArrayList(Record).init(allocator);
    defer deinitCatalog(&core_live);
    if (paths.metadata.kind == .project) {
        var core_metadata = try shards.resolveCoreMetadata(allocator);
        defer core_metadata.deinit();
        var core_paths = try shards.resolvePaths(allocator, core_metadata.metadata);
        defer core_paths.deinit();
        core_live = try loadCatalog(allocator, core_paths.abstractions_live_abs_path);
        try normalizeCatalogRecords(allocator, core_live.items, core_paths.metadata.kind, core_paths.metadata.id, defaultTrustForKind(core_paths.metadata.kind));
    }

    var out = std.ArrayList(ReverseLinkReference).init(allocator);
    errdefer {
        for (out.items) |item| deinitReverseLinkReferenceItem(allocator, item);
        out.deinit();
    }

    const pack_catalogs = try loadMountedPackCatalogs(
        allocator,
        paths,
        options.rel_paths,
        options.tokens,
        options.patterns,
        options.pack_routing_stage,
        options.pack_routing_caps,
        options.pack_conflict_policy,
        options.pack_routing,
    );
    defer {
        for (pack_catalogs) |*catalog| catalog.deinit();
        allocator.free(pack_catalogs);
    }

    for (support_refs) |ref| {
        const record = findReverseLinkRecord(paths, local_live.items, local_staged.items, core_live.items, pack_catalogs, ref) orelse continue;
        try appendReverseLinksForRecord(allocator, ref, record, options.rel_paths, &out);
    }

    sortReverseLinkReferences(out.items);
    trimReverseLinkReferenceList(allocator, &out, options.max_items);
    return out.toOwnedSlice();
}

pub fn deinitReverseLinkReferences(allocator: std.mem.Allocator, items: []ReverseLinkReference) void {
    for (items) |item| deinitReverseLinkReferenceItem(allocator, item);
    allocator.free(items);
}

pub fn inspectMountedPackRouting(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    rel_paths: []const []const u8,
    tokens: []const []const u8,
    patterns: []const []const u8,
    stage: PackRoutingStage,
    caps: PackRoutingCaps,
) ![]PackRoutingTrace {
    const routed = try routeMountedPacks(allocator, paths, rel_paths, tokens, patterns, stage, caps, .{}, 0);
    defer {
        for (routed.mounts) |*mount| mount.deinit();
        allocator.free(routed.mounts);
    }
    return routed.traces;
}

pub fn lookupFamilyConcepts(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    options: FamilyLookupOptions,
) ![]SupportReference {
    var live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&live);

    var staged = std.ArrayList(Record).init(allocator);
    defer deinitCatalog(&staged);
    if (options.include_staged) {
        staged = try loadCatalog(allocator, paths.abstractions_staged_abs_path);
        try normalizeCatalogRecords(allocator, staged.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    }

    var out = std.ArrayList(SupportReference).init(allocator);
    errdefer {
        for (out.items) |item| deinitSupportReferenceItem(allocator, item);
        out.deinit();
    }

    try collectFamilyLookup(allocator, paths.metadata.kind, paths.metadata.id, live.items, false, options, &out);
    if (options.include_staged) try collectFamilyLookup(allocator, paths.metadata.kind, paths.metadata.id, staged.items, true, options, &out);
    try mergeMountedPackFamilyReferences(allocator, paths, options, &out);
    sortSupportReferences(out.items);
    trimSupportReferenceList(allocator, &out, options.max_items);
    return out.toOwnedSlice();
}

pub fn applyReinforcementEvents(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    events: []const ReinforcementEvent,
    options: ReinforcementApplyOptions,
) !usize {
    if (events.len == 0 or options.max_events == 0 or options.max_new_records == 0) return 0;

    var live = try loadCatalog(allocator, paths.abstractions_live_abs_path);
    try normalizeCatalogRecords(allocator, live.items, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind));
    defer deinitCatalog(&live);

    var state = try loadCatalogState(allocator, paths);
    var applied: usize = 0;
    var new_records: usize = 0;

    for (events[0..@min(events.len, options.max_events)]) |event| {
        const concept_id = try reinforcementConceptId(allocator, event);
        defer allocator.free(concept_id);

        var target = findMutableRecord(live.items, concept_id);
        if (target == null) {
            if (new_records >= options.max_new_records) break;
            try live.append(try initReinforcementRecord(allocator, paths, event, concept_id));
            target = &live.items[live.items.len - 1];
            new_records += 1;
        }

        const already_seen = reinforcementCaseSeen(target.?, event.case_id, event.outcome);
        if (already_seen) continue;

        try mergeUniqueTextInto(&target.?.sources, allocator, event.source_specs);
        try mergeUniqueTextInto(&target.?.tokens, allocator, event.tokens);
        try mergeUniqueTextInto(&target.?.patterns, allocator, event.patterns);
        applyReinforcementOutcome(target.?, event.outcome, DEFAULT_TRUST_POLICY);
        refreshReinforcementRecord(target.?);

        const extra = try reinforcementExtra(allocator, event);
        defer allocator.free(extra);
        try appendRecordProvenance(target.?, allocator, try buildOperationProvenance(
            allocator,
            .reinforce_observe,
            paths.metadata.kind,
            paths.metadata.id,
            target.?.concept_id,
            target.?.lineage_id,
            target.?.lineage_version + 1,
            target.?.trust_class,
            extra,
        ));

        const post_state = promotionLineageOperation(target.?);
        if (post_state) |operation| {
            try appendRecordProvenance(target.?, allocator, try buildOperationProvenance(
                allocator,
                operation,
                paths.metadata.kind,
                paths.metadata.id,
                target.?.concept_id,
                target.?.lineage_id,
                target.?.lineage_version + 1,
                target.?.trust_class,
                null,
            ));
        }

        applied += 1;
    }

    if (applied > 0) {
        state.revision +|= 1;
        for (live.items) |*record| try finalizeStagedRecord(allocator, record, &.{}, paths.metadata.kind, paths.metadata.id, state.revision);
        try persistCatalog(allocator, paths.abstractions_live_abs_path, live.items);
        try persistCatalogState(allocator, paths, state);
    }

    return applied;
}

pub fn countUsableReferences(items: []const SupportReference) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.usable) count += 1;
    }
    return count;
}

fn collectFamilyLookup(
    allocator: std.mem.Allocator,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    records: []const Record,
    staged: bool,
    options: FamilyLookupOptions,
    out: *std.ArrayList(SupportReference),
) !void {
    for (records) |*record| {
        if (record.family != options.family) continue;
        if (!reinforcementUsable(record)) continue;

        const source_hits = countSupportMatches(record.sources, options.rel_paths);
        const token_hits = countTextMatches(record.tokens, options.tokens);
        const pattern_hits = countTextMatches(record.patterns, options.patterns);
        const structured_hits = countRecordStructuredSignalMatches(record, options.tokens, options.patterns);
        if (source_hits == 0 and token_hits == 0 and pattern_hits == 0 and structured_hits == 0) continue;

        const source_spec = preferredSupportSource(record.sources, options.rel_paths) orelse preferredGroundingSource(record.sources) orelse familyName(record.family);
        const score = computeFamilyLookupScore(record, source_hits, token_hits, pattern_hits + structured_hits);
        try out.append(.{
            .concept_id = try allocator.dupe(u8, record.concept_id),
            .family = record.family,
            .source_spec = try allocator.dupe(u8, source_spec),
            .staged = staged,
            .tier = record.tier,
            .category = record.category,
            .trust_class = record.trust_class,
            .decay_state = record.decay_state,
            .owner_kind = owner_kind,
            .owner_id = try allocator.dupe(u8, owner_id),
            .lineage_id = try allocator.dupe(u8, record.lineage_id),
            .lineage_version = record.lineage_version,
            .parent_concept_id = if (record.parent_concept_id) |value| try allocator.dupe(u8, value) else null,
            .supporting_concept_id = null,
            .quality_score = record.quality_score,
            .confidence_score = record.confidence_score,
            .lookup_score = score,
            .direct_support_count = source_hits,
            .lineage_support_count = @intCast(record.independent_case_count),
            .token_support_count = token_hits,
            .pattern_support_count = pattern_hits,
            .source_support_count = source_hits,
            .selection_mode = if (record.promotion_ready) .promoted else .fallback,
            .consensus_hash = record.consensus_hash,
            .usable = reinforcementUsable(record),
            .resolution = .local,
        });
    }
}

fn preferredSupportSource(sources: [][]u8, rel_paths: []const []const u8) ?[]const u8 {
    for (sources) |source| {
        for (rel_paths) |rel_path| {
            if (rel_path.len == 0) continue;
            if (std.mem.indexOf(u8, source, rel_path) != null) return source;
        }
    }
    return null;
}

fn computeFamilyLookupScore(record: *const Record, source_hits: u16, token_hits: u16, pattern_hits: u16) u16 {
    var score: u32 = @as(u32, record.quality_score);
    score += @as(u32, record.confidence_score) / 2;
    score += @as(u32, record.independent_case_count) * 80;
    score += @as(u32, source_hits) * 70;
    score += @as(u32, token_hits) * 65;
    score += @as(u32, pattern_hits) * 95;
    return @intCast(@min(score, @as(u32, MAX_SCORE)));
}

fn matchSupportSource(sources: [][]u8, rel_paths: []const []const u8) ?[]const u8 {
    for (sources) |source| {
        if (std.mem.startsWith(u8, source, "code_intel:last_result")) return source;
        for (rel_paths) |rel_path| {
            if (rel_path.len == 0) continue;
            if (std.mem.indexOf(u8, source, rel_path) != null) return source;
        }
    }
    return null;
}

const CatalogEntry = struct {
    record: *const Record,
    staged: bool,
};

const MatchAccumulator = struct {
    entry_index: usize,
    source_spec: []const u8,
    direct_support_count: u16 = 0,
    lineage_support_count: u16 = 0,
    token_support_count: u16 = 0,
    pattern_support_count: u16 = 0,
    structured_support_count: u16 = 0,
    source_support_count: u16 = 0,
    depth: u8 = std.math.maxInt(u8),
    supporting_entry_index: usize = std.math.maxInt(usize),
};

fn collectSupportLookup(
    allocator: std.mem.Allocator,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    live_records: []const Record,
    staged_records: []const Record,
    options: LookupOptions,
    out: *std.ArrayList(SupportReference),
) !void {
    if (options.max_items == 0 or options.rel_paths.len == 0) return;

    var entries = std.ArrayList(CatalogEntry).init(allocator);
    defer entries.deinit();
    for (live_records) |*record| try entries.append(.{ .record = record, .staged = false });
    for (staged_records) |*record| try entries.append(.{ .record = record, .staged = true });

    var matches = std.ArrayList(MatchAccumulator).init(allocator);
    defer matches.deinit();

    for (entries.items, 0..) |entry, entry_index| {
        const source_match = matchSupportSource(entry.record.sources, options.rel_paths) orelse continue;
        const direct_support_count = countSupportMatches(entry.record.sources, options.rel_paths);
        const token_support_count = countTextMatches(entry.record.tokens, options.tokens);
        const pattern_support_count = countTextMatches(entry.record.patterns, options.patterns);
        const structured_support_count = countRecordStructuredSignalMatches(entry.record, options.tokens, options.patterns);
        try upsertMatch(&matches, .{
            .entry_index = entry_index,
            .source_spec = source_match,
            .direct_support_count = direct_support_count,
            .lineage_support_count = direct_support_count,
            .token_support_count = token_support_count,
            .pattern_support_count = pattern_support_count,
            .structured_support_count = structured_support_count,
            .source_support_count = direct_support_count,
            .depth = 0,
            .supporting_entry_index = entry_index,
        });

        var parent_id = entry.record.parent_concept_id;
        var depth: usize = 1;
        while (parent_id != null and depth <= MAX_PARENT_CHAIN_DEPTH) : (depth += 1) {
            const parent_index = findEntryIndex(entries.items, parent_id.?, entry.staged) orelse break;
            try upsertMatch(&matches, .{
                .entry_index = parent_index,
                .source_spec = source_match,
                .direct_support_count = 0,
                .lineage_support_count = direct_support_count,
                .token_support_count = token_support_count,
                .pattern_support_count = pattern_support_count,
                .structured_support_count = structured_support_count,
                .source_support_count = direct_support_count,
                .depth = @intCast(depth),
                .supporting_entry_index = entry_index,
            });
            parent_id = entries.items[parent_index].record.parent_concept_id;
        }
    }

    if (matches.items.len == 0) return;

    for (matches.items) |match| {
        const entry = entries.items[match.entry_index];
        const record = entry.record;
        if (!lookupEligible(record, match)) continue;

        const lookup_score = computeLookupScore(record, match, options);
        const selection_mode: SelectionMode = if (match.depth == 0)
            .direct
        else if (record.promotion_ready)
            .promoted
        else
            .fallback;

        try out.append(.{
            .concept_id = try allocator.dupe(u8, record.concept_id),
            .family = record.family,
            .source_spec = try allocator.dupe(u8, match.source_spec),
            .staged = entry.staged,
            .tier = record.tier,
            .category = record.category,
            .trust_class = record.trust_class,
            .decay_state = record.decay_state,
            .owner_kind = owner_kind,
            .owner_id = try allocator.dupe(u8, owner_id),
            .lineage_id = try allocator.dupe(u8, record.lineage_id),
            .lineage_version = record.lineage_version,
            .parent_concept_id = if (record.parent_concept_id) |parent_concept_id| try allocator.dupe(u8, parent_concept_id) else null,
            .supporting_concept_id = if (match.depth != 0 and match.supporting_entry_index != std.math.maxInt(usize))
                try allocator.dupe(u8, entries.items[match.supporting_entry_index].record.concept_id)
            else
                null,
            .quality_score = record.quality_score,
            .confidence_score = record.confidence_score,
            .lookup_score = lookup_score,
            .direct_support_count = match.direct_support_count,
            .lineage_support_count = match.lineage_support_count,
            .token_support_count = match.token_support_count,
            .pattern_support_count = match.pattern_support_count,
            .source_support_count = match.source_support_count,
            .selection_mode = selection_mode,
            .consensus_hash = record.consensus_hash,
            .resolution = if (owner_kind == .core) .imported else .local,
        });
    }

    sortSupportReferences(out.items);
    trimSupportReferenceList(allocator, out, options.max_items);
}

fn collectGroundingLookup(
    allocator: std.mem.Allocator,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    live_records: []const Record,
    staged_records: []const Record,
    options: GroundingOptions,
    out: *std.ArrayList(SupportReference),
) !void {
    if (options.max_items == 0 or (options.tokens.len == 0 and options.patterns.len == 0 and options.rel_paths.len == 0)) return;

    var entries = std.ArrayList(CatalogEntry).init(allocator);
    defer entries.deinit();
    for (live_records) |*record| try entries.append(.{ .record = record, .staged = false });
    for (staged_records) |*record| try entries.append(.{ .record = record, .staged = true });

    var matches = std.ArrayList(MatchAccumulator).init(allocator);
    defer matches.deinit();

    for (entries.items, 0..) |entry, entry_index| {
        const source_support_count = countSupportMatches(entry.record.sources, options.rel_paths);
        const token_support_count = countTextMatches(entry.record.tokens, options.tokens);
        const pattern_support_count = countTextMatches(entry.record.patterns, options.patterns);
        const structured_support_count = countRecordStructuredSignalMatches(entry.record, options.tokens, options.patterns);
        if (!groundingEligible(entry.record, token_support_count, pattern_support_count + structured_support_count, source_support_count, 0)) continue;

        const source_spec = preferredGroundingSource(entry.record.sources) orelse continue;
        const direct_support_count = computeGroundingSupportWeight(token_support_count, pattern_support_count + structured_support_count, source_support_count);
        try upsertMatch(&matches, .{
            .entry_index = entry_index,
            .source_spec = source_spec,
            .direct_support_count = direct_support_count,
            .lineage_support_count = direct_support_count,
            .token_support_count = token_support_count,
            .pattern_support_count = pattern_support_count,
            .structured_support_count = structured_support_count,
            .source_support_count = source_support_count,
            .depth = 0,
            .supporting_entry_index = entry_index,
        });

        var parent_id = entry.record.parent_concept_id;
        var depth: usize = 1;
        while (parent_id != null and depth <= MAX_PARENT_CHAIN_DEPTH) : (depth += 1) {
            const parent_index = findEntryIndex(entries.items, parent_id.?, entry.staged) orelse break;
            if (!groundingEligible(entries.items[parent_index].record, token_support_count, pattern_support_count + structured_support_count, source_support_count, @intCast(depth))) break;
            try upsertMatch(&matches, .{
                .entry_index = parent_index,
                .source_spec = source_spec,
                .direct_support_count = 0,
                .lineage_support_count = direct_support_count,
                .token_support_count = token_support_count,
                .pattern_support_count = pattern_support_count,
                .structured_support_count = structured_support_count,
                .source_support_count = source_support_count,
                .depth = @intCast(depth),
                .supporting_entry_index = entry_index,
            });
            parent_id = entries.items[parent_index].record.parent_concept_id;
        }
    }

    if (matches.items.len == 0) return;

    for (matches.items) |match| {
        const entry = entries.items[match.entry_index];
        const record = entry.record;
        const lookup_score = computeGroundingScore(record, match, options);
        const selection_mode: SelectionMode = if (match.depth == 0)
            .direct
        else if (record.promotion_ready)
            .promoted
        else
            .fallback;

        try out.append(.{
            .concept_id = try allocator.dupe(u8, record.concept_id),
            .family = record.family,
            .source_spec = try allocator.dupe(u8, match.source_spec),
            .staged = entry.staged,
            .tier = record.tier,
            .category = record.category,
            .trust_class = record.trust_class,
            .decay_state = record.decay_state,
            .owner_kind = owner_kind,
            .owner_id = try allocator.dupe(u8, owner_id),
            .lineage_id = try allocator.dupe(u8, record.lineage_id),
            .lineage_version = record.lineage_version,
            .parent_concept_id = if (record.parent_concept_id) |parent_concept_id| try allocator.dupe(u8, parent_concept_id) else null,
            .supporting_concept_id = if (match.depth != 0 and match.supporting_entry_index != std.math.maxInt(usize))
                try allocator.dupe(u8, entries.items[match.supporting_entry_index].record.concept_id)
            else
                null,
            .quality_score = record.quality_score,
            .confidence_score = record.confidence_score,
            .lookup_score = lookup_score,
            .direct_support_count = match.direct_support_count,
            .lineage_support_count = match.lineage_support_count,
            .token_support_count = match.token_support_count,
            .pattern_support_count = match.pattern_support_count,
            .source_support_count = match.source_support_count,
            .selection_mode = selection_mode,
            .consensus_hash = record.consensus_hash,
            .resolution = if (owner_kind == .core) .imported else .local,
        });
    }

    sortSupportReferences(out.items);
    trimSupportReferenceList(allocator, out, options.max_items);
}

fn countSupportMatches(sources: [][]u8, rel_paths: []const []const u8) u16 {
    var count: u16 = 0;
    for (sources) |source| {
        if (std.mem.startsWith(u8, source, "code_intel:last_result")) {
            count +|= 1;
            continue;
        }
        for (rel_paths) |rel_path| {
            if (rel_path.len == 0) continue;
            if (std.mem.indexOf(u8, source, rel_path) != null) {
                count +|= 1;
                break;
            }
        }
    }
    return count;
}

fn findReverseLinkRecord(
    paths: *const shards.Paths,
    local_live: []const Record,
    local_staged: []const Record,
    core_live: []const Record,
    pack_catalogs: []const MountedPackCatalog,
    ref: SupportReference,
) ?*const Record {
    if (ref.owner_kind == paths.metadata.kind and std.mem.eql(u8, ref.owner_id, paths.metadata.id)) {
        return findRecordByConceptId(local_live, local_staged, ref.concept_id, ref.staged);
    }
    if (ref.owner_kind == .core) {
        return findRecordByConceptId(core_live, &.{}, ref.concept_id, false);
    }
    for (pack_catalogs) |*catalog| {
        if (!std.mem.eql(u8, catalog.owner_id, ref.owner_id)) continue;
        return findRecordByConceptId(catalog.records, &.{}, ref.concept_id, false);
    }
    return null;
}

fn findRecordByConceptId(
    live_records: []const Record,
    staged_records: []const Record,
    concept_id: []const u8,
    prefer_staged: bool,
) ?*const Record {
    if (prefer_staged) {
        for (staged_records) |*record| {
            if (std.mem.eql(u8, record.concept_id, concept_id)) return record;
        }
    }
    for (live_records) |*record| {
        if (std.mem.eql(u8, record.concept_id, concept_id)) return record;
    }
    if (!prefer_staged) {
        for (staged_records) |*record| {
            if (std.mem.eql(u8, record.concept_id, concept_id)) return record;
        }
    }
    return null;
}

fn appendReverseLinksForRecord(
    allocator: std.mem.Allocator,
    ref: SupportReference,
    record: *const Record,
    rel_paths: []const []const u8,
    out: *std.ArrayList(ReverseLinkReference),
) !void {
    for (record.sources) |source| {
        if (!isReverseSymbolicSource(source, rel_paths)) continue;
        try out.append(.{
            .concept_id = try allocator.dupe(u8, ref.concept_id),
            .family = ref.family,
            .matched_source_spec = try allocator.dupe(u8, ref.source_spec),
            .symbolic_source_spec = try allocator.dupe(u8, source),
            .staged = ref.staged,
            .tier = ref.tier,
            .category = ref.category,
            .trust_class = ref.trust_class,
            .decay_state = ref.decay_state,
            .owner_kind = ref.owner_kind,
            .owner_id = try allocator.dupe(u8, ref.owner_id),
            .lineage_id = if (ref.lineage_id.len > 0) try allocator.dupe(u8, ref.lineage_id) else &.{},
            .lineage_version = ref.lineage_version,
            .parent_concept_id = if (ref.parent_concept_id) |parent_concept_id| try allocator.dupe(u8, parent_concept_id) else null,
            .supporting_concept_id = if (ref.supporting_concept_id) |supporting_concept_id| try allocator.dupe(u8, supporting_concept_id) else null,
            .quality_score = ref.quality_score,
            .confidence_score = ref.confidence_score,
            .lookup_score = ref.lookup_score,
            .direct_support_count = ref.direct_support_count,
            .lineage_support_count = ref.lineage_support_count,
            .token_support_count = ref.token_support_count,
            .pattern_support_count = ref.pattern_support_count,
            .source_support_count = ref.source_support_count,
            .selection_mode = ref.selection_mode,
            .consensus_hash = ref.consensus_hash,
            .usable = ref.usable,
            .resolution = ref.resolution,
            .conflict_kind = ref.conflict_kind,
            .conflict_concept_id = if (ref.conflict_concept_id) |conflict_concept_id| try allocator.dupe(u8, conflict_concept_id) else null,
            .conflict_owner_kind = ref.conflict_owner_kind,
            .conflict_owner_id = if (ref.conflict_owner_id) |conflict_owner_id| try allocator.dupe(u8, conflict_owner_id) else null,
            .pack_outcome = ref.pack_outcome,
            .pack_conflict_category = ref.pack_conflict_category,
        });
    }
}

fn isReverseSymbolicSource(source_spec: []const u8, rel_paths: []const []const u8) bool {
    if (std.mem.startsWith(u8, source_spec, "code_intel:last_result")) return false;
    const rel_path = reverseSourceRelPath(source_spec) orelse return false;
    for (rel_paths) |rel_path_match| {
        if (rel_path_match.len == 0) continue;
        if (std.mem.indexOf(u8, source_spec, rel_path_match) != null or std.mem.eql(u8, rel_path, rel_path_match)) return false;
    }
    return isSymbolicSurfacePath(rel_path);
}

fn reverseSourceRelPath(source_spec: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, source_spec, "file:")) {
        const rel_path = std.mem.trim(u8, source_spec["file:".len..], " \r\n\t");
        return if (rel_path.len == 0) null else rel_path;
    }
    if (std.mem.startsWith(u8, source_spec, "region:")) {
        const payload = source_spec["region:".len..];
        const colon = std.mem.lastIndexOfScalar(u8, payload, ':') orelse return null;
        const rel_path = payload[0..colon];
        return if (rel_path.len == 0) null else rel_path;
    }
    return null;
}

fn isSymbolicSurfacePath(rel_path: []const u8) bool {
    return std.mem.endsWith(u8, rel_path, ".md") or
        std.mem.endsWith(u8, rel_path, ".txt") or
        std.mem.endsWith(u8, rel_path, ".rst") or
        std.mem.endsWith(u8, rel_path, ".html") or
        std.mem.endsWith(u8, rel_path, ".xml") or
        std.mem.endsWith(u8, rel_path, ".toml") or
        std.mem.endsWith(u8, rel_path, ".yaml") or
        std.mem.endsWith(u8, rel_path, ".yml") or
        std.mem.endsWith(u8, rel_path, ".json") or
        std.mem.endsWith(u8, rel_path, ".ini") or
        std.mem.endsWith(u8, rel_path, ".cfg") or
        std.mem.endsWith(u8, rel_path, ".conf") or
        std.mem.endsWith(u8, rel_path, ".env") or
        std.mem.endsWith(u8, rel_path, ".tf") or
        std.mem.endsWith(u8, rel_path, ".tfvars") or
        std.mem.endsWith(u8, rel_path, ".tpl") or
        std.mem.endsWith(u8, rel_path, ".rules") or
        std.mem.endsWith(u8, rel_path, ".dsl") or
        std.mem.endsWith(u8, rel_path, ".test") or
        std.mem.endsWith(u8, rel_path, ".spec");
}

fn upsertMatch(matches: *std.ArrayList(MatchAccumulator), next: MatchAccumulator) !void {
    for (matches.items) |*match| {
        if (match.entry_index != next.entry_index) continue;
        match.direct_support_count +|= next.direct_support_count;
        match.lineage_support_count +|= next.lineage_support_count;
        match.token_support_count = @max(match.token_support_count, next.token_support_count);
        match.pattern_support_count = @max(match.pattern_support_count, next.pattern_support_count);
        match.structured_support_count = @max(match.structured_support_count, next.structured_support_count);
        match.source_support_count = @max(match.source_support_count, next.source_support_count);
        if (next.depth < match.depth) {
            match.depth = next.depth;
            match.source_spec = next.source_spec;
            match.supporting_entry_index = next.supporting_entry_index;
        }
        return;
    }
    try matches.append(next);
}

fn findEntryIndex(entries: []const CatalogEntry, concept_id: []const u8, preferred_staged: bool) ?usize {
    var fallback: ?usize = null;
    for (entries, 0..) |entry, idx| {
        if (!std.mem.eql(u8, entry.record.concept_id, concept_id)) continue;
        if (entry.staged == preferred_staged) return idx;
        if (fallback == null) fallback = idx;
    }
    return fallback;
}

fn lookupEligible(record: *const Record, match: MatchAccumulator) bool {
    if (record.family != .distilled and !reinforcementUsable(record)) return false;
    const support_hits = @max(match.direct_support_count, match.lineage_support_count);
    if (support_hits == 0) return false;
    if (match.depth == 0) return true;
    return record.promotion_ready and
        record.quality_score >= tierQualityFloor(record.tier) and
        record.confidence_score >= tierConfidenceFloor(record.tier) and
        support_hits >= tierPromotionSupportFloor(record.tier);
}

fn computeLookupScore(record: *const Record, match: MatchAccumulator, options: LookupOptions) u16 {
    var score: u32 = @as(u32, record.quality_score) / 2;
    score += @as(u32, record.confidence_score) / 3;
    score += @as(u32, record.reuse_score) / 3;
    score += @as(u32, match.direct_support_count) * 120;
    score += @as(u32, match.lineage_support_count) * 80;
    score += @as(u32, match.token_support_count) * 60;
    score += @as(u32, match.pattern_support_count) * 95;
    score += @as(u32, match.structured_support_count) * 180;
    if (options.prefer_higher_tiers) score += @as(u32, tierRank(record.tier)) * 60;
    if (options.category_hint) |category_hint| {
        if (category_hint == record.category) score += 50;
    }
    if (match.depth > 0) score = score -| @as(u32, match.depth) * 25;
    return @intCast(@min(score, @as(u32, MAX_SCORE)));
}

fn preferredGroundingSource(sources: [][]u8) ?[]const u8 {
    for (sources) |source| {
        if (std.mem.startsWith(u8, source, "file:")) return source;
        if (std.mem.startsWith(u8, source, "region:")) return source;
    }
    if (sources.len == 0) return null;
    return sources[0];
}

fn countTextMatches(candidates: [][]u8, needles: []const []const u8) u16 {
    var count: u16 = 0;
    for (candidates) |candidate| {
        for (needles) |needle| {
            if (needle.len == 0) continue;
            if (!std.mem.eql(u8, candidate, needle)) continue;
            count +|= 1;
            break;
        }
    }
    return count;
}

fn countRecordStructuredSignalMatches(record: *const Record, tokens: []const []const u8, patterns: []const []const u8) u16 {
    var count: u16 = 0;
    count +|= countTextMatches(record.anchor_signals, tokens);
    count +|= countTextMatches(record.anchor_signals, patterns);
    count +|= countTextMatches(record.schema_entity_signals, tokens);
    count +|= countTextMatches(record.schema_entity_signals, patterns);
    count +|= countTextMatches(record.schema_relation_signals, tokens);
    count +|= countTextMatches(record.schema_relation_signals, patterns);
    count +|= countTextMatches(record.obligation_signals, tokens);
    count +|= countTextMatches(record.obligation_signals, patterns);
    count +|= countTextMatches(record.verifier_hint_signals, tokens);
    count +|= countTextMatches(record.verifier_hint_signals, patterns);
    count +|= countTextMatches(record.schema_signals, tokens);
    count +|= countTextMatches(record.schema_signals, patterns);
    return count;
}

fn computeGroundingSupportWeight(token_hits: u16, pattern_hits: u16, source_hits: u16) u16 {
    var total: u16 = 0;
    total +|= token_hits;
    total +|= pattern_hits * 2;
    total +|= source_hits;
    return total;
}

fn groundingEligible(record: *const Record, token_hits: u16, pattern_hits: u16, source_hits: u16, depth: u8) bool {
    if (record.family != .distilled and !reinforcementUsable(record)) return false;
    const support_hits = computeGroundingSupportWeight(token_hits, pattern_hits, source_hits);
    if (support_hits == 0) return false;
    if (depth == 0) {
        return pattern_hits > 0 or
            token_hits >= 2 or
            (source_hits > 0 and token_hits > 0);
    }
    return support_hits >= 3;
}

fn computeGroundingScore(record: *const Record, match: MatchAccumulator, options: GroundingOptions) u16 {
    var score: u32 = @as(u32, record.quality_score) / 2;
    score += @as(u32, record.confidence_score) / 3;
    score += @as(u32, record.reuse_score) / 4;
    score += @as(u32, match.token_support_count) * 90;
    score += @as(u32, match.pattern_support_count) * 150;
    score += @as(u32, match.structured_support_count) * 240;
    score += @as(u32, match.source_support_count) * 45;
    if (options.prefer_higher_tiers) score += @as(u32, tierRank(record.tier)) * 60;
    if (options.category_hint) |category_hint| {
        if (category_hint == record.category) score += 50;
    }
    if (match.depth > 0) score = score -| @as(u32, match.depth) * 25;
    return @intCast(@min(score, @as(u32, MAX_SCORE)));
}

fn sortSupportReferences(items: []SupportReference) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and lessSupportReference(items[j], items[j - 1])) : (j -= 1) {
            const tmp = items[j - 1];
            items[j - 1] = items[j];
            items[j] = tmp;
        }
    }
}

fn lessSupportReference(a: SupportReference, b: SupportReference) bool {
    if (a.usable != b.usable) return a.usable;
    if (a.decay_state != b.decay_state) return decayRank(a.decay_state) < decayRank(b.decay_state);
    if (a.trust_class != b.trust_class) return trustRank(a.trust_class, DEFAULT_TRUST_POLICY) > trustRank(b.trust_class, DEFAULT_TRUST_POLICY);
    if (a.lookup_score != b.lookup_score) return a.lookup_score > b.lookup_score;
    if (tierRank(a.tier) != tierRank(b.tier)) return tierRank(a.tier) > tierRank(b.tier);
    if (a.direct_support_count != b.direct_support_count) return a.direct_support_count > b.direct_support_count;
    if (a.lineage_support_count != b.lineage_support_count) return a.lineage_support_count > b.lineage_support_count;
    if (a.staged != b.staged) return a.staged;
    if (a.owner_kind != b.owner_kind) return @intFromEnum(a.owner_kind) < @intFromEnum(b.owner_kind);
    return std.mem.order(u8, a.concept_id, b.concept_id) == .lt;
}

fn sortReverseLinkReferences(items: []ReverseLinkReference) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and lessReverseLinkReference(items[j], items[j - 1])) : (j -= 1) {
            const tmp = items[j - 1];
            items[j - 1] = items[j];
            items[j] = tmp;
        }
    }
}

fn lessReverseLinkReference(a: ReverseLinkReference, b: ReverseLinkReference) bool {
    if (a.usable != b.usable) return a.usable;
    if (a.decay_state != b.decay_state) return decayRank(a.decay_state) < decayRank(b.decay_state);
    if (a.trust_class != b.trust_class) return trustRank(a.trust_class, DEFAULT_TRUST_POLICY) > trustRank(b.trust_class, DEFAULT_TRUST_POLICY);
    if (a.lookup_score != b.lookup_score) return a.lookup_score > b.lookup_score;
    if (tierRank(a.tier) != tierRank(b.tier)) return tierRank(a.tier) > tierRank(b.tier);
    if (a.direct_support_count != b.direct_support_count) return a.direct_support_count > b.direct_support_count;
    if (a.lineage_support_count != b.lineage_support_count) return a.lineage_support_count > b.lineage_support_count;
    if (reverseSourceRank(a.symbolic_source_spec) != reverseSourceRank(b.symbolic_source_spec)) return reverseSourceRank(a.symbolic_source_spec) > reverseSourceRank(b.symbolic_source_spec);
    if (a.staged != b.staged) return a.staged;
    if (a.owner_kind != b.owner_kind) return @intFromEnum(a.owner_kind) < @intFromEnum(b.owner_kind);
    const concept_order = std.mem.order(u8, a.concept_id, b.concept_id);
    if (concept_order != .eq) return concept_order == .lt;
    return std.mem.order(u8, a.symbolic_source_spec, b.symbolic_source_spec) == .lt;
}

fn reverseSourceRank(source_spec: []const u8) u8 {
    if (std.mem.startsWith(u8, source_spec, "region:")) return 2;
    if (std.mem.startsWith(u8, source_spec, "file:")) return 1;
    return 0;
}

fn trimSupportReferenceList(allocator: std.mem.Allocator, out: *std.ArrayList(SupportReference), max_items: usize) void {
    if (out.items.len <= max_items) return;
    var idx = max_items;
    while (idx < out.items.len) : (idx += 1) {
        deinitSupportReferenceItem(allocator, out.items[idx]);
    }
    out.items.len = max_items;
}

fn trimReverseLinkReferenceList(allocator: std.mem.Allocator, out: *std.ArrayList(ReverseLinkReference), max_items: usize) void {
    if (out.items.len <= max_items) return;
    var idx = max_items;
    while (idx < out.items.len) : (idx += 1) {
        deinitReverseLinkReferenceItem(allocator, out.items[idx]);
    }
    out.items.len = max_items;
}

fn deinitSupportReferenceItem(allocator: std.mem.Allocator, item: SupportReference) void {
    allocator.free(item.concept_id);
    allocator.free(item.source_spec);
    allocator.free(item.owner_id);
    if (item.lineage_id.len > 0) allocator.free(item.lineage_id);
    if (item.parent_concept_id) |parent_concept_id| allocator.free(parent_concept_id);
    if (item.supporting_concept_id) |supporting_concept_id| allocator.free(supporting_concept_id);
    if (item.conflict_concept_id) |conflict_concept_id| allocator.free(conflict_concept_id);
    if (item.conflict_owner_id) |conflict_owner_id| allocator.free(conflict_owner_id);
}

fn deinitReverseLinkReferenceItem(allocator: std.mem.Allocator, item: ReverseLinkReference) void {
    allocator.free(item.concept_id);
    allocator.free(item.matched_source_spec);
    allocator.free(item.symbolic_source_spec);
    allocator.free(item.owner_id);
    if (item.lineage_id.len > 0) allocator.free(item.lineage_id);
    if (item.parent_concept_id) |parent_concept_id| allocator.free(parent_concept_id);
    if (item.supporting_concept_id) |supporting_concept_id| allocator.free(supporting_concept_id);
    if (item.conflict_concept_id) |conflict_concept_id| allocator.free(conflict_concept_id);
    if (item.conflict_owner_id) |conflict_owner_id| allocator.free(conflict_owner_id);
}

fn cloneSupportReference(allocator: std.mem.Allocator, item: SupportReference) !SupportReference {
    return .{
        .concept_id = try allocator.dupe(u8, item.concept_id),
        .family = item.family,
        .source_spec = try allocator.dupe(u8, item.source_spec),
        .staged = item.staged,
        .tier = item.tier,
        .category = item.category,
        .trust_class = item.trust_class,
        .decay_state = item.decay_state,
        .owner_kind = item.owner_kind,
        .owner_id = try allocator.dupe(u8, item.owner_id),
        .lineage_id = if (item.lineage_id.len > 0) try allocator.dupe(u8, item.lineage_id) else &.{},
        .lineage_version = item.lineage_version,
        .parent_concept_id = if (item.parent_concept_id) |parent_concept_id| try allocator.dupe(u8, parent_concept_id) else null,
        .supporting_concept_id = if (item.supporting_concept_id) |supporting_concept_id| try allocator.dupe(u8, supporting_concept_id) else null,
        .quality_score = item.quality_score,
        .confidence_score = item.confidence_score,
        .lookup_score = item.lookup_score,
        .direct_support_count = item.direct_support_count,
        .lineage_support_count = item.lineage_support_count,
        .token_support_count = item.token_support_count,
        .pattern_support_count = item.pattern_support_count,
        .source_support_count = item.source_support_count,
        .selection_mode = item.selection_mode,
        .consensus_hash = item.consensus_hash,
        .usable = item.usable,
        .reuse_decision = item.reuse_decision,
        .resolution = item.resolution,
        .conflict_kind = item.conflict_kind,
        .conflict_concept_id = if (item.conflict_concept_id) |conflict_concept_id| try allocator.dupe(u8, conflict_concept_id) else null,
        .conflict_owner_kind = item.conflict_owner_kind,
        .conflict_owner_id = if (item.conflict_owner_id) |conflict_owner_id| try allocator.dupe(u8, conflict_owner_id) else null,
        .pack_outcome = item.pack_outcome,
        .pack_conflict_category = item.pack_conflict_category,
    };
}

fn mergeCrossShardSupport(
    allocator: std.mem.Allocator,
    local_refs: []const SupportReference,
    core_refs: []const SupportReference,
    live_reuse: []const ReuseEntry,
    staged_reuse: []const ReuseEntry,
    out: *std.ArrayList(SupportReference),
) !void {
    for (local_refs) |local_ref| {
        var next = try cloneSupportReference(allocator, local_ref);
        if (findSupportReference(core_refs, local_ref.concept_id)) |core_ref| {
            if (!supportReferenceCompatible(local_ref, core_ref)) {
                next.resolution = .local_override;
                next.conflict_kind = .incompatible;
                next.conflict_concept_id = try allocator.dupe(u8, core_ref.concept_id);
                next.conflict_owner_kind = core_ref.owner_kind;
                next.conflict_owner_id = try allocator.dupe(u8, core_ref.owner_id);
                if (findMatchingReuseDecision(staged_reuse, .promote, core_ref, local_ref) != null or
                    findMatchingReuseDecision(live_reuse, .promote, core_ref, local_ref) != null)
                {
                    next.reuse_decision = .promote;
                }
            }
        }
        try out.append(next);
    }

    for (core_refs) |core_ref| {
        if (findSupportReference(local_refs, core_ref.concept_id)) |local_ref| {
            if (supportReferenceCompatible(local_ref, core_ref)) continue;

            var refused = try cloneSupportReference(allocator, core_ref);
            refused.usable = false;
            refused.resolution = .conflict_refused;
            refused.conflict_kind = .incompatible;
            refused.conflict_concept_id = try allocator.dupe(u8, local_ref.concept_id);
            refused.conflict_owner_kind = local_ref.owner_kind;
            refused.conflict_owner_id = try allocator.dupe(u8, local_ref.owner_id);
            try out.append(refused);
            continue;
        }

        var imported = try cloneSupportReference(allocator, core_ref);
        if (findMatchingReuseDecision(staged_reuse, .reject, core_ref, null) != null or
            findMatchingReuseDecision(live_reuse, .reject, core_ref, null) != null)
        {
            imported.usable = false;
            imported.reuse_decision = .reject;
            imported.resolution = .rejected;
            imported.conflict_kind = .explicit_reject;
        } else if (findMatchingReuseDecision(staged_reuse, .adopt, core_ref, null) != null or
            findMatchingReuseDecision(live_reuse, .adopt, core_ref, null) != null)
        {
            imported.reuse_decision = .adopt;
            imported.resolution = .adopted;
        }
        try out.append(imported);
    }

    sortSupportReferences(out.items);
}

fn mergeMountedPackGroundingReferences(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    options: GroundingOptions,
    out: *std.ArrayList(SupportReference),
) !void {
    if (paths.metadata.kind != .project) return;
    const catalogs = try loadMountedPackCatalogs(allocator, paths, options.rel_paths, options.tokens, options.patterns, options.pack_routing_stage, options.pack_routing_caps, options.pack_conflict_policy, options.pack_routing);
    defer {
        for (catalogs) |*catalog| catalog.deinit();
        allocator.free(catalogs);
    }

    var pack_refs = std.ArrayList(SupportReference).init(allocator);
    defer {
        for (pack_refs.items) |item| deinitSupportReferenceItem(allocator, item);
        pack_refs.deinit();
    }
    for (catalogs) |*catalog| {
        try collectGroundingLookup(allocator, .project, catalog.owner_id, catalog.records, &.{}, options, &pack_refs);
    }
    try appendResolvedPackReferences(allocator, out, pack_refs.items, options.pack_routing_stage, options.pack_routing, options.pack_conflict_policy, options.pack_routing_caps.max_candidate_surfaces_per_query);
}

fn mergeMountedPackSupportReferences(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    options: LookupOptions,
    out: *std.ArrayList(SupportReference),
) !void {
    if (paths.metadata.kind != .project) return;
    const catalogs = try loadMountedPackCatalogs(allocator, paths, options.rel_paths, options.tokens, options.patterns, options.pack_routing_stage, options.pack_routing_caps, options.pack_conflict_policy, options.pack_routing);
    defer {
        for (catalogs) |*catalog| catalog.deinit();
        allocator.free(catalogs);
    }

    var pack_refs = std.ArrayList(SupportReference).init(allocator);
    defer {
        for (pack_refs.items) |item| deinitSupportReferenceItem(allocator, item);
        pack_refs.deinit();
    }
    for (catalogs) |*catalog| {
        try collectSupportLookup(allocator, .project, catalog.owner_id, catalog.records, &.{}, options, &pack_refs);
    }
    try appendResolvedPackReferences(allocator, out, pack_refs.items, options.pack_routing_stage, options.pack_routing, options.pack_conflict_policy, options.pack_routing_caps.max_candidate_surfaces_per_query);
}

fn mergeMountedPackFamilyReferences(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    options: FamilyLookupOptions,
    out: *std.ArrayList(SupportReference),
) !void {
    if (paths.metadata.kind != .project) return;
    const catalogs = try loadMountedPackCatalogs(allocator, paths, options.rel_paths, options.tokens, options.patterns, options.pack_routing_stage, options.pack_routing_caps, options.pack_conflict_policy, options.pack_routing);
    defer {
        for (catalogs) |*catalog| catalog.deinit();
        allocator.free(catalogs);
    }

    var pack_refs = std.ArrayList(SupportReference).init(allocator);
    defer {
        for (pack_refs.items) |item| deinitSupportReferenceItem(allocator, item);
        pack_refs.deinit();
    }
    for (catalogs) |*catalog| {
        try collectFamilyLookup(allocator, .project, catalog.owner_id, catalog.records, false, options, &pack_refs);
    }
    try appendResolvedPackReferences(allocator, out, pack_refs.items, options.pack_routing_stage, options.pack_routing, options.pack_conflict_policy, options.pack_routing_caps.max_candidate_surfaces_per_query);
}

fn appendResolvedPackReferences(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(SupportReference),
    pack_refs: []const SupportReference,
    stage: PackRoutingStage,
    collector: ?*PackRoutingCollector,
    policy: PackConflictPolicy,
    max_candidate_surfaces: usize,
) !void {
    var ordered_refs = std.ArrayList(SupportReference).init(allocator);
    defer ordered_refs.deinit();
    try ordered_refs.resize(pack_refs.len);
    for (pack_refs, 0..) |item, idx| ordered_refs.items[idx] = item;
    sortSupportReferences(ordered_refs.items);

    var kept = std.ArrayList(bool).init(allocator);
    defer kept.deinit();
    try kept.resize(ordered_refs.items.len);
    @memset(kept.items, false);

    var surfaces_left = max_candidate_surfaces;
    for (ordered_refs.items, 0..) |_, idx| {
        if (surfaces_left == 0) break;
        kept.items[idx] = true;
        surfaces_left -= 1;
    }

    if (collector) |value| {
        var idx: usize = 0;
        while (idx < ordered_refs.items.len) : (idx += 1) {
            const owner_id = ordered_refs.items[idx].owner_id;
            var kept_count: usize = 0;
            var suppressed_count: usize = 0;
            var cursor = idx;
            while (cursor < ordered_refs.items.len and std.mem.eql(u8, ordered_refs.items[cursor].owner_id, owner_id)) : (cursor += 1) {
                if (kept.items[cursor]) kept_count += 1 else suppressed_count += 1;
            }
            value.noteCandidateSurfaces(stage, owner_id, kept_count, suppressed_count);
            idx = cursor - 1;
        }
    }

    for (ordered_refs.items, 0..) |pack_ref, idx| {
        if (!kept.items[idx]) continue;
        var next = try cloneSupportReference(allocator, pack_ref);
        errdefer deinitSupportReferenceItem(allocator, next);
        next.resolution = .imported;
        next.reuse_decision = .adopt;
        next.pack_outcome = .activated;

        if (findHigherTrustConceptCompetitor(ordered_refs.items, idx)) |conflict| {
            next.usable = false;
            next.resolution = .conflict_refused;
            next.conflict_kind = .incompatible;
            next.conflict_concept_id = try allocator.dupe(u8, conflict.concept_id);
            next.conflict_owner_kind = conflict.owner_kind;
            next.conflict_owner_id = try allocator.dupe(u8, conflict.owner_id);
            next.pack_outcome = .trust_blocked;
            next.pack_conflict_category = .trust_mismatch;
            if (collector) |value| value.noteConflict(stage, next.owner_id, .trust_blocked, .trust_mismatch, false);
        } else if (policy.competition == .deterministic_winner) {
            if (findEarlierConflictingPackReference(ordered_refs.items, idx)) |conflict| {
                next.usable = false;
                next.resolution = .conflict_refused;
                next.conflict_kind = .incompatible;
                next.conflict_concept_id = try allocator.dupe(u8, conflict.concept_id);
                next.conflict_owner_kind = conflict.owner_kind;
                next.conflict_owner_id = try allocator.dupe(u8, conflict.owner_id);
                next.pack_outcome = .suppressed;
                next.pack_conflict_category = .same_concept_incompatible;
                if (collector) |value| value.noteConflict(stage, next.owner_id, .suppressed, .same_concept_incompatible, false);
            }
        } else if (findConflictingPackReference(ordered_refs.items, idx)) |conflict| {
            next.usable = false;
            next.resolution = .conflict_refused;
            next.conflict_kind = .incompatible;
            next.conflict_concept_id = try allocator.dupe(u8, conflict.concept_id);
            next.conflict_owner_kind = conflict.owner_kind;
            next.conflict_owner_id = try allocator.dupe(u8, conflict.owner_id);
            next.pack_outcome = .conflict_refused;
            next.pack_conflict_category = .same_concept_incompatible;
            if (collector) |value| value.noteConflict(stage, next.owner_id, .conflict_refused, .same_concept_incompatible, false);
        } else if (findSupportReference(out.items, pack_ref.concept_id)) |existing| {
            if (!supportReferenceCompatible(existing, pack_ref)) {
                next.usable = false;
                next.resolution = .conflict_refused;
                next.conflict_kind = .incompatible;
                next.conflict_concept_id = try allocator.dupe(u8, existing.concept_id);
                next.conflict_owner_kind = existing.owner_kind;
                next.conflict_owner_id = try allocator.dupe(u8, existing.owner_id);
                next.pack_outcome = .conflict_refused;
                next.pack_conflict_category = .same_concept_incompatible;
                if (collector) |value| value.noteConflict(stage, next.owner_id, .conflict_refused, .same_concept_incompatible, existing.owner_kind != .project or !std.mem.startsWith(u8, existing.owner_id, "pack/"));
            }
        }

        try out.append(next);
    }
    sortSupportReferences(out.items);
}

fn findConflictingPackReference(items: []const SupportReference, idx: usize) ?SupportReference {
    const needle = items[idx];
    for (items, 0..) |item, other_idx| {
        if (other_idx == idx) continue;
        if (!std.mem.eql(u8, item.concept_id, needle.concept_id)) continue;
        if (supportReferenceCompatible(item, needle)) continue;
        return item;
    }
    return null;
}

fn findHigherTrustConceptCompetitor(items: []const SupportReference, idx: usize) ?SupportReference {
    const needle = items[idx];
    for (items, 0..) |item, other_idx| {
        if (other_idx == idx) continue;
        if (!std.mem.eql(u8, item.concept_id, needle.concept_id)) continue;
        if (supportReferenceCompatible(item, needle)) continue;
        if (trustRank(item.trust_class, DEFAULT_TRUST_POLICY) > trustRank(needle.trust_class, DEFAULT_TRUST_POLICY)) return item;
    }
    return null;
}

fn findEarlierConflictingPackReference(items: []const SupportReference, idx: usize) ?SupportReference {
    const needle = items[idx];
    for (items[0..idx]) |item| {
        if (!std.mem.eql(u8, item.concept_id, needle.concept_id)) continue;
        if (supportReferenceCompatible(item, needle)) continue;
        return item;
    }
    return null;
}

fn routeMountedPacks(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    rel_paths: []const []const u8,
    tokens: []const []const u8,
    patterns: []const []const u8,
    stage: PackRoutingStage,
    caps: PackRoutingCaps,
    policy: PackConflictPolicy,
    call_id: u16,
) !RoutedMountLoad {
    const started = sys.getMilliTick();
    defer lookup_profile.pack_mount_resolve_ms += sys.getMilliTick() - started;
    if (paths.metadata.kind != .project) {
        return .{
            .mounts = try allocator.alloc(knowledge_pack_store.ResolvedMount, 0),
            .traces = try allocator.alloc(PackRoutingTrace, 0),
        };
    }

    const manifest_started = sys.getMilliTick();
    const mounts = try knowledge_pack_store.listResolvedMounts(allocator, paths);
    lookup_profile.pack_manifest_preview_load_ms += sys.getMilliTick() - manifest_started;
    errdefer {
        for (mounts) |*mount| mount.deinit();
        allocator.free(mounts);
    }

    const routing_started = sys.getMilliTick();
    var candidates = try allocator.alloc(MountedPackCandidate, mounts.len);
    defer allocator.free(candidates);
    for (mounts, 0..) |*mount, idx| {
        candidates[idx] = scoreMountedPack(mount, rel_paths, tokens, patterns);
        candidates[idx].mount_index = idx;
    }
    sortMountedPackCandidates(candidates);

    var traces = std.ArrayList(PackRoutingTrace).init(allocator);
    errdefer {
        for (traces.items) |*trace| trace.deinit();
        traces.deinit();
    }

    var active_mounts = std.ArrayList(knowledge_pack_store.ResolvedMount).init(allocator);
    errdefer {
        for (active_mounts.items) |*mount| mount.deinit();
        active_mounts.deinit();
    }
    var moved = try allocator.alloc(bool, mounts.len);
    defer allocator.free(moved);
    @memset(moved, false);

    var considered_rank: u16 = 0;
    var activation_rank: u16 = 0;
    var considered_used: usize = 0;
    var activated_used: usize = 0;

    for (candidates, 0..) |candidate, candidate_idx| {
        const mount = &mounts[candidate.mount_index];
        var status: PackRoutingStatus = .skipped;
        var reason = candidate.reason;
        var considered_for_budget = false;
        var activated = false;
        var trace_candidate = candidate;

        if (trace_candidate.freshness_state == .stale) {
            status = .stale_blocked;
            trace_candidate.conflict_category = .stale_pack;
            reason = "stale pack was blocked by conservative freshness policy";
        } else if (trace_candidate.compatible and trace_candidate.eligible) {
            if (findHigherTrustAnchorCompetitor(candidates, candidate_idx)) |_| {
                status = .trust_blocked;
                trace_candidate.conflict_category = .trust_mismatch;
                reason = "lower-trust pack lost to a higher-trust competing pack on the same anchor";
            } else if (findEarlierAnchorPeer(candidates, candidate_idx)) |_| {
                switch (policy.competition) {
                    .refuse_all_competing, .prefer_higher_trust_only => {
                        status = .conflict_refused;
                        trace_candidate.conflict_category = .same_anchor_competing;
                        reason = "competing packs matched the same anchor and conservative policy refused them";
                    },
                    .deterministic_winner => {
                        status = .suppressed;
                        trace_candidate.conflict_category = .same_anchor_competing;
                        reason = "deterministic policy selected an earlier competing pack as the single winner";
                    },
                }
            } else if ((policy.competition == .refuse_all_competing or policy.competition == .prefer_higher_trust_only) and
                findLaterEqualTrustAnchorPeer(candidates, candidate_idx) != null)
            {
                status = .conflict_refused;
                trace_candidate.conflict_category = .same_anchor_competing;
                reason = "competing packs matched the same anchor and conservative policy refused them";
            } else if (considered_used >= caps.max_considered_per_query) {
                status = .suppressed;
                reason = "pack preselection cap reached before this eligible mount could be considered";
            } else {
                considered_used += 1;
                considered_rank += 1;
                considered_for_budget = true;
                if (activated_used >= caps.max_activated_per_query) {
                    status = .suppressed;
                    reason = "pack activation cap reached after higher-ranked mounts were selected";
                } else {
                    activated_used += 1;
                    activation_rank += 1;
                    status = .activated;
                    activated = true;
                    reason = if (findLaterAnchorPeer(candidates, candidate_idx) != null and policy.competition == .deterministic_winner)
                        "deterministic policy chose a single competing pack winner by stable rank"
                    else
                        "deterministic pack route activated by bounded anchor match";
                }
            }
        } else if (!trace_candidate.compatible) {
            status = .suppressed;
            if (trace_candidate.conflict_category == .none) trace_candidate.conflict_category = .incompatible_pack_family;
            reason = "pack metadata was incompatible with deterministic Linux-first routing";
        } else if (!mount.entry.enabled) {
            status = .suppressed;
            reason = "pack is mounted but disabled";
        } else if (trace_candidate.eligible) {
            if (considered_used >= caps.max_considered_per_query) {
                status = .suppressed;
            }
        }

        try traces.append(try makePackRoutingTrace(
            allocator,
            stage,
            mount.entry.pack_id,
            mount.entry.pack_version,
            status,
            reason,
            policy,
            trace_candidate,
            call_id,
            if (considered_for_budget) considered_rank else 0,
            if (activated) activation_rank else 0,
        ));

        if (!activated) continue;
        try active_mounts.append(mount.*);
        moved[candidate.mount_index] = true;
    }

    for (mounts, 0..) |*mount, idx| {
        if (moved[idx]) continue;
        mount.deinit();
    }
    allocator.free(mounts);

    lookup_profile.pack_routing_ms += sys.getMilliTick() - routing_started;
    return .{
        .mounts = try active_mounts.toOwnedSlice(),
        .traces = try traces.toOwnedSlice(),
    };
}

fn candidatesShareAnchor(a: MountedPackCandidate, b: MountedPackCandidate) bool {
    if (!a.compatible or !b.compatible or !a.eligible or !b.eligible) return false;
    return a.path_hits == b.path_hits and
        a.symbol_hits == b.symbol_hits and
        a.domain_hits == b.domain_hits and
        a.file_family_hits == b.file_family_hits;
}

fn findHigherTrustAnchorCompetitor(items: []const MountedPackCandidate, idx: usize) ?MountedPackCandidate {
    const needle = items[idx];
    for (items, 0..) |item, item_idx| {
        if (item_idx == idx) continue;
        if (item.freshness_state != .active) continue;
        if (!candidatesShareAnchor(item, needle)) continue;
        if (trustRank(item.trust_class, DEFAULT_TRUST_POLICY) > trustRank(needle.trust_class, DEFAULT_TRUST_POLICY)) return item;
    }
    return null;
}

fn findEarlierAnchorPeer(items: []const MountedPackCandidate, idx: usize) ?MountedPackCandidate {
    const needle = items[idx];
    for (items[0..idx]) |item| {
        if (item.freshness_state != .active) continue;
        if (!candidatesShareAnchor(item, needle)) continue;
        if (trustRank(item.trust_class, DEFAULT_TRUST_POLICY) < trustRank(needle.trust_class, DEFAULT_TRUST_POLICY)) continue;
        return item;
    }
    return null;
}

fn findLaterAnchorPeer(items: []const MountedPackCandidate, idx: usize) ?MountedPackCandidate {
    const needle = items[idx];
    for (items[idx + 1 ..]) |item| {
        if (item.freshness_state != .active) continue;
        if (candidatesShareAnchor(item, needle)) return item;
    }
    return null;
}

fn findLaterEqualTrustAnchorPeer(items: []const MountedPackCandidate, idx: usize) ?MountedPackCandidate {
    const needle = items[idx];
    for (items[idx + 1 ..]) |item| {
        if (item.freshness_state != .active) continue;
        if (!candidatesShareAnchor(item, needle)) continue;
        if (trustRank(item.trust_class, DEFAULT_TRUST_POLICY) != trustRank(needle.trust_class, DEFAULT_TRUST_POLICY)) continue;
        return item;
    }
    return null;
}

fn makePackRoutingTrace(
    allocator: std.mem.Allocator,
    stage: PackRoutingStage,
    pack_id: []const u8,
    pack_version: []const u8,
    status: PackRoutingStatus,
    reason: []const u8,
    policy: PackConflictPolicy,
    candidate: MountedPackCandidate,
    call_id: u16,
    considered_rank: u16,
    activation_rank: u16,
) !PackRoutingTrace {
    const owner_id = try std.fmt.allocPrint(allocator, "pack/{s}@{s}", .{ pack_id, pack_version });
    errdefer allocator.free(owner_id);
    return .{
        .allocator = allocator,
        .stage = stage,
        .pack_id = try allocator.dupe(u8, pack_id),
        .pack_version = try allocator.dupe(u8, pack_version),
        .owner_id = owner_id,
        .status = status,
        .reason = try allocator.dupe(u8, reason),
        .policy = policy,
        .conflict_category = candidate.conflict_category,
        .trust_class = candidate.trust_class,
        .freshness_state = candidate.freshness_state,
        .score = candidate.score,
        .support_potential_upper_bound = @intCast(@min(candidate.score, @as(u32, 1000))),
        .call_id = call_id,
        .considered_rank = considered_rank,
        .activation_rank = activation_rank,
        .path_hits = candidate.path_hits,
        .symbol_hits = candidate.symbol_hits,
        .domain_hits = candidate.domain_hits,
        .file_family_hits = candidate.file_family_hits,
    };
}

pub fn clonePackRoutingTrace(allocator: std.mem.Allocator, trace: PackRoutingTrace) !PackRoutingTrace {
    return .{
        .allocator = allocator,
        .stage = trace.stage,
        .pack_id = try allocator.dupe(u8, trace.pack_id),
        .pack_version = try allocator.dupe(u8, trace.pack_version),
        .owner_id = try allocator.dupe(u8, trace.owner_id),
        .status = trace.status,
        .reason = try allocator.dupe(u8, trace.reason),
        .policy = trace.policy,
        .conflict_category = trace.conflict_category,
        .trust_class = trace.trust_class,
        .freshness_state = trace.freshness_state,
        .score = trace.score,
        .support_potential_upper_bound = trace.support_potential_upper_bound,
        .call_id = trace.call_id,
        .considered_rank = trace.considered_rank,
        .activation_rank = trace.activation_rank,
        .path_hits = trace.path_hits,
        .symbol_hits = trace.symbol_hits,
        .domain_hits = trace.domain_hits,
        .file_family_hits = trace.file_family_hits,
        .candidate_surfaces = trace.candidate_surfaces,
        .suppressed_candidates = trace.suppressed_candidates,
        .conflict_refused = trace.conflict_refused,
        .local_truth_won = trace.local_truth_won,
    };
}

fn scoreMountedPack(
    mount: *const knowledge_pack_store.ResolvedMount,
    rel_paths: []const []const u8,
    tokens: []const []const u8,
    patterns: []const []const u8,
) MountedPackCandidate {
    var out = MountedPackCandidate{ .mount_index = 0, .reason = "pack lacked a deterministic anchor for this query" };
    out.trust_class = parseTrustClassName(mount.manifest.trust_class) orelse .exploratory;
    out.freshness_state = mount.manifest.provenance.freshness_state;
    if (!mount.entry.enabled) {
        out.reason = "pack is mounted but disabled";
        return out;
    }
    if (!mount.manifest.compatibility.linux_first or !mount.manifest.compatibility.deterministic_only or !std.mem.eql(u8, mount.manifest.compatibility.mount_schema, knowledge_pack_store.MOUNT_SCHEMA_VERSION)) {
        out.compatible = false;
        out.conflict_category = .incompatible_pack_family;
        out.reason = "pack compatibility rejected deterministic Linux-first routing";
        return out;
    }

    out.path_hits = countPackPreviewPathHits(mount.manifest.content.corpus_preview, rel_paths);
    out.symbol_hits = countPackSymbolHits(mount.manifest.content.concept_preview, tokens, patterns);
    out.domain_hits = countPackDomainHits(mount.manifest.domain_family, rel_paths, tokens, patterns);
    out.file_family_hits = countPackFileFamilyHits(mount.manifest.content.corpus_preview, rel_paths);
    out.eligible = out.path_hits != 0 or out.symbol_hits != 0 or out.domain_hits != 0 or out.file_family_hits != 0;
    if (!out.eligible) return out;
    out.score =
        @as(u32, out.path_hits) * 2000 +
        @as(u32, out.symbol_hits) * 1400 +
        @as(u32, out.domain_hits) * 900 +
        @as(u32, out.file_family_hits) * 250 +
        @as(u32, trustRank(out.trust_class, DEFAULT_TRUST_POLICY)) * 50;
    out.reason = "eligible deterministic anchor";
    return out;
}

fn sortMountedPackCandidates(items: []MountedPackCandidate) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and lessMountedPackCandidate(items[j], items[j - 1])) : (j -= 1) {
            const tmp = items[j - 1];
            items[j - 1] = items[j];
            items[j] = tmp;
        }
    }
}

fn lessMountedPackCandidate(a: MountedPackCandidate, b: MountedPackCandidate) bool {
    if (a.compatible != b.compatible) return a.compatible;
    if (a.eligible != b.eligible) return a.eligible;
    if (a.freshness_state != b.freshness_state) return a.freshness_state == .active;
    if (a.trust_class != b.trust_class) return trustRank(a.trust_class, DEFAULT_TRUST_POLICY) > trustRank(b.trust_class, DEFAULT_TRUST_POLICY);
    if (a.score != b.score) return a.score > b.score;
    if (a.path_hits != b.path_hits) return a.path_hits > b.path_hits;
    if (a.symbol_hits != b.symbol_hits) return a.symbol_hits > b.symbol_hits;
    if (a.domain_hits != b.domain_hits) return a.domain_hits > b.domain_hits;
    return a.mount_index < b.mount_index;
}

fn countPackPreviewPathHits(preview: [][]u8, rel_paths: []const []const u8) u16 {
    var count: u16 = 0;
    for (preview) |item| {
        for (rel_paths) |rel_path| {
            if (rel_path.len == 0) continue;
            if (std.mem.indexOf(u8, item, rel_path) != null or std.mem.indexOf(u8, item, std.fs.path.basename(rel_path)) != null) {
                count +|= 1;
                break;
            }
        }
    }
    return count;
}

fn countPackSymbolHits(preview: [][]u8, tokens: []const []const u8, patterns: []const []const u8) u16 {
    var count: u16 = 0;
    for (preview) |item| {
        var matched = false;
        for (tokens) |token| {
            if (token.len < 3) continue;
            if (std.mem.indexOf(u8, item, token) != null) {
                matched = true;
                break;
            }
        }
        if (!matched) {
            for (patterns) |pattern| {
                if (pattern.len < 4) continue;
                if (std.mem.indexOf(u8, item, pattern) != null) {
                    matched = true;
                    break;
                }
            }
        }
        if (matched) count +|= 1;
    }
    return count;
}

fn countPackDomainHits(domain_family: []const u8, rel_paths: []const []const u8, tokens: []const []const u8, patterns: []const []const u8) u16 {
    if (std.mem.eql(u8, domain_family, "general")) return 0;
    for (rel_paths) |rel_path| {
        if (std.mem.indexOf(u8, rel_path, domain_family) != null) return 1;
    }
    for (tokens) |token| {
        if (std.mem.eql(u8, token, domain_family) or std.mem.indexOf(u8, token, domain_family) != null) return 1;
    }
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, pattern, domain_family) != null) return 1;
    }
    return 0;
}

fn countPackFileFamilyHits(preview: [][]u8, rel_paths: []const []const u8) u16 {
    var family_hits: u16 = 0;
    for (rel_paths) |rel_path| {
        const family = requestFamilyForPath(rel_path);
        if (family == .other) continue;
        for (preview) |item| {
            if (requestFamilyForPath(item) == family) {
                family_hits +|= 1;
                break;
            }
        }
    }
    return family_hits;
}

fn requestFamilyForPath(path: []const u8) PackRequestFamily {
    if (std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".txt")) return .docs;
    if (std.mem.endsWith(u8, path, ".json") or std.mem.endsWith(u8, path, ".toml") or std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml") or std.mem.endsWith(u8, path, ".cfg") or std.mem.endsWith(u8, path, ".conf") or std.mem.endsWith(u8, path, ".ini")) return .config;
    if (std.mem.indexOf(u8, path, "/test") != null or std.mem.endsWith(u8, path, "_test.zig")) return .tests;
    if (std.mem.indexOf(u8, path, "/log") != null or std.mem.endsWith(u8, path, ".log")) return .logs;
    if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".c") or std.mem.endsWith(u8, path, ".cpp") or std.mem.endsWith(u8, path, ".h")) return .code;
    return .other;
}

fn loadMountedPackCatalogs(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    rel_paths: []const []const u8,
    tokens: []const []const u8,
    patterns: []const []const u8,
    stage: PackRoutingStage,
    caps: PackRoutingCaps,
    policy: PackConflictPolicy,
    collector: ?*PackRoutingCollector,
) ![]MountedPackCatalog {
    const started = sys.getMilliTick();
    defer lookup_profile.pack_catalog_load_ms += sys.getMilliTick() - started;
    if (paths.metadata.kind != .project) return allocator.alloc(MountedPackCatalog, 0);
    const call_id = if (collector) |value| value.beginCall() else 0;
    var routed = try routeMountedPacks(allocator, paths, rel_paths, tokens, patterns, stage, caps, policy, call_id);
    defer routed.deinit(allocator);
    if (collector) |value| {
        for (routed.traces) |trace| {
            try value.append(try clonePackRoutingTrace(allocator, trace));
        }
    }

    var out = std.ArrayList(MountedPackCatalog).init(allocator);
    errdefer {
        for (out.items) |*catalog| catalog.deinit();
        out.deinit();
    }
    for (routed.mounts) |*mount| {
        const owner_id = try mount.ownerId(allocator);
        errdefer allocator.free(owner_id);
        const prefix = try mount.mountPrefix(allocator);
        defer allocator.free(prefix);
        var records = try loadCatalog(allocator, mount.abstraction_catalog_abs_path);
        defer deinitCatalog(&records);
        try projectPackRecords(allocator, &records, prefix, owner_id);
        try out.append(.{
            .allocator = allocator,
            .owner_id = owner_id,
            .records = try records.toOwnedSlice(),
        });
    }
    return out.toOwnedSlice();
}

fn projectPackRecords(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(Record),
    mount_prefix: []const u8,
    owner_id: []const u8,
) !void {
    for (records.items) |*record| {
        for (record.sources, 0..) |source, idx| {
            const projected = try rewritePackSourceSpec(allocator, source, mount_prefix);
            allocator.free(record.sources[idx]);
            record.sources[idx] = projected;
        }
        for (record.provenance, 0..) |item, idx| {
            const projected = try std.fmt.allocPrint(allocator, "{s}|pack_owner={s}", .{ item, owner_id });
            allocator.free(record.provenance[idx]);
            record.provenance[idx] = projected;
        }
        if (record.lineage_id.len > 0) allocator.free(record.lineage_id);
        record.lineage_id = try std.fmt.allocPrint(allocator, "pack:{s}:{s}", .{ owner_id, record.concept_id });
    }
}

fn rewritePackSourceSpec(allocator: std.mem.Allocator, source: []const u8, mount_prefix: []const u8) ![]u8 {
    const corpus_prefix = "@corpus/";
    const idx = std.mem.indexOf(u8, source, corpus_prefix) orelse return allocator.dupe(u8, source);
    const before = source[0..idx];
    const after = source[idx + corpus_prefix.len ..];
    return std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ before, mount_prefix, after });
}

fn findSupportReference(items: []const SupportReference, concept_id: []const u8) ?SupportReference {
    for (items) |item| {
        if (std.mem.eql(u8, item.concept_id, concept_id)) return item;
    }
    return null;
}

fn supportReferenceCompatible(local_ref: SupportReference, remote_ref: SupportReference) bool {
    if (local_ref.consensus_hash != remote_ref.consensus_hash) return false;
    if (local_ref.tier != remote_ref.tier) return false;
    if (local_ref.category != remote_ref.category) return false;
    return stringOptionEql(local_ref.parent_concept_id, remote_ref.parent_concept_id);
}

fn findMatchingReuseDecision(
    items: []const ReuseEntry,
    decision: ReuseDecision,
    source_ref: SupportReference,
    local_ref: ?SupportReference,
) ?ReuseEntry {
    for (items) |item| {
        if (item.decision != decision) continue;
        if (item.source_kind != source_ref.owner_kind) continue;
        if (!std.mem.eql(u8, item.source_id, source_ref.owner_id)) continue;
        if (!std.mem.eql(u8, item.source_concept_id, source_ref.concept_id)) continue;
        if (item.source_consensus_hash != source_ref.consensus_hash) continue;
        if (!std.mem.eql(u8, item.source_lineage_id, source_ref.lineage_id)) continue;
        if (item.source_lineage_version != source_ref.lineage_version) continue;
        if (item.source_trust_class != source_ref.trust_class) continue;
        if (decision == .promote) {
            const local = local_ref orelse continue;
            if (item.local_concept_id == null or item.local_lineage_id == null or item.local_trust_class == null) continue;
            if (!std.mem.eql(u8, item.local_concept_id.?, local.concept_id)) continue;
            if (item.local_consensus_hash != local.consensus_hash) continue;
            if (!std.mem.eql(u8, item.local_lineage_id.?, local.lineage_id)) continue;
            if (item.local_lineage_version != local.lineage_version) continue;
            if (item.local_trust_class.? != local.trust_class) continue;
        }
        return item;
    }
    return null;
}

fn stringOptionEql(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn parseCommand(allocator: std.mem.Allocator, script: []const u8) !struct {
    allocator: std.mem.Allocator,
    concept_id: []u8,
    tier: Tier,
    category: Category,
    parent_concept_id: ?[]u8,
    source_specs: [][]u8,

    fn deinit(self: *@This()) void {
        self.allocator.free(self.concept_id);
        if (self.parent_concept_id) |parent_concept_id| self.allocator.free(parent_concept_id);
        for (self.source_specs) |spec| self.allocator.free(spec);
        self.allocator.free(self.source_specs);
        self.* = undefined;
    }
} {
    const trimmed = std.mem.trim(u8, script, " \r\n\t");
    var it = std.mem.tokenizeAny(u8, trimmed, " \r\n\t");
    const command = it.next() orelse return error.InvalidAbstractionCommand;
    if (!std.mem.eql(u8, command, COMMIT_COMMAND_NAME)) return error.InvalidAbstractionCommand;

    const raw_concept = it.next() orelse return error.InvalidAbstractionCommand;
    const concept_id = try sanitizeConceptId(allocator, raw_concept);
    errdefer allocator.free(concept_id);

    var specs = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (specs.items) |spec| allocator.free(spec);
        specs.deinit();
    }
    var tier: Tier = .pattern;
    var category: Category = .structural;
    var parent_concept_id: ?[]u8 = null;
    errdefer if (parent_concept_id) |parent| allocator.free(parent);

    while (it.next()) |spec| {
        if (std.mem.startsWith(u8, spec, "tier:")) {
            tier = parseTier(spec["tier:".len..]) orelse return error.InvalidAbstractionCommand;
            continue;
        }
        if (std.mem.startsWith(u8, spec, "category:")) {
            category = parseCategory(spec["category:".len..]) orelse return error.InvalidAbstractionCommand;
            continue;
        }
        if (std.mem.startsWith(u8, spec, "parent:")) {
            if (parent_concept_id != null) return error.InvalidAbstractionCommand;
            parent_concept_id = try sanitizeConceptId(allocator, spec["parent:".len..]);
            continue;
        }
        if (specs.items.len >= MAX_SOURCE_SPECS) return error.TooManySources;
        try specs.append(try allocator.dupe(u8, spec));
    }
    if (specs.items.len == 0) return error.InvalidAbstractionCommand;
    if (parent_concept_id) |parent| {
        if (std.mem.eql(u8, parent, concept_id)) return error.InvalidAbstractionCommand;
    }

    return .{
        .allocator = allocator,
        .concept_id = concept_id,
        .tier = tier,
        .category = category,
        .parent_concept_id = parent_concept_id,
        .source_specs = try specs.toOwnedSlice(),
    };
}

fn parseReuseCommand(allocator: std.mem.Allocator, script: []const u8) !struct {
    allocator: std.mem.Allocator,
    decision: ReuseDecision,
    source_concept_id: []u8,
    local_concept_id: ?[]u8 = null,

    fn deinit(self: *@This()) void {
        self.allocator.free(self.source_concept_id);
        if (self.local_concept_id) |local_concept_id| self.allocator.free(local_concept_id);
        self.* = undefined;
    }
} {
    const trimmed = std.mem.trim(u8, script, " \r\n\t");
    var it = std.mem.tokenizeAny(u8, trimmed, " \r\n\t");
    const command = it.next() orelse return error.InvalidAbstractionCommand;
    if (!std.mem.eql(u8, command, REUSE_COMMAND_NAME)) return error.InvalidAbstractionCommand;

    const decision = parseReuseDecision(it.next() orelse return error.InvalidAbstractionCommand) orelse return error.InvalidAbstractionCommand;
    const raw_source = it.next() orelse return error.InvalidAbstractionCommand;
    const source_concept_id = try parseReuseSourceConcept(allocator, raw_source);
    errdefer allocator.free(source_concept_id);

    var local_concept_id: ?[]u8 = null;
    errdefer if (local_concept_id) |concept_id| allocator.free(concept_id);

    while (it.next()) |token| {
        if (!std.mem.startsWith(u8, token, "local:")) return error.InvalidAbstractionCommand;
        if (local_concept_id != null) return error.InvalidAbstractionCommand;
        local_concept_id = try sanitizeConceptId(allocator, token["local:".len..]);
    }

    switch (decision) {
        .promote => if (local_concept_id == null) return error.InvalidAbstractionCommand,
        .adopt, .reject => if (local_concept_id != null) return error.InvalidAbstractionCommand,
        .none => return error.InvalidAbstractionCommand,
    }

    return .{
        .allocator = allocator,
        .decision = decision,
        .source_concept_id = source_concept_id,
        .local_concept_id = local_concept_id,
    };
}

fn parseReuseDecision(text: []const u8) ?ReuseDecision {
    if (std.ascii.eqlIgnoreCase(text, "adopt")) return .adopt;
    if (std.ascii.eqlIgnoreCase(text, "reject")) return .reject;
    if (std.ascii.eqlIgnoreCase(text, "promote")) return .promote;
    return null;
}

fn parseMergeMode(text: []const u8) ?MergeMode {
    if (std.ascii.eqlIgnoreCase(text, "adopt")) return .adopt;
    if (std.ascii.eqlIgnoreCase(text, "promote")) return .promote;
    return null;
}

fn parsePruneMode(text: []const u8) ?PruneMode {
    if (std.ascii.eqlIgnoreCase(text, "stale")) return .mark_stale;
    if (std.ascii.eqlIgnoreCase(text, "prunable")) return .mark_prunable;
    if (std.ascii.eqlIgnoreCase(text, "refresh")) return .refresh;
    if (std.ascii.eqlIgnoreCase(text, "collect")) return .collect;
    return null;
}

fn parseReuseSourceConcept(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (!std.mem.startsWith(u8, trimmed, "core:")) return error.InvalidAbstractionCommand;
    return sanitizeConceptId(allocator, trimmed["core:".len..]);
}

fn parseMergeCommand(allocator: std.mem.Allocator, script: []const u8) !struct {
    allocator: std.mem.Allocator,
    mode: MergeMode,
    source_kind: shards.Kind,
    source_id: []u8,
    source_concept_id: []u8,
    target_concept_id: ?[]u8 = null,

    fn deinit(self: *@This()) void {
        self.allocator.free(self.source_id);
        self.allocator.free(self.source_concept_id);
        if (self.target_concept_id) |target| self.allocator.free(target);
        self.* = undefined;
    }
} {
    const trimmed = std.mem.trim(u8, script, " \r\n\t");
    var it = std.mem.tokenizeAny(u8, trimmed, " \r\n\t");
    const command = it.next() orelse return error.InvalidAbstractionCommand;
    if (!std.mem.eql(u8, command, MERGE_COMMAND_NAME)) return error.InvalidAbstractionCommand;

    const mode = parseMergeMode(it.next() orelse return error.InvalidAbstractionCommand) orelse return error.InvalidAbstractionCommand;
    const raw_source = it.next() orelse return error.InvalidAbstractionCommand;
    var source_parts = std.mem.splitScalar(u8, raw_source, ':');
    const kind_text = source_parts.next() orelse return error.InvalidAbstractionCommand;
    const source_kind: shards.Kind = if (std.ascii.eqlIgnoreCase(kind_text, "core"))
        .core
    else if (std.ascii.eqlIgnoreCase(kind_text, "project"))
        .project
    else
        return error.InvalidAbstractionCommand;

    const source_id = if (source_kind == .core) blk: {
        break :blk try allocator.dupe(u8, "core");
    } else blk: {
        var metadata = try shards.resolveProjectMetadata(allocator, source_parts.next() orelse return error.InvalidAbstractionCommand);
        defer metadata.deinit();
        break :blk try allocator.dupe(u8, metadata.metadata.id);
    };
    errdefer allocator.free(source_id);

    const concept_text = source_parts.next() orelse return error.InvalidAbstractionCommand;
    if (source_parts.next() != null) return error.InvalidAbstractionCommand;
    const source_concept_id = try sanitizeConceptId(allocator, concept_text);
    errdefer allocator.free(source_concept_id);

    var target_concept_id: ?[]u8 = null;
    errdefer if (target_concept_id) |target| allocator.free(target);
    while (it.next()) |token| {
        if (!std.mem.startsWith(u8, token, "as:")) return error.InvalidAbstractionCommand;
        if (target_concept_id != null) return error.InvalidAbstractionCommand;
        target_concept_id = try sanitizeConceptId(allocator, token["as:".len..]);
    }

    return .{
        .allocator = allocator,
        .mode = mode,
        .source_kind = source_kind,
        .source_id = source_id,
        .source_concept_id = source_concept_id,
        .target_concept_id = target_concept_id,
    };
}

fn parsePruneCommand(allocator: std.mem.Allocator, script: []const u8) !struct {
    allocator: std.mem.Allocator,
    mode: PruneMode,
    target_concept_id: ?[]u8 = null,
    collect_gap: u32 = 2,
    collect_quality: u16 = 700,
    collect_confidence: u16 = 700,
    collect_trust: TrustClass = .project,

    fn deinit(self: *@This()) void {
        if (self.target_concept_id) |target| self.allocator.free(target);
        self.* = undefined;
    }
} {
    const trimmed = std.mem.trim(u8, script, " \r\n\t");
    var it = std.mem.tokenizeAny(u8, trimmed, " \r\n\t");
    const command = it.next() orelse return error.InvalidAbstractionCommand;
    if (!std.mem.eql(u8, command, PRUNE_COMMAND_NAME)) return error.InvalidAbstractionCommand;

    const mode = parsePruneMode(it.next() orelse return error.InvalidAbstractionCommand) orelse return error.InvalidAbstractionCommand;
    var target_concept_id: ?[]u8 = null;
    errdefer if (target_concept_id) |target| allocator.free(target);
    var collect_gap: u32 = 2;
    var collect_quality: u16 = 700;
    var collect_confidence: u16 = 700;
    var collect_trust: TrustClass = .project;

    while (it.next()) |token| {
        if (std.mem.startsWith(u8, token, "gap:")) {
            collect_gap = try std.fmt.parseUnsigned(u32, token["gap:".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, token, "quality_below:")) {
            collect_quality = try std.fmt.parseUnsigned(u16, token["quality_below:".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, token, "confidence_below:")) {
            collect_confidence = try std.fmt.parseUnsigned(u16, token["confidence_below:".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, token, "trust_at_most:")) {
            collect_trust = parseTrustClass(token["trust_at_most:".len..]) orelse return error.InvalidAbstractionCommand;
            continue;
        }
        if (target_concept_id != null) return error.InvalidAbstractionCommand;
        target_concept_id = try sanitizeConceptId(allocator, token);
    }

    switch (mode) {
        .mark_stale, .mark_prunable, .refresh => if (target_concept_id == null) return error.InvalidAbstractionCommand,
        .collect => if (target_concept_id != null) return error.InvalidAbstractionCommand,
    }

    return .{
        .allocator = allocator,
        .mode = mode,
        .target_concept_id = target_concept_id,
        .collect_gap = collect_gap,
        .collect_quality = collect_quality,
        .collect_confidence = collect_confidence,
        .collect_trust = collect_trust,
    };
}

fn collectExamplesFromSpec(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    spec: []const u8,
    examples: *std.ArrayList(Example),
) !void {
    if (std.mem.startsWith(u8, spec, "region:")) {
        var region = try parseRegionSpec(allocator, spec);
        defer region.deinit(allocator);
        try appendRegionExample(allocator, spec, region.rel_path, region.start_line, region.end_line, examples);
        return;
    }

    if (std.mem.startsWith(u8, spec, "code_intel:last_result")) {
        try collectCodeIntelExamples(allocator, paths, spec, examples);
        return;
    }

    return error.InvalidAbstractionCommand;
}

fn parseRegionSpec(allocator: std.mem.Allocator, spec: []const u8) !RegionSpec {
    const payload = spec["region:".len..];
    const colon = std.mem.lastIndexOfScalar(u8, payload, ':') orelse return error.InvalidRegionSpec;
    const dash = std.mem.indexOfScalar(u8, payload[colon + 1 ..], '-') orelse return error.InvalidRegionSpec;
    const rel_path = std.mem.trim(u8, payload[0..colon], " \r\n\t");
    if (rel_path.len == 0) return error.InvalidRegionSpec;

    const start_text = payload[colon + 1 .. colon + 1 + dash];
    const end_text = payload[colon + 1 + dash + 1 ..];
    const start_line = try std.fmt.parseUnsigned(u32, start_text, 10);
    const end_line = try std.fmt.parseUnsigned(u32, end_text, 10);
    if (start_line == 0 or end_line < start_line) return error.InvalidRegionSpec;
    if (end_line - start_line + 1 > MAX_REGION_LINES) return error.RegionTooLarge;

    return .{
        .rel_path = try allocator.dupe(u8, rel_path),
        .start_line = start_line,
        .end_line = end_line,
    };
}

fn collectCodeIntelExamples(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    spec: []const u8,
    examples: *std.ArrayList(Example),
) !void {
    const file_path = try std.fs.path.join(allocator, &.{ paths.root_abs_path, CODE_INTEL_FILE_REL });
    defer allocator.free(file_path);
    const body = readOwnedFile(allocator, file_path, 512 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.CodeIntelResultMissing,
        else => return err,
    };
    defer allocator.free(body);

    const sections = blk: {
        if (std.mem.eql(u8, spec, "code_intel:last_result"))
            break :blk &[_][]const u8{ "evidence", "refactorPath", "overlap" };
        if (std.mem.eql(u8, spec, "code_intel:last_result:evidence"))
            break :blk &[_][]const u8{"evidence"};
        if (std.mem.eql(u8, spec, "code_intel:last_result:refactorPath"))
            break :blk &[_][]const u8{"refactorPath"};
        if (std.mem.eql(u8, spec, "code_intel:last_result:overlap"))
            break :blk &[_][]const u8{"overlap"};
        return error.InvalidAbstractionCommand;
    };

    for (sections) |section| {
        try collectCodeIntelSection(allocator, body, section, examples);
        if (examples.items.len >= MAX_EXAMPLES) break;
    }
}

fn collectCodeIntelSection(
    allocator: std.mem.Allocator,
    body: []const u8,
    section: []const u8,
    examples: *std.ArrayList(Example),
) !void {
    var pat_buf: [64]u8 = undefined;
    const section_pat = try std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{section});
    const start = std.mem.indexOf(u8, body, section_pat) orelse return;
    const array_open = std.mem.indexOfScalarPos(u8, body, start, '[') orelse return error.InvalidCodeIntelResult;
    const array_close = findMatchingBracket(body, array_open) orelse return error.InvalidCodeIntelResult;
    var cursor = array_open + 1;

    while (cursor < array_close and examples.items.len < MAX_EXAMPLES) {
        const object_open = std.mem.indexOfScalarPos(u8, body, cursor, '{') orelse break;
        if (object_open >= array_close) break;
        const object_close = findMatchingBrace(body, object_open) orelse return error.InvalidCodeIntelResult;
        if (object_close > array_close) return error.InvalidCodeIntelResult;

        const object = body[object_open .. object_close + 1];
        var rel_path_buf = std.ArrayList(u8).init(allocator);
        defer rel_path_buf.deinit();
        const rel_path = jsonLooseString(object, "relPath", &rel_path_buf) orelse return error.InvalidCodeIntelResult;
        const line = jsonLooseUnsigned(object, "line") orelse return error.InvalidCodeIntelResult;

        const start_line = if (line > CODE_INTEL_CONTEXT_RADIUS) line - CODE_INTEL_CONTEXT_RADIUS else 1;
        const end_line = line + CODE_INTEL_CONTEXT_RADIUS;
        const source_spec = try std.fmt.allocPrint(allocator, "region:{s}:{d}-{d}", .{ rel_path, start_line, end_line });
        defer allocator.free(source_spec);
        try appendRegionExample(allocator, source_spec, rel_path, start_line, end_line, examples);
        cursor = object_close + 1;
    }
}

fn appendRegionExample(
    allocator: std.mem.Allocator,
    source_spec: []const u8,
    rel_path: []const u8,
    start_line: u32,
    end_line: u32,
    examples: *std.ArrayList(Example),
) !void {
    if (examples.items.len >= MAX_EXAMPLES) return error.TooManyExamples;
    for (examples.items) |example| {
        if (std.mem.eql(u8, example.source_spec, source_spec)) return;
    }

    const abs_path = try config.getPath(allocator, rel_path);
    defer allocator.free(abs_path);
    const source = try readOwnedFile(allocator, abs_path, 2 * 1024 * 1024);
    defer allocator.free(source);
    const region_text = try extractRegionText(allocator, source, start_line, end_line);
    defer allocator.free(region_text);

    var tokens = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (tokens.items) |token| allocator.free(token);
        tokens.deinit();
    }
    var patterns = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (patterns.items) |pattern| allocator.free(pattern);
        patterns.deinit();
    }

    var line_it = std.mem.splitScalar(u8, region_text, '\n');
    while (line_it.next()) |raw_line| {
        const normalized = try normalizeLine(allocator, raw_line);
        defer allocator.free(normalized);
        if (normalized.len == 0) continue;

        try appendOwnedUnique(&patterns, allocator, normalized);
        var token_it = std.mem.splitScalar(u8, normalized, ' ');
        while (token_it.next()) |token| {
            if (!isSignificantToken(token)) continue;
            try appendOwnedUnique(&tokens, allocator, token);
        }
    }

    if (patterns.items.len == 0 and tokens.items.len == 0) return error.NoConsensus;

    try examples.append(.{
        .allocator = allocator,
        .source_spec = try allocator.dupe(u8, source_spec),
        .tokens = try tokens.toOwnedSlice(),
        .patterns = try patterns.toOwnedSlice(),
    });
}

fn extractRegionText(allocator: std.mem.Allocator, source: []const u8, start_line: u32, end_line: u32) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var line_it = std.mem.splitScalar(u8, source, '\n');
    var current: u32 = 0;
    var found = false;
    while (line_it.next()) |line| {
        current += 1;
        if (current < start_line) continue;
        if (current > end_line) break;
        found = true;
        try out.appendSlice(std.mem.trimRight(u8, line, "\r"));
        try out.append('\n');
    }

    if (!found or current < start_line) return error.RegionOutOfRange;
    if (out.items.len > MAX_REGION_BYTES) return error.RegionTooLarge;
    return out.toOwnedSlice();
}

fn distillRecord(
    allocator: std.mem.Allocator,
    concept_id: []const u8,
    tier: Tier,
    category: Category,
    parent_concept_id: ?[]const u8,
    examples: []const Example,
) !Record {
    const threshold_examples: u32 = @intCast(@max(@as(usize, 2), std.math.divCeil(usize, examples.len * 2, 3) catch unreachable));

    var token_counts = std.StringHashMap(u32).init(allocator);
    defer token_counts.deinit();
    defer freeCountMap(&token_counts);
    var pattern_counts = std.StringHashMap(u32).init(allocator);
    defer pattern_counts.deinit();
    defer freeCountMap(&pattern_counts);

    for (examples) |example| {
        for (example.tokens) |token| try bumpCount(&token_counts, token);
        for (example.patterns) |pattern| try bumpCount(&pattern_counts, pattern);
    }

    const retained_tokens = try selectRetainedStrings(allocator, &token_counts, threshold_examples, MAX_TOKENS);
    defer freeStringSlice(allocator, retained_tokens);
    const retained_patterns = try selectRetainedStrings(allocator, &pattern_counts, threshold_examples, MAX_PATTERNS);
    defer freeStringSlice(allocator, retained_patterns);

    if (retained_patterns.len == 0) return error.NoConsensus;
    if (retained_tokens.len + retained_patterns.len < 2) return error.NoConsensus;

    var example_vectors = try allocator.alloc(vsa.HyperVector, examples.len);
    defer allocator.free(example_vectors);

    for (examples, 0..) |example, idx| {
        example_vectors[idx] = computeExampleVector(example, retained_tokens, retained_patterns);
    }

    const generalized = bundleVectors(example_vectors);
    const consensus_hash = vsa.collapse(generalized);

    var resonance_total: u32 = 0;
    var min_resonance: u16 = std.math.maxInt(u16);
    for (example_vectors) |vector| {
        const resonance = config.HYPERVECTOR_BITS - vsa.hammingDistance(vector, generalized);
        resonance_total += resonance;
        min_resonance = @min(min_resonance, resonance);
    }
    const average_resonance: u16 = @intCast(resonance_total / @as(u32, @intCast(example_vectors.len)));
    const valid_to_commit = min_resonance >= MIN_COMMIT_RESONANCE;
    if (!valid_to_commit) return error.AbstractionBelowThreshold;

    var sources = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (sources.items) |item| allocator.free(item);
        sources.deinit();
    }
    for (examples) |example| try sources.append(try allocator.dupe(u8, example.source_spec));

    const support_score = computeSupportScore(examples.len, threshold_examples, retained_tokens.len, retained_patterns.len);
    const reuse_score = computeReuseScore(sources.items.len, tier, parent_concept_id != null);
    const quality_score = computeQualityScore(average_resonance, min_resonance, support_score, reuse_score);
    const confidence_score = computeConfidenceScore(average_resonance, min_resonance, quality_score, examples.len, sources.items.len);
    const promotion_ready = computePromotionReady(tier, quality_score, confidence_score, examples.len, threshold_examples, sources.items.len);

    return .{
        .allocator = allocator,
        .concept_id = try allocator.dupe(u8, concept_id),
        .tier = tier,
        .category = category,
        .parent_concept_id = if (parent_concept_id) |parent| try allocator.dupe(u8, parent) else null,
        .example_count = @intCast(examples.len),
        .threshold_examples = threshold_examples,
        .retained_token_count = @intCast(retained_tokens.len),
        .retained_pattern_count = @intCast(retained_patterns.len),
        .average_resonance = average_resonance,
        .min_resonance = min_resonance,
        .quality_score = quality_score,
        .confidence_score = confidence_score,
        .reuse_score = reuse_score,
        .support_score = support_score,
        .promotion_ready = promotion_ready,
        .consensus_hash = consensus_hash,
        .valid_to_commit = valid_to_commit,
        .vector = generalized,
        .sources = try sources.toOwnedSlice(),
        .tokens = try cloneStringSlice(allocator, retained_tokens),
        .patterns = try cloneStringSlice(allocator, retained_patterns),
    };
}

fn computeExampleVector(example: Example, retained_tokens: [][]u8, retained_patterns: [][]u8) vsa.HyperVector {
    var votes = [_]i32{0} ** 1024;
    var feature_count: usize = 0;

    for (retained_tokens) |token| {
        if (!containsText(example.tokens, token)) continue;
        addVectorVotes(&votes, featureVector("tok:", token));
        feature_count += 1;
    }
    for (retained_patterns) |pattern| {
        if (!containsText(example.patterns, pattern)) continue;
        addVectorVotes(&votes, featureVector("pat:", pattern));
        feature_count += 1;
    }
    if (feature_count == 0) return @as(vsa.HyperVector, @splat(@as(u64, 0)));
    return collapseVotes(&votes);
}

fn bundleVectors(vectors: []const vsa.HyperVector) vsa.HyperVector {
    var votes = [_]i32{0} ** 1024;
    for (vectors) |vector| addVectorVotes(&votes, vector);
    return collapseVotes(&votes);
}

fn featureVector(prefix: []const u8, text: []const u8) vsa.HyperVector {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(prefix);
    hasher.update(text);
    const seed = ghost_state.wyhash(ghost_state.GENESIS_SEED, hasher.final());
    return vsa.generate(seed);
}

fn addVectorVotes(votes: *[1024]i32, vector: vsa.HyperVector) void {
    var lane_idx: usize = 0;
    while (lane_idx < 16) : (lane_idx += 1) {
        const word = vector[lane_idx];
        var bit_idx: usize = 0;
        while (bit_idx < 64) : (bit_idx += 1) {
            const bit = (word >> @as(u6, @intCast(bit_idx))) & 1;
            votes[lane_idx * 64 + bit_idx] += if (bit == 1) 1 else -1;
        }
    }
}

fn collapseVotes(votes: *const [1024]i32) vsa.HyperVector {
    var lanes = [_]u64{0} ** 16;
    var idx: usize = 0;
    while (idx < 1024) : (idx += 1) {
        if (votes[idx] >= 0) {
            lanes[idx / 64] |= (@as(u64, 1) << @as(u6, @intCast(idx % 64)));
        }
    }
    var result: vsa.HyperVector = lanes;
    result[15] = vsa.generateParity(result);
    return result;
}

fn normalizeLine(allocator: std.mem.Allocator, raw_line: []const u8) ![]u8 {
    const line = std.mem.trim(u8, stripLineComment(raw_line), " \r\n\t");
    if (line.len == 0) return allocator.dupe(u8, "");

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    var first = true;
    while (i < line.len) {
        if (std.ascii.isWhitespace(line[i])) {
            i += 1;
            continue;
        }

        const token = blk: {
            if (isIdentifierStart(line[i])) {
                const start = i;
                i += 1;
                while (i < line.len and isIdentifierContinue(line[i])) : (i += 1) {}
                break :blk try normalizeIdentifier(allocator, line[start..i]);
            }
            if (std.ascii.isDigit(line[i])) {
                i += 1;
                while (i < line.len and (std.ascii.isDigit(line[i]) or std.ascii.isAlphabetic(line[i]) or line[i] == '_')) : (i += 1) {}
                break :blk try allocator.dupe(u8, "#");
            }
            if (line[i] == '"' or line[i] == '\'') {
                const quote = line[i];
                i += 1;
                while (i < line.len) : (i += 1) {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        i += 1;
                        continue;
                    }
                    if (line[i] == quote) {
                        i += 1;
                        break;
                    }
                }
                break :blk try allocator.dupe(u8, "str");
            }
            if (i + 1 < line.len) {
                const pair = line[i .. i + 2];
                if (std.mem.eql(u8, pair, "=>") or
                    std.mem.eql(u8, pair, "==") or
                    std.mem.eql(u8, pair, "!=") or
                    std.mem.eql(u8, pair, "<=") or
                    std.mem.eql(u8, pair, ">=") or
                    std.mem.eql(u8, pair, "&&") or
                    std.mem.eql(u8, pair, "||"))
                {
                    i += 2;
                    break :blk try allocator.dupe(u8, pair);
                }
            }

            const single = try allocator.alloc(u8, 1);
            single[0] = line[i];
            i += 1;
            break :blk single;
        };
        defer allocator.free(token);

        if (!first) try out.append(' ');
        first = false;
        try out.appendSlice(token);
    }

    return out.toOwnedSlice();
}

fn normalizeIdentifier(allocator: std.mem.Allocator, ident: []const u8) ![]u8 {
    if (isKeyword(ident)) return asciiLowerDup(allocator, ident);
    if (ident.len > 0 and std.ascii.isUpper(ident[0])) return asciiLowerDup(allocator, ident);
    return allocator.dupe(u8, "id");
}

fn stripLineComment(line: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, line, "//") orelse return line;
    return line[0..idx];
}

fn selectRetainedStrings(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(u32),
    threshold_examples: u32,
    max_items: usize,
) ![][]u8 {
    var counted = std.ArrayList(CountedText).init(allocator);
    defer {
        for (counted.items) |item| allocator.free(item.text);
        counted.deinit();
    }

    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* < threshold_examples) continue;
        try counted.append(.{
            .text = try allocator.dupe(u8, entry.key_ptr.*),
            .count = entry.value_ptr.*,
        });
    }

    sortCountedText(counted.items);
    const retained_len = @min(counted.items.len, max_items);
    const retained = try allocator.alloc([]u8, retained_len);
    for (retained, 0..) |*slot, idx| {
        slot.* = try allocator.dupe(u8, counted.items[idx].text);
    }
    return retained;
}

fn sortCountedText(items: []CountedText) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and lessCounted(items[j], items[j - 1])) : (j -= 1) {
            const tmp = items[j - 1];
            items[j - 1] = items[j];
            items[j] = tmp;
        }
    }
}

fn lessCounted(a: CountedText, b: CountedText) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.text, b.text) == .lt;
}

fn bumpCount(map: *std.StringHashMap(u32), text: []const u8) !void {
    const entry = try map.getOrPut(text);
    if (!entry.found_existing) {
        entry.key_ptr.* = try map.allocator.dupe(u8, text);
        entry.value_ptr.* = 1;
        return;
    }
    entry.value_ptr.* += 1;
}

fn freeCountMap(map: *std.StringHashMap(u32)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        map.allocator.free(entry.key_ptr.*);
    }
}

fn persistCatalog(allocator: std.mem.Allocator, abs_path: []const u8, records: []const Record) !void {
    const bytes = try serializeCatalog(allocator, records);
    defer allocator.free(bytes);
    try ensureParentDir(allocator, abs_path);
    try writeOwnedFile(allocator, abs_path, bytes);
}

fn serializeCatalog(allocator: std.mem.Allocator, records: []const Record) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice(MAGIC_LINE);
    try out.append('\n');
    for (records) |record| {
        try appendLine(&out, "concept", record.concept_id);
        try appendLine(&out, "family", familyName(record.family));
        try appendLine(&out, "tier", tierName(record.tier));
        try appendLine(&out, "category", categoryName(record.category));
        if (record.parent_concept_id) |parent_concept_id| try appendLine(&out, "parent", parent_concept_id);
        try appendLineInt(&out, "examples", record.example_count);
        try appendLineInt(&out, "threshold", record.threshold_examples);
        try appendLineInt(&out, "retained_tokens", record.retained_token_count);
        try appendLineInt(&out, "retained_patterns", record.retained_pattern_count);
        try appendLineInt(&out, "average_resonance", record.average_resonance);
        try appendLineInt(&out, "min_resonance", record.min_resonance);
        try appendLineInt(&out, "quality_score", record.quality_score);
        try appendLineInt(&out, "confidence_score", record.confidence_score);
        try appendLineInt(&out, "reuse_score", record.reuse_score);
        try appendLineInt(&out, "support_score", record.support_score);
        try appendLineInt(&out, "promotion_ready", @intFromBool(record.promotion_ready));
        try appendLineInt(&out, "consensus_hash", record.consensus_hash);
        try appendLineInt(&out, "valid", @intFromBool(record.valid_to_commit));
        try appendLine(&out, "lineage_id", record.lineage_id);
        try appendLineInt(&out, "lineage_version", record.lineage_version);
        try appendLine(&out, "trust_class", trustClassName(record.trust_class));
        try appendLine(&out, "decay_state", decayStateName(record.decay_state));
        try appendLineInt(&out, "success_count", record.success_count);
        try appendLineInt(&out, "failure_count", record.failure_count);
        try appendLineInt(&out, "ambiguity_count", record.ambiguity_count);
        try appendLineInt(&out, "contradiction_count", record.contradiction_count);
        try appendLineInt(&out, "independent_case_count", record.independent_case_count);
        try appendLineInt(&out, "first_revision", record.first_revision);
        try appendLineInt(&out, "last_revision", record.last_revision);
        try appendLineInt(&out, "last_review_revision", record.last_review_revision);
        try appendVectorLine(&out, record.vector);
        for (record.sources) |item| try appendLine(&out, "source", item);
        for (record.tokens) |item| try appendLine(&out, "token", item);
        for (record.patterns) |item| try appendLine(&out, "pattern", item);
        for (record.schema_entity_signals) |item| try appendLine(&out, "schema_entity_signal", item);
        for (record.schema_relation_signals) |item| try appendLine(&out, "schema_relation_signal", item);
        for (record.obligation_signals) |item| try appendLine(&out, "obligation_signal", item);
        for (record.anchor_signals) |item| try appendLine(&out, "anchor_signal", item);
        for (record.verifier_hint_signals) |item| try appendLine(&out, "verifier_hint_signal", item);
        for (record.schema_signals) |item| try appendLine(&out, "schema_signal", item);
        for (record.provenance) |item| try appendLine(&out, "provenance", item);
        try out.appendSlice("end\n");
    }
    return out.toOwnedSlice();
}

fn loadCatalog(allocator: std.mem.Allocator, abs_path: []const u8) !std.ArrayList(Record) {
    var records = std.ArrayList(Record).init(allocator);
    errdefer deinitCatalog(&records);
    if (!fileExists(abs_path)) return records;

    const stat_file = try std.fs.openFileAbsolute(abs_path, .{});
    defer stat_file.close();
    const stat = try stat_file.stat();
    var cache = catalogCache();
    for (cache.items) |*entry| {
        if (!std.mem.eql(u8, entry.abs_path, abs_path)) continue;
        if (entry.size_bytes != stat.size or entry.mtime_ns != stat.mtime) continue;
        return try cloneCatalogRecords(allocator, entry.records);
    }

    const bytes = try readOwnedFile(allocator, abs_path, MAX_CATALOG_BYTES);
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const magic = lines.next() orelse return records;
    if (!std.mem.eql(u8, std.mem.trimRight(u8, magic, "\r"), MAGIC_LINE)) return error.InvalidAbstractionCatalog;

    var builder: ?RecordBuilder = null;
    errdefer if (builder) |*active| active.deinit();

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "concept ")) {
            if (builder != null) return error.InvalidAbstractionCatalog;
            var next_builder = RecordBuilder.init(allocator);
            try next_builder.setConcept(line["concept ".len..]);
            builder = next_builder;
            continue;
        }

        if (std.mem.eql(u8, line, "end")) {
            var finished = builder orelse return error.InvalidAbstractionCatalog;
            try records.append(try finished.finish());
            builder = null;
            continue;
        }

        var active = builder orelse return error.InvalidAbstractionCatalog;
        try active.parseLine(line);
        builder = active;
    }

    if (builder != null) return error.InvalidAbstractionCatalog;

    if (cache.items.len >= MAX_CATALOG_CACHE_ENTRIES) {
        cache.items[0].deinit();
        _ = cache.orderedRemove(0);
    }
    const cached_abs_path = try std.heap.page_allocator.dupe(u8, abs_path);
    errdefer std.heap.page_allocator.free(cached_abs_path);
    var cached_records = try cloneCatalogRecords(std.heap.page_allocator, records.items);
    errdefer deinitCatalog(&cached_records);
    try cache.append(.{
        .allocator = std.heap.page_allocator,
        .abs_path = cached_abs_path,
        .size_bytes = stat.size,
        .mtime_ns = stat.mtime,
        .records = try cached_records.toOwnedSlice(),
    });

    return records;
}

fn persistReuseCatalog(allocator: std.mem.Allocator, abs_path: []const u8, entries: []const ReuseEntry) !void {
    const bytes = try serializeReuseCatalog(allocator, entries);
    defer allocator.free(bytes);
    try ensureParentDir(allocator, abs_path);
    try writeOwnedFile(allocator, abs_path, bytes);
}

fn serializeReuseCatalog(allocator: std.mem.Allocator, entries: []const ReuseEntry) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice(REUSE_MAGIC_LINE);
    try out.append('\n');
    for (entries) |entry| {
        try appendLine(&out, "decision", reuseDecisionName(entry.decision));
        try appendLine(&out, "source_kind", @tagName(entry.source_kind));
        try appendLine(&out, "source_id", entry.source_id);
        try appendLine(&out, "source_concept", entry.source_concept_id);
        try appendLineInt(&out, "source_hash", entry.source_consensus_hash);
        try appendLine(&out, "source_lineage_id", entry.source_lineage_id);
        try appendLineInt(&out, "source_lineage_version", entry.source_lineage_version);
        try appendLine(&out, "source_trust_class", trustClassName(entry.source_trust_class));
        if (entry.local_concept_id) |local_concept_id| try appendLine(&out, "local_concept", local_concept_id);
        if (entry.local_concept_id != null) try appendLineInt(&out, "local_hash", entry.local_consensus_hash);
        if (entry.local_lineage_id) |local_lineage_id| try appendLine(&out, "local_lineage_id", local_lineage_id);
        if (entry.local_lineage_id != null) try appendLineInt(&out, "local_lineage_version", entry.local_lineage_version);
        if (entry.local_trust_class) |local_trust_class| try appendLine(&out, "local_trust_class", trustClassName(local_trust_class));
        try out.appendSlice("end\n");
    }
    return out.toOwnedSlice();
}

fn loadReuseCatalog(allocator: std.mem.Allocator, abs_path: []const u8) !std.ArrayList(ReuseEntry) {
    var entries = std.ArrayList(ReuseEntry).init(allocator);
    errdefer deinitReuseCatalog(&entries);
    if (!fileExists(abs_path)) return entries;

    const bytes = try readOwnedFile(allocator, abs_path, 256 * 1024);
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const magic = lines.next() orelse return entries;
    if (!std.mem.eql(u8, std.mem.trimRight(u8, magic, "\r"), REUSE_MAGIC_LINE)) return error.InvalidAbstractionCatalog;

    var builder: ?ReuseBuilder = null;
    errdefer if (builder) |*active| active.deinit();
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "decision ")) {
            if (builder != null) return error.InvalidAbstractionCatalog;
            var next_builder = ReuseBuilder.init(allocator);
            try next_builder.parseLine(line);
            builder = next_builder;
            continue;
        }

        if (std.mem.eql(u8, line, "end")) {
            var finished = builder orelse return error.InvalidAbstractionCatalog;
            try entries.append(try finished.finish());
            builder = null;
            continue;
        }

        var active = builder orelse return error.InvalidAbstractionCatalog;
        try active.parseLine(line);
        builder = active;
    }

    if (builder != null) return error.InvalidAbstractionCatalog;
    return entries;
}

fn reuseLivePath(allocator: std.mem.Allocator, paths: *const shards.Paths) ![]u8 {
    return std.fs.path.join(allocator, &.{ paths.abstractions_root_abs_path, REUSE_LIVE_FILE_NAME });
}

fn reuseStagedPath(allocator: std.mem.Allocator, paths: *const shards.Paths) ![]u8 {
    return std.fs.path.join(allocator, &.{ paths.abstractions_root_abs_path, REUSE_STAGED_FILE_NAME });
}

fn copyMaybeFile(allocator: std.mem.Allocator, from_path: []const u8, to_path: []const u8) !void {
    if (!fileExists(from_path)) {
        try deleteFileIfExists(to_path);
        return;
    }
    const bytes = try readOwnedFile(allocator, from_path, 1 * 1024 * 1024);
    defer allocator.free(bytes);
    try ensureParentDir(allocator, to_path);
    try writeOwnedFile(allocator, to_path, bytes);
}

const RecordBuilder = struct {
    allocator: std.mem.Allocator,
    concept_id: ?[]u8 = null,
    family: Family = .distilled,
    tier: Tier = .pattern,
    category: Category = .structural,
    parent_concept_id: ?[]u8 = null,
    example_count: u32 = 0,
    threshold_examples: u32 = 0,
    retained_token_count: u32 = 0,
    retained_pattern_count: u32 = 0,
    average_resonance: u16 = 0,
    min_resonance: u16 = 0,
    quality_score: u16 = 0,
    confidence_score: u16 = 0,
    reuse_score: u16 = 0,
    support_score: u16 = 0,
    promotion_ready: bool = false,
    consensus_hash: u64 = 0,
    valid_to_commit: bool = false,
    vector: vsa.HyperVector = @splat(@as(u64, 0)),
    lineage_id: ?[]u8 = null,
    lineage_version: u32 = 0,
    trust_class: TrustClass = .exploratory,
    decay_state: DecayState = .active,
    success_count: u32 = 0,
    failure_count: u32 = 0,
    ambiguity_count: u32 = 0,
    contradiction_count: u32 = 0,
    independent_case_count: u32 = 0,
    first_revision: u32 = 0,
    last_revision: u32 = 0,
    last_review_revision: u32 = 0,
    sources: std.ArrayList([]u8),
    tokens: std.ArrayList([]u8),
    patterns: std.ArrayList([]u8),
    schema_entity_signals: std.ArrayList([]u8),
    schema_relation_signals: std.ArrayList([]u8),
    obligation_signals: std.ArrayList([]u8),
    anchor_signals: std.ArrayList([]u8),
    verifier_hint_signals: std.ArrayList([]u8),
    schema_signals: std.ArrayList([]u8),
    provenance: std.ArrayList([]u8),

    fn init(allocator: std.mem.Allocator) RecordBuilder {
        return .{
            .allocator = allocator,
            .sources = std.ArrayList([]u8).init(allocator),
            .tokens = std.ArrayList([]u8).init(allocator),
            .patterns = std.ArrayList([]u8).init(allocator),
            .schema_entity_signals = std.ArrayList([]u8).init(allocator),
            .schema_relation_signals = std.ArrayList([]u8).init(allocator),
            .obligation_signals = std.ArrayList([]u8).init(allocator),
            .anchor_signals = std.ArrayList([]u8).init(allocator),
            .verifier_hint_signals = std.ArrayList([]u8).init(allocator),
            .schema_signals = std.ArrayList([]u8).init(allocator),
            .provenance = std.ArrayList([]u8).init(allocator),
        };
    }

    fn deinit(self: *RecordBuilder) void {
        if (self.concept_id) |id| self.allocator.free(id);
        if (self.parent_concept_id) |parent_concept_id| self.allocator.free(parent_concept_id);
        if (self.lineage_id) |lineage_id| self.allocator.free(lineage_id);
        for (self.sources.items) |item| self.allocator.free(item);
        for (self.tokens.items) |item| self.allocator.free(item);
        for (self.patterns.items) |item| self.allocator.free(item);
        for (self.schema_entity_signals.items) |item| self.allocator.free(item);
        for (self.schema_relation_signals.items) |item| self.allocator.free(item);
        for (self.obligation_signals.items) |item| self.allocator.free(item);
        for (self.anchor_signals.items) |item| self.allocator.free(item);
        for (self.verifier_hint_signals.items) |item| self.allocator.free(item);
        for (self.schema_signals.items) |item| self.allocator.free(item);
        for (self.provenance.items) |item| self.allocator.free(item);
        self.sources.deinit();
        self.tokens.deinit();
        self.patterns.deinit();
        self.schema_entity_signals.deinit();
        self.schema_relation_signals.deinit();
        self.obligation_signals.deinit();
        self.anchor_signals.deinit();
        self.verifier_hint_signals.deinit();
        self.schema_signals.deinit();
        self.provenance.deinit();
        self.* = undefined;
    }

    fn setConcept(self: *RecordBuilder, concept: []const u8) !void {
        self.concept_id = try self.allocator.dupe(u8, concept);
    }

    fn parseLine(self: *RecordBuilder, line: []const u8) !void {
        if (std.mem.startsWith(u8, line, "family ")) {
            self.family = parseFamily(line["family ".len..]) orelse return error.InvalidAbstractionCatalog;
            return;
        }
        if (std.mem.startsWith(u8, line, "tier ")) {
            self.tier = parseTier(line["tier ".len..]) orelse return error.InvalidAbstractionCatalog;
            return;
        }
        if (std.mem.startsWith(u8, line, "category ")) {
            self.category = parseCategory(line["category ".len..]) orelse return error.InvalidAbstractionCatalog;
            return;
        }
        if (std.mem.startsWith(u8, line, "parent ")) {
            if (self.parent_concept_id != null) return error.InvalidAbstractionCatalog;
            self.parent_concept_id = try self.allocator.dupe(u8, line["parent ".len..]);
            return;
        }
        if (std.mem.startsWith(u8, line, "examples ")) {
            self.example_count = try std.fmt.parseUnsigned(u32, line["examples ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "threshold ")) {
            self.threshold_examples = try std.fmt.parseUnsigned(u32, line["threshold ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "retained_tokens ")) {
            self.retained_token_count = try std.fmt.parseUnsigned(u32, line["retained_tokens ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "retained_patterns ")) {
            self.retained_pattern_count = try std.fmt.parseUnsigned(u32, line["retained_patterns ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "average_resonance ")) {
            self.average_resonance = try std.fmt.parseUnsigned(u16, line["average_resonance ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "min_resonance ")) {
            self.min_resonance = try std.fmt.parseUnsigned(u16, line["min_resonance ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "quality_score ")) {
            self.quality_score = try std.fmt.parseUnsigned(u16, line["quality_score ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "confidence_score ")) {
            self.confidence_score = try std.fmt.parseUnsigned(u16, line["confidence_score ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "reuse_score ")) {
            self.reuse_score = try std.fmt.parseUnsigned(u16, line["reuse_score ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "support_score ")) {
            self.support_score = try std.fmt.parseUnsigned(u16, line["support_score ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "promotion_ready ")) {
            self.promotion_ready = (try std.fmt.parseUnsigned(u8, line["promotion_ready ".len..], 10)) != 0;
            return;
        }
        if (std.mem.startsWith(u8, line, "consensus_hash ")) {
            self.consensus_hash = try std.fmt.parseUnsigned(u64, line["consensus_hash ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "valid ")) {
            self.valid_to_commit = (try std.fmt.parseUnsigned(u8, line["valid ".len..], 10)) != 0;
            return;
        }
        if (std.mem.startsWith(u8, line, "lineage_id ")) {
            if (self.lineage_id != null) return error.InvalidAbstractionCatalog;
            self.lineage_id = try self.allocator.dupe(u8, line["lineage_id ".len..]);
            return;
        }
        if (std.mem.startsWith(u8, line, "lineage_version ")) {
            self.lineage_version = try std.fmt.parseUnsigned(u32, line["lineage_version ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "trust_class ")) {
            self.trust_class = parseTrustClass(line["trust_class ".len..]) orelse return error.InvalidAbstractionCatalog;
            return;
        }
        if (std.mem.startsWith(u8, line, "decay_state ")) {
            self.decay_state = parseDecayState(line["decay_state ".len..]) orelse return error.InvalidAbstractionCatalog;
            return;
        }
        if (std.mem.startsWith(u8, line, "success_count ")) {
            self.success_count = try std.fmt.parseUnsigned(u32, line["success_count ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "failure_count ")) {
            self.failure_count = try std.fmt.parseUnsigned(u32, line["failure_count ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "ambiguity_count ")) {
            self.ambiguity_count = try std.fmt.parseUnsigned(u32, line["ambiguity_count ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "contradiction_count ")) {
            self.contradiction_count = try std.fmt.parseUnsigned(u32, line["contradiction_count ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "independent_case_count ")) {
            self.independent_case_count = try std.fmt.parseUnsigned(u32, line["independent_case_count ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "first_revision ")) {
            self.first_revision = try std.fmt.parseUnsigned(u32, line["first_revision ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "last_revision ")) {
            self.last_revision = try std.fmt.parseUnsigned(u32, line["last_revision ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "last_review_revision ")) {
            self.last_review_revision = try std.fmt.parseUnsigned(u32, line["last_review_revision ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "vector ")) {
            self.vector = try parseVectorLine(line["vector ".len..]);
            return;
        }
        if (std.mem.startsWith(u8, line, "source ")) {
            try self.sources.append(try self.allocator.dupe(u8, line["source ".len..]));
            return;
        }
        if (std.mem.startsWith(u8, line, "token ")) {
            try self.tokens.append(try self.allocator.dupe(u8, line["token ".len..]));
            return;
        }
        if (std.mem.startsWith(u8, line, "pattern ")) {
            try self.patterns.append(try self.allocator.dupe(u8, line["pattern ".len..]));
            return;
        }
        if (std.mem.startsWith(u8, line, "schema_entity_signal ")) {
            try self.schema_entity_signals.append(try self.allocator.dupe(u8, line["schema_entity_signal ".len..]));
            return;
        }
        if (std.mem.startsWith(u8, line, "schema_relation_signal ")) {
            try self.schema_relation_signals.append(try self.allocator.dupe(u8, line["schema_relation_signal ".len..]));
            return;
        }
        if (std.mem.startsWith(u8, line, "obligation_signal ")) {
            try self.obligation_signals.append(try self.allocator.dupe(u8, line["obligation_signal ".len..]));
            return;
        }
        if (std.mem.startsWith(u8, line, "anchor_signal ")) {
            try self.anchor_signals.append(try self.allocator.dupe(u8, line["anchor_signal ".len..]));
            return;
        }
        if (std.mem.startsWith(u8, line, "verifier_hint_signal ")) {
            try self.verifier_hint_signals.append(try self.allocator.dupe(u8, line["verifier_hint_signal ".len..]));
            return;
        }
        if (std.mem.startsWith(u8, line, "schema_signal ")) {
            try self.schema_signals.append(try self.allocator.dupe(u8, line["schema_signal ".len..]));
            return;
        }
        if (std.mem.startsWith(u8, line, "provenance ")) {
            try self.provenance.append(try self.allocator.dupe(u8, line["provenance ".len..]));
            return;
        }
        return error.InvalidAbstractionCatalog;
    }

    fn finish(self: *RecordBuilder) !Record {
        const concept_id = self.concept_id orelse return error.InvalidAbstractionCatalog;
        const source_count = self.sources.items.len;
        if (self.support_score == 0) {
            self.support_score = computeSupportScore(self.example_count, self.threshold_examples, self.retained_token_count, self.retained_pattern_count);
        }
        if (self.reuse_score == 0) {
            self.reuse_score = computeReuseScore(source_count, self.tier, self.parent_concept_id != null);
        }
        if (self.quality_score == 0) {
            self.quality_score = computeQualityScore(self.average_resonance, self.min_resonance, self.support_score, self.reuse_score);
        }
        if (self.confidence_score == 0) {
            self.confidence_score = computeConfidenceScore(self.average_resonance, self.min_resonance, self.quality_score, self.example_count, source_count);
        }
        if (!self.promotion_ready) {
            self.promotion_ready = computePromotionReady(self.tier, self.quality_score, self.confidence_score, self.example_count, self.threshold_examples, source_count);
        }
        const out = Record{
            .allocator = self.allocator,
            .concept_id = concept_id,
            .family = self.family,
            .tier = self.tier,
            .category = self.category,
            .parent_concept_id = self.parent_concept_id,
            .example_count = self.example_count,
            .threshold_examples = self.threshold_examples,
            .retained_token_count = self.retained_token_count,
            .retained_pattern_count = self.retained_pattern_count,
            .average_resonance = self.average_resonance,
            .min_resonance = self.min_resonance,
            .quality_score = self.quality_score,
            .confidence_score = self.confidence_score,
            .reuse_score = self.reuse_score,
            .support_score = self.support_score,
            .promotion_ready = self.promotion_ready,
            .consensus_hash = self.consensus_hash,
            .valid_to_commit = self.valid_to_commit,
            .vector = self.vector,
            .lineage_id = if (self.lineage_id) |lineage_id| lineage_id else &.{},
            .lineage_version = self.lineage_version,
            .trust_class = self.trust_class,
            .decay_state = self.decay_state,
            .success_count = self.success_count,
            .failure_count = self.failure_count,
            .ambiguity_count = self.ambiguity_count,
            .contradiction_count = self.contradiction_count,
            .independent_case_count = self.independent_case_count,
            .first_revision = self.first_revision,
            .last_revision = self.last_revision,
            .last_review_revision = self.last_review_revision,
            .sources = try self.sources.toOwnedSlice(),
            .tokens = try self.tokens.toOwnedSlice(),
            .patterns = try self.patterns.toOwnedSlice(),
            .schema_entity_signals = try self.schema_entity_signals.toOwnedSlice(),
            .schema_relation_signals = try self.schema_relation_signals.toOwnedSlice(),
            .obligation_signals = try self.obligation_signals.toOwnedSlice(),
            .anchor_signals = try self.anchor_signals.toOwnedSlice(),
            .verifier_hint_signals = try self.verifier_hint_signals.toOwnedSlice(),
            .schema_signals = try self.schema_signals.toOwnedSlice(),
            .provenance = try self.provenance.toOwnedSlice(),
        };
        self.concept_id = null;
        self.parent_concept_id = null;
        self.lineage_id = null;
        self.sources = std.ArrayList([]u8).init(self.allocator);
        self.tokens = std.ArrayList([]u8).init(self.allocator);
        self.patterns = std.ArrayList([]u8).init(self.allocator);
        self.schema_entity_signals = std.ArrayList([]u8).init(self.allocator);
        self.schema_relation_signals = std.ArrayList([]u8).init(self.allocator);
        self.obligation_signals = std.ArrayList([]u8).init(self.allocator);
        self.anchor_signals = std.ArrayList([]u8).init(self.allocator);
        self.verifier_hint_signals = std.ArrayList([]u8).init(self.allocator);
        self.schema_signals = std.ArrayList([]u8).init(self.allocator);
        self.provenance = std.ArrayList([]u8).init(self.allocator);
        return out;
    }
};

const ReuseBuilder = struct {
    allocator: std.mem.Allocator,
    decision: ReuseDecision = .none,
    source_kind: ?shards.Kind = null,
    source_id: ?[]u8 = null,
    source_concept_id: ?[]u8 = null,
    source_consensus_hash: u64 = 0,
    source_lineage_id: ?[]u8 = null,
    source_lineage_version: u32 = 0,
    source_trust_class: ?TrustClass = null,
    local_concept_id: ?[]u8 = null,
    local_consensus_hash: u64 = 0,
    local_lineage_id: ?[]u8 = null,
    local_lineage_version: u32 = 0,
    local_trust_class: ?TrustClass = null,

    fn init(allocator: std.mem.Allocator) ReuseBuilder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ReuseBuilder) void {
        if (self.source_id) |source_id| self.allocator.free(source_id);
        if (self.source_concept_id) |source_concept_id| self.allocator.free(source_concept_id);
        if (self.source_lineage_id) |source_lineage_id| self.allocator.free(source_lineage_id);
        if (self.local_concept_id) |local_concept_id| self.allocator.free(local_concept_id);
        if (self.local_lineage_id) |local_lineage_id| self.allocator.free(local_lineage_id);
        self.* = undefined;
    }

    fn parseLine(self: *ReuseBuilder, line: []const u8) !void {
        if (std.mem.startsWith(u8, line, "decision ")) {
            self.decision = parseReuseDecision(line["decision ".len..]) orelse return error.InvalidAbstractionCatalog;
            return;
        }
        if (std.mem.startsWith(u8, line, "source_kind ")) {
            const value = line["source_kind ".len..];
            if (std.ascii.eqlIgnoreCase(value, "core")) {
                self.source_kind = .core;
                return;
            }
            if (std.ascii.eqlIgnoreCase(value, "project")) {
                self.source_kind = .project;
                return;
            }
            return error.InvalidAbstractionCatalog;
        }
        if (std.mem.startsWith(u8, line, "source_id ")) {
            if (self.source_id != null) return error.InvalidAbstractionCatalog;
            self.source_id = try self.allocator.dupe(u8, line["source_id ".len..]);
            return;
        }
        if (std.mem.startsWith(u8, line, "source_concept ")) {
            if (self.source_concept_id != null) return error.InvalidAbstractionCatalog;
            self.source_concept_id = try self.allocator.dupe(u8, line["source_concept ".len..]);
            return;
        }
        if (std.mem.startsWith(u8, line, "source_hash ")) {
            self.source_consensus_hash = try std.fmt.parseUnsigned(u64, line["source_hash ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "source_lineage_id ")) {
            if (self.source_lineage_id != null) return error.InvalidAbstractionCatalog;
            self.source_lineage_id = try self.allocator.dupe(u8, line["source_lineage_id ".len..]);
            return;
        }
        if (std.mem.startsWith(u8, line, "source_lineage_version ")) {
            self.source_lineage_version = try std.fmt.parseUnsigned(u32, line["source_lineage_version ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "source_trust_class ")) {
            self.source_trust_class = parseTrustClass(line["source_trust_class ".len..]) orelse return error.InvalidAbstractionCatalog;
            return;
        }
        if (std.mem.startsWith(u8, line, "local_concept ")) {
            if (self.local_concept_id != null) return error.InvalidAbstractionCatalog;
            self.local_concept_id = try self.allocator.dupe(u8, line["local_concept ".len..]);
            return;
        }
        if (std.mem.startsWith(u8, line, "local_hash ")) {
            self.local_consensus_hash = try std.fmt.parseUnsigned(u64, line["local_hash ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "local_lineage_id ")) {
            if (self.local_lineage_id != null) return error.InvalidAbstractionCatalog;
            self.local_lineage_id = try self.allocator.dupe(u8, line["local_lineage_id ".len..]);
            return;
        }
        if (std.mem.startsWith(u8, line, "local_lineage_version ")) {
            self.local_lineage_version = try std.fmt.parseUnsigned(u32, line["local_lineage_version ".len..], 10);
            return;
        }
        if (std.mem.startsWith(u8, line, "local_trust_class ")) {
            self.local_trust_class = parseTrustClass(line["local_trust_class ".len..]) orelse return error.InvalidAbstractionCatalog;
            return;
        }
        return error.InvalidAbstractionCatalog;
    }

    fn finish(self: *ReuseBuilder) !ReuseEntry {
        const source_kind = self.source_kind orelse return error.InvalidAbstractionCatalog;
        const source_id = self.source_id orelse return error.InvalidAbstractionCatalog;
        const source_concept_id = self.source_concept_id orelse return error.InvalidAbstractionCatalog;
        const source_lineage_id = if (self.source_lineage_id) |lineage_id|
            lineage_id
        else
            try makeLineageId(self.allocator, source_kind, source_id, source_concept_id);
        const source_trust_class = self.source_trust_class orelse defaultTrustForKind(source_kind);
        if (self.decision == .none) return error.InvalidAbstractionCatalog;
        if (self.decision == .promote and self.local_concept_id == null) return error.InvalidAbstractionCatalog;

        const out = ReuseEntry{
            .allocator = self.allocator,
            .decision = self.decision,
            .source_kind = source_kind,
            .source_id = source_id,
            .source_concept_id = source_concept_id,
            .source_consensus_hash = self.source_consensus_hash,
            .source_lineage_id = source_lineage_id,
            .source_lineage_version = self.source_lineage_version,
            .source_trust_class = source_trust_class,
            .local_concept_id = self.local_concept_id,
            .local_consensus_hash = self.local_consensus_hash,
            .local_lineage_id = self.local_lineage_id,
            .local_lineage_version = self.local_lineage_version,
            .local_trust_class = self.local_trust_class,
        };
        self.source_kind = null;
        self.source_id = null;
        self.source_concept_id = null;
        self.source_lineage_id = null;
        self.local_concept_id = null;
        self.local_lineage_id = null;
        return out;
    }
};

fn parseVectorLine(text: []const u8) !vsa.HyperVector {
    var lanes = [_]u64{0} ** 64; // 4096-bit HyperVector (64 lanes)
    var parts = std.mem.splitScalar(u8, text, ',');
    var idx: usize = 0;
    while (parts.next()) |part| {
        if (idx >= lanes.len) return error.InvalidAbstractionCatalog;
        lanes[idx] = try std.fmt.parseUnsigned(u64, part, 16);
        idx += 1;
    }
    // accept full 64-lane (4096-bit) entries, or legacy 16-lane (1024-bit) catalogs zero-extended into the low lanes
    if (idx != 64 and idx != 16) return error.InvalidAbstractionCatalog;
    return lanes;
}

fn appendVectorLine(out: *std.ArrayList(u8), vector: vsa.HyperVector) !void {
    try out.appendSlice("vector ");
    for (0..16) |idx| {
        if (idx != 0) try out.append(',');
        var buf: [32]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&buf, "{x}", .{vector[idx]});
        try out.appendSlice(rendered);
    }
    try out.append('\n');
}

fn appendLine(out: *std.ArrayList(u8), prefix: []const u8, value: []const u8) !void {
    try out.appendSlice(prefix);
    try out.append(' ');
    try out.appendSlice(value);
    try out.append('\n');
}

fn appendLineInt(out: *std.ArrayList(u8), prefix: []const u8, value: anytype) !void {
    try out.appendSlice(prefix);
    try out.append(' ');
    var buf: [64]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try out.appendSlice(rendered);
    try out.append('\n');
}

fn deinitCatalog(records: *std.ArrayList(Record)) void {
    for (records.items) |*record| record.deinit();
    records.deinit();
}

fn deinitReuseCatalog(entries: *std.ArrayList(ReuseEntry)) void {
    for (entries.items) |*entry| entry.deinit();
    entries.deinit();
}

fn upsertRecord(records: *std.ArrayList(Record), record: Record) !void {
    for (records.items) |*existing| {
        if (!std.mem.eql(u8, existing.concept_id, record.concept_id)) continue;
        existing.deinit();
        existing.* = record;
        return;
    }
    try records.append(record);
}

fn upsertReuseEntry(entries: *std.ArrayList(ReuseEntry), entry: ReuseEntry) !void {
    for (entries.items) |*existing| {
        if (existing.source_kind != entry.source_kind) continue;
        if (!std.mem.eql(u8, existing.source_id, entry.source_id)) continue;
        if (!std.mem.eql(u8, existing.source_concept_id, entry.source_concept_id)) continue;
        existing.deinit();
        existing.* = entry;
        return;
    }
    try entries.append(entry);
}

fn findRecordByConcept(records: []const Record, concept_id: []const u8) ?*const Record {
    for (records) |*record| {
        if (std.mem.eql(u8, record.concept_id, concept_id)) return record;
    }
    return null;
}

fn conflictingLocalConflict(local_record: ?*const Record, source_record: *const Record) bool {
    const local = local_record orelse return false;
    return !recordsCompatible(local, source_record);
}

fn recordsCompatible(lhs: *const Record, rhs: *const Record) bool {
    if (lhs.consensus_hash != rhs.consensus_hash) return false;
    if (lhs.tier != rhs.tier) return false;
    if (lhs.category != rhs.category) return false;
    return stringOptionEql(lhs.parent_concept_id, rhs.parent_concept_id);
}

fn cloneStringSlice(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, items.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = try allocator.dupe(u8, item);
        copied += 1;
    }
    return out;
}

fn freeStringSlice(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn appendOwnedUnique(list: *std.ArrayList([]u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (list.items) |item| {
        if (std.mem.eql(u8, item, text)) return;
    }
    try list.append(try allocator.dupe(u8, text));
}

fn containsText(items: []const []const u8, target: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, target)) return true;
    }
    return false;
}

fn sanitizeConceptId(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \r\n\t/");
    if (trimmed.len == 0) return error.InvalidAbstractionCommand;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (trimmed) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') {
            try out.append(std.ascii.toLower(byte));
        } else {
            try out.append('_');
        }
    }
    return out.toOwnedSlice();
}

fn parseTier(text: []const u8) ?Tier {
    if (std.ascii.eqlIgnoreCase(text, "pattern")) return .pattern;
    if (std.ascii.eqlIgnoreCase(text, "convention") or std.ascii.eqlIgnoreCase(text, "idiom")) return .convention;
    if (std.ascii.eqlIgnoreCase(text, "logic") or std.ascii.eqlIgnoreCase(text, "mechanism")) return .logic;
    if (std.ascii.eqlIgnoreCase(text, "contract")) return .contract;
    return null;
}

fn parseCategory(text: []const u8) ?Category {
    if (std.ascii.eqlIgnoreCase(text, "structural") or std.ascii.eqlIgnoreCase(text, "syntax")) return .structural;
    if (std.ascii.eqlIgnoreCase(text, "procedural") or std.ascii.eqlIgnoreCase(text, "control_flow")) return .procedural;
    if (std.ascii.eqlIgnoreCase(text, "relational") or std.ascii.eqlIgnoreCase(text, "data_flow")) return .relational;
    if (std.ascii.eqlIgnoreCase(text, "boundary") or std.ascii.eqlIgnoreCase(text, "interface")) return .boundary;
    if (std.ascii.eqlIgnoreCase(text, "state")) return .state;
    if (std.ascii.eqlIgnoreCase(text, "invariant")) return .invariant;
    return null;
}

fn parseFamily(text: []const u8) ?Family {
    if (std.ascii.eqlIgnoreCase(text, "distilled")) return .distilled;
    if (std.ascii.eqlIgnoreCase(text, "parser_sketch")) return .parser_sketch;
    if (std.ascii.eqlIgnoreCase(text, "grounding_schema")) return .grounding_schema;
    if (std.ascii.eqlIgnoreCase(text, "route_suppressor")) return .route_suppressor;
    if (std.ascii.eqlIgnoreCase(text, "claim_template")) return .claim_template;
    if (std.ascii.eqlIgnoreCase(text, "intent_interpretation")) return .intent_interpretation;
    if (std.ascii.eqlIgnoreCase(text, "action_surface")) return .action_surface;
    if (std.ascii.eqlIgnoreCase(text, "verifier_pattern")) return .verifier_pattern;
    return null;
}

fn tierRank(tier: Tier) u16 {
    return switch (tier) {
        .pattern => 0,
        .convention => 1,
        .logic => 2,
        .contract => 3,
    };
}

fn tierQualityFloor(tier: Tier) u16 {
    return switch (tier) {
        .pattern => 560,
        .convention => 620,
        .logic => 690,
        .contract => 760,
    };
}

fn tierConfidenceFloor(tier: Tier) u16 {
    return switch (tier) {
        .pattern => 560,
        .convention => 630,
        .logic => 700,
        .contract => 780,
    };
}

fn tierPromotionSupportFloor(tier: Tier) u16 {
    return switch (tier) {
        .pattern => 1,
        .convention => 1,
        .logic => 1,
        .contract => 2,
    };
}

fn computeSupportScore(example_count: usize, threshold_examples: u32, token_count: usize, pattern_count: usize) u16 {
    var score: u32 = 0;
    score += @as(u32, @intCast(@min(example_count, MAX_EXAMPLES))) * @as(u32, 30);
    score += @min(threshold_examples, @as(u32, MAX_EXAMPLES)) * @as(u32, 20);
    score += @as(u32, @intCast(@min(token_count, MAX_TOKENS))) * @as(u32, 6);
    score += @as(u32, @intCast(@min(pattern_count, MAX_PATTERNS))) * @as(u32, 10);
    return @intCast(@min(score, @as(u32, 400)));
}

fn computeReuseScore(source_count: usize, tier: Tier, has_parent: bool) u16 {
    var score: u32 = @as(u32, @intCast(@min(source_count, MAX_SOURCE_SPECS))) * @as(u32, 40);
    score += @as(u32, tierRank(tier)) * @as(u32, 20);
    if (has_parent) score += @as(u32, 40);
    return @intCast(@min(score, @as(u32, 250)));
}

fn computeQualityScore(average_resonance: u16, min_resonance: u16, support_score: u16, reuse_score: u16) u16 {
    const weighted_resonance = (@as(u32, min_resonance) * 55 + @as(u32, average_resonance) * 45) / 100;
    const resonance_score: u32 = if (weighted_resonance <= MIN_COMMIT_RESONANCE)
        350
    else
        350 + ((weighted_resonance - MIN_COMMIT_RESONANCE) * 250) / (config.HYPERVECTOR_BITS - MIN_COMMIT_RESONANCE);
    const total = resonance_score + @as(u32, support_score) / 2 + @as(u32, reuse_score) / 2;
    return @intCast(@min(total, @as(u32, MAX_SCORE)));
}

fn computeConfidenceScore(
    average_resonance: u16,
    min_resonance: u16,
    quality_score: u16,
    example_count: usize,
    source_count: usize,
) u16 {
    var score: u32 = @as(u32, quality_score) / 2;
    score += @as(u32, min_resonance) / 3;
    score += @as(u32, average_resonance) / 4;
    score += @as(u32, @intCast(@min(example_count, MAX_EXAMPLES))) * @as(u32, 18);
    score += @as(u32, @intCast(@min(source_count, MAX_SOURCE_SPECS))) * @as(u32, 12);
    return @intCast(@min(score, @as(u32, MAX_SCORE)));
}

fn computePromotionReady(
    tier: Tier,
    quality_score: u16,
    confidence_score: u16,
    example_count: usize,
    threshold_examples: u32,
    source_count: usize,
) bool {
    if (tier == .pattern) return false;
    return quality_score >= tierQualityFloor(tier) and
        confidence_score >= tierConfidenceFloor(tier) and
        example_count >= threshold_examples and
        source_count >= 2;
}

fn parseTrustClass(text: []const u8) ?TrustClass {
    if (std.ascii.eqlIgnoreCase(text, "exploratory")) return .exploratory;
    if (std.ascii.eqlIgnoreCase(text, "project")) return .project;
    if (std.ascii.eqlIgnoreCase(text, "promoted")) return .promoted;
    if (std.ascii.eqlIgnoreCase(text, "core")) return .core;
    return null;
}

fn parseDecayState(text: []const u8) ?DecayState {
    if (std.ascii.eqlIgnoreCase(text, "active")) return .active;
    if (std.ascii.eqlIgnoreCase(text, "stale")) return .stale;
    if (std.ascii.eqlIgnoreCase(text, "prunable")) return .prunable;
    if (std.ascii.eqlIgnoreCase(text, "protected")) return .protected;
    return null;
}

fn defaultTrustForKind(kind: shards.Kind) TrustClass {
    return switch (kind) {
        .core => .core,
        .project => .project,
        .scratch => .exploratory,
    };
}

pub const TrustDecayPolicy = struct {
    exploratory_rank: u8 = 0,
    project_rank: u8 = 1,
    promoted_rank: u8 = 2,
    core_rank: u8 = 3,
    contradiction_decay_threshold: u8 = 2,
    core_immune_to_contradiction: bool = false,
};

pub const DEFAULT_TRUST_POLICY = TrustDecayPolicy{};

pub fn trustRank(class: TrustClass, policy: TrustDecayPolicy) u8 {
    return switch (class) {
        .exploratory => policy.exploratory_rank,
        .project => policy.project_rank,
        .promoted => policy.promoted_rank,
        .core => policy.core_rank,
    };
}

fn decayRank(state: DecayState) u8 {
    return switch (state) {
        .active => 0,
        .protected => 1,
        .stale => 2,
        .prunable => 3,
    };
}

fn stateLivePath(allocator: std.mem.Allocator, paths: *const shards.Paths) ![]u8 {
    return std.fs.path.join(allocator, &.{ paths.abstractions_root_abs_path, STATE_FILE_NAME });
}

fn makeLineageId(allocator: std.mem.Allocator, owner_kind: shards.Kind, owner_id: []const u8, concept_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ @tagName(owner_kind), owner_id, concept_id });
}

fn buildOperationProvenance(
    allocator: std.mem.Allocator,
    operation: LineageOperation,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    concept_id: []const u8,
    lineage_id: []const u8,
    lineage_version: u32,
    trust_class: TrustClass,
    extra: ?[]const u8,
) ![]u8 {
    if (extra) |value| {
        return std.fmt.allocPrint(
            allocator,
            "{s}|owner={s}/{s}|concept={s}|lineage={s}@{d}|trust={s}|extra={s}",
            .{
                lineageOperationName(operation),
                @tagName(owner_kind),
                owner_id,
                concept_id,
                lineage_id,
                lineage_version,
                trustClassName(trust_class),
                value,
            },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}|owner={s}/{s}|concept={s}|lineage={s}@{d}|trust={s}",
        .{
            lineageOperationName(operation),
            @tagName(owner_kind),
            owner_id,
            concept_id,
            lineage_id,
            lineage_version,
            trustClassName(trust_class),
        },
    );
}

fn appendRecordProvenance(record: *Record, allocator: std.mem.Allocator, entry: []u8) !void {
    errdefer allocator.free(entry);
    if (record.provenance.len >= MAX_PROVENANCE_ENTRIES) {
        allocator.free(record.provenance[0]);
        var idx: usize = 1;
        while (idx < record.provenance.len) : (idx += 1) {
            record.provenance[idx - 1] = record.provenance[idx];
        }
        record.provenance[record.provenance.len - 1] = entry;
        return;
    }

    const next = try allocator.alloc([]u8, record.provenance.len + 1);
    for (record.provenance, 0..) |item, idx| next[idx] = item;
    next[record.provenance.len] = entry;
    if (record.provenance.len > 0) allocator.free(record.provenance);
    record.provenance = next;
}

fn applyInitialRecordMetadata(
    allocator: std.mem.Allocator,
    record: *Record,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    trust_class: TrustClass,
    operation: LineageOperation,
) !void {
    if (record.lineage_id.len == 0) record.lineage_id = try makeLineageId(allocator, owner_kind, owner_id, record.concept_id);
    if (record.lineage_version == 0) record.lineage_version = 1;
    record.trust_class = trust_class;
    if (record.provenance.len == 0) {
        const extra = try std.fmt.allocPrint(allocator, "hash={d}", .{record.consensus_hash});
        defer allocator.free(extra);
        try appendRecordProvenance(record, allocator, try buildOperationProvenance(
            allocator,
            operation,
            owner_kind,
            owner_id,
            record.concept_id,
            record.lineage_id,
            record.lineage_version,
            trust_class,
            extra,
        ));
    }
}

fn inheritExistingRecordIdentity(
    record: *Record,
    staged_records: []const Record,
    live_records: []const Record,
    owner_kind: shards.Kind,
    owner_id: []const u8,
) !void {
    _ = owner_kind;
    _ = owner_id;
    const existing = findRecordByConcept(staged_records, record.concept_id) orelse findRecordByConcept(live_records, record.concept_id) orelse return;
    if (record.lineage_id.len > 0) record.allocator.free(record.lineage_id);
    record.lineage_id = try record.allocator.dupe(u8, existing.lineage_id);
    record.lineage_version = existing.lineage_version + 1;
    record.trust_class = existing.trust_class;
    record.decay_state = existing.decay_state;
    record.first_revision = existing.first_revision;
    record.last_revision = existing.last_revision;
    record.last_review_revision = existing.last_review_revision;
}

fn finalizeStagedRecord(
    allocator: std.mem.Allocator,
    record: *Record,
    live_records: []const Record,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    revision: u32,
) !void {
    if (record.lineage_id.len == 0) record.lineage_id = try makeLineageId(allocator, owner_kind, owner_id, record.concept_id);
    if (findRecordByConcept(live_records, record.concept_id)) |existing| {
        if (record.lineage_version <= existing.lineage_version) record.lineage_version = existing.lineage_version + 1;
        if (record.first_revision == 0) record.first_revision = existing.first_revision;
        if (record.last_review_revision == 0) record.last_review_revision = existing.last_review_revision;
    } else {
        if (record.lineage_version == 0) record.lineage_version = 1;
        if (record.first_revision == 0) record.first_revision = revision;
    }
    record.last_revision = revision;
    if (record.last_review_revision == 0 and record.decay_state == .active) record.last_review_revision = revision;
}

fn normalizeCatalogRecords(
    allocator: std.mem.Allocator,
    records: []Record,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    default_trust: TrustClass,
) !void {
    for (records) |*record| {
        if (record.lineage_id.len == 0) record.lineage_id = try makeLineageId(allocator, owner_kind, owner_id, record.concept_id);
        if (record.lineage_version == 0) record.lineage_version = 1;
        if (record.family != .distilled) refreshReinforcementRecord(record);
        if (record.trust_class == .exploratory and owner_kind != .scratch and record.provenance.len == 0) {
            record.trust_class = default_trust;
        }
        if (record.provenance.len == 0) {
            const extra = try std.fmt.allocPrint(allocator, "hash={d}", .{record.consensus_hash});
            defer allocator.free(extra);
            try appendRecordProvenance(record, allocator, try buildOperationProvenance(
                allocator,
                .distilled,
                owner_kind,
                owner_id,
                record.concept_id,
                record.lineage_id,
                record.lineage_version,
                record.trust_class,
                extra,
            ));
        }
    }
}

fn normalizeReuseEntries(
    allocator: std.mem.Allocator,
    entries: []ReuseEntry,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    local_records: []const Record,
) !void {
    for (entries) |*entry| {
        _ = owner_kind;
        _ = owner_id;
        if (entry.source_lineage_id.len == 0) entry.source_lineage_id = try makeLineageId(allocator, entry.source_kind, entry.source_id, entry.source_concept_id);
        if (entry.source_lineage_version == 0) entry.source_lineage_version = 1;
        if (entry.local_concept_id != null and entry.local_lineage_id == null) {
            if (findRecordByConcept(local_records, entry.local_concept_id.?)) |record| {
                entry.local_lineage_id = try allocator.dupe(u8, record.lineage_id);
                entry.local_lineage_version = record.lineage_version;
                entry.local_trust_class = record.trust_class;
            }
        }
    }
}

fn reinforcementConceptId(allocator: std.mem.Allocator, event: ReinforcementEvent) ![]u8 {
    const key = try sanitizeConceptId(allocator, event.key);
    defer allocator.free(key);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ familyName(event.family), key });
}

fn initReinforcementRecord(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    event: ReinforcementEvent,
    concept_id: []const u8,
) !Record {
    var record = Record{
        .allocator = allocator,
        .concept_id = try allocator.dupe(u8, concept_id),
        .family = event.family,
        .tier = event.tier,
        .category = event.category,
        .example_count = 0,
        .threshold_examples = reinforcementSuccessFloor(event.family),
        .retained_token_count = @intCast(event.tokens.len),
        .retained_pattern_count = @intCast(event.patterns.len),
        .average_resonance = MIN_COMMIT_RESONANCE,
        .min_resonance = MIN_COMMIT_RESONANCE,
        .consensus_hash = std.hash.Fnv1a_64.hash(concept_id),
        .valid_to_commit = true,
        .vector = @splat(@as(u64, 0)),
        .sources = try cloneStringSlice(allocator, event.source_specs),
        .tokens = try cloneStringSlice(allocator, event.tokens),
        .patterns = try cloneStringSlice(allocator, event.patterns),
    };
    errdefer record.deinit();
    try applyInitialRecordMetadata(allocator, &record, paths.metadata.kind, paths.metadata.id, defaultTrustForKind(paths.metadata.kind), .reinforce_observe);
    return record;
}

fn reinforcementExtra(allocator: std.mem.Allocator, event: ReinforcementEvent) ![]u8 {
    if (event.detail) |detail| {
        return std.fmt.allocPrint(allocator, "family={s};case={s};outcome={s};detail={s}", .{
            familyName(event.family),
            event.case_id,
            reinforcementOutcomeName(event.outcome),
            detail,
        });
    }
    return std.fmt.allocPrint(allocator, "family={s};case={s};outcome={s}", .{
        familyName(event.family),
        event.case_id,
        reinforcementOutcomeName(event.outcome),
    });
}

fn applyReinforcementOutcome(record: *Record, outcome: ReinforcementOutcome, policy: TrustDecayPolicy) void {
    switch (outcome) {
        .success => {
            record.success_count +|= 1;
            record.independent_case_count +|= 1;
            record.example_count = record.success_count;
        },
        .failure => record.failure_count +|= 1,
        .ambiguous => record.ambiguity_count +|= 1,
        .contradicted => {
            record.contradiction_count +|= 1;
            if (record.contradiction_count >= policy.contradiction_decay_threshold) {
                if (record.trust_class == .core and policy.core_immune_to_contradiction) {
                    // Immune
                } else if (record.trust_class == .core) {
                    record.trust_class = .promoted;
                    record.decay_state = .stale;
                } else if (record.trust_class == .promoted) {
                    record.trust_class = .project;
                    record.decay_state = .stale;
                } else if (record.trust_class == .project) {
                    record.trust_class = .exploratory;
                    record.decay_state = .prunable;
                }
            }
        },
    }
}

/// Public wrapper for cross-module policy tests.
/// The underlying applyReinforcementOutcome is intentionally private since
/// it is an internal detail of the reinforcement loop. This wrapper exists
/// solely so artifact_policy tests can verify trust decay behavior without
/// duplicating logic.
pub fn applyReinforcementOutcomePublic(record: *Record, outcome: ReinforcementOutcome, policy: TrustDecayPolicy) void {
    applyReinforcementOutcome(record, outcome, policy);
}

fn reinforcementCaseSeen(record: *const Record, case_id: []const u8, outcome: ReinforcementOutcome) bool {
    var needle_buf = std.ArrayList(u8).init(record.allocator);
    defer needle_buf.deinit();
    needle_buf.appendSlice("case=") catch return false;
    needle_buf.appendSlice(case_id) catch return false;
    needle_buf.appendSlice(";outcome=") catch return false;
    needle_buf.appendSlice(reinforcementOutcomeName(outcome)) catch return false;
    for (record.provenance) |entry| {
        if (std.mem.indexOf(u8, entry, needle_buf.items) != null) return true;
    }
    return false;
}

fn reinforcementSuccessFloor(family: Family) u32 {
    return switch (family) {
        .parser_sketch => 3,
        .grounding_schema => 2,
        .route_suppressor => 2,
        .claim_template => 2,
        .intent_interpretation => 2,
        .action_surface => 2,
        .verifier_pattern => 2,
        .distilled => 2,
    };
}

fn reinforcementIndependentFloor(family: Family) u32 {
    return switch (family) {
        .parser_sketch => 2,
        .grounding_schema => 2,
        .route_suppressor => 2,
        .claim_template => 2,
        .intent_interpretation => 2,
        .action_surface => 2,
        .verifier_pattern => 2,
        .distilled => 2,
    };
}

fn reinforcementUsable(record: *const Record) bool {
    if (record.family == .distilled) return true;
    if (record.decay_state != .active and record.decay_state != .protected) return false;
    if (!record.promotion_ready) return false;
    if (record.failure_count >= 2) return false;
    if (record.ambiguity_count >= 2) return false;
    if (record.contradiction_count > 0) return false;
    return true;
}

fn refreshReinforcementRecord(record: *Record) void {
    if (record.family == .distilled) return;
    record.threshold_examples = reinforcementSuccessFloor(record.family);
    record.example_count = record.success_count;
    record.retained_token_count = @intCast(record.tokens.len);
    record.retained_pattern_count = @intCast(record.patterns.len);
    const positive = record.success_count * 180 + record.independent_case_count * 140;
    const negative = record.failure_count * 180 + record.ambiguity_count * 150 + record.contradiction_count * 320;
    record.support_score = @intCast(@min(@as(u32, 400), positive));
    record.reuse_score = @intCast(@min(@as(u32, 250), record.independent_case_count * 80));
    record.quality_score = @intCast(@min(@as(u32, MAX_SCORE), 420 + positive -| negative));
    record.confidence_score = @intCast(@min(@as(u32, MAX_SCORE), 360 + positive -| negative));
    record.promotion_ready = record.success_count >= record.threshold_examples and
        record.independent_case_count >= reinforcementIndependentFloor(record.family) and
        record.failure_count == 0 and
        record.ambiguity_count <= 1 and
        record.contradiction_count == 0;
    record.decay_state = if (record.contradiction_count > 0 or record.failure_count >= 2 or record.ambiguity_count >= 2)
        .stale
    else
        .active;
}

fn promotionLineageOperation(record: *const Record) ?LineageOperation {
    if (record.family == .distilled) return null;
    if (record.decay_state == .stale) return .reinforce_demote;
    if (record.promotion_ready) return .reinforce_promote;
    return null;
}

fn recordHasLineageOperation(record: *const Record, operation: LineageOperation) bool {
    const needle = lineageOperationName(operation);
    for (record.provenance) |entry| {
        if (std.mem.startsWith(u8, entry, needle)) return true;
    }
    return false;
}

fn adoptSourceRecord(
    allocator: std.mem.Allocator,
    source_record: *const Record,
    source_kind: shards.Kind,
    source_id: []const u8,
    target_concept_id: []const u8,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    mode: MergeMode,
) !Record {
    var record = try source_record.clone(allocator);
    errdefer record.deinit();
    allocator.free(record.concept_id);
    record.concept_id = try allocator.dupe(u8, target_concept_id);
    if (record.lineage_id.len > 0) allocator.free(record.lineage_id);
    record.lineage_id = try makeLineageId(allocator, owner_kind, owner_id, record.concept_id);
    record.lineage_version = 1;
    record.trust_class = switch (mode) {
        .adopt => source_record.trust_class,
        .promote => .promoted,
    };
    record.decay_state = .active;
    record.first_revision = 0;
    record.last_revision = 0;
    record.last_review_revision = 0;
    const extra = try std.fmt.allocPrint(
        allocator,
        "from={s}/{s}:{s}@{d}",
        .{ @tagName(source_kind), source_id, source_record.lineage_id, source_record.lineage_version },
    );
    defer allocator.free(extra);
    try appendRecordProvenance(&record, allocator, try buildOperationProvenance(
        allocator,
        if (mode == .adopt) .merge_adopt else .merge_promote,
        owner_kind,
        owner_id,
        record.concept_id,
        record.lineage_id,
        record.lineage_version,
        record.trust_class,
        extra,
    ));
    return record;
}

fn mergeCompatibleRecord(
    allocator: std.mem.Allocator,
    current: *const Record,
    source: *const Record,
    source_kind: shards.Kind,
    source_id: []const u8,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    mode: MergeMode,
) !Record {
    var merged = try current.clone(allocator);
    errdefer merged.deinit();
    merged.trust_class = @enumFromInt(@max(@intFromEnum(merged.trust_class), @intFromEnum(if (mode == .promote) TrustClass.promoted else source.trust_class)));
    merged.decay_state = .active;
    merged.lineage_version = current.lineage_version + 1;
    merged.last_review_revision = current.last_review_revision;
    try mergeUniqueTextInto(&merged.sources, allocator, source.sources);
    try mergeUniqueTextInto(&merged.tokens, allocator, source.tokens);
    try mergeUniqueTextInto(&merged.patterns, allocator, source.patterns);
    try mergeUniqueTextInto(&merged.provenance, allocator, source.provenance);
    const extra = try std.fmt.allocPrint(
        allocator,
        "from={s}/{s}:{s}@{d}",
        .{ @tagName(source_kind), source_id, source.lineage_id, source.lineage_version },
    );
    defer allocator.free(extra);
    try appendRecordProvenance(&merged, allocator, try buildOperationProvenance(
        allocator,
        if (mode == .adopt) .merge_adopt else .merge_promote,
        owner_kind,
        owner_id,
        merged.concept_id,
        merged.lineage_id,
        merged.lineage_version,
        merged.trust_class,
        extra,
    ));
    merged.reuse_score = computeReuseScore(merged.sources.len, merged.tier, merged.parent_concept_id != null);
    return merged;
}

fn provenanceMergeAllowed(current: *const Record, source: *const Record, mode: MergeMode, destination_trust: TrustClass) bool {
    if (current.decay_state == .protected and mode != .promote) return false;
    if (mode == .promote and trustRank(destination_trust, DEFAULT_TRUST_POLICY) <= trustRank(source.trust_class, DEFAULT_TRUST_POLICY)) return false;
    return true;
}

fn mergeUniqueTextInto(list_ptr: *[][]u8, allocator: std.mem.Allocator, items: []const []const u8) !void {
    var list = std.ArrayList([]u8).init(allocator);
    defer list.deinit();
    for (list_ptr.*) |item| try list.append(item);
    for (items) |item| {
        var found = false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, item)) {
                found = true;
                break;
            }
        }
        if (!found) try list.append(try allocator.dupe(u8, item));
    }
    if (list_ptr.*.len > 0) allocator.free(list_ptr.*);
    list_ptr.* = try list.toOwnedSlice();
}

fn findMutableRecord(records: []Record, concept_id: []const u8) ?*Record {
    for (records) |*record| {
        if (std.mem.eql(u8, record.concept_id, concept_id)) return record;
    }
    return null;
}

fn pruneCollectEligible(record: *const Record, state: CatalogState, gap: u32, quality: u16, confidence: u16, trust_limit: TrustClass) bool {
    if (record.decay_state == .protected or record.decay_state == .prunable) return false;
    if (trustRank(record.trust_class, DEFAULT_TRUST_POLICY) > trustRank(trust_limit, DEFAULT_TRUST_POLICY)) return false;
    if (record.quality_score > quality or record.confidence_score > confidence) return false;
    const last_seen = @max(record.last_review_revision, record.last_revision);
    return state.revision >= last_seen + gap;
}

fn loadCatalogState(allocator: std.mem.Allocator, paths: *const shards.Paths) !CatalogState {
    const abs_path = try stateLivePath(allocator, paths);
    defer allocator.free(abs_path);
    if (!fileExists(abs_path)) {
        return .{ .default_trust = defaultTrustForKind(paths.metadata.kind) };
    }

    const bytes = try readOwnedFile(allocator, abs_path, 8 * 1024);
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const magic = lines.next() orelse return error.InvalidAbstractionCatalog;
    if (!std.mem.eql(u8, std.mem.trimRight(u8, magic, "\r"), STATE_MAGIC_LINE)) return error.InvalidAbstractionCatalog;

    var state = CatalogState{ .default_trust = defaultTrustForKind(paths.metadata.kind) };
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "revision ")) {
            state.revision = try std.fmt.parseUnsigned(u32, line["revision ".len..], 10);
        } else if (std.mem.startsWith(u8, line, "default_trust ")) {
            state.default_trust = parseTrustClass(line["default_trust ".len..]) orelse return error.InvalidAbstractionCatalog;
        } else if (std.mem.startsWith(u8, line, "last_merge_revision ")) {
            state.last_merge_revision = try std.fmt.parseUnsigned(u32, line["last_merge_revision ".len..], 10);
        } else if (std.mem.startsWith(u8, line, "last_prune_revision ")) {
            state.last_prune_revision = try std.fmt.parseUnsigned(u32, line["last_prune_revision ".len..], 10);
        } else {
            return error.InvalidAbstractionCatalog;
        }
    }
    return state;
}

fn persistCatalogState(allocator: std.mem.Allocator, paths: *const shards.Paths, state: CatalogState) !void {
    const abs_path = try stateLivePath(allocator, paths);
    defer allocator.free(abs_path);
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try out.appendSlice(STATE_MAGIC_LINE);
    try out.append('\n');
    try appendLineInt(&out, "revision", state.revision);
    try appendLine(&out, "default_trust", trustClassName(state.default_trust));
    try appendLineInt(&out, "last_merge_revision", state.last_merge_revision);
    try appendLineInt(&out, "last_prune_revision", state.last_prune_revision);
    try ensureParentDir(allocator, abs_path);
    try writeOwnedFile(allocator, abs_path, out.items);
}

fn isKeyword(token: []const u8) bool {
    const keywords = [_][]const u8{
        "if",     "else", "return", "try",      "catch", "orelse",   "const", "var", "pub",  "fn",   "switch",
        "while",  "for",  "break",  "continue", "defer", "errdefer", "and",   "or",  "null", "true", "false",
        "struct", "enum", "union",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, token, keyword)) return true;
    }
    return false;
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isIdentifierContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isSignificantToken(token: []const u8) bool {
    if (std.mem.eql(u8, token, "id") or std.mem.eql(u8, token, "#") or std.mem.eql(u8, token, "str")) return false;
    if (token.len == 1 and std.mem.indexOfScalar(u8, "(){}[];,.:", token[0]) != null) return false;
    return true;
}

fn asciiLowerDup(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, idx| out[idx] = std.ascii.toLower(byte);
    return out;
}

fn fileExists(abs_path: []const u8) bool {
    const file = std.fs.openFileAbsolute(abs_path, .{}) catch return false;
    file.close();
    return true;
}

fn readOwnedFile(allocator: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn writeOwnedFile(allocator: std.mem.Allocator, abs_path: []const u8, bytes: []const u8) !void {
    const handle = try sys.openForWrite(allocator, abs_path);
    defer sys.closeFile(handle);
    try sys.writeAll(handle, bytes);
}

fn ensureParentDir(allocator: std.mem.Allocator, abs_path: []const u8) !void {
    const parent = std.fs.path.dirname(abs_path) orelse return;
    try sys.makePath(allocator, parent);
}

fn deleteFileIfExists(abs_path: []const u8) !void {
    std.fs.deleteFileAbsolute(abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn findMatchingBracket(text: []const u8, open_index: usize) ?usize {
    var depth: usize = 0;
    var i = open_index;
    while (i < text.len) : (i += 1) {
        if (text[i] == '[') depth += 1;
        if (text[i] == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findMatchingBrace(text: []const u8, open_index: usize) ?usize {
    var depth: usize = 0;
    var i = open_index;
    while (i < text.len) : (i += 1) {
        if (text[i] == '{') depth += 1;
        if (text[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn jsonLooseString(body: []const u8, key: []const u8, out: *std.ArrayList(u8)) ?[]const u8 {
    out.clearRetainingCapacity();
    var pat_buf: [96]u8 = undefined;
    const key_pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, key_pat) orelse return null;
    var pos = idx + key_pat.len;
    while (pos < body.len and std.ascii.isWhitespace(body[pos])) : (pos += 1) {}
    if (pos >= body.len or body[pos] != ':') return null;
    pos += 1;
    while (pos < body.len and std.ascii.isWhitespace(body[pos])) : (pos += 1) {}
    if (pos >= body.len or body[pos] != '"') return null;
    pos += 1;

    while (pos < body.len) : (pos += 1) {
        const byte = body[pos];
        if (byte == '"') return out.items;
        if (byte == '\\') {
            pos += 1;
            if (pos >= body.len) return null;
            const escaped = body[pos];
            switch (escaped) {
                '"', '\\', '/' => out.append(escaped) catch return null,
                'n' => out.append('\n') catch return null,
                'r' => out.append('\r') catch return null,
                't' => out.append('\t') catch return null,
                else => return null,
            }
            continue;
        }
        out.append(byte) catch return null;
    }
    return null;
}

fn jsonLooseUnsigned(body: []const u8, key: []const u8) ?u32 {
    var pat_buf: [96]u8 = undefined;
    const key_pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, key_pat) orelse return null;
    var pos = idx + key_pat.len;
    while (pos < body.len and std.ascii.isWhitespace(body[pos])) : (pos += 1) {}
    if (pos >= body.len or body[pos] != ':') return null;
    pos += 1;
    while (pos < body.len and std.ascii.isWhitespace(body[pos])) : (pos += 1) {}
    const start = pos;
    while (pos < body.len and std.ascii.isDigit(body[pos])) : (pos += 1) {}
    if (pos == start) return null;
    return std.fmt.parseUnsigned(u32, body[start..pos], 10) catch null;
}

fn appendEscapedJson(out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '\\' => try out.appendSlice("\\\\"),
        '"' => try out.appendSlice("\\\""),
        '\n' => try out.appendSlice("\\n"),
        '\r' => try out.appendSlice("\\r"),
        '\t' => try out.appendSlice("\\t"),
        else => try out.append(byte),
    };
}

fn appendIntJson(out: *std.ArrayList(u8), value: anytype) !void {
    var buf: [64]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try out.appendSlice(rendered);
}

fn appendStringArrayJson(out: *std.ArrayList(u8), items: []const []const u8) !void {
    try out.append('[');
    for (items, 0..) |item, idx| {
        if (idx != 0) try out.append(',');
        try out.append('"');
        try appendEscapedJson(out, item);
        try out.append('"');
    }
    try out.append(']');
}

test "trust decay: contradictions degrade promoted and core knowledge unless immune" {
    const allocator = std.testing.allocator;

    var core_record: Record = undefined;
    core_record.concept_id = try allocator.dupe(u8, "test");
    core_record.category = .structural;
    core_record.tier = .pattern;
    core_record.trust_class = .core;
    core_record.decay_state = .active;
    core_record.allocator = allocator;
    core_record.contradiction_count = 0;

    // Default policy: 2 contradictions decays
    const policy = TrustDecayPolicy{};

    // First contradiction: count increases, state remains core
    applyReinforcementOutcome(&core_record, .contradicted, policy);
    try std.testing.expectEqual(TrustClass.core, core_record.trust_class);

    // Second contradiction: hits threshold (2), decays to promoted/stale
    applyReinforcementOutcome(&core_record, .contradicted, policy);
    try std.testing.expectEqual(TrustClass.promoted, core_record.trust_class);
    try std.testing.expectEqual(DecayState.stale, core_record.decay_state);

    // Test immunity
    var immune_core: Record = undefined;
    immune_core.concept_id = try allocator.dupe(u8, "test");
    immune_core.category = .structural;
    immune_core.tier = .pattern;
    immune_core.trust_class = .core;
    immune_core.decay_state = .active;
    immune_core.allocator = allocator;
    immune_core.contradiction_count = 0;

    var immune_policy = policy;
    immune_policy.core_immune_to_contradiction = true;

    applyReinforcementOutcome(&immune_core, .contradicted, immune_policy);
    applyReinforcementOutcome(&immune_core, .contradicted, immune_policy);
    try std.testing.expectEqual(TrustClass.core, immune_core.trust_class); // Immune

    allocator.free(core_record.concept_id);
    allocator.free(immune_core.concept_id);
}

test "parseTier and parseCategory correctly parse standard names" {
    // Tests for Tier parsing
    try std.testing.expectEqual(Tier.pattern, parseTier("pattern"));
    try std.testing.expectEqual(Tier.convention, parseTier("convention"));
    try std.testing.expectEqual(Tier.logic, parseTier("logic"));
    try std.testing.expectEqual(Tier.contract, parseTier("contract"));

    // Tests for Category parsing
    try std.testing.expectEqual(Category.structural, parseCategory("structural"));
    try std.testing.expectEqual(Category.procedural, parseCategory("procedural"));
    try std.testing.expectEqual(Category.relational, parseCategory("relational"));
    try std.testing.expectEqual(Category.boundary, parseCategory("boundary"));
    try std.testing.expectEqual(Category.state, parseCategory("state"));
    try std.testing.expectEqual(Category.invariant, parseCategory("invariant"));
}

test "parseTier and parseCategory correctly parse legacy aliases" {
    // Tier legacy aliases
    try std.testing.expectEqual(Tier.convention, parseTier("idiom"));
    try std.testing.expectEqual(Tier.logic, parseTier("mechanism"));

    // Category legacy aliases
    try std.testing.expectEqual(Category.structural, parseCategory("syntax"));
    try std.testing.expectEqual(Category.procedural, parseCategory("control_flow"));
    try std.testing.expectEqual(Category.relational, parseCategory("data_flow"));
    try std.testing.expectEqual(Category.boundary, parseCategory("interface"));
}
