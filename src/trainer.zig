const std = @import("std");
const builtin = @import("builtin");
const core = @import("ghost_core");
const sys = core.sys;
const ghost_state = core.ghost_state;
const vsa = core.vsa;
const vsa_vulkan = core.vsa_vulkan;
const config = core.config;
const shards = core.shards;
const sigil_runtime = core.sigil_runtime;

// ── Ghost Engine v2 ──
const forge_mod = core.forge;
const STREAM_BUFFER_CAPACITY = 64 * 1024;
const CPU_SUDH_PROBE_LIMIT: u32 = 32;
const CPU_LATTICE_LEAKY_MASK: u64 = 0xEFEFEFEFEFEFEFEF;
const CPU_DOMAIN_SYNTAX: u64 = 0x9E3779B97F4A7C15;
const CPU_DOMAIN_CONCEPT: u64 = 0xC7115792D0E47B43;
const CPU_DOMAIN_INTUITION: u64 = 0x6C62272E07BB0142;
const CPU_MATRIX_LOCK_STRIPES: usize = 1024;
const CPU_LATTICE_LOCK_STRIPES: usize = 4096;

pub const CorpusWeight = struct {
    name: []const u8,
    weight: u32,
};

pub const CapacityTelemetry = struct {
    dropped_runes: u32 = 0,
    collision_stalls: u32 = 0,
    saturated_slots: u32 = 0,
    truncated_inputs: u32 = 0,
    truncated_snippets: u32 = 0,
    skipped_inputs: u32 = 0,
    skipped_files: u32 = 0,
    budget_hits: u32 = 0,
    max_results_hit: bool = false,
    max_outputs_hit: bool = false,
    max_rules_hit: bool = false,
    unknowns_created: u32 = 0,
    capacity_warnings: u32 = 0,
    expansion_recommended: bool = false,
    spillover_recommended: bool = false,
};

pub const TrainerOptions = struct {
    tier: u32 = @intFromEnum(vsa_vulkan.OperationalTier.standard),
    batch_size_override: u32 = 0,
    max_active_streams: u32 = 0,
    checkpoint_interval_ms: u32 = 60_000,
    stop_after_minutes: u32 = 0,
    stop_after_runes: u64 = 0,
    stop_after_slot_usage_bp: u32 = 0,
    idle_sleep_ms: u32 = 10,
    selected_gpu_ids: []const u32 = &.{},
};

pub const StopReason = enum(u32) {
    none = 0,
    completed = 1,
    manual = 2,
    max_time = 3,
    max_runes = 4,
    slot_usage = 5,
    failed = 6,
};

fn resolveSelectedShardPaths(allocator: std.mem.Allocator) !shards.Paths {
    const project_id = std.process.getEnvVarOwned(allocator, "GHOST_PROJECT_SHARD") catch null;
    defer if (project_id) |value| allocator.free(value);

    var metadata = if (project_id) |value|
        try shards.resolveProjectMetadata(allocator, value)
    else
        try shards.resolveCoreMetadata(allocator);
    defer metadata.deinit();

    return shards.resolvePaths(allocator, metadata.metadata);
}

pub const StreamState = struct {
    const Source = enum {
        memory,
        file,
    };

    lexical_rotor: u64,
    semantic_rotor: u64,
    source: Source,
    file_data: []const u8,
    cursor: std.atomic.Value(usize),
    name: []const u8,
    weight: u32,
    done: std.atomic.Value(bool),
    total_bytes: usize,
    file: sys.FileHandle,
    buffer: [STREAM_BUFFER_CAPACITY + 4]u8,
    buffer_start: usize,
    buffer_end: usize,
    eof: bool,
    mutex: core.sync.Mutex = .{},

    // V32: Context accumulator — 1024-bit context vector.
    // Memory cost: 128 bytes per active stream (16 × u64).
    context_rotor: vsa.HyperVector,

    pub fn init(data: []const u8, name: []const u8, weight: u32) StreamState {
        return .{
            .lexical_rotor = ghost_state.FNV_OFFSET_BASIS,
            .semantic_rotor = ghost_state.FNV_OFFSET_BASIS,
            .source = .memory,
            .file_data = data,
            .cursor = std.atomic.Value(usize).init(0),
            .name = name,
            .weight = @max(weight, 1),
            .done = std.atomic.Value(bool).init(false),
            .total_bytes = data.len,
            .file = sys.INVALID_HANDLE,
            .buffer = undefined,
            .buffer_start = 0,
            .buffer_end = 0,
            .eof = true,
            .context_rotor = @splat(0),
        };
    }

    pub fn initFile(allocator: std.mem.Allocator, path: []const u8, name: []const u8, weight: u32) !StreamState {
        const file = try sys.openForRead(allocator, path);
        errdefer sys.closeFile(file);
        return .{
            .lexical_rotor = ghost_state.FNV_OFFSET_BASIS,
            .semantic_rotor = ghost_state.FNV_OFFSET_BASIS,
            .source = .file,
            .file_data = &.{},
            .cursor = std.atomic.Value(usize).init(0),
            .name = name,
            .weight = @max(weight, 1),
            .done = std.atomic.Value(bool).init(false),
            .total_bytes = sys.getFileSize(file) catch 0,
            .file = file,
            .buffer = undefined,
            .buffer_start = 0,
            .buffer_end = 0,
            .eof = false,
            .context_rotor = @splat(0),
        };
    }

    pub fn deinit(self: *StreamState) void {
        if (self.source == .file and self.file != sys.INVALID_HANDLE) {
            sys.closeFile(self.file);
            self.file = sys.INVALID_HANDLE;
        }
    }

    pub fn totalSizeBytes(self: *const StreamState) usize {
        return switch (self.source) {
            .memory => self.file_data.len,
            .file => self.total_bytes,
        };
    }

    fn refillBuffer(self: *StreamState) !bool {
        const carry = self.buffer_end - self.buffer_start;
        if (carry > 0) {
            std.mem.copyForwards(u8, self.buffer[0..carry], self.buffer[self.buffer_start..self.buffer_end]);
        }
        const bytes_read = try sys.readAll(self.file, self.buffer[carry..STREAM_BUFFER_CAPACITY]);
        self.buffer_start = 0;
        self.buffer_end = carry + bytes_read;
        if (bytes_read == 0) self.eof = true;
        return self.buffer_end > 0;
    }

    fn nextRuneFromMemory(self: *StreamState) ?u32 {
        const cursor = self.cursor.load(.monotonic);
        if (cursor >= self.file_data.len) {
            self.done.store(true, .monotonic);
            return null;
        }

        const first_byte = self.file_data[cursor];
        const cp_len = std.unicode.utf8ByteSequenceLength(first_byte) catch {
            self.cursor.store(cursor + 1, .monotonic);
            if (cursor + 1 >= self.file_data.len) self.done.store(true, .monotonic);
            return 0xFFFD;
        };

        if (cursor + cp_len > self.file_data.len) {
            self.cursor.store(self.file_data.len, .monotonic);
            self.done.store(true, .monotonic);
            return null;
        }

        const rune_slice = self.file_data[cursor .. cursor + cp_len];
        var view = std.unicode.Utf8View.init(rune_slice) catch {
            self.cursor.store(cursor + 1, .monotonic);
            if (cursor + 1 >= self.file_data.len) self.done.store(true, .monotonic);
            return 0xFFFD;
        };
        var iter = view.iterator();
        const rune = iter.nextCodepoint() orelse 0xFFFD;

        const next_cursor = cursor + cp_len;
        self.cursor.store(next_cursor, .monotonic);
        if (next_cursor >= self.file_data.len) self.done.store(true, .monotonic);
        return rune;
    }

    fn nextRuneFromFile(self: *StreamState) !?u32 {
        while (true) {
            if (self.buffer_start >= self.buffer_end) {
                if (!(try self.refillBuffer())) {
                    self.done.store(true, .monotonic);
                    return null;
                }
            }

            const available = self.buffer_end - self.buffer_start;
            const first_byte = self.buffer[self.buffer_start];
            const cp_len = std.unicode.utf8ByteSequenceLength(first_byte) catch {
                self.buffer_start += 1;
                _ = self.cursor.fetchAdd(1, .monotonic);
                if (self.eof and self.buffer_start >= self.buffer_end) self.done.store(true, .monotonic);
                return 0xFFFD;
            };

            if (cp_len > available) {
                if (self.eof) {
                    _ = self.cursor.fetchAdd(available, .monotonic);
                    self.buffer_start = self.buffer_end;
                    self.done.store(true, .monotonic);
                    return null;
                }
                _ = try self.refillBuffer();
                continue;
            }

            const rune_slice = self.buffer[self.buffer_start .. self.buffer_start + cp_len];
            var view = std.unicode.Utf8View.init(rune_slice) catch {
                self.buffer_start += 1;
                _ = self.cursor.fetchAdd(1, .monotonic);
                if (self.eof and self.buffer_start >= self.buffer_end) self.done.store(true, .monotonic);
                return 0xFFFD;
            };
            var iter = view.iterator();
            const rune = iter.nextCodepoint() orelse 0xFFFD;

            self.buffer_start += cp_len;
            _ = self.cursor.fetchAdd(cp_len, .monotonic);
            if (self.eof and self.buffer_start >= self.buffer_end) self.done.store(true, .monotonic);
            return rune;
        }
    }

    fn nextRune(self: *StreamState) !?u32 {
        return switch (self.source) {
            .memory => self.nextRuneFromMemory(),
            .file => try self.nextRuneFromFile(),
        };
    }
};

pub const GreedyBatcher = struct {
    streams: []StreamState,
    allocator: std.mem.Allocator,
    current_stream_idx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    total_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_active_streams: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_requested_batch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_packed_batch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_active_streams: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(allocator: std.mem.Allocator, streams: []StreamState) !GreedyBatcher {
        return .{
            .streams = streams,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GreedyBatcher) void {
        for (self.streams) |*stream| stream.deinit();
    }

    fn packRune(stream: *StreamState, stream_idx: usize, total_packed: *u32, out_chars: []u32, out_rotors: []u64, out_indices: []u32) bool {
        stream.mutex.lock();
        defer stream.mutex.unlock();

        const rune = stream.nextRune() catch {
            stream.done.store(true, .monotonic);
            return false;
        } orelse return false;
        out_chars[total_packed.*] = rune;
        out_indices[total_packed.*] = @intCast(stream_idx);

        const boundary = vsa.detectSyntacticBoundary(rune);
        stream.lexical_rotor ^= rune;
        stream.lexical_rotor = std.math.rotl(u64, stream.lexical_rotor, 13) *% ghost_state.FNV_PRIME;

        if (boundary != .none) {
            stream.semantic_rotor ^= stream.lexical_rotor;
            stream.semantic_rotor = std.math.rotl(u64, stream.semantic_rotor, 13) *% ghost_state.FNV_PRIME;
        }

        stream.context_rotor = vsa.bundle(vsa.rotate(stream.context_rotor, 1), vsa.generate(rune), vsa.generate(stream.lexical_rotor));

        const base = total_packed.* * 18;
        // context_rotor is the 4096-bit working vector; the GPU rotor buffer is stride-18 (1024-bit spine),
        // so serialize its primary 16 lanes (4096-bit migration: project at the GPU serialization boundary).
        const rotor_full: [64]u64 = stream.context_rotor;
        const rotor_words: [16]u64 = rotor_full[0..16].*;
        inline for (0..16) |j| {
            out_rotors[base + j] = rotor_words[j];
        }
        out_rotors[base + 16] = stream.lexical_rotor;
        out_rotors[base + 17] = stream.semantic_rotor;

        total_packed.* += 1;
        return true;
    }

    /// Pulls up to 'max_runes' from available streams.
    /// Returns the number of runes actually packed.
    pub fn pack(self: *GreedyBatcher, max_runes: u32, out_chars: []u32, out_rotors: []u64, out_indices: []u32, num_streams_out: *u32) u32 {
        var total_packed: u32 = 0;
        self.last_requested_batch.store(max_runes, .monotonic);

        const stream_count: u32 = @intCast(self.streams.len);
        if (stream_count == 0 or max_runes == 0) {
            self.last_packed_batch.store(0, .monotonic);
            self.last_active_streams.store(0, .monotonic);
            num_streams_out.* = 0;
            return 0;
        }

        const configured_limit = self.max_active_streams.load(.acquire);
        const active_limit: u32 = if (configured_limit == 0) stream_count else @min(configured_limit, stream_count);
        const start_idx = self.current_stream_idx.load(.monotonic);
        var considered_active: u32 = 0;

        while (total_packed < max_runes) {
            var any_packed_this_pass = false;
            considered_active = 0;

            for (0..self.streams.len) |i| {
                if (total_packed >= max_runes or considered_active >= active_limit) break;

                const idx = (start_idx + i) % self.streams.len;
                const stream = &self.streams[idx];
                if (stream.done.load(.monotonic)) continue;
                considered_active += 1;

                const repeats = @max(stream.weight, 1);
                for (0..repeats) |_| {
                    if (total_packed >= max_runes) break;
                    if (packRune(stream, idx, &total_packed, out_chars, out_rotors, out_indices)) {
                        any_packed_this_pass = true;
                    } else {
                        break;
                    }
                }
            }

            if (!any_packed_this_pass) break;
        }

        num_streams_out.* = considered_active;
        self.last_packed_batch.store(total_packed, .monotonic);
        self.last_active_streams.store(considered_active, .monotonic);
        if (total_packed > 0) {
            _ = self.current_stream_idx.fetchAdd(1, .monotonic);
        }
        _ = self.total_processed.fetchAdd(total_packed, .monotonic);
        return total_packed;
    }
};

pub const GpuRuntimeStats = struct {
    device_index: u32 = 0,
    target_batch_size: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_batch_size: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    processed_runes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dispatched_batches: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    idle_loops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    busy_time_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_dispatch_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const EtchLockState = struct {
    hash_locked: bool,
    slot_lock_mask: u32,
};

fn computeEtchLockState(word_hash: u64, num_slots: u32) EtchLockState {
    const control = sigil_runtime.getActiveControl() orelse return .{
        .hash_locked = false,
        .slot_lock_mask = 0,
    };

    var state = EtchLockState{
        .hash_locked = control.isHashLocked(word_hash),
        .slot_lock_mask = 0,
    };
    if (state.hash_locked or num_slots == 0) return state;

    const addr = vsa.computeSudhAddress(@as(u32, @truncate(word_hash)), word_hash, num_slots);
    var p: u32 = 0;
    while (p < vsa.SUDH_CPU_PROBES) : (p += 1) {
        const slot = addr.probe(p, num_slots);
        if (slot >= num_slots) break;
        if (control.isSlotLocked(slot)) {
            state.slot_lock_mask |= @as(u32, 1) << @as(u5, @intCast(p));
        }
    }
    return state;
}

fn isLockedRuneSlot(rotor: u64, slot_count: u32) bool {
    const control = sigil_runtime.getActiveControl() orelse return false;
    if (slot_count == 0) return false;
    const slot = @as(u32, @truncate(rotor & @as(u64, slot_count - 1)));
    return control.isSlotLocked(slot);
}

fn isLockedMatrixSlot(slot: u32) bool {
    const control = sigil_runtime.getActiveControl() orelse return false;
    return control.isSlotLocked(slot);
}

fn initMutexArray(allocator: std.mem.Allocator, count: usize) ![]core.sync.Mutex {
    const locks = try allocator.alloc(core.sync.Mutex, count);
    for (locks) |*lock| lock.* = .{};
    return locks;
}

fn latticeWyhash(state: u64, in_val: u64) u64 {
    const x = state ^ 0x60bee2bee120fc15;
    const y = in_val ^ 0xa3b195354a39b70d;
    const product = @as(u128, x) * @as(u128, y);
    const lo = @as(u64, @truncate(product));
    const hi = @as(u64, @truncate(product >> 64));
    return lo ^ hi;
}

fn fillLatticeProbes(out: *[4]u32, lattice_quarter: u32, h: u64) void {
    out[0] = @as(u32, @truncate(h)) % lattice_quarter;
    out[1] = @as(u32, @truncate(h >> 32)) % lattice_quarter + lattice_quarter;
    const h2 = latticeWyhash(h, 0x12345678);
    out[2] = @as(u32, @truncate(h2)) % lattice_quarter + lattice_quarter * 2;
    const h3 = latticeWyhash(h, 0x87654321);
    out[3] = @as(u32, @truncate(h3)) % lattice_quarter + lattice_quarter * 3;
}

fn etchLatticeProbe(lattice: []u16, entry_idx: u32, h: u64) void {
    const idx: usize = @intCast(entry_idx);
    const current = lattice[idx];
    if (current == 0) {
        lattice[idx] = 1;
        return;
    }

    const rng = latticeWyhash(h, entry_idx);
    if (rng % @as(u64, current) == 0 and current < std.math.maxInt(u16)) {
        lattice[idx] = current + 1;
    }
}

fn etchLatticeDomain(lattice: []u16, lattice_quarter: u32, rotor: u64, rune: u32, domain: u64) void {
    const leaky_domain = domain & CPU_LATTICE_LEAKY_MASK;
    const h = latticeWyhash(rotor ^ leaky_domain, rune);

    var probes: [4]u32 = undefined;
    fillLatticeProbes(&probes, lattice_quarter, h);
    for (probes) |entry_idx| etchLatticeProbe(lattice, entry_idx, h);
}

fn projectSpatialSignatureFromWords(words: []const u64) u32 {
    var result: u32 = 0;
    for (0..16) |i| {
        const word = words[i];
        if (@popCount(@as(u32, @truncate(word))) > 16) {
            result |= @as(u32, 1) << @as(u5, @intCast(i * 2));
        }
        if (@popCount(@as(u32, @truncate(word >> 32))) > 16) {
            result |= @as(u32, 1) << @as(u5, @intCast(i * 2 + 1));
        }
    }
    return result;
}

fn findMeaningSlot(tags: []u64, spatial_sig: u32, uniform_hash: u64, collision_stalls: *std.atomic.Value(u64), dropped_runes: *std.atomic.Value(u64)) ?u32 {
    const slot_count: u32 = @intCast(tags.len);
    const wide = @as(u64, spatial_sig) * @as(u64, slot_count);
    const base_slot = @as(u32, @truncate(wide >> 32)) & ~@as(u32, vsa.SUDH_NEIGHBORHOOD_SIZE - 1);
    const raw_stride = @as(u32, @truncate(uniform_hash >> 32));
    const stride = @max(raw_stride | 1, vsa.SUDH_NEIGHBORHOOD_SIZE + 1) | 1;
    const slot_mask = slot_count - 1;

    var p: u32 = 0;
    while (p < CPU_SUDH_PROBE_LIMIT) : (p += 1) {
        const slot = (base_slot +% p *% stride) & slot_mask;
        const existing = tags[slot];
        if (existing == uniform_hash) return slot;
        if (existing == 0) {
            tags[slot] = uniform_hash;
            return slot;
        }
        _ = collision_stalls.fetchAdd(1, .monotonic);
    }

    _ = dropped_runes.fetchAdd(1, .monotonic);
    return null;
}

fn etchMeaningSlot(meaning: *vsa.MeaningMatrix, slot_idx: u32, target_char: u32) void {
    const base_idx = slot_idx * 1024;
    const concept = vsa.generate(target_char);
    // concept is the 4096-bit working vector; a MeaningMatrix slot is 1024 accumulators, so etch the primary
    // 1024 bits (4096-bit migration: project at the meaning-slot boundary, matching collapseToBinaryAtSlot).
    const concept_full: [512]u8 = @bitCast(concept);
    const bytes: [128]u8 = concept_full[0..128].*;

    for (0..1024) |bit_index| {
        const bit = (bytes[bit_index / 8] >> @as(u3, @intCast(bit_index % 8))) & 1;
        const target_idx = base_idx + @as(u32, @intCast(bit_index));
        if (bit != 0) {
            meaning.data[target_idx] +%= 1;
        } else {
            meaning.data[target_idx] +%= 0xFFFF_FFFF;
        }
    }
}

pub const OhlTrainer = struct {
    allocator: std.mem.Allocator,
    fleet: ?*vsa_vulkan.MultiGPU,
    batcher: *GreedyBatcher,
    engines: []*vsa_vulkan.VulkanEngine,
    gpu_stats: []GpuRuntimeStats,
    is_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    is_paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    checkpoint_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    checkpoint_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    threads: []std.Thread,
    start_time: i64 = 0,
    last_checkpoint_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    current_tier: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(vsa_vulkan.OperationalTier.standard)),
    batch_size_override: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    checkpoint_interval_ms: std.atomic.Value(u32) = std.atomic.Value(u32).init(60_000),
    stop_after_minutes: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    stop_after_runes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stop_after_slot_usage_bp: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    idle_sleep_ms: std.atomic.Value(u32) = std.atomic.Value(u32).init(10),
    stop_reason: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(StopReason.none)),
    cpu_dropped_runes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cpu_collision_stalls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cpu_matrix_locks: []core.sync.Mutex = &.{},
    cpu_lattice_locks: []core.sync.Mutex = &.{},

    // Global mapped files for checkpointing (synced from main.zig or newly mapped)
    mapped_lattice: ?[]u16 = null,
    mapped_meaning: ?[]u32 = null,
    mapped_tags: ?[]u64 = null,
    mapped_ranks: ?[]u8 = null,
    lattice_file: ?*const sys.MappedFile = null,
    meaning_file: ?*const sys.MappedFile = null,
    tags_file: ?*const sys.MappedFile = null,
    rank_file: ?*const sys.MappedFile = null,

    // ── v2: Forge Engine (Rank-Based Training) ──
    // When attached, the trainer observes every etched rune into the Forge’s
    // Rune Lattice, building rank history alongside the existing MeaningMatrix.
    forge: ?*forge_mod.ForgeEngine = null,

    pub fn init(allocator: std.mem.Allocator, fleet: ?*vsa_vulkan.MultiGPU, batcher: *GreedyBatcher, options: TrainerOptions) !OhlTrainer {
        var selected_count: usize = 0;
        if (fleet) |fleet_ref| {
            if (options.selected_gpu_ids.len == 0) {
                selected_count = fleet_ref.engines.len;
            } else {
                for (fleet_ref.engines) |engine| {
                    for (options.selected_gpu_ids) |wanted| {
                        if (wanted == engine.device_index) {
                            selected_count += 1;
                            break;
                        }
                    }
                }
            }
        } else if (options.selected_gpu_ids.len != 0) {
            return error.NoGpuSelected;
        }

        const cpu_fallback = selected_count == 0;
        const worker_count = if (cpu_fallback) @max(@as(usize, 1), std.Thread.getCpuCount() catch 1) else selected_count;

        const selected = try allocator.alloc(*vsa_vulkan.VulkanEngine, selected_count);
        errdefer allocator.free(selected);
        const gpu_stats = try allocator.alloc(GpuRuntimeStats, worker_count);
        errdefer allocator.free(gpu_stats);
        const cpu_matrix_locks = if (cpu_fallback) try initMutexArray(allocator, CPU_MATRIX_LOCK_STRIPES) else try allocator.alloc(core.sync.Mutex, 0);
        errdefer allocator.free(cpu_matrix_locks);
        const cpu_lattice_locks = if (cpu_fallback) try initMutexArray(allocator, CPU_LATTICE_LOCK_STRIPES) else try allocator.alloc(core.sync.Mutex, 0);
        errdefer allocator.free(cpu_lattice_locks);

        var out_idx: usize = 0;
        if (fleet) |fleet_ref| {
            for (fleet_ref.engines) |*engine| {
                if (options.selected_gpu_ids.len != 0) {
                    var keep = false;
                    for (options.selected_gpu_ids) |wanted| {
                        if (wanted == engine.device_index) {
                            keep = true;
                            break;
                        }
                    }
                    if (!keep) continue;
                }
                selected[out_idx] = engine;
                gpu_stats[out_idx] = .{ .device_index = engine.device_index };
                out_idx += 1;
            }
        } else {
            gpu_stats[0] = .{ .device_index = 0 };
        }

        var self = OhlTrainer{
            .allocator = allocator,
            .fleet = fleet,
            .batcher = batcher,
            .engines = selected,
            .gpu_stats = gpu_stats,
            .threads = try allocator.alloc(std.Thread, worker_count),
            .cpu_matrix_locks = cpu_matrix_locks,
            .cpu_lattice_locks = cpu_lattice_locks,
        };
        self.applyOptions(options);
        return self;
    }

    pub fn deinit(self: *OhlTrainer) void {
        self.allocator.free(self.threads);
        self.allocator.free(self.gpu_stats);
        self.allocator.free(self.engines);
        if (self.cpu_matrix_locks.len > 0) self.allocator.free(self.cpu_matrix_locks);
        if (self.cpu_lattice_locks.len > 0) self.allocator.free(self.cpu_lattice_locks);
    }

    pub fn applyOptions(self: *OhlTrainer, options: TrainerOptions) void {
        self.current_tier.store(options.tier, .release);
        self.batch_size_override.store(options.batch_size_override, .release);
        self.checkpoint_interval_ms.store(options.checkpoint_interval_ms, .release);
        self.stop_after_minutes.store(options.stop_after_minutes, .release);
        self.stop_after_runes.store(options.stop_after_runes, .release);
        self.stop_after_slot_usage_bp.store(options.stop_after_slot_usage_bp, .release);
        self.idle_sleep_ms.store(@max(options.idle_sleep_ms, 1), .release);
        self.batcher.max_active_streams.store(options.max_active_streams, .release);

        for (self.engines) |engine| {
            engine.setTier(options.tier);
        }
    }

    pub fn start(self: *OhlTrainer) !void {
        self.is_running.store(true, .release);
        self.is_paused.store(false, .release);
        self.stop_reason.store(@intFromEnum(StopReason.none), .release);
        self.start_time = @intCast(sys.getMilliTick());
        self.last_checkpoint_ms.store(@intCast(self.start_time), .release);

        if (self.engines.len == 0) {
            for (self.threads, 0..) |*thread, i| {
                self.gpu_stats[i].device_index = @intCast(i);
                thread.* = try std.Thread.spawn(.{ .allocator = self.allocator }, cpuWorker, .{ self, @as(u32, @intCast(i)), &self.gpu_stats[i] });
            }
        } else {
            for (self.engines, 0..) |engine, i| {
                self.gpu_stats[i].device_index = engine.device_index;
                self.threads[i] = try std.Thread.spawn(.{ .allocator = self.allocator }, gpuWorker, .{ self, engine, &self.gpu_stats[i] });
            }
        }

        while (self.is_running.load(.acquire)) {
            if (!self.is_paused.load(.acquire) and self.areAllStreamsDone()) {
                self.stop_reason.store(@intFromEnum(StopReason.completed), .release);
                break;
            }

            const now = sys.getMilliTick();
            if (!self.is_paused.load(.acquire)) {
                if (self.checkStopConditions(now)) break;
                try self.maybeCheckpoint(now);
            }

            const throughput = self.getThroughput();
            const processed = self.batcher.total_processed.load(.monotonic);
            sys.print("[FLEET] Throughput: {d:.2} MiB/s | Progress: {d} runes | Bottleneck: {s}\n", .{
                throughput,
                processed,
                self.getBottleneckReason(),
            });

            if (processed > 0) {
                const elapsed = @as(f64, @floatFromInt(now - @as(u64, @intCast(self.start_time)))) / 1000.0;
                if (elapsed > 0.1) {
                    sys.print("[BENCH] Fleet RPS: {d:.2} Runes/sec\n", .{@as(f64, @floatFromInt(processed)) / elapsed});
                }
            }

            sys.sleep(500);
        }

        self.is_running.store(false, .release);
        for (self.threads) |t| t.join();
    }

    pub fn requestStop(self: *OhlTrainer, reason: StopReason) void {
        self.stop_reason.store(@intFromEnum(reason), .release);
        self.is_running.store(false, .release);
    }

    pub fn pause(self: *OhlTrainer) void {
        self.is_paused.store(true, .release);
    }

    pub fn resumeTraining(self: *OhlTrainer) void {
        self.is_paused.store(false, .release);
    }

    pub fn requestCheckpoint(self: *OhlTrainer) void {
        self.checkpoint_requested.store(true, .release);
    }

    pub fn getOverallProgress(self: *const OhlTrainer) f64 {
        var total_size: usize = 0;
        var total_cursor: usize = 0;
        for (self.batcher.streams) |s| {
            total_size += s.totalSizeBytes();
            total_cursor += s.cursor.load(.monotonic);
        }
        if (total_size == 0) return 1.0;
        return @as(f64, @floatFromInt(total_cursor)) / @as(f64, @floatFromInt(total_size));
    }

    pub fn getThroughput(self: *const OhlTrainer) f64 {
        const elapsed = @as(f64, @floatFromInt(sys.getMilliTick() - @as(u64, @intCast(self.start_time)))) / 1000.0;
        if (elapsed < 0.1) return 0;
        return (@as(f64, @floatFromInt(self.batcher.total_processed.load(.monotonic))) / 1024.0 / 1024.0) / elapsed;
    }

    pub fn getProcessedRunes(self: *const OhlTrainer) u64 {
        return self.batcher.total_processed.load(.monotonic);
    }

    pub fn getElapsedMs(self: *const OhlTrainer) u64 {
        if (self.start_time <= 0) return 0;
        return sys.getMilliTick() - @as(u64, @intCast(self.start_time));
    }

    pub fn getEtaMs(self: *const OhlTrainer) u64 {
        const progress = self.getOverallProgress();
        if (progress <= 0.0001 or progress >= 0.9999) return 0;
        const elapsed = @as(f64, @floatFromInt(self.getElapsedMs()));
        const total = elapsed / progress;
        return @intFromFloat(@max(total - elapsed, 0.0));
    }

    pub fn getActiveStreamCount(self: *const OhlTrainer) u32 {
        var active: u32 = 0;
        for (self.batcher.streams) |s| {
            if (!s.done.load(.monotonic)) active += 1;
        }
        return active;
    }

    pub fn getTotalStreamCount(self: *const OhlTrainer) u32 {
        return @intCast(self.batcher.streams.len);
    }

    pub fn getDroppedRunes(self: *const OhlTrainer) u32 {
        var dropped: u32 = 0;
        for (self.engines) |engine| {
            if (engine.mapped_diag) |d| dropped += d.dropped_runes;
        }
        dropped += @intCast(@min(self.cpu_dropped_runes.load(.monotonic), @as(u64, std.math.maxInt(u32) - dropped)));
        return dropped;
    }

    pub fn getCollisionStalls(self: *const OhlTrainer) u32 {
        var stalls: u32 = 0;
        for (self.engines) |engine| {
            if (engine.mapped_diag) |d| stalls += d.collision_stalls;
        }
        stalls += @intCast(@min(self.cpu_collision_stalls.load(.monotonic), @as(u64, std.math.maxInt(u32) - stalls)));
        return stalls;
    }

    pub fn getCapacityTelemetry(self: *const OhlTrainer) CapacityTelemetry {
        const dropped = self.getDroppedRunes();
        const stalls = self.getCollisionStalls();
        const slot_usage = self.getSlotUsageBp();
        const saturated = slot_usage >= 9000 or self.getStopReason() == .slot_usage;
        const warnings: u32 = (if (dropped != 0) @as(u32, 1) else 0) +
            (if (stalls != 0) @as(u32, 1) else 0) +
            (if (saturated) @as(u32, 1) else 0);
        return .{
            .dropped_runes = dropped,
            .collision_stalls = stalls,
            .saturated_slots = if (saturated) self.countUsedSlots() else 0,
            .budget_hits = if (self.getStopReason() == .slot_usage or self.getStopReason() == .max_runes) 1 else 0,
            .capacity_warnings = warnings,
            .expansion_recommended = dropped != 0 or saturated,
            .spillover_recommended = stalls != 0 or saturated,
        };
    }

    pub fn getBatchFillPct(self: *const OhlTrainer) f64 {
        const requested = self.batcher.last_requested_batch.load(.monotonic);
        if (requested == 0) return 0;
        return (@as(f64, @floatFromInt(self.batcher.last_packed_batch.load(.monotonic))) / @as(f64, @floatFromInt(requested))) * 100.0;
    }

    pub fn getLastCheckpointMs(self: *const OhlTrainer) u64 {
        return self.last_checkpoint_ms.load(.acquire);
    }

    pub fn getCheckpointAgeMs(self: *const OhlTrainer) u64 {
        const last = self.getLastCheckpointMs();
        return if (last == 0) 0 else sys.getMilliTick() - last;
    }

    pub fn getCurrentTier(self: *const OhlTrainer) u32 {
        return self.current_tier.load(.acquire);
    }

    pub fn getBatchSizeOverride(self: *const OhlTrainer) u32 {
        return self.batch_size_override.load(.acquire);
    }

    pub fn getCheckpointIntervalMs(self: *const OhlTrainer) u32 {
        return self.checkpoint_interval_ms.load(.acquire);
    }

    pub fn getMaxActiveStreams(self: *const OhlTrainer) u32 {
        return self.batcher.max_active_streams.load(.acquire);
    }

    pub fn getStopAfterMinutes(self: *const OhlTrainer) u32 {
        return self.stop_after_minutes.load(.acquire);
    }

    pub fn getStopAfterRunes(self: *const OhlTrainer) u64 {
        return self.stop_after_runes.load(.acquire);
    }

    pub fn getStopAfterSlotUsageBp(self: *const OhlTrainer) u32 {
        return self.stop_after_slot_usage_bp.load(.acquire);
    }

    pub fn getSelectedGpuCount(self: *const OhlTrainer) u32 {
        return @intCast(self.engines.len);
    }

    pub fn getStopReason(self: *const OhlTrainer) StopReason {
        return @enumFromInt(self.stop_reason.load(.acquire));
    }

    pub fn getBottleneckReason(self: *const OhlTrainer) []const u8 {
        const collision_alarm_bp: u32 = 9000;
        if (!self.is_running.load(.acquire)) return "idle";
        if (self.is_paused.load(.acquire)) return "paused";
        if (self.getActiveStreamCount() == 0) return "complete";
        if (self.getDroppedRunes() > 0) return "drop-pressure";
        if (self.getCollisionStalls() > 0 and self.getSlotUsageBp() >= collision_alarm_bp) return "collision-pressure";
        const requested = self.batcher.last_requested_batch.load(.monotonic);
        const packed_batch = self.batcher.last_packed_batch.load(.monotonic);
        if (requested > 0 and packed_batch < requested / 2) return "corpus-starvation";
        if (self.getMaxActiveStreams() != 0 and self.getActiveStreamCount() > self.getMaxActiveStreams()) return "stream-cap";
        return "balanced";
    }

    fn areAllStreamsDone(self: *const OhlTrainer) bool {
        for (self.batcher.streams) |s| {
            if (!s.done.load(.monotonic)) return false;
        }
        return true;
    }

    fn countUsedSlots(self: *const OhlTrainer) u32 {
        const tags: []const u64 = if (self.engines.len > 0)
            self.engines[0].getTagsData()
        else if (self.mapped_tags) |mapped|
            mapped
        else
            &.{};
        var used: u32 = 0;
        for (tags) |tag| {
            if (tag != 0) used += 1;
        }
        return used;
    }

    fn getSlotUsageBp(self: *const OhlTrainer) u32 {
        const mapped_tags: []const u64 = if (self.mapped_tags) |mapped| mapped else &.{};
        const capacity = if (self.engines.len > 0)
            self.engines[0].matrix_slots
        else
            @as(u32, @intCast(mapped_tags.len));
        if (capacity == 0) return 0;
        return @intFromFloat((@as(f64, @floatFromInt(self.countUsedSlots())) / @as(f64, @floatFromInt(capacity))) * 10_000.0);
    }

    fn checkStopConditions(self: *OhlTrainer, now: u64) bool {
        const stop_minutes = self.stop_after_minutes.load(.acquire);
        if (stop_minutes > 0) {
            const elapsed_minutes = @as(f64, @floatFromInt(now - @as(u64, @intCast(self.start_time)))) / 60_000.0;
            if (elapsed_minutes >= @as(f64, @floatFromInt(stop_minutes))) {
                self.requestStop(.max_time);
                return true;
            }
        }

        const stop_runes = self.stop_after_runes.load(.acquire);
        if (stop_runes > 0 and self.getProcessedRunes() >= stop_runes) {
            self.requestStop(.max_runes);
            return true;
        }

        const stop_slot_bp = self.stop_after_slot_usage_bp.load(.acquire);
        if (stop_slot_bp > 0 and self.getSlotUsageBp() >= stop_slot_bp) {
            self.requestStop(.slot_usage);
            return true;
        }

        return false;
    }

    fn maybeCheckpoint(self: *OhlTrainer, now: u64) !void {
        const interval = self.checkpoint_interval_ms.load(.acquire);
        const requested = self.checkpoint_requested.swap(false, .acq_rel);
        const due = interval > 0 and now - self.last_checkpoint_ms.load(.acquire) >= interval;
        if (!requested and !due) return;
        self.checkpoint_in_progress.store(true, .release);
        defer self.checkpoint_in_progress.store(false, .release);
        try self.checkpoint();
        self.last_checkpoint_ms.store(now, .release);

        // v2: Run Forge maintenance (prune stale noise, sweep promotions)
        if (self.forge) |forge_engine| {
            forge_engine.tick(now);
        }
    }

    pub fn checkpoint(self: *OhlTrainer) !void {
        if (self.mapped_lattice == null or self.mapped_meaning == null or self.mapped_tags == null or self.mapped_ranks == null) return;

        for (self.engines) |engine| {
            try engine.syncDeviceToHost(self.mapped_meaning.?, self.mapped_tags.?, self.mapped_ranks.?, self.mapped_lattice.?);

            if (engine.mapped_edges) |edges_ptr| {
                var graph = vsa.FlatGraph.fromMapped(@as([*]vsa.GraphNode, @ptrCast(@alignCast(edges_ptr))), engine.matrix_slots);

                const matrix_view = vsa.MeaningMatrix{
                    .data = self.mapped_meaning.?[0..core.config.SEMANTIC_ENTRIES],
                    .tags = self.mapped_tags.?[0..core.config.TAG_ENTRIES],
                };

                var prng = std.Random.DefaultPrng.init(@intCast(sys.getMilliTick()));
                const random = prng.random();

                for (0..1024) |_| {
                    const slot_a = random.uintLessThan(u32, engine.matrix_slots);
                    if (matrix_view.tags.?[slot_a] == 0) continue;

                    const slot_b = random.uintLessThan(u32, engine.matrix_slots);
                    if (slot_a == slot_b or matrix_view.tags.?[slot_b] == 0) continue;

                    const vec_a = matrix_view.collapseToBinaryAtSlot(slot_a);
                    const vec_b = matrix_view.collapseToBinaryAtSlot(slot_b);

                    graph.maintainEdges(slot_a, vec_a, slot_b, vec_b, &matrix_view);
                }
            }
        }

        if (self.lattice_file) |f| {
            sys.flushMappedMemory(f) catch |err| sys.print("[WARN] Lattice checkpoint flush failed: {any}\n", .{err});
        }
        if (self.meaning_file) |f| {
            sys.flushMappedMemory(f) catch |err| sys.print("[WARN] Meaning checkpoint flush failed: {any}\n", .{err});
        }
        if (self.tags_file) |f| {
            sys.flushMappedMemory(f) catch |err| sys.print("[WARN] Tags checkpoint flush failed: {any}\n", .{err});
        }

        sys.print("[FLEET] Crystallization Checkpoint OK (V33 Graph Refined)\n", .{});
    }

    fn gpuWorker(self: *OhlTrainer, engine: *vsa_vulkan.VulkanEngine, stats: *GpuRuntimeStats) void {
        sys.print("[GPU-{d}] Worker Online: {s}\n", .{ engine.device_index, engine.device_name });

        while (true) {
            if (self.is_paused.load(.acquire)) {
                if (!self.is_running.load(.acquire)) break;
                _ = stats.idle_loops.fetchAdd(1, .monotonic);
                sys.sleep(self.idle_sleep_ms.load(.acquire));
                continue;
            }
            if (!self.is_running.load(.acquire)) break;

            const tier = @as(vsa_vulkan.OperationalTier, @enumFromInt(self.current_tier.load(.acquire)));
            const tier_batch = tier.getBatchSize(engine.max_workgroup_invocations);
            const override_batch = self.batch_size_override.load(.acquire);
            const batch_size = @min(
                if (override_batch > 0) override_batch else tier_batch,
                config.MAX_STREAMS,
            );
            stats.target_batch_size.store(batch_size, .monotonic);

            const f = engine.frame_idx;
            var num_streams: u32 = 0;
            const num_packed = self.batcher.pack(batch_size, engine.mapped_chars[f].?[0..batch_size], engine.mapped_rotors[f].?[0..(batch_size * 18)], engine.mapped_index[f].?[0..batch_size], &num_streams);
            stats.last_batch_size.store(num_packed, .monotonic);

            if (num_packed == 0) {
                _ = stats.idle_loops.fetchAdd(1, .monotonic);
                sys.sleep(self.idle_sleep_ms.load(.acquire));
                continue;
            }

            const dispatch_start = sys.getMilliTick();
            engine.dispatchMergedEtch(num_packed, num_streams) catch |err| {
                sys.print("[GPU-{d}] Dispatch Error: {any}\n", .{ engine.device_index, err });
                self.requestStop(.failed);
                break;
            };
            const dispatch_elapsed = sys.getMilliTick() - dispatch_start;
            _ = stats.processed_runes.fetchAdd(num_packed, .monotonic);
            _ = stats.dispatched_batches.fetchAdd(1, .monotonic);
            _ = stats.busy_time_ms.fetchAdd(dispatch_elapsed, .monotonic);
            stats.last_dispatch_ms.store(dispatch_elapsed, .monotonic);

            if (!self.is_running.load(.acquire)) break;
        }

        sys.print("[GPU-{d}] Worker Offline.\n", .{engine.device_index});
    }

    fn claimMeaningSlot(self: *OhlTrainer, tags: []u64, spatial_sig: u32, uniform_hash: u64) ?u32 {
        const slot_count: u32 = @intCast(tags.len);
        const wide = @as(u64, spatial_sig) * @as(u64, slot_count);
        const base_slot = @as(u32, @truncate(wide >> 32)) & ~@as(u32, vsa.SUDH_NEIGHBORHOOD_SIZE - 1);
        const raw_stride = @as(u32, @truncate(uniform_hash >> 32));
        const stride = @max(raw_stride | 1, vsa.SUDH_NEIGHBORHOOD_SIZE + 1) | 1;
        const slot_mask = slot_count - 1;

        var p: u32 = 0;
        while (p < CPU_SUDH_PROBE_LIMIT) : (p += 1) {
            const slot = (base_slot +% p *% stride) & slot_mask;
            const lock = &self.cpu_matrix_locks[@as(usize, slot) & (self.cpu_matrix_locks.len - 1)];
            lock.lock();
            const existing = tags[slot];
            if (existing == uniform_hash) return slot;
            if (existing == 0) {
                tags[slot] = uniform_hash;
                return slot;
            }
            lock.unlock();
            _ = self.cpu_collision_stalls.fetchAdd(1, .monotonic);
        }

        _ = self.cpu_dropped_runes.fetchAdd(1, .monotonic);
        return null;
    }

    fn releaseMeaningSlot(self: *OhlTrainer, slot: u32) void {
        const lock = &self.cpu_matrix_locks[@as(usize, slot) & (self.cpu_matrix_locks.len - 1)];
        lock.unlock();
    }

    fn etchLatticeProbeLocked(self: *OhlTrainer, lattice: []u16, entry_idx: u32, h: u64) void {
        const lock = &self.cpu_lattice_locks[@as(usize, entry_idx) & (self.cpu_lattice_locks.len - 1)];
        lock.lock();
        defer lock.unlock();
        etchLatticeProbe(lattice, entry_idx, h);
    }

    fn etchLatticeDomainLocked(self: *OhlTrainer, lattice: []u16, lattice_quarter: u32, rotor: u64, rune: u32, domain: u64) void {
        const leaky_domain = domain & CPU_LATTICE_LEAKY_MASK;
        const h = latticeWyhash(rotor ^ leaky_domain, rune);

        var probes: [4]u32 = undefined;
        fillLatticeProbes(&probes, lattice_quarter, h);
        for (probes) |entry_idx| self.etchLatticeProbeLocked(lattice, entry_idx, h);
    }

    fn cpuWorker(self: *OhlTrainer, worker_id: u32, stats: *GpuRuntimeStats) void {
        sys.print("[CPU-{d}] Worker Online: host fallback trainer\n", .{worker_id});

        const max_batch = config.MAX_STREAMS;
        const chars = self.allocator.alloc(u32, max_batch) catch {
            self.requestStop(.failed);
            return;
        };
        defer self.allocator.free(chars);
        const rotors = self.allocator.alloc(u64, max_batch * 18) catch {
            self.requestStop(.failed);
            self.allocator.free(chars);
            return;
        };
        defer self.allocator.free(rotors);
        const indices = self.allocator.alloc(u32, max_batch) catch {
            self.requestStop(.failed);
            self.allocator.free(chars);
            self.allocator.free(rotors);
            return;
        };
        defer self.allocator.free(indices);

        const host_lattice = self.mapped_lattice orelse {
            self.requestStop(.failed);
            return;
        };
        const host_meaning = self.mapped_meaning orelse {
            self.requestStop(.failed);
            return;
        };
        const host_tags = self.mapped_tags orelse {
            self.requestStop(.failed);
            return;
        };
        var meaning = vsa.MeaningMatrix{
            .data = host_meaning[0..config.SEMANTIC_ENTRIES],
            .tags = host_tags[0..config.TAG_ENTRIES],
        };
        const lattice_quarter: u32 = @intCast(host_lattice.len / 4);
        const slot_count: u32 = @intCast(host_tags.len);

        while (true) {
            if (self.is_paused.load(.acquire)) {
                if (!self.is_running.load(.acquire)) break;
                _ = stats.idle_loops.fetchAdd(1, .monotonic);
                sys.sleep(self.idle_sleep_ms.load(.acquire));
                continue;
            }
            if (!self.is_running.load(.acquire)) break;

            const tier = @as(vsa_vulkan.OperationalTier, @enumFromInt(self.current_tier.load(.acquire)));
            const tier_batch = tier.getBatchSize(config.BATCH_SIZE);
            const override_batch = self.batch_size_override.load(.acquire);
            const batch_size = @min(if (override_batch > 0) override_batch else tier_batch, config.MAX_STREAMS);
            stats.target_batch_size.store(batch_size, .monotonic);

            var num_streams: u32 = 0;
            const num_packed = self.batcher.pack(batch_size, chars[0..batch_size], rotors[0..(batch_size * 18)], indices[0..batch_size], &num_streams);
            stats.last_batch_size.store(num_packed, .monotonic);

            if (num_packed == 0) {
                _ = stats.idle_loops.fetchAdd(1, .monotonic);
                sys.sleep(self.idle_sleep_ms.load(.acquire));
                continue;
            }

            const dispatch_start = sys.getMilliTick();
            for (0..num_packed) |i| {
                const base = i * 18;
                const rune = chars[i];
                const lexical = rotors[base + 16];
                const semantic = rotors[base + 17];
                const spatial_sig = projectSpatialSignatureFromWords(rotors[base .. base + 16]);

                if (!isLockedRuneSlot(lexical, slot_count)) {
                    self.etchLatticeDomainLocked(host_lattice, lattice_quarter, lexical, rune, CPU_DOMAIN_SYNTAX);
                    self.etchLatticeDomainLocked(host_lattice, lattice_quarter, lexical, rune, CPU_DOMAIN_CONCEPT);
                }
                if (!isLockedRuneSlot(semantic, slot_count)) {
                    self.etchLatticeDomainLocked(host_lattice, lattice_quarter, semantic, rune, CPU_DOMAIN_INTUITION);
                }

                const lexical_lock = computeEtchLockState(lexical, slot_count);
                if (!lexical_lock.hash_locked) {
                    if (self.claimMeaningSlot(meaning.tags.?, spatial_sig, lexical)) |slot_idx| {
                        defer self.releaseMeaningSlot(slot_idx);
                        if (!isLockedMatrixSlot(slot_idx)) etchMeaningSlot(&meaning, slot_idx, rune);
                    }
                }

                const semantic_lock = computeEtchLockState(semantic, slot_count);
                if (!semantic_lock.hash_locked) {
                    if (self.claimMeaningSlot(meaning.tags.?, spatial_sig, semantic)) |slot_idx| {
                        defer self.releaseMeaningSlot(slot_idx);
                        if (!isLockedMatrixSlot(slot_idx)) etchMeaningSlot(&meaning, slot_idx, rune);
                    }
                }
            }

            const dispatch_elapsed = sys.getMilliTick() - dispatch_start;
            _ = stats.processed_runes.fetchAdd(num_packed, .monotonic);
            stats.last_dispatch_ms.store(dispatch_elapsed, .monotonic);
            _ = stats.busy_time_ms.fetchAdd(dispatch_elapsed, .monotonic);
            _ = stats.dispatched_batches.fetchAdd(1, .monotonic);

            // v2: Observe etched runes into the Forge Rune Lattice
            if (self.forge) |forge_engine| {
                const now_ms = sys.getMilliTick();
                for (0..num_packed) |fi| {
                    const frune = chars[fi];
                    const fbase = fi * 18;
                    const ctx_hash = ghost_state.wyhash(rotors[fbase + 16], rotors[fbase + 17]);
                    _ = forge_engine.observe(vsa.generate(frune), ctx_hash, now_ms);
                }
            }
        }

        sys.print("[CPU-{d}] Worker Offline.\n", .{worker_id});
    }
};

fn main_wrapped(allocator: std.mem.Allocator) !void {
    sys.print("\nGhost Trainer {s}: Sovereign Fleet\n", .{@import("ghost_core").VERSION});

    if (!sys.acquireTrainerLock()) {
        sys.print("[FATAL] Trainer is already running or lock could not be acquired.\n", .{});
        sys.exit(1);
    }

    var fleet = vsa_vulkan.MultiGPU.init(allocator) catch |err| blk: {
        sys.print("[TRAINER] Vulkan fleet unavailable ({any}). Falling back to CPU-only training.\n", .{err});
        break :blk null;
    };
    defer if (fleet) |*fleet_ref| fleet_ref.deinit();

    var shard_paths = try resolveSelectedShardPaths(allocator);
    defer shard_paths.deinit();

    var m_lattice = try sys.createMappedFile(allocator, shard_paths.lattice_abs_path, config.UNIFIED_SIZE_BYTES);
    defer m_lattice.unmap();
    var m_meaning = try sys.createMappedFile(allocator, shard_paths.semantic_abs_path, config.SEMANTIC_SIZE_BYTES);
    defer m_meaning.unmap();
    var m_tags = try sys.createMappedFile(allocator, shard_paths.tags_abs_path, config.TAG_SIZE_BYTES);
    defer m_tags.unmap();
    var m_ranks = try sys.createMappedFile(allocator, shard_paths.rank_abs_path, config.SEMANTIC_SLOTS);
    defer m_ranks.unmap();

    const host_lattice = @as([*]u16, @ptrCast(@alignCast(m_lattice.data.ptr)))[0 .. m_lattice.data.len / @sizeOf(u16)];
    const host_meaning = @as([*]u32, @ptrCast(@alignCast(m_meaning.data.ptr)))[0..config.SEMANTIC_ENTRIES];
    const host_tags = @as([*]u64, @ptrCast(@alignCast(m_tags.data.ptr)))[0..config.TAG_ENTRIES];
    const host_ranks = @as([*]u8, @ptrCast(@alignCast(m_ranks.data.ptr)))[0..config.SEMANTIC_SLOTS];

    if (fleet) |*fleet_ref| {
        for (fleet_ref.engines) |*engine| {
            engine.bindHostState(host_meaning, host_tags, host_ranks, host_lattice);
        }
    }

    const corpus_files = sys.findCorpusFiles(allocator) catch try allocator.alloc([]const u8, 0);
    defer {
        for (corpus_files) |path| allocator.free(path);
        allocator.free(corpus_files);
    }

    var streams = try allocator.alloc(StreamState, @max(corpus_files.len, 1));
    defer allocator.free(streams);
    var active_streams: usize = 0;
    if (corpus_files.len > 0) {
        for (corpus_files) |path| {
            streams[active_streams] = StreamState.initFile(allocator, path, path, 1) catch continue;
            if (streams[active_streams].totalSizeBytes() == 0) {
                streams[active_streams].deinit();
                continue;
            }
            active_streams += 1;
        }
        sys.print("[TRAINER] Loaded {d} corpus streams\n", .{active_streams});
    }

    if (active_streams == 0) {
        sys.print("[TRAINER] No corpus files found. Using synthetic benchmark.\n", .{});
        const bench_pattern = "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG. GHOST ENGINE SOVEREIGNTY. ";
        const data = try allocator.alloc(u8, bench_pattern.len * 1000000);
        for (0..1000000) |i| {
            @memcpy(data[i * bench_pattern.len .. (i + 1) * bench_pattern.len], bench_pattern);
        }
        streams[0] = StreamState.init(data, "bench_stream", 1);
        active_streams = 1;
    }

    var batcher = try GreedyBatcher.init(allocator, streams[0..active_streams]);
    defer batcher.deinit();
    var trainer = try OhlTrainer.init(allocator, if (fleet) |*fleet_ref| fleet_ref else null, &batcher, .{});
    defer trainer.deinit();

    trainer.mapped_lattice = host_lattice;
    trainer.mapped_meaning = host_meaning;
    trainer.mapped_tags = host_tags;
    trainer.lattice_file = &m_lattice;
    trainer.meaning_file = &m_meaning;
    trainer.tags_file = &m_tags;
    trainer.start_time = @intCast(sys.getMilliTick());

    try trainer.start();
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    main_wrapped(gpa.allocator()) catch |err| {
        sys.print("\n[FATAL ERROR] {any}\n", .{err});
        std.process.exit(1);
    };
}

test "trainer capacity telemetry exposes dropped runes and collision stalls" {
    const allocator = std.testing.allocator;
    var batcher = try GreedyBatcher.init(allocator, &.{});
    var trainer = try OhlTrainer.init(allocator, null, &batcher, .{});
    defer trainer.deinit();

    trainer.cpu_dropped_runes.store(3, .monotonic);
    trainer.cpu_collision_stalls.store(5, .monotonic);
    trainer.stop_reason.store(@intFromEnum(StopReason.max_runes), .monotonic);

    const telemetry = trainer.getCapacityTelemetry();
    try std.testing.expectEqual(@as(u32, 3), telemetry.dropped_runes);
    try std.testing.expectEqual(@as(u32, 5), telemetry.collision_stalls);
    try std.testing.expectEqual(@as(u32, 1), telemetry.budget_hits);
    try std.testing.expectEqual(true, telemetry.expansion_recommended);
    try std.testing.expectEqual(true, telemetry.spillover_recommended);
}
