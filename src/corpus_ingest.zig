const std = @import("std");
const abstractions = @import("abstractions.zig");
const config = @import("config.zig");
const corpus_sketch = @import("corpus_sketch.zig");
const external_evidence = @import("external_evidence.zig");
const ghost_state = @import("ghost_state.zig");
const hash_acceleration = @import("hash_acceleration.zig");
const axioms = @import("ghost_code_intel/axioms.zig");
const cpp_ast = @import("ghost_code_intel/cpp_ast.zig");
const knowledge_pack_store = @import("knowledge_pack_store.zig");
const shards = @import("shards.zig");
const vsa = @import("vsa_core.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");

pub const MANIFEST_VERSION = "GCIN1";
pub const CORPUS_REL_PREFIX = "@corpus";
pub const CONCEPT_PREFIX = "corpus_ingest__";
pub const DEFAULT_MAX_FILE_BYTES: usize = 2 * 1024 * 1024;
pub const DEFAULT_MAX_FILES: usize = 512;
pub const DEFAULT_AXIOM_MAX_FILES: usize = 8192;
pub const DEFAULT_MAX_CONCEPT_CANDIDATES: usize = 4096;
pub const DEFAULT_MAX_CONCEPTS: usize = 1024;
pub const DEFAULT_INGEST_WORKERS: usize = 24;
pub const DEFAULT_MAX_CONCEPT_SOURCE_BYTES: usize = 64 * 1024;
const MAX_FILE_READ_INDEX_BYTES: usize = 64 * 1024;
const MAX_TOKEN_COUNT: usize = 24;
const MAX_PATTERN_COUNT: usize = 12;

pub const ItemClass = enum {
    code,
    docs,
    specs,
    configs,
    symbolic,
    axiom,
};

pub const DedupStatus = enum {
    unique,
    exact_duplicate,
    normalized_duplicate,
};

pub const RejectReason = enum {
    unsupported_extension,
    file_too_large,
    contains_nul,
    invalid_utf8,
    low_structure,
};

pub const IngestCapacityTelemetry = struct {
    too_many_files: bool = false,
    file_cap_hit: bool = false,
    concept_candidate_cap_hit: bool = false,
    concept_emit_cap_hit: bool = false,
    concept_candidates_considered: usize = 0,
    concepts_emitted: usize = 0,
    budget_hits: usize = 0,

    pub fn hasPressure(self: IngestCapacityTelemetry) bool {
        return self.too_many_files or
            self.file_cap_hit or
            self.concept_candidate_cap_hit or
            self.concept_emit_cap_hit or
            self.budget_hits != 0;
    }
};

pub const Options = struct {
    corpus_path: []const u8,
    project_shard: ?[]const u8 = null,
    trust_class: ?abstractions.TrustClass = null,
    source_label: ?[]const u8 = null,
    max_file_bytes: usize = DEFAULT_MAX_FILE_BYTES,
    max_files: usize = DEFAULT_MAX_FILES,
    allow_partial: bool = false,
    cursor_after: ?[]const u8 = null,
    max_concept_candidates: usize = DEFAULT_MAX_CONCEPT_CANDIDATES,
    max_concepts: usize = DEFAULT_MAX_CONCEPTS,
    merge_live: bool = false,
    axiom_mode: bool = false,
    axiom_language: axioms.AxiomLanguage = .unknown,
};

pub const ItemResult = struct {
    allocator: std.mem.Allocator,
    source_rel_path: []u8,
    synthetic_rel_path: ?[]u8 = null,
    class: ?ItemClass = null,
    status: []const u8,
    dedup: ?DedupStatus = null,
    trust_class: ?abstractions.TrustClass = null,
    lineage_id: ?[]u8 = null,
    lineage_version: u32 = 0,
    provenance: ?[]u8 = null,
    reject_reason: ?RejectReason = null,
    target_rel_path: ?[]u8 = null,

    pub fn deinit(self: *ItemResult) void {
        self.allocator.free(self.source_rel_path);
        if (self.synthetic_rel_path) |value| self.allocator.free(value);
        if (self.lineage_id) |value| self.allocator.free(value);
        if (self.provenance) |value| self.allocator.free(value);
        if (self.target_rel_path) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub const StageResult = struct {
    allocator: std.mem.Allocator,
    shard_kind: shards.Kind,
    shard_id: []u8,
    shard_root: []u8,
    corpus_root: []u8,
    source_label: []u8,
    trust_class: abstractions.TrustClass,
    staged_manifest_path: []u8,
    staged_files_root: []u8,
    scanned_files: u32,
    staged_items: u32,
    duplicate_items: u32,
    rejected_items: u32,
    concept_count: u32,
    coverage_complete: bool,
    next_cursor: ?[]u8,
    capacity_telemetry: IngestCapacityTelemetry,
    items: []ItemResult,
    axiom_mode: bool = false,
    axioms_locked: bool = false,
    axiom_language: ?[]u8 = null,
    axiom_vector_count: u32 = 0,
    l1_index_before_bytes: u64 = 0,
    l1_index_after_bytes: u64 = 0,
    l1_index_delta_bytes: u64 = 0,

    pub fn deinit(self: *StageResult) void {
        for (self.items) |*item| item.deinit();
        self.allocator.free(self.items);
        self.allocator.free(self.shard_id);
        self.allocator.free(self.shard_root);
        self.allocator.free(self.corpus_root);
        self.allocator.free(self.source_label);
        self.allocator.free(self.staged_manifest_path);
        self.allocator.free(self.staged_files_root);
        if (self.next_cursor) |value| self.allocator.free(value);
        if (self.axiom_language) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub const LiveCoverage = struct {
    complete: bool,
    scanned_files: u32,
    staged_items: u32,
    rejected_items: u32,
    next_cursor: ?[]u8,
    capacity_telemetry: IngestCapacityTelemetry,

    pub fn deinit(self: *LiveCoverage, allocator: std.mem.Allocator) void {
        if (self.next_cursor) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const CorpusMeta = struct {
    allocator: std.mem.Allocator,
    class: ItemClass,
    source_rel_path: []u8,
    source_label: []u8,
    provenance: []u8,
    trust_class: abstractions.TrustClass,
    license_status: []u8,
    license_authority_level: u8,
    lineage_id: []u8,
    lineage_version: u32,
    code_intel_summary: ?[]u8 = null,
    axiom_locked: bool = false,
    axiom_language: ?[]u8 = null,
    axiom_rule: ?[]u8 = null,

    pub fn clone(self: CorpusMeta, allocator: std.mem.Allocator) !CorpusMeta {
        return .{
            .allocator = allocator,
            .class = self.class,
            .source_rel_path = try allocator.dupe(u8, self.source_rel_path),
            .source_label = try allocator.dupe(u8, self.source_label),
            .provenance = try allocator.dupe(u8, self.provenance),
            .trust_class = self.trust_class,
            .license_status = try allocator.dupe(u8, self.license_status),
            .license_authority_level = self.license_authority_level,
            .lineage_id = try allocator.dupe(u8, self.lineage_id),
            .lineage_version = self.lineage_version,
            .code_intel_summary = if (self.code_intel_summary) |value| try allocator.dupe(u8, value) else null,
            .axiom_locked = self.axiom_locked,
            .axiom_language = if (self.axiom_language) |value| try allocator.dupe(u8, value) else null,
            .axiom_rule = if (self.axiom_rule) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *CorpusMeta) void {
        self.allocator.free(self.source_rel_path);
        self.allocator.free(self.source_label);
        self.allocator.free(self.provenance);
        self.allocator.free(self.license_status);
        self.allocator.free(self.lineage_id);
        if (self.code_intel_summary) |value| self.allocator.free(value);
        if (self.axiom_language) |value| self.allocator.free(value);
        if (self.axiom_rule) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub const IndexedEntry = struct {
    allocator: std.mem.Allocator,
    rel_path: []u8,
    abs_path: []u8,
    size_bytes: u64,
    mtime_ns: i128,
    semantic_hash: u64,
    search_sketch_hash: u64,
    search_sketch_features: usize,
    spo_forward_hash: u64,
    spo_inverse_hash: u64,
    corpus_meta: CorpusMeta,

    pub fn deinit(self: *IndexedEntry) void {
        self.allocator.free(self.rel_path);
        self.allocator.free(self.abs_path);
        self.corpus_meta.deinit();
        self.* = undefined;
    }
};

pub const MountedPackRef = struct {
    pack_id: []const u8,
    pack_version: []const u8 = "v1",
};

const RootHint = enum {
    none,
    docs,
    specs,
    configs,
    code,
};

const SourceUnit = struct {
    allocator: std.mem.Allocator,
    synthetic_rel_path: []u8,
    storage_rel_path: []u8,
    source_rel_path: []u8,
    source_abs_path: ?[]u8 = null,
    class: ItemClass,
    trust_class: abstractions.TrustClass,
    source_label: []u8,
    license_status: []u8,
    license_authority_level: u8,
    source_mtime_ns: i128,
    size_bytes: u64,
    raw_hash: u64,
    normalized_hash: u64,
    semantic_hash: u64,
    search_sketch_hash: u64,
    search_sketch_features: usize,
    spo_forward_hash: u64,
    spo_inverse_hash: u64,
    dedup: DedupStatus = .unique,
    canonical_rel_path: ?[]u8 = null,
    lineage_id: []u8,
    lineage_version: u32 = 1,
    provenance: []u8,
    target_rel_path: ?[]u8 = null,
    lower_text: ?[]u8 = null,
    tokens: [][]u8 = &.{},
    patterns: [][]u8 = &.{},
    code_intel_summary: ?[]u8 = null,
    axiom_locked: bool = false,
    axiom_language: ?[]u8 = null,
    axiom_rule: ?[]u8 = null,

    fn deinit(self: *SourceUnit) void {
        self.allocator.free(self.synthetic_rel_path);
        self.allocator.free(self.storage_rel_path);
        self.allocator.free(self.source_rel_path);
        if (self.source_abs_path) |value| self.allocator.free(value);
        self.allocator.free(self.source_label);
        self.allocator.free(self.license_status);
        if (self.canonical_rel_path) |value| self.allocator.free(value);
        self.allocator.free(self.lineage_id);
        self.allocator.free(self.provenance);
        if (self.target_rel_path) |value| self.allocator.free(value);
        if (self.lower_text) |value| self.allocator.free(value);
        for (self.tokens) |item| self.allocator.free(item);
        for (self.patterns) |item| self.allocator.free(item);
        if (self.tokens.len > 0) self.allocator.free(self.tokens);
        if (self.patterns.len > 0) self.allocator.free(self.patterns);
        if (self.code_intel_summary) |value| self.allocator.free(value);
        if (self.axiom_language) |value| self.allocator.free(value);
        if (self.axiom_rule) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

const ConceptSpec = struct {
    allocator: std.mem.Allocator,
    concept_id: []u8,
    tier: abstractions.Tier,
    category: abstractions.Category,
    trust_class: abstractions.TrustClass,
    lineage_id: []u8,
    lineage_version: u32,
    source_specs: [][]u8,
    tokens: [][]u8,
    patterns: [][]u8,
    provenance: [][]u8,
    consensus_hash: u64,
    quality_score: u16,
    confidence_score: u16,
    reuse_score: u16,
    support_score: u16,
    promotion_ready: bool,

    fn deinit(self: *ConceptSpec) void {
        self.allocator.free(self.concept_id);
        self.allocator.free(self.lineage_id);
        for (self.source_specs) |item| self.allocator.free(item);
        for (self.tokens) |item| self.allocator.free(item);
        for (self.patterns) |item| self.allocator.free(item);
        for (self.provenance) |item| self.allocator.free(item);
        self.allocator.free(self.source_specs);
        self.allocator.free(self.tokens);
        self.allocator.free(self.patterns);
        self.allocator.free(self.provenance);
        self.* = undefined;
    }
};

const Rejection = struct {
    allocator: std.mem.Allocator,
    source_rel_path: []u8,
    reason: RejectReason,

    fn deinit(self: *Rejection) void {
        self.allocator.free(self.source_rel_path);
        self.* = undefined;
    }
};

const FileCandidate = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,
    rel_path: []u8,

    fn deinit(self: *FileCandidate) void {
        self.allocator.free(self.abs_path);
        self.allocator.free(self.rel_path);
        self.* = undefined;
    }
};

const ScanOutcome = union(enum) {
    unit: SourceUnit,
    rejection: Rejection,

    fn deinit(self: *ScanOutcome) void {
        switch (self.*) {
            .unit => |*unit| unit.deinit(),
            .rejection => |*rejection| rejection.deinit(),
        }
        self.* = undefined;
    }
};

const ScanResult = struct {
    outcome: ?ScanOutcome = null,
    err: ?anyerror = null,

    fn deinit(self: *ScanResult) void {
        if (self.outcome) |*outcome| outcome.deinit();
        self.* = undefined;
    }
};

const ParallelScanContext = struct {
    candidates: []const FileCandidate,
    results: []ScanResult,
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    root_hint: RootHint,
    source_label: []const u8,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    trust_class: abstractions.TrustClass,
    options: Options,
    external_meta: *const std.StringHashMap(ExternalMetadata),
    license_status: []const u8,
    license_authority_level: u8,
    acceleration: ?*hash_acceleration.Context,
};

const RuneParseSummary = struct {
    rune_count: usize = 0,
    structural_punctuation_count: usize = 0,
};

const Manifest = struct {
    allocator: std.mem.Allocator,
    source_root: []u8,
    source_label: []u8,
    items: std.ArrayList(SourceUnit),
    concepts: std.ArrayList(ConceptSpec),
    rejections: std.ArrayList(Rejection),
    coverage_complete: bool = true,
    next_cursor: ?[]u8 = null,
    capacity_telemetry: IngestCapacityTelemetry = .{},

    fn init(allocator: std.mem.Allocator, source_root: []const u8, source_label: []const u8) !Manifest {
        return .{
            .allocator = allocator,
            .source_root = try allocator.dupe(u8, source_root),
            .source_label = try allocator.dupe(u8, source_label),
            .items = std.ArrayList(SourceUnit).init(allocator),
            .concepts = std.ArrayList(ConceptSpec).init(allocator),
            .rejections = std.ArrayList(Rejection).init(allocator),
        };
    }

    fn deinit(self: *Manifest) void {
        for (self.items.items) |*item| item.deinit();
        for (self.concepts.items) |*concept| concept.deinit();
        for (self.rejections.items) |*rejection| rejection.deinit();
        self.items.deinit();
        self.concepts.deinit();
        self.rejections.deinit();
        self.allocator.free(self.source_root);
        self.allocator.free(self.source_label);
        if (self.next_cursor) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

const ExternalMetadata = struct {
    source_url: []u8,
    fetch_time_ms: i64,
    content_hash: u64,
    considered_reason: []u8,
    query_text: ?[]u8 = null,
    origin: external_evidence.OriginKind,

    fn deinit(self: *ExternalMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.source_url);
        allocator.free(self.considered_reason);
        if (self.query_text) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn className(class: ItemClass) []const u8 {
    return switch (class) {
        .code => "code",
        .docs => "docs",
        .specs => "specs",
        .configs => "configs",
        .symbolic => "symbolic",
        .axiom => "axioms",
    };
}

fn dedupName(value: DedupStatus) []const u8 {
    return switch (value) {
        .unique => "unique",
        .exact_duplicate => "exact_duplicate",
        .normalized_duplicate => "normalized_duplicate",
    };
}

fn rejectReasonName(value: RejectReason) []const u8 {
    return switch (value) {
        .unsupported_extension => "unsupported_extension",
        .file_too_large => "file_too_large",
        .contains_nul => "contains_nul",
        .invalid_utf8 => "invalid_utf8",
        .low_structure => "low_structure",
    };
}

pub fn clearStaged(_: std.mem.Allocator, paths: *const shards.Paths) !void {
    deleteTreeIfExistsAbsolute(paths.corpus_ingest_staged_abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn writeLiveToSlot(allocator: std.mem.Allocator, paths: *const shards.Paths, slot_dir: []const u8) !void {
    const slot_root = try std.fs.path.join(allocator, &.{ slot_dir, config.CORPUS_INGEST_SLOT_DIR_NAME });
    defer allocator.free(slot_root);
    try deleteTreeIfExistsAbsolute(slot_root);
    if (!pathExists(paths.corpus_ingest_live_abs_path)) return;
    try copyTreeAbsolute(paths.corpus_ingest_live_abs_path, slot_root);
}

pub fn restoreLiveFromSlot(allocator: std.mem.Allocator, paths: *const shards.Paths, slot_dir: []const u8) !void {
    const slot_root = try std.fs.path.join(allocator, &.{ slot_dir, config.CORPUS_INGEST_SLOT_DIR_NAME });
    defer allocator.free(slot_root);
    try deleteTreeIfExistsAbsolute(paths.corpus_ingest_live_abs_path);
    if (!pathExists(slot_root)) return;
    try copyTreeAbsolute(slot_root, paths.corpus_ingest_live_abs_path);
}

pub fn applyStaged(allocator: std.mem.Allocator, paths: *const shards.Paths) !void {
    const loaded = loadManifestFromPath(allocator, paths.corpus_ingest_staged_manifest_abs_path) catch |err| switch (err) {
        error.FileNotFound => {
            try deleteTreeIfExistsAbsolute(paths.corpus_ingest_live_abs_path);
            try abstractions.replaceImportedLiveRecords(allocator, paths, CONCEPT_PREFIX, &.{});
            return;
        },
        else => return err,
    };
    var loaded_manifest = loaded.manifest;
    defer loaded_manifest.deinit();

    if (pathExists(paths.corpus_ingest_live_manifest_abs_path)) {
        try mergeLiveManifest(allocator, paths, &loaded_manifest);
    }
    try std.fs.cwd().makePath(paths.corpus_ingest_live_abs_path);
    try copyTreeAbsolute(paths.corpus_ingest_staged_abs_path, paths.corpus_ingest_live_abs_path);
    const live_json = try serializeManifest(allocator, &loaded_manifest);
    defer allocator.free(live_json);
    try ensureParentDirAbsolute(paths.corpus_ingest_live_manifest_abs_path);
    try writeAbsoluteFile(paths.corpus_ingest_live_manifest_abs_path, live_json);

    const imported_records = try buildRecordsFromConcepts(allocator, loaded_manifest.concepts.items);
    defer {
        for (imported_records) |*record| record.deinit();
        allocator.free(imported_records);
    }
    try abstractions.replaceImportedLiveRecords(allocator, paths, CONCEPT_PREFIX, imported_records);
    try clearStaged(allocator, paths);
}

pub fn liveCoverage(allocator: std.mem.Allocator, paths: *const shards.Paths) !LiveCoverage {
    const loaded = loadManifestFromPath(allocator, paths.corpus_ingest_live_manifest_abs_path) catch |err| switch (err) {
        error.FileNotFound => return .{
            .complete = true,
            .scanned_files = 0,
            .staged_items = 0,
            .rejected_items = 0,
            .next_cursor = null,
            .capacity_telemetry = .{},
        },
        else => return err,
    };
    var manifest = loaded.manifest;
    defer manifest.deinit();

    var unique_items: u32 = 0;
    for (manifest.items.items) |item| {
        if (item.dedup == .unique) unique_items += 1;
    }
    return .{
        .complete = manifest.coverage_complete,
        .scanned_files = @intCast(manifest.items.items.len + manifest.rejections.items.len),
        .staged_items = unique_items,
        .rejected_items = @intCast(manifest.rejections.items.len),
        .next_cursor = if (manifest.next_cursor) |value| try allocator.dupe(u8, value) else null,
        .capacity_telemetry = manifest.capacity_telemetry,
    };
}

pub fn collectLiveScanEntries(allocator: std.mem.Allocator, paths: *const shards.Paths) ![]IndexedEntry {
    const loaded = loadManifestFromPath(allocator, paths.corpus_ingest_live_manifest_abs_path) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    var manifest = loaded.manifest;
    defer manifest.deinit();

    var out = std.ArrayList(IndexedEntry).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit();
        out.deinit();
    }

    for (manifest.items.items) |item| {
        if (item.dedup != .unique) continue;
        const abs_path = try std.fs.path.join(allocator, &.{ paths.corpus_ingest_live_abs_path, item.storage_rel_path });
        errdefer allocator.free(abs_path);
        const file = try std.fs.openFileAbsolute(abs_path, .{});
        defer file.close();
        const stat = try file.stat();
        try out.append(.{
            .allocator = allocator,
            .rel_path = try allocator.dupe(u8, item.synthetic_rel_path),
            .abs_path = abs_path,
            .size_bytes = stat.size,
            .mtime_ns = @max(@as(i128, @intCast(stat.mtime)), loaded.mtime_ns),
            .semantic_hash = item.semantic_hash,
            .search_sketch_hash = item.search_sketch_hash,
            .search_sketch_features = item.search_sketch_features,
            .spo_forward_hash = item.spo_forward_hash,
            .spo_inverse_hash = item.spo_inverse_hash,
            .corpus_meta = .{
                .allocator = allocator,
                .class = item.class,
                .source_rel_path = try allocator.dupe(u8, item.source_rel_path),
                .source_label = try allocator.dupe(u8, item.source_label),
                .provenance = try allocator.dupe(u8, item.provenance),
                .trust_class = item.trust_class,
                .license_status = try allocator.dupe(u8, item.license_status),
                .license_authority_level = item.license_authority_level,
                .lineage_id = try allocator.dupe(u8, item.lineage_id),
                .lineage_version = item.lineage_version,
                .code_intel_summary = if (item.code_intel_summary) |value| try allocator.dupe(u8, value) else null,
                .axiom_locked = item.axiom_locked,
                .axiom_language = if (item.axiom_language) |value| try allocator.dupe(u8, value) else null,
                .axiom_rule = if (item.axiom_rule) |value| try allocator.dupe(u8, value) else null,
            },
        });
    }

    return out.toOwnedSlice();
}

pub fn collectComposedLiveScanEntries(
    allocator: std.mem.Allocator,
    paths: *const shards.Paths,
    mounted_packs: []const MountedPackRef,
) ![]IndexedEntry {
    const live_entries = try collectLiveScanEntries(allocator, paths);
    var live_entries_moved = false;
    errdefer if (!live_entries_moved) deinitIndexedEntries(allocator, live_entries);
    if (mounted_packs.len == 0) return live_entries;

    var out = std.ArrayList(IndexedEntry).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit();
        out.deinit();
    }

    try out.ensureTotalCapacity(live_entries.len);
    for (live_entries) |entry| {
        out.appendAssumeCapacity(entry);
    }
    allocator.free(live_entries);
    live_entries_moved = true;

    for (mounted_packs) |mounted_pack| {
        const safe_pack_id = try knowledge_pack_store.sanitizePackId(allocator, mounted_pack.pack_id);
        defer allocator.free(safe_pack_id);
        const safe_pack_version = try knowledge_pack_store.sanitizeVersion(allocator, mounted_pack.pack_version);
        defer allocator.free(safe_pack_version);

        var manifest = try knowledge_pack_store.loadManifest(allocator, safe_pack_id, safe_pack_version);
        defer manifest.deinit();
        const root_abs_path = try knowledge_pack_store.packRootAbsPath(allocator, safe_pack_id, safe_pack_version);
        defer allocator.free(root_abs_path);
        const corpus_manifest_abs_path = try std.fs.path.join(allocator, &.{ root_abs_path, manifest.storage.corpus_manifest_rel_path });
        defer allocator.free(corpus_manifest_abs_path);
        const corpus_files_abs_path = try std.fs.path.join(allocator, &.{ root_abs_path, manifest.storage.corpus_files_rel_path });
        defer allocator.free(corpus_files_abs_path);

        const pack_entries = try collectPackScanEntries(
            allocator,
            safe_pack_id,
            safe_pack_version,
            corpus_manifest_abs_path,
            corpus_files_abs_path,
        );
        var pack_entries_moved = false;
        errdefer if (!pack_entries_moved) deinitIndexedEntries(allocator, pack_entries);
        try out.ensureUnusedCapacity(pack_entries.len);
        for (pack_entries) |entry| {
            out.appendAssumeCapacity(entry);
        }
        allocator.free(pack_entries);
        pack_entries_moved = true;
    }

    return out.toOwnedSlice();
}

pub fn collectPackScanEntries(
    allocator: std.mem.Allocator,
    pack_id: []const u8,
    pack_version: []const u8,
    manifest_abs_path: []const u8,
    files_root_abs_path: []const u8,
) ![]IndexedEntry {
    const loaded = try loadManifestFromPath(allocator, manifest_abs_path);
    var manifest = loaded.manifest;
    defer manifest.deinit();

    const pack_prefix = try std.fmt.allocPrint(allocator, "@pack/{s}/{s}", .{ pack_id, pack_version });
    defer allocator.free(pack_prefix);
    const source_label = try std.fmt.allocPrint(allocator, "pack:{s}@{s}", .{ pack_id, pack_version });
    defer allocator.free(source_label);

    var out = std.ArrayList(IndexedEntry).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit();
        out.deinit();
    }

    for (manifest.items.items) |item| {
        if (item.dedup != .unique) continue;
        const rewritten_rel_path = try rewritePackSyntheticRelPath(allocator, pack_prefix, item.synthetic_rel_path);
        errdefer allocator.free(rewritten_rel_path);
        const abs_path = try std.fs.path.join(allocator, &.{ files_root_abs_path, item.storage_rel_path });
        errdefer allocator.free(abs_path);
        const file = try std.fs.openFileAbsolute(abs_path, .{});
        defer file.close();
        const stat = try file.stat();

        const provenance = try std.fmt.allocPrint(
            allocator,
            "{s}|pack={s}@{s}|mounted_prefix={s}",
            .{ item.provenance, pack_id, pack_version, pack_prefix },
        );
        errdefer allocator.free(provenance);
        const lineage_id = try std.fmt.allocPrint(
            allocator,
            "pack:{s}@{s}:{s}",
            .{ pack_id, pack_version, rewritten_rel_path },
        );
        errdefer allocator.free(lineage_id);

        try out.append(.{
            .allocator = allocator,
            .rel_path = rewritten_rel_path,
            .abs_path = abs_path,
            .size_bytes = stat.size,
            .mtime_ns = @max(@as(i128, @intCast(stat.mtime)), loaded.mtime_ns),
            .semantic_hash = item.semantic_hash,
            .search_sketch_hash = item.search_sketch_hash,
            .search_sketch_features = item.search_sketch_features,
            .spo_forward_hash = item.spo_forward_hash,
            .spo_inverse_hash = item.spo_inverse_hash,
            .corpus_meta = .{
                .allocator = allocator,
                .class = item.class,
                .source_rel_path = try allocator.dupe(u8, item.source_rel_path),
                .source_label = try allocator.dupe(u8, source_label),
                .provenance = provenance,
                .trust_class = item.trust_class,
                .license_status = try allocator.dupe(u8, item.license_status),
                .license_authority_level = item.license_authority_level,
                .lineage_id = lineage_id,
                .lineage_version = item.lineage_version,
                .code_intel_summary = if (item.code_intel_summary) |value| try allocator.dupe(u8, value) else null,
                .axiom_locked = item.axiom_locked,
                .axiom_language = if (item.axiom_language) |value| try allocator.dupe(u8, value) else null,
                .axiom_rule = if (item.axiom_rule) |value| try allocator.dupe(u8, value) else null,
            },
        });
    }

    return out.toOwnedSlice();
}

pub fn deinitIndexedEntries(allocator: std.mem.Allocator, entries: []IndexedEntry) void {
    for (entries) |*entry| entry.deinit();
    allocator.free(entries);
}

pub fn readLicenseStatus(allocator: std.mem.Allocator, root_abs_path: []const u8) ![]u8 {
    var license_path: ?[]u8 = try std.fs.path.join(allocator, &.{ root_abs_path, "license.json" });
    defer if (license_path) |value| allocator.free(value);
    const file = std.fs.openFileAbsolute(license_path.?, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            allocator.free(license_path.?);
            license_path = null;
            license_path = try findTrashedLicensePath(allocator, root_abs_path) orelse return try allocator.dupe(u8, "unspecified");
            break :blk try std.fs.openFileAbsolute(license_path.?, .{});
        },
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    const bytes = try file.readToEndAlloc(allocator, @intCast(@min(stat.size, 16 * 1024)));
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(struct {
        status: ?[]const u8 = null,
    }, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return try allocator.dupe(u8, "unverified");
    defer parsed.deinit();
    const status = std.mem.trim(u8, parsed.value.status orelse return try allocator.dupe(u8, "unverified"), " \r\n\t");
    if (status.len == 0) return try allocator.dupe(u8, "unverified");
    var out = try allocator.alloc(u8, status.len);
    for (status, 0..) |c, idx| out[idx] = std.ascii.toLower(c);
    return out;
}

pub fn readLicenseAuthorityLevel(root_abs_path: []const u8) !u8 {
    const allocator = std.heap.page_allocator;
    var license_path: ?[]u8 = try std.fs.path.join(allocator, &.{ root_abs_path, "license.json" });
    defer if (license_path) |value| allocator.free(value);
    const file = std.fs.openFileAbsolute(license_path.?, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            allocator.free(license_path.?);
            license_path = null;
            license_path = try findTrashedLicensePath(allocator, root_abs_path) orelse return 2;
            break :blk try std.fs.openFileAbsolute(license_path.?, .{});
        },
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    const bytes = try file.readToEndAlloc(allocator, @intCast(@min(stat.size, 16 * 1024)));
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return 2;
    defer parsed.deinit();
    if (parsed.value != .object) return 2;
    const obj = parsed.value.object;
    if (jsonAuthorityLevel(obj.get("authority_level"))) |level| return level;
    if (jsonAuthorityLevel(obj.get("authorityLevel"))) |level| return level;
    if (jsonAuthorityLevel(obj.get("status"))) |level| return level;
    return 2;
}

fn jsonAuthorityLevel(value: ?std.json.Value) ?u8 {
    const actual = value orelse return null;
    switch (actual) {
        .integer => |level| {
            if (level < 0) return 2;
            return @min(@as(u8, @intCast(@min(level, 4))), 4);
        },
        .float => |level| {
            if (level <= 0) return 0;
            if (level >= 4) return 4;
            return @intFromFloat(level);
        },
        .string => |status| {
            if (std.ascii.eqlIgnoreCase(status, "root")) return 0;
            if (std.ascii.eqlIgnoreCase(status, "verified")) return 1;
            if (std.ascii.eqlIgnoreCase(status, "unverified")) return 2;
            if (std.ascii.eqlIgnoreCase(status, "shadow")) return 3;
            if (std.ascii.eqlIgnoreCase(status, "trash")) return 4;
            return null;
        },
        else => return null,
    }
}

fn findTrashedLicensePath(allocator: std.mem.Allocator, root_abs_path: []const u8) !?[]u8 {
    const parent = std.fs.path.dirname(root_abs_path) orelse return null;
    const base_name = std.fs.path.basename(root_abs_path);
    const trash_root = try std.fs.path.join(allocator, &.{ parent, ".trash" });
    defer allocator.free(trash_root);
    var dir = std.fs.openDirAbsolute(trash_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "license.json")) continue;
        const dirname = std.fs.path.dirname(entry.path) orelse continue;
        const trashed_base = std.fs.path.basename(dirname);
        if (!std.mem.eql(u8, trashed_base, base_name) and !startsWithTrashCollisionName(trashed_base, base_name)) continue;
        return try std.fs.path.join(allocator, &.{ trash_root, entry.path });
    }
    return null;
}

fn startsWithTrashCollisionName(name: []const u8, base_name: []const u8) bool {
    return name.len > base_name.len + 1 and
        std.mem.startsWith(u8, name, base_name) and
        name[base_name.len] == '-';
}

pub fn stage(allocator: std.mem.Allocator, options: Options) !StageResult {
    var profile_timer: ?std.time.Timer = if (ingestProfileEnabled()) try std.time.Timer.start() else null;
    var profile_last_ns: u64 = 0;

    var shard_metadata = if (options.axiom_mode)
        try shards.resolveCoreMetadata(allocator)
    else if (options.project_shard) |project_shard|
        try shards.resolveProjectMetadata(allocator, project_shard)
    else
        try shards.resolveCoreMetadata(allocator);
    defer shard_metadata.deinit();

    var paths = try shards.resolvePaths(allocator, shard_metadata.metadata);
    defer paths.deinit();
    ingestProfileMark(&profile_timer, &profile_last_ns, "resolve_shard");

    const corpus_root = try std.fs.cwd().realpathAlloc(allocator, options.corpus_path);
    errdefer allocator.free(corpus_root);
    const root_kind = try pathKindAbsolute(corpus_root);
    const axiom_language = if (options.axiom_mode) resolvedAxiomLanguage(options, corpus_root) else .unknown;
    const manifest_root = if (root_kind == .file)
        try allocator.dupe(u8, std.fs.path.dirname(corpus_root) orelse corpus_root)
    else
        try allocator.dupe(u8, corpus_root);
    defer allocator.free(manifest_root);

    const source_label = if (options.source_label) |label|
        try allocator.dupe(u8, label)
    else if (options.axiom_mode)
        try std.fmt.allocPrint(allocator, "axioms:{s}", .{axioms.languageName(axiom_language)})
    else
        try allocator.dupe(u8, std.fs.path.basename(corpus_root));
    errdefer allocator.free(source_label);

    const trust_class = if (options.axiom_mode) abstractions.TrustClass.core else options.trust_class orelse defaultTrustForKind(paths.metadata.kind);
    try validateTrustClass(paths.metadata.kind, trust_class);
    const l1_before_bytes = if (options.axiom_mode) fileSizeOrZero(paths.corpus_ingest_live_manifest_abs_path) else 0;

    var manifest = try Manifest.init(allocator, manifest_root, source_label);
    defer manifest.deinit();
    var external_meta = try loadExternalMetadata(allocator, manifest_root);
    defer deinitExternalMetadataMap(allocator, &external_meta);
    var acceleration = hash_acceleration.Context.init(allocator, "corpus ingest hashing");
    defer acceleration.deinit();
    ingestProfileMark(&profile_timer, &profile_last_ns, "init_manifest_metadata_acceleration");

    try scanCorpusPath(allocator, corpus_root, detectRootHint(corpus_root), source_label, paths.metadata.kind, paths.metadata.id, trust_class, options, &external_meta, &manifest, &acceleration);
    ingestProfileMark(&profile_timer, &profile_last_ns, "scan_parse_index");
    try buildConceptSpecs(&manifest, paths.metadata.kind, paths.metadata.id, options.max_concept_candidates, options.max_concepts);
    ingestProfileMark(&profile_timer, &profile_last_ns, "build_concept_specs");

    if (options.merge_live and pathExists(paths.corpus_ingest_live_manifest_abs_path)) {
        try mergeLiveManifest(allocator, &paths, &manifest);
        ingestProfileMark(&profile_timer, &profile_last_ns, "merge_live");
    }

    try persistStagedState(allocator, &paths, &manifest, options.max_file_bytes);
    ingestProfileMark(&profile_timer, &profile_last_ns, "persist_staged_state");
    const staged_manifest_bytes = if (options.axiom_mode) fileSizeOrZero(paths.corpus_ingest_staged_manifest_abs_path) else 0;
    const l1_after_bytes = if (options.axiom_mode) l1_before_bytes + staged_manifest_bytes else 0;

    const results = try buildStageItems(allocator, &manifest);
    ingestProfileMark(&profile_timer, &profile_last_ns, "build_stage_items");
    errdefer {
        for (results) |*item| item.deinit();
        allocator.free(results);
    }

    var staged_items: u32 = 0;
    var duplicate_items: u32 = 0;
    for (manifest.items.items) |item| {
        switch (item.dedup) {
            .unique => staged_items += 1,
            .exact_duplicate, .normalized_duplicate => duplicate_items += 1,
        }
    }

    return .{
        .allocator = allocator,
        .shard_kind = paths.metadata.kind,
        .shard_id = try allocator.dupe(u8, paths.metadata.id),
        .shard_root = try allocator.dupe(u8, paths.root_abs_path),
        .corpus_root = corpus_root,
        .source_label = source_label,
        .trust_class = trust_class,
        .staged_manifest_path = try allocator.dupe(u8, paths.corpus_ingest_staged_manifest_abs_path),
        .staged_files_root = try allocator.dupe(u8, paths.corpus_ingest_staged_files_abs_path),
        .scanned_files = @intCast(manifest.items.items.len + manifest.rejections.items.len),
        .staged_items = staged_items,
        .duplicate_items = duplicate_items,
        .rejected_items = @intCast(manifest.rejections.items.len),
        .concept_count = @intCast(manifest.concepts.items.len),
        .coverage_complete = manifest.coverage_complete,
        .next_cursor = if (manifest.next_cursor) |value| try allocator.dupe(u8, value) else null,
        .capacity_telemetry = manifest.capacity_telemetry,
        .items = results,
        .axiom_mode = options.axiom_mode,
        .axioms_locked = options.axiom_mode and staged_items != 0 and trust_class == .core,
        .axiom_language = if (options.axiom_mode) try allocator.dupe(u8, axioms.languageName(axiom_language)) else null,
        .axiom_vector_count = if (options.axiom_mode) countAxiomUnits(&manifest) else 0,
        .l1_index_before_bytes = l1_before_bytes,
        .l1_index_after_bytes = l1_after_bytes,
        .l1_index_delta_bytes = if (l1_after_bytes >= l1_before_bytes) l1_after_bytes - l1_before_bytes else 0,
    };
}

fn pathKindAbsolute(path: []const u8) !std.fs.File.Kind {
    const stat = try std.fs.cwd().statFile(path);
    return stat.kind;
}

fn resolvedAxiomLanguage(options: Options, path: []const u8) axioms.AxiomLanguage {
    if (options.axiom_language != .unknown) return options.axiom_language;
    const from_path = axioms.inferLanguageFromPath(path);
    if (from_path != .unknown) return from_path;
    return axioms.inferLanguageFromPath(options.corpus_path);
}

fn fileSizeOrZero(abs_path: []const u8) u64 {
    const stat = std.fs.cwd().statFile(abs_path) catch return 0;
    return stat.size;
}

fn countAxiomUnits(manifest: *const Manifest) u32 {
    var count: u32 = 0;
    for (manifest.items.items) |item| {
        if (item.class == .axiom and item.dedup == .unique) count += 1;
    }
    return count;
}

fn ingestProfileEnabled() bool {
    const raw = std.posix.getenv("GHOST_PROFILE_INGEST") orelse return false;
    return raw.len != 0 and !std.mem.eql(u8, raw, "0") and !std.ascii.eqlIgnoreCase(raw, "false");
}

fn ingestProfileMark(timer: *?std.time.Timer, last_ns: *u64, label: []const u8) void {
    if (timer.*) |*actual| {
        const now = actual.read();
        const delta = now - last_ns.*;
        last_ns.* = now;
        std.debug.print("[PROFILE][ingest] {s}: delta_ms={d} total_ms={d}\n", .{
            label,
            delta / std.time.ns_per_ms,
            now / std.time.ns_per_ms,
        });
    }
}

pub fn renderJson(allocator: std.mem.Allocator, result: *const StageResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{");
    try writeJsonFieldString(writer, "status", if (result.coverage_complete) "staged" else "staged_partial", true);
    try writer.writeAll(",\"shard\":{");
    try writeJsonFieldString(writer, "kind", @tagName(result.shard_kind), true);
    try writeJsonFieldString(writer, "id", result.shard_id, false);
    try writeJsonFieldString(writer, "root", result.shard_root, false);
    try writer.writeAll("}");
    try writeOptionalStringField(writer, "corpusRoot", result.corpus_root);
    try writeOptionalStringField(writer, "sourceLabel", result.source_label);
    try writeOptionalStringField(writer, "trustClass", abstractions.trustClassName(result.trust_class));
    if (result.axiom_mode) {
        try writer.writeAll(",\"axioms\":{");
        try writeJsonFieldString(writer, "status", if (result.axioms_locked) "Axioms Locked" else "Axioms Pending", true);
        try writeJsonFieldString(writer, "mode", "technical_axiom_matrix", false);
        try writeJsonFieldString(writer, "authorityTier", axioms.AXIOM_TIER_LABEL, false);
        try writer.print(",\"authorityLevel\":{d},\"locked\":{s}", .{
            axioms.AXIOM_AUTHORITY_LEVEL,
            if (result.axioms_locked) "true" else "false",
        });
        if (result.axiom_language) |language| try writeOptionalStringField(writer, "language", language);
        try writer.print(",\"axiomVectorCount\":{d},\"l1ConceptIndexFootprintBeforeBytes\":{d},\"l1ConceptIndexFootprintAfterBytes\":{d},\"l1ConceptIndexFootprintDeltaBytes\":{d}", .{
            result.axiom_vector_count,
            result.l1_index_before_bytes,
            result.l1_index_after_bytes,
            result.l1_index_delta_bytes,
        });
        try writer.writeAll("}");
    }
    try writeOptionalStringField(writer, "stagedManifest", result.staged_manifest_path);
    try writeOptionalStringField(writer, "stagedFilesRoot", result.staged_files_root);
    try writer.print(",\"scannedFiles\":{d}", .{result.scanned_files});
    try writer.print(",\"stagedItems\":{d}", .{result.staged_items});
    try writer.print(",\"duplicateItems\":{d}", .{result.duplicate_items});
    try writer.print(",\"rejectedItems\":{d}", .{result.rejected_items});
    try writer.print(",\"conceptCount\":{d}", .{result.concept_count});
    try writer.writeAll(",\"coverage\":{");
    try writer.print("\"complete\":{s}", .{if (result.coverage_complete) "true" else "false"});
    try writer.print(",\"scannedFiles\":{d},\"stagedItems\":{d},\"rejectedItems\":{d}", .{
        result.scanned_files,
        result.staged_items,
        result.rejected_items,
    });
    if (result.next_cursor) |value| try writeOptionalStringField(writer, "nextCursor", value);
    try writer.writeAll("},\"capacityTelemetry\":");
    try writeIngestCapacityTelemetry(writer, result.capacity_telemetry);
    try writer.writeAll(",\"items\":[");
    for (result.items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "source", item.source_rel_path, true);
        try writeJsonFieldString(writer, "status", item.status, false);
        if (item.class) |value| try writeOptionalStringField(writer, "class", className(value));
        if (item.synthetic_rel_path) |value| try writeOptionalStringField(writer, "targetPath", value);
        if (item.dedup) |value| try writeOptionalStringField(writer, "dedup", dedupName(value));
        if (item.trust_class) |value| try writeOptionalStringField(writer, "trustClass", abstractions.trustClassName(value));
        if (item.lineage_id) |value| {
            try writer.writeAll(",\"lineage\":{");
            try writeJsonFieldString(writer, "id", value, true);
            try writer.print(",\"version\":{d}", .{item.lineage_version});
            try writer.writeAll("}");
        }
        if (item.provenance) |value| try writeOptionalStringField(writer, "provenance", value);
        if (item.reject_reason) |value| try writeOptionalStringField(writer, "rejectReason", rejectReasonName(value));
        if (item.target_rel_path) |value| try writeOptionalStringField(writer, "linkedTarget", value);
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn defaultTrustForKind(kind: shards.Kind) abstractions.TrustClass {
    return switch (kind) {
        .core => .core,
        .project => .project,
        .scratch => .exploratory,
    };
}

pub fn validateTrustClass(kind: shards.Kind, trust_class: abstractions.TrustClass) !void {
    switch (kind) {
        .core => if (trust_class != .core) return error.InvalidTrustClass,
        .project => if (trust_class == .core) return error.InvalidTrustClass,
        .scratch => return error.InvalidTrustClass,
    }
}

fn buildExternalProvenance(
    allocator: std.mem.Allocator,
    source_label: []const u8,
    rel_path: []const u8,
    mtime_ns: i128,
    meta: *const ExternalMetadata,
) ![]u8 {
    const query_suffix = if (meta.query_text) |value|
        try std.fmt.allocPrint(allocator, "|query={s}", .{value})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(query_suffix);
    return std.fmt.allocPrint(
        allocator,
        "origin=external_evidence|source={s}|path={s}|mtime_ns={d}|source_url={s}|fetch_time_ms={d}|content_hash={d}|reason={s}|provider={s}|origin_kind={s}{s}",
        .{
            source_label,
            rel_path,
            mtime_ns,
            meta.source_url,
            meta.fetch_time_ms,
            meta.content_hash,
            meta.considered_reason,
            external_evidence.SEARCH_PROVIDER_LABEL,
            @tagName(meta.origin),
            query_suffix,
        },
    );
}

fn loadExternalMetadata(allocator: std.mem.Allocator, corpus_root: []const u8) !std.StringHashMap(ExternalMetadata) {
    var map = std.StringHashMap(ExternalMetadata).init(allocator);
    errdefer deinitExternalMetadataMap(allocator, &map);

    const meta_path = try std.fs.path.join(allocator, &.{ corpus_root, external_evidence.EXTERNAL_METADATA_FILE_NAME });
    defer allocator.free(meta_path);
    const file = std.fs.openFileAbsolute(meta_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return map,
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    const bytes = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(bytes);

    const DiskSource = struct {
        relPath: []const u8,
        sourceUrl: []const u8,
        fetchTimeMs: i64,
        contentHash: u64,
        consideredReason: []const u8,
        queryText: ?[]const u8 = null,
        origin: external_evidence.OriginKind,
    };
    const DiskManifest = struct {
        version: []const u8,
        sources: []const DiskSource,
    };

    const parsed = try std.json.parseFromSlice(DiskManifest, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.version, "ghost_external_evidence_v1")) return error.InvalidCorpusManifest;

    for (parsed.value.sources) |item| {
        try map.put(try allocator.dupe(u8, item.relPath), .{
            .source_url = try allocator.dupe(u8, item.sourceUrl),
            .fetch_time_ms = item.fetchTimeMs,
            .content_hash = item.contentHash,
            .considered_reason = try allocator.dupe(u8, item.consideredReason),
            .query_text = if (item.queryText) |value| try allocator.dupe(u8, value) else null,
            .origin = item.origin,
        });
    }
    return map;
}

fn deinitExternalMetadataMap(allocator: std.mem.Allocator, map: *std.StringHashMap(ExternalMetadata)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn mergeLiveManifest(allocator: std.mem.Allocator, paths: *const shards.Paths, next_manifest: *Manifest) !void {
    const loaded = try loadManifestFromPath(allocator, paths.corpus_ingest_live_manifest_abs_path);
    var live_manifest = loaded.manifest;
    defer live_manifest.deinit();

    for (live_manifest.items.items) |item| {
        var cloned = try cloneSourceUnit(allocator, item);
        errdefer cloned.deinit();
        cloned.source_abs_path = try std.fs.path.join(allocator, &.{ paths.corpus_ingest_live_abs_path, item.storage_rel_path });
        try next_manifest.items.append(cloned);
    }
    for (live_manifest.concepts.items) |item| {
        try next_manifest.concepts.append(try cloneConceptSpec(allocator, item));
    }
    for (live_manifest.rejections.items) |item| {
        try next_manifest.rejections.append(.{
            .allocator = allocator,
            .source_rel_path = try allocator.dupe(u8, item.source_rel_path),
            .reason = item.reason,
        });
    }
}

fn detectRootHint(path: []const u8) RootHint {
    if (std.mem.indexOf(u8, path, "/docs/") != null) return .docs;
    if (std.mem.indexOf(u8, path, "/specs/") != null) return .specs;
    if (std.mem.indexOf(u8, path, "/configs/") != null) return .configs;
    if (std.mem.indexOf(u8, path, "/code/") != null) return .code;
    return .none;
}

fn scanCorpusPath(
    allocator: std.mem.Allocator,
    corpus_root: []const u8,
    root_hint: RootHint,
    source_label: []const u8,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    trust_class: abstractions.TrustClass,
    options: Options,
    external_meta: *const std.StringHashMap(ExternalMetadata),
    manifest: *Manifest,
    acceleration: *hash_acceleration.Context,
) !void {
    var maybe_dir = std.fs.openDirAbsolute(corpus_root, .{ .iterate = true }) catch |dir_err| switch (dir_err) {
        error.NotDir, error.FileNotFound => null,
        else => return dir_err,
    };
    if (maybe_dir) |*dir| {
        dir.close();
        try scanDirParallel(allocator, corpus_root, root_hint, source_label, owner_kind, owner_id, trust_class, options, external_meta, manifest, acceleration);
        return;
    }

    const rel_path = try allocator.dupe(u8, std.fs.path.basename(corpus_root));
    defer allocator.free(rel_path);
    try scanOneFile(allocator, corpus_root, rel_path, root_hint, source_label, owner_kind, owner_id, trust_class, options, external_meta, manifest, acceleration);
}

fn scanDirParallel(
    allocator: std.mem.Allocator,
    corpus_root: []const u8,
    root_hint: RootHint,
    source_label: []const u8,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    trust_class: abstractions.TrustClass,
    options: Options,
    external_meta: *const std.StringHashMap(ExternalMetadata),
    manifest: *Manifest,
    acceleration: *hash_acceleration.Context,
) !void {
    var candidates = std.ArrayList(FileCandidate).init(allocator);
    defer {
        for (candidates.items) |*candidate| candidate.deinit();
        candidates.deinit();
    }

    try collectFileCandidates(allocator, corpus_root, "", options, &manifest.capacity_telemetry, &manifest.coverage_complete, &candidates);

    if (candidates.items.len == 0) return;

    const license_status = try readLicenseStatus(allocator, manifest.source_root);
    defer allocator.free(license_status);
    const license_authority_level = try readLicenseAuthorityLevel(manifest.source_root);

    if (config.TEST_MODE or candidates.items.len <= 1) {
        try scanCandidatesSerial(allocator, candidates.items, root_hint, source_label, owner_kind, owner_id, trust_class, options, external_meta, manifest, license_status, license_authority_level, acceleration);
        return;
    }

    const results = try allocator.alloc(ScanResult, candidates.items.len);
    defer {
        for (results) |*result| result.deinit();
        allocator.free(results);
    }
    for (results) |*result| result.* = .{};

    var context = ParallelScanContext{
        .candidates = candidates.items,
        .results = results,
        .root_hint = root_hint,
        .source_label = source_label,
        .owner_kind = owner_kind,
        .owner_id = owner_id,
        .trust_class = trust_class,
        .options = options,
        .external_meta = external_meta,
        .license_status = license_status,
        .license_authority_level = license_authority_level,
        .acceleration = acceleration,
    };

    const worker_count = @min(DEFAULT_INGEST_WORKERS, candidates.items.len);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    for (threads, 0..) |*thread, worker_id| {
        thread.* = try std.Thread.spawn(.{ .allocator = allocator }, scanWorker, .{ &context, worker_id });
    }
    for (threads) |thread| thread.join();

    for (results, 0..) |*result, index| {
        if (result.err) |err| return err;
        var outcome = result.outcome orelse return error.IncompleteParallelScan;
        result.outcome = null;
        errdefer outcome.deinit();
        switch (outcome) {
            .unit => |*unit| try appendScannedUnit(manifest, unit),
            .rejection => |*rejection| try manifest.rejections.append(rejection.*),
        }
        if (manifest.next_cursor) |old| allocator.free(old);
        manifest.next_cursor = try allocator.dupe(u8, candidates.items[index].rel_path);
    }
    try applyBatchedSemanticHashes(allocator, manifest, acceleration);
}

fn scanCandidatesSerial(
    allocator: std.mem.Allocator,
    candidates: []const FileCandidate,
    root_hint: RootHint,
    source_label: []const u8,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    trust_class: abstractions.TrustClass,
    options: Options,
    external_meta: *const std.StringHashMap(ExternalMetadata),
    manifest: *Manifest,
    license_status: []const u8,
    license_authority_level: u8,
    acceleration: *hash_acceleration.Context,
) !void {
    for (candidates) |candidate| {
        var outcome = try parseOneFileForIngest(allocator, candidate.abs_path, candidate.rel_path, root_hint, source_label, owner_kind, owner_id, trust_class, options, external_meta, license_status, license_authority_level, acceleration);
        errdefer outcome.deinit();
        switch (outcome) {
            .unit => |*unit| try appendScannedUnit(manifest, unit),
            .rejection => |*rejection| try manifest.rejections.append(rejection.*),
        }
        if (manifest.next_cursor) |old| allocator.free(old);
        manifest.next_cursor = try allocator.dupe(u8, candidate.rel_path);
        outcome = undefined;
    }
    try applyBatchedSemanticHashes(allocator, manifest, acceleration);
}

fn applyBatchedSemanticHashes(allocator: std.mem.Allocator, manifest: *Manifest, acceleration: *hash_acceleration.Context) !void {
    var texts = std.ArrayList([]const u8).init(allocator);
    defer texts.deinit();
    var indexes = std.ArrayList(usize).init(allocator);
    defer indexes.deinit();

    for (manifest.items.items, 0..) |item, idx| {
        if (item.lower_text) |text| {
            try texts.append(text[0..@min(text.len, MAX_FILE_READ_INDEX_BYTES)]);
            try indexes.append(idx);
        }
    }
    if (texts.items.len == 0) return;

    const hashes = try allocator.alloc(u64, texts.items.len);
    defer allocator.free(hashes);
    try hash_acceleration.semanticHash64Batch(acceleration, allocator, texts.items, hashes);
    for (hashes, 0..) |hash, idx| {
        manifest.items.items[indexes.items[idx]].semantic_hash = hash;
    }
}

fn collectFileCandidates(
    allocator: std.mem.Allocator,
    abs_dir: []const u8,
    rel_dir: []const u8,
    options: Options,
    capacity: *IngestCapacityTelemetry,
    coverage_complete: *bool,
    candidates: *std.ArrayList(FileCandidate),
) !void {
    var dir = try std.fs.openDirAbsolute(abs_dir, .{ .iterate = true });
    defer dir.close();

    const DirEntry = struct {
        name: []u8,
        kind: std.fs.File.Kind,

        fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            return walkNameLessThan(lhs.name, rhs.name);
        }
    };
    var entries = std.ArrayList(DirEntry).init(allocator);
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit();
    }
    var it = dir.iterate();
    while (try it.next()) |entry| {
        try entries.append(.{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
        });
    }
    std.mem.sort(DirEntry, entries.items, {}, DirEntry.lessThan);

    for (entries.items) |entry| {
        const rel_path = if (rel_dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel_dir, entry.name });
        defer allocator.free(rel_path);

        switch (entry.kind) {
            .directory => {
                if (shouldSkipWalkPath(entry.name)) continue;
                const child_abs = try std.fs.path.join(allocator, &.{ abs_dir, entry.name });
                defer allocator.free(child_abs);
                try collectFileCandidates(allocator, child_abs, rel_path, options, capacity, coverage_complete, candidates);
                if (!coverage_complete.*) return;
            },
            .file => {
                if (std.mem.eql(u8, entry.name, external_evidence.EXTERNAL_METADATA_FILE_NAME)) continue;
                if (options.cursor_after) |cursor| {
                    if (std.mem.order(u8, rel_path, cursor) != .gt) continue;
                }
                if (candidates.items.len >= options.max_files) {
                    if (!options.allow_partial) {
                        capacity.too_many_files = true;
                        capacity.file_cap_hit = true;
                        capacity.budget_hits += 1;
                        return error.TooManyFiles;
                    }
                    coverage_complete.* = false;
                    capacity.file_cap_hit = true;
                    capacity.budget_hits += 1;
                    return;
                }
                const abs_path = try std.fs.path.join(allocator, &.{ abs_dir, entry.name });
                errdefer allocator.free(abs_path);
                try candidates.append(.{
                    .allocator = allocator,
                    .abs_path = abs_path,
                    .rel_path = try allocator.dupe(u8, rel_path),
                });
            },
            else => {},
        }
    }
}

fn scanOneFile(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    rel_path: []const u8,
    root_hint: RootHint,
    source_label: []const u8,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    trust_class: abstractions.TrustClass,
    options: Options,
    external_meta: *const std.StringHashMap(ExternalMetadata),
    manifest: *Manifest,
    acceleration: *hash_acceleration.Context,
) !void {
    const license_status = try readLicenseStatus(allocator, manifest.source_root);
    defer allocator.free(license_status);
    const license_authority_level = try readLicenseAuthorityLevel(manifest.source_root);
    var outcome = try parseOneFileForIngest(allocator, abs_path, rel_path, root_hint, source_label, owner_kind, owner_id, trust_class, options, external_meta, license_status, license_authority_level, acceleration);
    errdefer outcome.deinit();
    switch (outcome) {
        .unit => |*unit| try appendScannedUnit(manifest, unit),
        .rejection => |*rejection| try manifest.rejections.append(rejection.*),
    }
    outcome = undefined;
    try applyBatchedSemanticHashes(allocator, manifest, acceleration);
}

fn scanWorker(context: *ParallelScanContext, _: usize) void {
    while (true) {
        const index = context.next_index.fetchAdd(1, .monotonic);
        if (index >= context.candidates.len) return;
        const candidate = context.candidates[index];
        context.results[index].outcome = parseOneFileForIngest(
            std.heap.page_allocator,
            candidate.abs_path,
            candidate.rel_path,
            context.root_hint,
            context.source_label,
            context.owner_kind,
            context.owner_id,
            context.trust_class,
            context.options,
            context.external_meta,
            context.license_status,
            context.license_authority_level,
            context.acceleration,
        ) catch |err| {
            context.results[index].err = err;
            return;
        };
    }
}

fn parseOneFileForIngest(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    rel_path: []const u8,
    root_hint: RootHint,
    source_label: []const u8,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    trust_class: abstractions.TrustClass,
    options: Options,
    external_meta: *const std.StringHashMap(ExternalMetadata),
    license_status: []const u8,
    license_authority_level: u8,
    acceleration: ?*hash_acceleration.Context,
) !ScanOutcome {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size > options.max_file_bytes) {
        return .{ .rejection = .{
            .allocator = allocator,
            .source_rel_path = try allocator.dupe(u8, rel_path),
            .reason = .file_too_large,
        } };
    }

    const bytes = try file.readToEndAlloc(allocator, options.max_file_bytes);
    defer allocator.free(bytes);
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) {
        return .{ .rejection = .{
            .allocator = allocator,
            .source_rel_path = try allocator.dupe(u8, rel_path),
            .reason = .contains_nul,
        } };
    }

    const axiom_language = resolvedAxiomLanguage(options, rel_path);
    const class = if (options.axiom_mode and axioms.isAxiomCandidatePath(rel_path, axiom_language))
        ItemClass.axiom
    else
        classifyInput(rel_path, root_hint, bytes) orelse {
            return .{ .rejection = .{
                .allocator = allocator,
                .source_rel_path = try allocator.dupe(u8, rel_path),
                .reason = .unsupported_extension,
            } };
        };

    _ = validateRuneBlocks(bytes) catch |err| switch (err) {
        error.InvalidUtf8 => return .{ .rejection = .{
            .allocator = allocator,
            .source_rel_path = try allocator.dupe(u8, rel_path),
            .reason = .invalid_utf8,
        } },
        else => return err,
    };

    const index_bytes = boundedUtf8Prefix(bytes, MAX_FILE_READ_INDEX_BYTES);
    const lower_text = try asciiLowerDup(allocator, index_bytes);
    errdefer allocator.free(lower_text);

    const tokens = try extractOwnedTokens(allocator, lower_text, MAX_TOKEN_COUNT);
    errdefer freeOwnedStringSlice(allocator, tokens);
    const patterns = try extractOwnedRuneGroups(allocator, lower_text, MAX_PATTERN_COUNT);
    errdefer freeOwnedStringSlice(allocator, patterns);

    if (class != .code and class != .axiom and tokens.len < 2 and patterns.len == 0) {
        allocator.free(lower_text);
        freeOwnedStringSlice(allocator, tokens);
        freeOwnedStringSlice(allocator, patterns);
        return .{ .rejection = .{
            .allocator = allocator,
            .source_rel_path = try allocator.dupe(u8, rel_path),
            .reason = .low_structure,
        } };
    }

    const raw_hash = vsa_vulkan.murmur3Bytes64(bytes);
    const normalized_bytes = try normalizedDedupBytes(allocator, bytes);
    defer allocator.free(normalized_bytes);
    const normalized_hash = vsa_vulkan.murmur3Bytes64(normalized_bytes);
    _ = acceleration;
    var code_intel_summary: ?[]u8 = null;
    errdefer if (code_intel_summary) |value| allocator.free(value);
    var axiom_rule: ?[]u8 = null;
    errdefer if (axiom_rule) |value| allocator.free(value);
    if (class == .axiom) {
        axiom_rule = try allocator.dupe(u8, axioms.ruleForPath(axiom_language, rel_path));
        code_intel_summary = try std.fmt.allocPrint(
            allocator,
            "axiom_vector|tier={s}|authority_level={d}|locked=true|language={s}|rule={s}",
            .{ axioms.AXIOM_TIER_LABEL, axioms.AXIOM_AUTHORITY_LEVEL, axioms.languageName(axiom_language), axiom_rule.? },
        );
    } else if (try cpp_ast.extract(allocator, manifestRootForCodeIntel(options.corpus_path), rel_path, index_bytes)) |summary| {
        code_intel_summary = summary.text;
    }
    const code_intel_lower = if (code_intel_summary) |summary_text| try asciiLowerDup(allocator, summary_text) else null;
    defer if (code_intel_lower) |value| allocator.free(value);
    const merged_index_text = if (code_intel_lower) |summary_lower|
        try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ lower_text[0..@min(lower_text.len, MAX_FILE_READ_INDEX_BYTES)], summary_lower })
    else
        null;
    defer if (merged_index_text) |value| allocator.free(value);
    const index_text = if (merged_index_text) |value| value[0..@min(value.len, MAX_FILE_READ_INDEX_BYTES)] else lower_text[0..@min(lower_text.len, MAX_FILE_READ_INDEX_BYTES)];
    const search_sketch = try corpus_sketch.simHash64(allocator, index_text);
    const frame_vector = if (class == .axiom)
        vsa_vulkan.SemanticFrameVector{
            .forward_hash = raw_hash,
            .inverse_hash = normalized_hash,
            .valid = raw_hash != 0,
        }
    else if (code_intel_summary == null)
        vsa_vulkan.extractFrameVector(index_text)
    else
        vsa_vulkan.SemanticFrameVector{};
    const synthetic_rel_path = try std.fs.path.join(allocator, &.{ CORPUS_REL_PREFIX, className(class), rel_path });
    errdefer allocator.free(synthetic_rel_path);
    const storage_rel_path = try std.fs.path.join(allocator, &.{ config.CORPUS_INGEST_FILES_DIR_NAME, className(class), rel_path });
    errdefer allocator.free(storage_rel_path);
    const lineage_id = try std.fmt.allocPrint(allocator, "corpus:{s}:{s}:{s}", .{ @tagName(owner_kind), owner_id, synthetic_rel_path });
    errdefer allocator.free(lineage_id);
    const provenance = if (external_meta.get(rel_path)) |meta|
        try buildExternalProvenance(allocator, source_label, rel_path, stat.mtime, &meta)
    else
        try std.fmt.allocPrint(allocator, "source={s}|path={s}|mtime_ns={d}", .{ source_label, rel_path, stat.mtime });
    errdefer allocator.free(provenance);

    var unit = SourceUnit{
        .allocator = allocator,
        .synthetic_rel_path = synthetic_rel_path,
        .storage_rel_path = storage_rel_path,
        .source_rel_path = try allocator.dupe(u8, rel_path),
        .source_abs_path = try allocator.dupe(u8, abs_path),
        .class = class,
        .trust_class = trust_class,
        .source_label = try allocator.dupe(u8, source_label),
        .license_status = try allocator.dupe(u8, if (class == .axiom) "axiom-locked" else license_status),
        .license_authority_level = if (class == .axiom) axioms.AXIOM_AUTHORITY_LEVEL else license_authority_level,
        .source_mtime_ns = stat.mtime,
        .size_bytes = stat.size,
        .raw_hash = raw_hash,
        .normalized_hash = normalized_hash,
        .semantic_hash = 0,
        .search_sketch_hash = search_sketch.hash,
        .search_sketch_features = search_sketch.feature_count,
        .spo_forward_hash = frame_vector.forward_hash,
        .spo_inverse_hash = frame_vector.inverse_hash,
        .lineage_id = lineage_id,
        .provenance = provenance,
        .lower_text = lower_text,
        .tokens = tokens,
        .patterns = patterns,
        .code_intel_summary = code_intel_summary,
        .axiom_locked = class == .axiom,
        .axiom_language = if (class == .axiom) try allocator.dupe(u8, axioms.languageName(axiom_language)) else null,
        .axiom_rule = axiom_rule,
    };
    code_intel_summary = null;
    axiom_rule = null;
    errdefer unit.deinit();

    return .{ .unit = unit };
}

fn manifestRootForCodeIntel(corpus_path: []const u8) []const u8 {
    return corpus_path;
}

fn appendScannedUnit(manifest: *Manifest, unit: *SourceUnit) !void {
    for (manifest.items.items) |*existing| {
        if (existing.raw_hash == unit.raw_hash) {
            unit.dedup = .exact_duplicate;
            unit.canonical_rel_path = try unit.allocator.dupe(u8, existing.synthetic_rel_path);
            break;
        }
        if (existing.normalized_hash == unit.normalized_hash) {
            unit.dedup = .normalized_duplicate;
            unit.canonical_rel_path = try unit.allocator.dupe(u8, existing.synthetic_rel_path);
            break;
        }
    }

    try manifest.items.append(unit.*);
}

const ConceptTarget = struct {
    item_index: usize,
    synthetic_rel_path: []const u8,
    source_rel_path: []const u8,
};

fn buildConceptSpecs(
    manifest: *Manifest,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    max_candidates: usize,
    max_concepts: usize,
) !void {
    try buildAxiomConceptSpecs(manifest, owner_kind, owner_id, max_concepts);

    var targets = std.ArrayList(ConceptTarget).init(manifest.allocator);
    defer targets.deinit();
    for (manifest.items.items, 0..) |target, target_index| {
        if (target.dedup != .unique) continue;
        try targets.append(.{
            .item_index = target_index,
            .synthetic_rel_path = target.synthetic_rel_path,
            .source_rel_path = target.source_rel_path,
        });
    }

    for (manifest.items.items, 0..) |*source, source_index| {
        if (source.class == .code or source.class == .axiom or source.dedup != .unique or source.lower_text == null) continue;
        const full_source_text = source.lower_text.?;
        const source_text = full_source_text[0..@min(full_source_text.len, DEFAULT_MAX_CONCEPT_SOURCE_BYTES)];
        for (targets.items) |target_info| {
            if (manifest.capacity_telemetry.concept_candidates_considered >= max_candidates) {
                manifest.capacity_telemetry.concept_candidate_cap_hit = true;
                manifest.capacity_telemetry.budget_hits += 1;
                return;
            }
            if (manifest.concepts.items.len >= max_concepts) {
                manifest.capacity_telemetry.concept_emit_cap_hit = true;
                manifest.capacity_telemetry.budget_hits += 1;
                return;
            }
            if (source_index == target_info.item_index) continue;
            manifest.capacity_telemetry.concept_candidates_considered += 1;
            if (!mentionsTarget(source_text, target_info.synthetic_rel_path, target_info.source_rel_path)) continue;
            const target = manifest.items.items[target_info.item_index];

            source.target_rel_path = if (source.target_rel_path) |existing|
                existing
            else
                try source.allocator.dupe(u8, target.synthetic_rel_path);
            if (source.target_rel_path != null and !std.mem.eql(u8, source.target_rel_path.?, target.synthetic_rel_path)) {
                source.allocator.free(source.target_rel_path.?);
                source.target_rel_path = try source.allocator.dupe(u8, target.synthetic_rel_path);
            }

            var source_specs = std.ArrayList([]u8).init(manifest.allocator);
            errdefer {
                for (source_specs.items) |item| manifest.allocator.free(item);
                source_specs.deinit();
            }
            try source_specs.append(try std.fmt.allocPrint(manifest.allocator, "file:{s}", .{target.synthetic_rel_path}));
            try source_specs.append(try std.fmt.allocPrint(manifest.allocator, "file:{s}", .{source.synthetic_rel_path}));

            var provenance = std.ArrayList([]u8).init(manifest.allocator);
            errdefer {
                for (provenance.items) |item| manifest.allocator.free(item);
                provenance.deinit();
            }
            try provenance.append(try manifest.allocator.dupe(u8, source.provenance));
            try provenance.append(try std.fmt.allocPrint(
                manifest.allocator,
                "ingested_link|target={s}|source_lineage={s}@{d}",
                .{ target.synthetic_rel_path, source.lineage_id, source.lineage_version },
            ));

            const concept_id = try std.fmt.allocPrint(
                manifest.allocator,
                "{s}{s}__to__{s}",
                .{ CONCEPT_PREFIX, conceptStem(source.source_rel_path), conceptStem(target.source_rel_path) },
            );
            errdefer manifest.allocator.free(concept_id);
            const lineage_id = try std.fmt.allocPrint(manifest.allocator, "{s}:{s}:{s}", .{ @tagName(owner_kind), owner_id, concept_id });
            errdefer manifest.allocator.free(lineage_id);
            const consensus_hash = conceptConsensusHash(concept_id, source.tokens, source.patterns, target.synthetic_rel_path);

            try manifest.concepts.append(.{
                .allocator = manifest.allocator,
                .concept_id = concept_id,
                .tier = conceptTierForClass(source.class),
                .category = conceptCategoryForClass(source.class),
                .trust_class = source.trust_class,
                .lineage_id = lineage_id,
                .lineage_version = 1,
                .source_specs = try source_specs.toOwnedSlice(),
                .tokens = try cloneStringSlice(manifest.allocator, source.tokens),
                .patterns = try buildConceptPatterns(manifest.allocator, source.patterns, target.synthetic_rel_path),
                .provenance = try provenance.toOwnedSlice(),
                .consensus_hash = consensus_hash,
                .quality_score = 780,
                .confidence_score = 760,
                .reuse_score = 220,
                .support_score = 760,
                .promotion_ready = source.trust_class != .exploratory,
            });
            manifest.capacity_telemetry.concepts_emitted = manifest.concepts.items.len;
        }
    }
    manifest.capacity_telemetry.concepts_emitted = manifest.concepts.items.len;
}

fn buildAxiomConceptSpecs(
    manifest: *Manifest,
    owner_kind: shards.Kind,
    owner_id: []const u8,
    max_concepts: usize,
) !void {
    for (manifest.items.items) |source| {
        if (source.class != .axiom or source.dedup != .unique) continue;
        if (manifest.concepts.items.len >= max_concepts) {
            manifest.capacity_telemetry.concept_emit_cap_hit = true;
            manifest.capacity_telemetry.budget_hits += 1;
            return;
        }

        var source_specs = std.ArrayList([]u8).init(manifest.allocator);
        errdefer {
            for (source_specs.items) |item| manifest.allocator.free(item);
            source_specs.deinit();
        }
        try source_specs.append(try std.fmt.allocPrint(manifest.allocator, "axiom:{s}", .{source.synthetic_rel_path}));

        var provenance = std.ArrayList([]u8).init(manifest.allocator);
        errdefer {
            for (provenance.items) |item| manifest.allocator.free(item);
            provenance.deinit();
        }
        try provenance.append(try manifest.allocator.dupe(u8, source.provenance));
        try provenance.append(try std.fmt.allocPrint(
            manifest.allocator,
            "axiom_vector|tier={s}|authority_level={d}|locked=true|lineage={s}@{d}",
            .{ axioms.AXIOM_TIER_LABEL, axioms.AXIOM_AUTHORITY_LEVEL, source.lineage_id, source.lineage_version },
        ));

        const concept_id = try std.fmt.allocPrint(
            manifest.allocator,
            "{s}axiom__{s}__{x}",
            .{ CONCEPT_PREFIX, conceptStem(source.source_rel_path), source.raw_hash },
        );
        errdefer manifest.allocator.free(concept_id);
        const lineage_id = try std.fmt.allocPrint(manifest.allocator, "{s}:{s}:{s}", .{ @tagName(owner_kind), owner_id, concept_id });
        errdefer manifest.allocator.free(lineage_id);

        try manifest.concepts.append(.{
            .allocator = manifest.allocator,
            .concept_id = concept_id,
            .tier = .contract,
            .category = .invariant,
            .trust_class = .core,
            .lineage_id = lineage_id,
            .lineage_version = 1,
            .source_specs = try source_specs.toOwnedSlice(),
            .tokens = try cloneStringSlice(manifest.allocator, source.tokens),
            .patterns = if (source.axiom_rule) |rule| try buildConceptPatterns(manifest.allocator, source.patterns, rule) else try cloneStringSlice(manifest.allocator, source.patterns),
            .provenance = try provenance.toOwnedSlice(),
            .consensus_hash = conceptConsensusHash(concept_id, source.tokens, source.patterns, source.synthetic_rel_path),
            .quality_score = 1000,
            .confidence_score = 1000,
            .reuse_score = 1000,
            .support_score = 1000,
            .promotion_ready = true,
        });
        manifest.capacity_telemetry.concepts_emitted = manifest.concepts.items.len;
    }
}

fn persistStagedState(allocator: std.mem.Allocator, paths: *const shards.Paths, manifest: *Manifest, max_file_bytes: usize) !void {
    try clearStaged(allocator, paths);
    try std.fs.cwd().makePath(paths.corpus_ingest_staged_abs_path);
    for (manifest.items.items) |item| {
        if (item.dedup != .unique) continue;
        const source_path = if (item.source_abs_path) |value|
            try allocator.dupe(u8, value)
        else
            try std.fs.path.join(allocator, &.{ manifest.source_root, item.source_rel_path });
        defer allocator.free(source_path);
        const dest_path = try std.fs.path.join(allocator, &.{ paths.corpus_ingest_staged_abs_path, item.storage_rel_path });
        defer allocator.free(dest_path);
        try ensureParentDirAbsolute(dest_path);
        try copyBoundedFile(source_path, dest_path, max_file_bytes);
    }
    const json = try serializeManifest(allocator, manifest);
    defer allocator.free(json);
    try ensureParentDirAbsolute(paths.corpus_ingest_staged_manifest_abs_path);
    try writeAbsoluteFile(paths.corpus_ingest_staged_manifest_abs_path, json);
}

fn buildStageItems(allocator: std.mem.Allocator, manifest: *const Manifest) ![]ItemResult {
    var out = std.ArrayList(ItemResult).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit();
        out.deinit();
    }

    for (manifest.items.items) |item| {
        try out.append(.{
            .allocator = allocator,
            .source_rel_path = try allocator.dupe(u8, item.source_rel_path),
            .synthetic_rel_path = try allocator.dupe(u8, item.synthetic_rel_path),
            .class = item.class,
            .status = if (item.dedup == .unique) "staged" else "duplicate",
            .dedup = item.dedup,
            .trust_class = item.trust_class,
            .lineage_id = try allocator.dupe(u8, item.lineage_id),
            .lineage_version = item.lineage_version,
            .provenance = try allocator.dupe(u8, item.provenance),
            .target_rel_path = if (item.target_rel_path) |value| try allocator.dupe(u8, value) else null,
        });
    }
    for (manifest.rejections.items) |rejection| {
        try out.append(.{
            .allocator = allocator,
            .source_rel_path = try allocator.dupe(u8, rejection.source_rel_path),
            .status = "rejected",
            .reject_reason = rejection.reason,
        });
    }
    return out.toOwnedSlice();
}

fn buildRecordsFromConcepts(allocator: std.mem.Allocator, concepts: []const ConceptSpec) ![]abstractions.Record {
    const out = try allocator.alloc(abstractions.Record, concepts.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*record| record.deinit();
        allocator.free(out);
    }

    for (concepts, 0..) |concept, idx| {
        const vector = computeConceptVector(concept.tokens, concept.patterns);
        out[idx] = .{
            .allocator = allocator,
            .concept_id = try allocator.dupe(u8, concept.concept_id),
            .tier = concept.tier,
            .category = concept.category,
            .example_count = 2,
            .threshold_examples = 2,
            .retained_token_count = @intCast(concept.tokens.len),
            .retained_pattern_count = @intCast(concept.patterns.len),
            .average_resonance = 780,
            .min_resonance = 720,
            .quality_score = concept.quality_score,
            .confidence_score = concept.confidence_score,
            .reuse_score = concept.reuse_score,
            .support_score = concept.support_score,
            .promotion_ready = concept.promotion_ready,
            .consensus_hash = concept.consensus_hash,
            .valid_to_commit = true,
            .vector = vector,
            .lineage_id = try allocator.dupe(u8, concept.lineage_id),
            .lineage_version = concept.lineage_version,
            .trust_class = concept.trust_class,
            .sources = try cloneStringSlice(allocator, concept.source_specs),
            .tokens = try cloneStringSlice(allocator, concept.tokens),
            .patterns = try cloneStringSlice(allocator, concept.patterns),
            .provenance = try cloneStringSlice(allocator, concept.provenance),
        };
        built += 1;
    }

    return out;
}

fn computeConceptVector(tokens: [][]u8, patterns: [][]u8) vsa.HyperVector {
    var votes = [_]i32{0} ** 1024;
    var feature_count: usize = 0;
    for (tokens) |token| {
        addVectorVotes(&votes, featureVector("tok:", token));
        feature_count += 1;
    }
    for (patterns) |pattern| {
        addVectorVotes(&votes, featureVector("pat:", pattern));
        feature_count += 1;
    }
    if (feature_count == 0) return @as(vsa.HyperVector, @splat(@as(u64, 0)));
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
    var lanes = [_]u64{0} ** 64; // 4096-bit HyperVector; the 1024 votes fill the low 16 data lanes
    var idx: usize = 0;
    while (idx < 1024) : (idx += 1) {
        if (votes[idx] >= 0) lanes[idx / 64] |= (@as(u64, 1) << @as(u6, @intCast(idx % 64)));
    }
    var result: vsa.HyperVector = lanes;
    result[vsa.PARITY_LANE] = vsa.generateParity(result); // was result[15] — stale 1024-bit parity-lane convention
    return result;
}

fn mentionsTarget(lower_source: []const u8, synthetic_rel_path: []const u8, source_rel_path: []const u8) bool {
    const basename = std.fs.path.basename(source_rel_path);
    const stem = std.fs.path.stem(basename);
    if (containsWholeLowerNeedle(lower_source, synthetic_rel_path)) return true;
    if (containsWholeLowerNeedle(lower_source, basename)) return true;
    if (stem.len >= 3 and containsWholeLowerNeedle(lower_source, stem)) return true;
    return false;
}

fn conceptTierForClass(class: ItemClass) abstractions.Tier {
    return switch (class) {
        .docs => .convention,
        .specs => .contract,
        .configs => .logic,
        .symbolic => .logic,
        .code => .logic,
        .axiom => .contract,
    };
}

fn conceptCategoryForClass(class: ItemClass) abstractions.Category {
    return switch (class) {
        .docs => .boundary,
        .specs => .invariant,
        .configs => .state,
        .symbolic => .procedural,
        .code => .relational,
        .axiom => .invariant,
    };
}

fn conceptStem(path: []const u8) []const u8 {
    return std.fs.path.stem(std.fs.path.basename(path));
}

fn conceptConsensusHash(concept_id: []const u8, tokens: [][]u8, patterns: [][]u8, target_rel_path: []const u8) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(concept_id);
    hasher.update(target_rel_path);
    for (tokens) |item| hasher.update(item);
    for (patterns) |item| hasher.update(item);
    return hasher.final();
}

fn buildConceptPatterns(allocator: std.mem.Allocator, source_patterns: [][]u8, target_rel_path: []const u8) ![][]u8 {
    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    for (source_patterns) |item| {
        if (out.items.len >= MAX_PATTERN_COUNT - 1) break;
        try out.append(try allocator.dupe(u8, item));
    }
    try out.append(try allocator.dupe(u8, std.fs.path.basename(target_rel_path)));
    return out.toOwnedSlice();
}

fn classifyInput(path: []const u8, root_hint: RootHint, bytes: []const u8) ?ItemClass {
    if (isCodeExtension(path)) return .code;
    if (isSymbolicExtension(path)) return .symbolic;
    if (isConfigExtension(path)) return .configs;
    if (isRawTextExtension(path)) {
        return if (root_hint == .specs) .specs else .docs;
    }
    if (isDocExtension(path)) {
        return if (root_hint == .specs) .specs else .docs;
    }
    if (root_hint == .specs or root_hint == .docs or root_hint == .configs) {
        if (std.mem.indexOfScalar(u8, bytes, 0) == null) {
            return switch (root_hint) {
                .specs => .specs,
                .docs => .docs,
                .configs => .configs,
                else => null,
            };
        }
    }
    return null;
}

fn isCodeExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") or
        std.mem.endsWith(u8, path, ".comp") or
        std.mem.endsWith(u8, path, ".sigil") or
        std.mem.endsWith(u8, path, ".c") or
        std.mem.endsWith(u8, path, ".cc") or
        std.mem.endsWith(u8, path, ".cpp") or
        std.mem.endsWith(u8, path, ".cxx") or
        std.mem.endsWith(u8, path, ".h") or
        std.mem.endsWith(u8, path, ".hh") or
        std.mem.endsWith(u8, path, ".hpp") or
        std.mem.endsWith(u8, path, ".hxx");
}

fn isRawTextExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".txt") or
        std.mem.endsWith(u8, path, ".md");
}

fn isDocExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or
        std.mem.endsWith(u8, path, ".txt") or
        std.mem.endsWith(u8, path, ".rst") or
        std.mem.endsWith(u8, path, ".html") or
        std.mem.endsWith(u8, path, ".xml");
}

fn isConfigExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".toml") or
        std.mem.endsWith(u8, path, ".yaml") or
        std.mem.endsWith(u8, path, ".yml") or
        std.mem.endsWith(u8, path, ".json") or
        std.mem.endsWith(u8, path, ".ini") or
        std.mem.endsWith(u8, path, ".cfg") or
        std.mem.endsWith(u8, path, ".conf") or
        std.mem.endsWith(u8, path, ".env") or
        std.mem.endsWith(u8, path, ".tf") or
        std.mem.endsWith(u8, path, ".tfvars") or
        std.mem.endsWith(u8, path, ".tpl");
}

fn isSymbolicExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".rules") or
        std.mem.endsWith(u8, path, ".dsl") or
        std.mem.endsWith(u8, path, ".test") or
        std.mem.endsWith(u8, path, ".spec");
}

fn shouldSkipWalkPath(base: []const u8) bool {
    return std.mem.eql(u8, base, ".git") or
        std.mem.eql(u8, base, ".hg") or
        std.mem.eql(u8, base, ".svn") or
        std.mem.eql(u8, base, ".zig-cache") or
        std.mem.eql(u8, base, "zig-out") or
        std.mem.eql(u8, base, "state");
}

fn walkNameLessThan(lhs: []const u8, rhs: []const u8) bool {
    const lhs_stem = std.fs.path.stem(lhs);
    const rhs_stem = std.fs.path.stem(rhs);
    if (lhs_stem.len > rhs_stem.len and
        std.mem.startsWith(u8, lhs_stem, rhs_stem) and
        lhs_stem[rhs_stem.len] == '-')
    {
        return false;
    }
    if (rhs_stem.len > lhs_stem.len and
        std.mem.startsWith(u8, rhs_stem, lhs_stem) and
        rhs_stem[lhs_stem.len] == '-')
    {
        return true;
    }
    return std.mem.lessThan(u8, lhs, rhs);
}

fn rewritePackSyntheticRelPath(allocator: std.mem.Allocator, pack_prefix: []const u8, synthetic_rel_path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, synthetic_rel_path, CORPUS_REL_PREFIX ++ "/")) {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_prefix, synthetic_rel_path[CORPUS_REL_PREFIX.len + 1 ..] });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_prefix, synthetic_rel_path });
}

fn extractOwnedTokens(allocator: std.mem.Allocator, lower_text: []const u8, max_items: usize) ![][]u8 {
    var list = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit();
    }
    var i: usize = 0;
    while (i < lower_text.len and list.items.len < max_items) {
        while (i < lower_text.len and !isTokenByte(lower_text[i])) : (i += 1) {}
        const start = i;
        while (i < lower_text.len and isTokenByte(lower_text[i])) : (i += 1) {}
        if (start == i) continue;
        const token = std.mem.trim(u8, lower_text[start..i], "._-/");
        if (token.len < 2) continue;
        if (containsOwned(list.items, token)) continue;
        try list.append(try allocator.dupe(u8, token));
    }
    return list.toOwnedSlice();
}

fn extractOwnedPatterns(allocator: std.mem.Allocator, lower_text: []const u8, max_items: usize) ![][]u8 {
    var list = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit();
    }
    var lines = std.mem.splitScalar(u8, lower_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len < 4) continue;
        if (containsOwned(list.items, line)) continue;
        try list.append(try allocator.dupe(u8, line));
        if (list.items.len >= max_items) break;
    }
    return list.toOwnedSlice();
}

fn validateRuneBlocks(text: []const u8) !RuneParseSummary {
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iter = view.iterator();
    var summary = RuneParseSummary{};
    while (iter.nextCodepoint()) |rune| {
        summary.rune_count += 1;
        if (isStructuralRune(rune)) summary.structural_punctuation_count += 1;
    }
    return summary;
}

fn boundedUtf8Prefix(text: []const u8, max_bytes: usize) []const u8 {
    var end = @min(text.len, max_bytes);
    while (end > 0) {
        _ = std.unicode.Utf8View.init(text[0..end]) catch {
            end -= 1;
            continue;
        };
        break;
    }
    return text[0..end];
}

fn extractOwnedRuneGroups(allocator: std.mem.Allocator, lower_text: []const u8, max_items: usize) ![][]u8 {
    var list = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit();
    }

    var group_start: usize = 0;
    var index: usize = 0;
    var view = std.unicode.Utf8View.init(lower_text) catch return error.InvalidUtf8;
    var iter = view.iterator();
    while (iter.nextCodepointSlice()) |rune_slice| {
        const rune = decodeRuneSlice(rune_slice) catch continue;
        index += rune_slice.len;
        if (!isStructuralRune(rune)) continue;

        const group = std.mem.trim(u8, lower_text[group_start..index], " \r\n\t-*#`>.,;:!?()[]{}\"'");
        group_start = index;
        if (group.len < 4) continue;
        if (!looksLikeClaimOrObligation(group) and list.items.len + 1 < max_items) continue;
        if (containsOwned(list.items, group)) continue;
        try list.append(try allocator.dupe(u8, group));
        if (list.items.len >= max_items) break;
    }

    if (list.items.len == 0) {
        return extractOwnedPatterns(allocator, lower_text, max_items);
    }
    return list.toOwnedSlice();
}

fn decodeRuneSlice(rune_slice: []const u8) !u21 {
    var view = try std.unicode.Utf8View.init(rune_slice);
    var iter = view.iterator();
    return iter.nextCodepoint() orelse error.InvalidUtf8;
}

fn isStructuralRune(rune: u21) bool {
    return rune == '.' or rune == ';' or rune == ':' or rune == '!' or rune == '?' or rune == '\n';
}

fn looksLikeClaimOrObligation(group: []const u8) bool {
    return std.mem.indexOf(u8, group, " is ") != null or
        std.mem.indexOf(u8, group, " are ") != null or
        std.mem.indexOf(u8, group, " was ") != null or
        std.mem.indexOf(u8, group, " were ") != null or
        std.mem.indexOf(u8, group, " must ") != null or
        std.mem.indexOf(u8, group, " shall ") != null or
        std.mem.indexOf(u8, group, " should ") != null or
        std.mem.startsWith(u8, group, "claim") or
        std.mem.startsWith(u8, group, "obligation");
}

fn containsOwned(items: [][]u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn freeOwnedStringSlice(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    if (items.len > 0) allocator.free(items);
}

fn cloneStringSlice(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, items.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = try allocator.dupe(u8, item);
        built += 1;
    }
    return out;
}

fn cloneSourceUnit(allocator: std.mem.Allocator, item: SourceUnit) !SourceUnit {
    return .{
        .allocator = allocator,
        .synthetic_rel_path = try allocator.dupe(u8, item.synthetic_rel_path),
        .storage_rel_path = try allocator.dupe(u8, item.storage_rel_path),
        .source_rel_path = try allocator.dupe(u8, item.source_rel_path),
        .source_abs_path = if (item.source_abs_path) |value| try allocator.dupe(u8, value) else null,
        .class = item.class,
        .trust_class = item.trust_class,
        .source_label = try allocator.dupe(u8, item.source_label),
        .license_status = try allocator.dupe(u8, item.license_status),
        .license_authority_level = item.license_authority_level,
        .source_mtime_ns = item.source_mtime_ns,
        .size_bytes = item.size_bytes,
        .raw_hash = item.raw_hash,
        .normalized_hash = item.normalized_hash,
        .semantic_hash = item.semantic_hash,
        .search_sketch_hash = item.search_sketch_hash,
        .search_sketch_features = item.search_sketch_features,
        .spo_forward_hash = item.spo_forward_hash,
        .spo_inverse_hash = item.spo_inverse_hash,
        .dedup = item.dedup,
        .canonical_rel_path = if (item.canonical_rel_path) |value| try allocator.dupe(u8, value) else null,
        .lineage_id = try allocator.dupe(u8, item.lineage_id),
        .lineage_version = item.lineage_version,
        .provenance = try allocator.dupe(u8, item.provenance),
        .target_rel_path = if (item.target_rel_path) |value| try allocator.dupe(u8, value) else null,
        .lower_text = if (item.lower_text) |value| try allocator.dupe(u8, value) else null,
        .tokens = try cloneStringSlice(allocator, item.tokens),
        .patterns = try cloneStringSlice(allocator, item.patterns),
        .code_intel_summary = if (item.code_intel_summary) |value| try allocator.dupe(u8, value) else null,
        .axiom_locked = item.axiom_locked,
        .axiom_language = if (item.axiom_language) |value| try allocator.dupe(u8, value) else null,
        .axiom_rule = if (item.axiom_rule) |value| try allocator.dupe(u8, value) else null,
    };
}

fn cloneConceptSpec(allocator: std.mem.Allocator, item: ConceptSpec) !ConceptSpec {
    return .{
        .allocator = allocator,
        .concept_id = try allocator.dupe(u8, item.concept_id),
        .tier = item.tier,
        .category = item.category,
        .trust_class = item.trust_class,
        .lineage_id = try allocator.dupe(u8, item.lineage_id),
        .lineage_version = item.lineage_version,
        .source_specs = try cloneStringSlice(allocator, item.source_specs),
        .tokens = try cloneStringSlice(allocator, item.tokens),
        .patterns = try cloneStringSlice(allocator, item.patterns),
        .provenance = try cloneStringSlice(allocator, item.provenance),
        .consensus_hash = item.consensus_hash,
        .quality_score = item.quality_score,
        .confidence_score = item.confidence_score,
        .reuse_score = item.reuse_score,
        .support_score = item.support_score,
        .promotion_ready = item.promotion_ready,
    };
}

fn normalizedDedupBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\r') {
            if (i + 1 < bytes.len and bytes[i + 1] == '\n') continue;
            try out.append('\n');
            continue;
        }
        try out.append(bytes[i]);
    }
    return out.toOwnedSlice();
}

fn asciiLowerDup(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, idx| out[idx] = std.ascii.toLower(byte);
    return out;
}

fn isTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == '/';
}

fn containsWhole(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |idx| {
        const before_ok = idx == 0 or !isTokenByte(haystack[idx - 1]);
        const after_pos = idx + needle.len;
        const after_ok = after_pos >= haystack.len or !isTokenByte(haystack[after_pos]);
        if (before_ok and after_ok) return true;
        start = idx + 1;
    }
    return false;
}

fn containsWholeLowerNeedle(haystack_lower: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack_lower.len < needle.len) return false;

    if (isAsciiLowerOrNeutral(needle)) {
        return containsWholeLowerNeedleExact(haystack_lower, needle);
    }

    var lower_buf: [512]u8 = undefined;
    if (needle.len <= lower_buf.len) {
        for (needle, 0..) |c, idx| lower_buf[idx] = std.ascii.toLower(c);
        return containsWholeLowerNeedleExact(haystack_lower, lower_buf[0..needle.len]);
    }

    var idx: usize = 0;
    while (idx + needle.len <= haystack_lower.len) : (idx += 1) {
        const before_ok = idx == 0 or !isTokenByte(haystack_lower[idx - 1]);
        const after_pos = idx + needle.len;
        const after_ok = after_pos >= haystack_lower.len or !isTokenByte(haystack_lower[after_pos]);
        if (!before_ok or !after_ok) continue;

        var matched = true;
        var needle_idx: usize = 0;
        while (needle_idx < needle.len) : (needle_idx += 1) {
            if (haystack_lower[idx + needle_idx] != std.ascii.toLower(needle[needle_idx])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn containsWholeLowerNeedleExact(haystack_lower: []const u8, lower_needle: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack_lower, start, lower_needle)) |idx| {
        const before_ok = idx == 0 or !isTokenByte(haystack_lower[idx - 1]);
        const after_pos = idx + lower_needle.len;
        const after_ok = after_pos >= haystack_lower.len or !isTokenByte(haystack_lower[after_pos]);
        if (before_ok and after_ok) return true;
        start = idx + 1;
    }
    return false;
}

fn isAsciiLowerOrNeutral(text: []const u8) bool {
    for (text) |c| {
        if (std.ascii.isUpper(c)) return false;
    }
    return true;
}

fn serializeManifest(allocator: std.mem.Allocator, manifest: *Manifest) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{");
    try writeJsonFieldString(writer, "version", MANIFEST_VERSION, true);
    try writeOptionalStringField(writer, "sourceRoot", manifest.source_root);
    try writeOptionalStringField(writer, "sourceLabel", manifest.source_label);
    try writer.writeAll(",\"coverage\":{");
    try writer.print("\"complete\":{s}", .{if (manifest.coverage_complete) "true" else "false"});
    try writer.print(",\"scannedFiles\":{d},\"stagedItems\":{d},\"rejectedItems\":{d}", .{
        manifest.items.items.len + manifest.rejections.items.len,
        manifest.items.items.len,
        manifest.rejections.items.len,
    });
    if (manifest.next_cursor) |value| try writeOptionalStringField(writer, "nextCursor", value);
    try writer.writeAll("},\"capacityTelemetry\":");
    try writeIngestCapacityTelemetry(writer, manifest.capacity_telemetry);
    try writer.writeAll(",\"items\":[");
    for (manifest.items.items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "syntheticRelPath", item.synthetic_rel_path, true);
        try writeJsonFieldString(writer, "storageRelPath", item.storage_rel_path, false);
        try writeJsonFieldString(writer, "sourceRelPath", item.source_rel_path, false);
        try writeJsonFieldString(writer, "class", className(item.class), false);
        try writeJsonFieldString(writer, "trustClass", abstractions.trustClassName(item.trust_class), false);
        try writeJsonFieldString(writer, "sourceLabel", item.source_label, false);
        try writeJsonFieldString(writer, "licenseStatus", item.license_status, false);
        try writer.print(",\"authorityLevel\":{d}", .{item.license_authority_level});
        try writer.print(",\"sourceMtimeNs\":{d},\"sizeBytes\":{d},\"rawHash\":{d},\"normalizedHash\":{d},\"semanticHash\":{d},\"searchSketchHash\":{d},\"searchSketchFeatures\":{d},\"spoForwardHash\":{d},\"spoInverseHash\":{d}", .{
            item.source_mtime_ns,
            item.size_bytes,
            item.raw_hash,
            item.normalized_hash,
            item.semantic_hash,
            item.search_sketch_hash,
            item.search_sketch_features,
            item.spo_forward_hash,
            item.spo_inverse_hash,
        });
        if (item.code_intel_summary) |summary| try writeOptionalStringField(writer, "codeIntelSummary", summary);
        if (item.axiom_locked) {
            try writer.writeAll(",\"axiomLocked\":true");
            try writeOptionalStringField(writer, "axiomAuthorityTier", axioms.AXIOM_TIER_LABEL);
            if (item.axiom_language) |value| try writeOptionalStringField(writer, "axiomLanguage", value);
            if (item.axiom_rule) |value| try writeOptionalStringField(writer, "axiomRule", value);
        }
        try writeOptionalStringField(writer, "dedup", dedupName(item.dedup));
        if (item.canonical_rel_path) |value| try writeOptionalStringField(writer, "canonicalRelPath", value);
        try writeOptionalStringField(writer, "lineageId", item.lineage_id);
        try writer.print(",\"lineageVersion\":{d}", .{item.lineage_version});
        try writeOptionalStringField(writer, "provenance", item.provenance);
        if (item.target_rel_path) |value| try writeOptionalStringField(writer, "targetRelPath", value);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"concepts\":[");
    for (manifest.concepts.items, 0..) |concept, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "conceptId", concept.concept_id, true);
        try writeJsonFieldString(writer, "tier", abstractions.tierName(concept.tier), false);
        try writeJsonFieldString(writer, "category", abstractions.categoryName(concept.category), false);
        try writeJsonFieldString(writer, "trustClass", abstractions.trustClassName(concept.trust_class), false);
        try writeOptionalStringField(writer, "lineageId", concept.lineage_id);
        try writer.print(",\"lineageVersion\":{d}", .{concept.lineage_version});
        try writer.print(",\"consensusHash\":{d},\"qualityScore\":{d},\"confidenceScore\":{d},\"reuseScore\":{d},\"supportScore\":{d},\"promotionReady\":{s}", .{
            concept.consensus_hash,
            concept.quality_score,
            concept.confidence_score,
            concept.reuse_score,
            concept.support_score,
            if (concept.promotion_ready) "true" else "false",
        });
        try writer.writeAll(",\"sourceSpecs\":");
        try writeStringArray(writer, concept.source_specs);
        try writer.writeAll(",\"tokens\":");
        try writeStringArray(writer, concept.tokens);
        try writer.writeAll(",\"patterns\":");
        try writeStringArray(writer, concept.patterns);
        try writer.writeAll(",\"provenance\":");
        try writeStringArray(writer, concept.provenance);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"rejections\":[");
    for (manifest.rejections.items, 0..) |rejection, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writeJsonFieldString(writer, "sourceRelPath", rejection.source_rel_path, true);
        try writeJsonFieldString(writer, "reason", rejectReasonName(rejection.reason), false);
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn loadManifestFromPath(allocator: std.mem.Allocator, abs_path: []const u8) !struct { manifest: Manifest, mtime_ns: i128 } {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    const stat = try file.stat();
    const bytes = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(bytes);

    const DiskItem = struct {
        syntheticRelPath: []const u8,
        storageRelPath: []const u8,
        sourceRelPath: []const u8,
        class: []const u8,
        trustClass: []const u8,
        sourceLabel: []const u8,
        licenseStatus: ?[]const u8 = null,
        authorityLevel: ?u8 = null,
        sourceMtimeNs: i128,
        sizeBytes: u64,
        rawHash: u64,
        normalizedHash: u64,
        semanticHash: ?u64 = null,
        searchSketchHash: ?u64 = null,
        searchSketchFeatures: ?usize = null,
        spoForwardHash: ?u64 = null,
        spoInverseHash: ?u64 = null,
        codeIntelSummary: ?[]const u8 = null,
        axiomLocked: bool = false,
        axiomLanguage: ?[]const u8 = null,
        axiomRule: ?[]const u8 = null,
        dedup: []const u8,
        canonicalRelPath: ?[]const u8 = null,
        lineageId: []const u8,
        lineageVersion: u32,
        provenance: []const u8,
        targetRelPath: ?[]const u8 = null,
    };
    const DiskConcept = struct {
        conceptId: []const u8,
        tier: []const u8,
        category: []const u8,
        trustClass: []const u8,
        lineageId: []const u8,
        lineageVersion: u32,
        consensusHash: u64,
        qualityScore: u16,
        confidenceScore: u16,
        reuseScore: u16,
        supportScore: u16,
        promotionReady: bool,
        sourceSpecs: []const []const u8,
        tokens: []const []const u8,
        patterns: []const []const u8,
        provenance: []const []const u8,
    };
    const DiskRejection = struct {
        sourceRelPath: []const u8,
        reason: []const u8,
    };
    const DiskCoverage = struct {
        complete: bool = true,
        scannedFiles: u32 = 0,
        stagedItems: u32 = 0,
        rejectedItems: u32 = 0,
        nextCursor: ?[]const u8 = null,
    };
    const DiskCapacityTelemetry = struct {
        tooManyFiles: bool = false,
        fileCapHit: bool = false,
        conceptCandidateCapHit: bool = false,
        conceptEmitCapHit: bool = false,
        conceptCandidatesConsidered: usize = 0,
        conceptsEmitted: usize = 0,
        budgetHits: usize = 0,
    };
    const DiskManifest = struct {
        version: []const u8,
        sourceRoot: []const u8,
        sourceLabel: []const u8,
        coverage: DiskCoverage = .{},
        capacityTelemetry: DiskCapacityTelemetry = .{},
        items: []const DiskItem,
        concepts: []const DiskConcept,
        rejections: []const DiskRejection,
    };

    const parsed = try std.json.parseFromSlice(DiskManifest, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.version, MANIFEST_VERSION)) return error.InvalidCorpusManifest;

    var manifest = try Manifest.init(allocator, parsed.value.sourceRoot, parsed.value.sourceLabel);
    errdefer manifest.deinit();
    manifest.coverage_complete = parsed.value.coverage.complete;
    manifest.next_cursor = if (parsed.value.coverage.nextCursor) |value| try allocator.dupe(u8, value) else null;
    manifest.capacity_telemetry = .{
        .too_many_files = parsed.value.capacityTelemetry.tooManyFiles,
        .file_cap_hit = parsed.value.capacityTelemetry.fileCapHit,
        .concept_candidate_cap_hit = parsed.value.capacityTelemetry.conceptCandidateCapHit,
        .concept_emit_cap_hit = parsed.value.capacityTelemetry.conceptEmitCapHit,
        .concept_candidates_considered = parsed.value.capacityTelemetry.conceptCandidatesConsidered,
        .concepts_emitted = parsed.value.capacityTelemetry.conceptsEmitted,
        .budget_hits = parsed.value.capacityTelemetry.budgetHits,
    };
    const fallback_license_status = try readLicenseStatus(allocator, parsed.value.sourceRoot);
    defer allocator.free(fallback_license_status);
    const fallback_authority_level = try readLicenseAuthorityLevel(parsed.value.sourceRoot);

    for (parsed.value.items) |item| {
        try manifest.items.append(.{
            .allocator = allocator,
            .synthetic_rel_path = try allocator.dupe(u8, item.syntheticRelPath),
            .storage_rel_path = try allocator.dupe(u8, item.storageRelPath),
            .source_rel_path = try allocator.dupe(u8, item.sourceRelPath),
            .class = parseClass(item.class) orelse return error.InvalidCorpusManifest,
            .trust_class = abstractions.parseTrustClassName(item.trustClass) orelse return error.InvalidCorpusManifest,
            .source_label = try allocator.dupe(u8, item.sourceLabel),
            .license_status = try allocator.dupe(u8, if (std.mem.eql(u8, fallback_license_status, "unspecified")) item.licenseStatus orelse fallback_license_status else fallback_license_status),
            .license_authority_level = if (std.mem.eql(u8, fallback_license_status, "unspecified")) item.authorityLevel orelse fallback_authority_level else fallback_authority_level,
            .source_mtime_ns = item.sourceMtimeNs,
            .size_bytes = item.sizeBytes,
            .raw_hash = item.rawHash,
            .normalized_hash = item.normalizedHash,
            .semantic_hash = item.semanticHash orelse item.normalizedHash,
            .search_sketch_hash = item.searchSketchHash orelse 0,
            .search_sketch_features = item.searchSketchFeatures orelse 0,
            .spo_forward_hash = item.spoForwardHash orelse 0,
            .spo_inverse_hash = item.spoInverseHash orelse 0,
            .code_intel_summary = if (item.codeIntelSummary) |value| try allocator.dupe(u8, value) else null,
            .axiom_locked = item.axiomLocked,
            .axiom_language = if (item.axiomLanguage) |value| try allocator.dupe(u8, value) else null,
            .axiom_rule = if (item.axiomRule) |value| try allocator.dupe(u8, value) else null,
            .dedup = parseDedup(item.dedup) orelse return error.InvalidCorpusManifest,
            .canonical_rel_path = if (item.canonicalRelPath) |value| try allocator.dupe(u8, value) else null,
            .lineage_id = try allocator.dupe(u8, item.lineageId),
            .lineage_version = item.lineageVersion,
            .provenance = try allocator.dupe(u8, item.provenance),
            .target_rel_path = if (item.targetRelPath) |value| try allocator.dupe(u8, value) else null,
        });
    }

    for (parsed.value.concepts) |concept| {
        try manifest.concepts.append(.{
            .allocator = allocator,
            .concept_id = try allocator.dupe(u8, concept.conceptId),
            .tier = try parseTier(concept.tier),
            .category = try parseCategory(concept.category),
            .trust_class = abstractions.parseTrustClassName(concept.trustClass) orelse return error.InvalidManifestMetadata,
            .lineage_id = try allocator.dupe(u8, concept.lineageId),
            .lineage_version = concept.lineageVersion,
            .source_specs = try cloneStringSlice(allocator, concept.sourceSpecs),
            .tokens = try cloneStringSlice(allocator, concept.tokens),
            .patterns = try cloneStringSlice(allocator, concept.patterns),
            .provenance = try cloneStringSlice(allocator, concept.provenance),
            .consensus_hash = concept.consensusHash,
            .quality_score = concept.qualityScore,
            .confidence_score = concept.confidenceScore,
            .reuse_score = concept.reuseScore,
            .support_score = concept.supportScore,
            .promotion_ready = concept.promotionReady,
        });
    }

    for (parsed.value.rejections) |rejection| {
        try manifest.rejections.append(.{
            .allocator = allocator,
            .source_rel_path = try allocator.dupe(u8, rejection.sourceRelPath),
            .reason = parseRejectReason(rejection.reason) orelse return error.InvalidCorpusManifest,
        });
    }

    return .{
        .manifest = manifest,
        .mtime_ns = stat.mtime,
    };
}

fn parseClass(text: []const u8) ?ItemClass {
    if (std.mem.eql(u8, text, "code")) return .code;
    if (std.mem.eql(u8, text, "docs")) return .docs;
    if (std.mem.eql(u8, text, "specs")) return .specs;
    if (std.mem.eql(u8, text, "configs")) return .configs;
    if (std.mem.eql(u8, text, "symbolic")) return .symbolic;
    if (std.mem.eql(u8, text, "axioms") or std.mem.eql(u8, text, "axiom")) return .axiom;
    return null;
}

fn parseDedup(text: []const u8) ?DedupStatus {
    if (std.mem.eql(u8, text, "unique")) return .unique;
    if (std.mem.eql(u8, text, "exact_duplicate")) return .exact_duplicate;
    if (std.mem.eql(u8, text, "normalized_duplicate")) return .normalized_duplicate;
    return null;
}

fn parseRejectReason(text: []const u8) ?RejectReason {
    if (std.mem.eql(u8, text, "unsupported_extension")) return .unsupported_extension;
    if (std.mem.eql(u8, text, "file_too_large")) return .file_too_large;
    if (std.mem.eql(u8, text, "contains_nul")) return .contains_nul;
    if (std.mem.eql(u8, text, "invalid_utf8")) return .invalid_utf8;
    if (std.mem.eql(u8, text, "low_structure")) return .low_structure;
    return null;
}

fn parseTier(text: []const u8) !abstractions.Tier {
    if (std.mem.eql(u8, text, "pattern")) return .pattern;
    if (std.mem.eql(u8, text, "convention") or std.mem.eql(u8, text, "idiom")) return .convention;
    if (std.mem.eql(u8, text, "logic")) return .logic;
    if (std.mem.eql(u8, text, "contract")) return .contract;

    std.debug.print("Invalid manifest tier: '{s}'. Supported tiers: pattern, convention, logic, contract. (Hint: 'idiom' is automatically mapped to 'convention')\n", .{text});
    return error.InvalidManifestMetadata;
}

fn parseCategory(text: []const u8) !abstractions.Category {
    if (std.mem.eql(u8, text, "structural")) return .structural;
    if (std.mem.eql(u8, text, "procedural")) return .procedural;
    if (std.mem.eql(u8, text, "relational")) return .relational;
    if (std.mem.eql(u8, text, "boundary") or std.mem.eql(u8, text, "interface")) return .boundary;
    if (std.mem.eql(u8, text, "state")) return .state;
    if (std.mem.eql(u8, text, "invariant")) return .invariant;

    std.debug.print("Invalid manifest category: '{s}'. Supported categories: structural, procedural, relational, boundary, state, invariant. (Hint: 'interface' is automatically mapped to 'boundary')\n", .{text});
    return error.InvalidManifestMetadata;
}

fn pathExists(abs_path: []const u8) bool {
    var file = std.fs.openFileAbsolute(abs_path, .{}) catch null;
    if (file) |*opened| {
        opened.close();
        return true;
    }
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch null;
    if (dir) |*opened| {
        opened.close();
        return true;
    }
    return false;
}

fn deleteTreeIfExistsAbsolute(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn ensureParentDirAbsolute(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(parent);
}

fn writeAbsoluteFile(abs_path: []const u8, bytes: []const u8) !void {
    const file = try std.fs.createFileAbsolute(abs_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn copyBoundedFile(src_abs_path: []const u8, dst_abs_path: []const u8, max_bytes: usize) !void {
    const src = try std.fs.openFileAbsolute(src_abs_path, .{});
    defer src.close();
    const bytes = try src.readToEndAlloc(std.heap.page_allocator, max_bytes);
    defer std.heap.page_allocator.free(bytes);
    const dst = try std.fs.createFileAbsolute(dst_abs_path, .{ .truncate = true });
    defer dst.close();
    try dst.writeAll(bytes);
}

fn copyTreeAbsolute(src_root: []const u8, dst_root: []const u8) !void {
    try std.fs.cwd().makePath(dst_root);
    var dir = try std.fs.openDirAbsolute(src_root, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const child_src = try std.fs.path.join(std.heap.page_allocator, &.{ src_root, entry.name });
        defer std.heap.page_allocator.free(child_src);
        const child_dst = try std.fs.path.join(std.heap.page_allocator, &.{ dst_root, entry.name });
        defer std.heap.page_allocator.free(child_dst);
        switch (entry.kind) {
            .directory => try copyTreeAbsolute(child_src, child_dst),
            .file => {
                try ensureParentDirAbsolute(child_dst);
                const src_file = try std.fs.openFileAbsolute(child_src, .{});
                defer src_file.close();
                const stat = try src_file.stat();
                try copyBoundedFile(child_src, child_dst, @intCast(stat.size));
            },
            else => {},
        }
    }
}

fn writeStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeAll("[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeAll("]");
}

fn writeIngestCapacityTelemetry(writer: anytype, telemetry: IngestCapacityTelemetry) !void {
    try writer.writeAll("{");
    try writer.print("\"tooManyFiles\":{s},\"fileCapHit\":{s}", .{
        if (telemetry.too_many_files) "true" else "false",
        if (telemetry.file_cap_hit) "true" else "false",
    });
    try writer.print(",\"conceptCandidateCapHit\":{s},\"conceptEmitCapHit\":{s}", .{
        if (telemetry.concept_candidate_cap_hit) "true" else "false",
        if (telemetry.concept_emit_cap_hit) "true" else "false",
    });
    try writer.print(",\"conceptCandidatesConsidered\":{d},\"conceptsEmitted\":{d},\"budgetHits\":{d}", .{
        telemetry.concept_candidates_considered,
        telemetry.concepts_emitted,
        telemetry.budget_hits,
    });
    try writer.writeAll(",\"capacityWarnings\":[");
    var wrote = false;
    try writeTelemetryWarning(writer, &wrote, telemetry.too_many_files, "too_many_files");
    try writeTelemetryWarning(writer, &wrote, telemetry.file_cap_hit, "file_cap_hit");
    try writeTelemetryWarning(writer, &wrote, telemetry.concept_candidate_cap_hit, "concept_candidate_cap_hit");
    try writeTelemetryWarning(writer, &wrote, telemetry.concept_emit_cap_hit, "concept_emit_cap_hit");
    try writer.writeAll("]}");
}

fn writeTelemetryWarning(writer: anytype, wrote: *bool, condition: bool, text: []const u8) !void {
    if (!condition) return;
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    try writeJsonString(writer, text);
}

fn writeJsonFieldString(writer: anytype, field: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writeJsonString(writer, field);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeOptionalStringField(writer: anytype, field: []const u8, value: []const u8) !void {
    try writer.writeByte(',');
    try writeJsonString(writer, field);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"', '\\' => {
                try writer.writeByte('\\');
                try writer.writeByte(byte);
            },
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}
