const std = @import("std");
const sys = @import("sys.zig");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");
const layer2a_gpu = @import("layer2a_gpu.zig");
const mc = @import("inference.zig");
const panic_dump = @import("panic_dump.zig");
const config = @import("config.zig");
const sigil_runtime = @import("sigil_runtime.zig");

// ── Ghost Engine v2: Rune-Native Triad ──
const triad = @import("triad.zig");
const forge_mod = @import("forge.zig");

pub const REASON_DEPTH: u32 = 8;
pub const REASON_TOP_K: u32 = 3;

/// V32: Resonance Self-Calibration (Fixed-Point Integer)
/// Replaces non-deterministic floating-point EMA with bit-perfect integer math.
/// Uses 24.8 fixed-point representation for average and Mean Absolute Deviation (MAD).
pub const ResonanceEMA = struct {
    average: u32 = 850 << 8, // Initial seed: 850.0
    deviation: u32 = 25 << 8, // Initial MAD: 25.0
    alpha_shift: u5 = 4, // Alpha = 1/16 (0.0625)

    pub fn update(self: *ResonanceEMA, sample: u16) void {
        const s = @as(u32, sample) << 8;
        const diff = if (s > self.average) s - self.average else self.average - s;

        // EMA update: (val * (1-alpha) + sample * alpha)
        const a = @as(u64, 1) << self.alpha_shift;
        self.average = @intCast((@as(u64, self.average) * (a - 1) + @as(u64, s)) >> self.alpha_shift);
        self.deviation = @intCast((@as(u64, self.deviation) * (a - 1) + @as(u64, diff)) >> self.alpha_shift);
    }

    pub fn getSurpriseThreshold(self: ResonanceEMA) u16 {
        // Threshold = average + 2.5 * deviation (approx 2.5 * MAD is roughly 2.0 * SD)
        const thresh = (self.average + (self.deviation * 5 / 2)) >> 8;
        return @as(u16, @intCast(@min(1024, thresh)));
    }

    pub fn getSearchThreshold(self: ResonanceEMA) u16 {
        // Threshold = average - 1.5 * deviation
        const avg = self.average >> 8;
        const dev_scaled = (self.deviation * 3 / 2) >> 8;
        return @as(u16, @intCast(if (avg > dev_scaled) avg - dev_scaled else 0));
    }
};

pub fn isAllowed(cp: u32) bool {
    if (cp > 0x10FFFF) return false;
    // Unicode standard: exclude surrogates [0xD800, 0xDFFF]
    if (cp >= 0xD800 and cp <= 0xDFFF) return false;
    // Allow all other valid codepoints
    return true;
}

pub const SoulSnapshot = struct {
    structural: vsa.HyperVector,
    phrase: vsa.HyperVector,
    concept: vsa.HyperVector,
    global: vsa.HyperVector,
    active_context_hash: u64,
    lexical_rotor: u64,
    fractal_state: vsa.HyperVector,
    spell_vector: vsa.HyperVector,
    sentence_pool: vsa.HyperVector,
    anchor_count: u64,
    last_energy: u16,
    last_boundary: vsa.Boundary,
};

pub fn saveSoul(soul: *const ghost_state.GhostSoul) SoulSnapshot {
    return .{
        .structural = soul.structural,
        .phrase = soul.phrase,
        .concept = soul.concept,
        .global = soul.global,
        .active_context_hash = soul.active_context_hash,
        .lexical_rotor = soul.lexical_rotor,
        .fractal_state = soul.fractal_state,
        .spell_vector = soul.spell_vector,
        .sentence_pool = soul.sentence_pool,
        .anchor_count = soul.anchor_count,
        .last_energy = soul.last_energy,
        .last_boundary = soul.last_boundary,
    };
}

pub fn restoreSoul(soul: *ghost_state.GhostSoul, snap: SoulSnapshot) void {
    soul.structural = snap.structural;
    soul.phrase = snap.phrase;
    soul.concept = snap.concept;
    soul.global = snap.global;
    soul.active_context_hash = snap.active_context_hash;
    soul.lexical_rotor = snap.lexical_rotor;
    soul.fractal_state = snap.fractal_state;
    soul.spell_vector = snap.spell_vector;
    soul.sentence_pool = snap.sentence_pool;
    soul.anchor_count = snap.anchor_count;
    soul.last_energy = snap.last_energy;
    soul.last_boundary = snap.last_boundary;
}

pub const SingularityEngine = struct {
    lattice: *ghost_state.UnifiedLattice,
    lattice_provider: ?*ghost_state.LatticeProvider = null,
    meaning: *vsa.MeaningMatrix,
    soul: *ghost_state.GhostSoul,
    canvas: ghost_state.MesoLattice,
    is_live: bool,
    inventory: [128]u8 = [_]u8{0} ** 128,
    inv_cursor: usize = 0,
    vulkan: ?*vsa_vulkan.VulkanEngine,
    allocator: std.mem.Allocator,
    rune_counter: u64 = 0,
    ema: ResonanceEMA = .{},
    last_layer2a_metrics: mc.Layer2aInstrumentation = .{},

    // ── v2 Triad Integration ──
    // Optional: when attached, the Scout monitors state variance during inference
    // and the Forge records observations for rank-based training.
    forge: ?*forge_mod.ForgeEngine = null,
    triad_byte_offset: u64 = 0,

    fn layer3Config(self: *const SingularityEngine) mc.Layer3Config {
        const reasoning_mode = if (sigil_runtime.getActiveControl()) |control|
            control.snapshot().reasoning_mode
        else
            .proof;
        return .{
            .confidence_floor = .{
                .min_score = @max(@as(u32, self.ema.getSearchThreshold()), config.LAYER3_CONFIDENCE_FLOOR_MIN),
            },
            .max_steps = config.LAYER3_MAX_STEPS,
            .max_branches = config.LAYER3_MAX_BRANCHES,
            .policy = mc.policyForMode(reasoning_mode),
            .dump = panic_dump.dumpHook(),
        };
    }

    pub fn setLatticeProvider(self: *SingularityEngine, provider: *ghost_state.LatticeProvider) void {
        self.lattice_provider = provider;
    }

    pub fn setCacheCap(self: *SingularityEngine, bytes: u64) !void {
        if (self.lattice_provider) |provider| {
            try provider.setCacheCap(bytes);
        }
    }

    pub fn acquireLatticeWords(self: *SingularityEngine, word_index: usize, word_count: usize, writable: bool) !ghost_state.LatticeLease {
        if (self.lattice_provider) |provider| {
            return provider.acquireWords(word_index, word_count, writable);
        }

        var fallback = ghost_state.LatticeProvider.initMapped(self.lattice);
        return fallback.acquireWords(word_index, word_count, writable);
    }

    pub fn measureNoise(self: *SingularityEngine, candidate_vec: vsa.HyperVector, position: u32) u16 {
        const pos_hash = ghost_state.wyhash(self.soul.active_context_hash, @as(u64, position));
        const target_vec = self.meaning.collapseToBinary(pos_hash);
        return vsa.resonanceScore(candidate_vec, target_vec);
    }

    pub fn resolveTopology(self: *SingularityEngine) ?mc.Layer3Decision {
        switch (self.canvas.topology) {
            .text_1d => return self.resolveText1D(),
            .image_2d => {
                self.resolveImage2D();
                return null;
            },
            .audio_1d_time => {
                self.resolveAudio1DTime();
                return null;
            },
        }
    }

    pub fn resolveText1D(self: *SingularityEngine) mc.Layer3Decision {
        const position = self.canvas.cursor;
        // Layer 3 is intentionally a tiny honesty gate at the output boundary.
        // It is not a reasoning layer and it must never invent a "best effort" answer.
        // `UNRESOLVED_OUTPUT` means the output is unsupported and must not be committed.
        // Layer 2b below remains the only owner of bounded reasoning over the
        // fixed top-K frontier. Optional Layer 2a GPU helpers may rank or filter
        // compact candidate sets, but branch-heavy reasoning and final decisions
        // stay on the CPU.
        const layer3 = self.layer3Config();
        var top_chars: [REASON_TOP_K]u32 = [_]u32{' '} ** REASON_TOP_K;
        var top_energies: [REASON_TOP_K]u32 = [_]u32{0} ** REASON_TOP_K;
        const base_cursor = self.inv_cursor % self.inventory.len;
        // inv_cursor always points at the next write slot, so these are the three
        // most recently committed bytes before we append the chosen rune below.
        const prev1 = self.inventory[(base_cursor + self.inventory.len - 1) % self.inventory.len];
        const prev2 = self.inventory[(base_cursor + self.inventory.len - 2) % self.inventory.len];
        const prev3 = self.inventory[(base_cursor + self.inventory.len - 3) % self.inventory.len];

        var gpu_success: bool = false;
        if (!config.force_cpu_inference and self.vulkan != null) {
            const vulkan = self.vulkan.?;
            if (vulkan.dispatchResonance(self.soul.lexical_rotor, self.soul.semantic_rotor)) |job| {
                if (vulkan.pollHardwareInterrupt(job.frame_idx) catch false) {
                    const energies = vulkan.waitResonance(job) catch &.{};
                    gpu_success = energies.len != 0;
                    const boredom = self.soul.getBoredomPenalty();
                    for (energies, 0..) |raw_e, i| {
                        const cb: u32 = @intCast(i);
                        if (!isAllowed(cb)) continue;
                        var energy = raw_e;
                        if (cb == prev1 and cb == prev2 and cb == prev3) energy = energy -| 50;
                        energy = energy -| boredom;
                        insertTopK(&top_chars, &top_energies, cb, energy);
                    }
                }
            } else |err| {
                sys.print("\n[VULKAN WARNING] Resonance Query Failed: {any}. Falling back to Silicon Heuristics...\n", .{err});
            }
        }

        if (!gpu_success) {
            const boredom = self.soul.getBoredomPenalty();
            const target_lex = self.meaning.collapseToBinary(self.soul.lexical_rotor);
            const target_sem = self.meaning.collapseToBinary(self.soul.semantic_rotor);
            for (0..0x1_0000) |cp_usize| {
                const cp: u32 = @intCast(cp_usize);
                if (!isAllowed(cp)) continue;

                const v = vsa.generate(cp);
                const e_lex = vsa.calculateResonance(target_lex, v);
                const e_sem = vsa.calculateResonance(target_sem, v);

                var energy: u32 = if (e_lex > 0) (e_lex * 2 + e_sem) / 3 else e_sem;
                if (energy == 0) energy = 512;
                if (cp == prev1 and cp == prev2 and cp == prev3) energy = energy -| 50;
                energy = energy -| boredom;
                insertTopK(&top_chars, &top_energies, cp, energy);
            }
        }

        var reason_best_char: u32 = top_chars[0];
        var chosen_energy: u32 = top_energies[0];
        var layer3_decision = mc.Layer3Decision{
            .output = reason_best_char,
            .confidence = chosen_energy,
        };

        // CPU Layer 2b owns bounded hypothesis expansion, contradiction pruning,
        // branch-cap enforcement, and final selection. When Vulkan is available,
        // Layer 2a only accelerates compact scoring/filter sub-operations inside
        // this same reasoning loop.
        self.last_layer2a_metrics = .{};
        var reasoning = mc.ReasoningContext.init(self.meaning, self.soul, layer3)
            .withRecentBytes(.{ prev1, prev2, prev3 })
            .withInstrumentation(&self.last_layer2a_metrics);
        var layer2a_helper: ?layer2a_gpu.Layer2aGpu = null;
        if (!config.force_cpu_inference and self.vulkan != null) {
            layer2a_helper = layer2a_gpu.Layer2aGpu.init(self.vulkan.?);
            reasoning = reasoning.withLayer2aGpu(&layer2a_helper.?);
        }
        const decision = reasoning.resolve(&top_chars, &top_energies);
        if (decision.stop_reason != .none) return decision;
        layer3_decision = decision;
        reason_best_char = decision.output;
        chosen_energy = decision.confidence;

        const chosen: u32 = reason_best_char;
        const chosen_vec = vsa.generate(chosen);

        // Paranoid Oracle: verify GPU resonance matches independent CPU computation.
        // Audit 1 in 10,000 runes to catch shader/CPU divergence in Hamming distance logic.
        self.rune_counter += 1;
        if (self.rune_counter % 10000 == 0 and gpu_success) {
            if (self.vulkan) |vulkan| {
                const audit_job = vulkan.dispatchResonance(self.soul.lexical_rotor, self.soul.semantic_rotor) catch return layer3_decision;
                if (!(vulkan.pollHardwareInterrupt(audit_job.frame_idx) catch false)) return layer3_decision;
                const gpu_energies = vulkan.waitResonance(audit_job) catch return layer3_decision;
                if (gpu_energies.len <= @as(usize, @intCast(chosen))) return layer3_decision;
                const gpu_energy = gpu_energies[@as(usize, @intCast(chosen))];

                // Independent CPU computation
                const cpu_target_lex = self.meaning.collapseToBinary(self.soul.lexical_rotor);
                const cpu_target_sem = self.meaning.collapseToBinary(self.soul.semantic_rotor);
                const cpu_e_lex = vsa.calculateResonance(cpu_target_lex, chosen_vec);
                const cpu_e_sem = vsa.calculateResonance(cpu_target_sem, chosen_vec);
                const cpu_energy: u32 = if (cpu_e_lex > 0) (@as(u32, cpu_e_lex) * 2 + cpu_e_sem) / 3 else cpu_e_sem;

                const delta = if (gpu_energy > cpu_energy) gpu_energy - cpu_energy else cpu_energy - gpu_energy;
                if (delta > 50) {
                    sys.print("[ORACLE] CPU/GPU divergence at rune {d}: CPU={d} GPU={d} delta={d}\n", .{ self.rune_counter, cpu_energy, gpu_energy, delta });
                }
            }
        }

        // Etch chosen vector into the canvas and measure per-position noise
        if (position < self.canvas.cells.len) {
            self.canvas.cells[position] = chosen_vec;
        }
        if (position < self.canvas.noise.len) {
            self.canvas.noise[position] = self.measureNoise(chosen_vec, position);
        }
        self.canvas.advance();

        // Encode and push to inventory
        var utf8_fin: [4]u8 = undefined;
        const len_fin = std.unicode.utf8Encode(@intCast(chosen), &utf8_fin) catch 1;
        for (utf8_fin[0..len_fin], 0..) |b, offset| {
            self.inventory[(base_cursor + offset) % self.inventory.len] = b;
        }
        self.inv_cursor = (base_cursor + len_fin) % self.inventory.len;

        // V32: Update the noise floor EMA with the chosen rune's resonance
        self.ema.update(@intCast(chosen_energy));

        // ── v2: Forge Observation ──
        // After the existing pipeline selects a rune, we feed it to the Forge
        // so the Rune Lattice can track patterns and build rank history.
        // This runs in parallel with the existing v1 pipeline (Option A: Overlay).
        if (self.forge) |forge_engine| {
            const context_hash = ghost_state.wyhash(self.soul.lexical_rotor, self.soul.semantic_rotor);
            const now_ms = @as(u64, @intCast(sys.getMilliTick()));
            _ = forge_engine.observe(@as(u64, chosen), context_hash, now_ms); // [GPU-PATH / dead-guarded] structured id-keyed observe
            self.triad_byte_offset += len_fin;
        }

        layer3_decision.output = chosen;
        layer3_decision.confidence = chosen_energy;
        layer3_decision.stop_reason = .none;
        return layer3_decision;
    }

    /// VSA-based 2D relaxation: each cell converges toward its MeaningMatrix target
    /// while being influenced by its 4-connected neighbors via VSA bundling.
    /// Iterates until noise stabilizes or max 20 passes.
    pub fn resolveImage2D(self: *SingularityEngine) void {
        const w = self.canvas.width;
        const h = self.canvas.height;
        const left_tag = vsa.generate(0x2D00);
        const right_tag = vsa.generate(0x2D01);
        const up_tag = vsa.generate(0x2D10);
        const down_tag = vsa.generate(0x2D11);
        const target_tag = vsa.generate(0x2DFF);
        var total_noise: u64 = 0;
        var prev_noise: u64 = 0xFFFFFFFFFFFFFFFF;
        var iterations: u32 = 0;
        while (iterations < 20) : (iterations += 1) {
            total_noise = 0;
            var y: u32 = 0;
            while (y < h) : (y += 1) {
                var x: u32 = 0;
                while (x < w) : (x += 1) {
                    const idx = self.canvas.cellIndex(x, y);
                    if (idx >= self.canvas.cells.len) continue;
                    const current = self.canvas.cells[idx];
                    // Bundle with 4-connected neighbors using position-tagged identity vectors
                    var neighbor_bundle = current;
                    if (x > 0) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x - 1, y), left_tag);
                    if (x < w - 1) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x + 1, y), right_tag);
                    if (y > 0) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x, y - 1), up_tag);
                    if (y < h - 1) neighbor_bundle = vsa.bundle(neighbor_bundle, self.canvas.getCell(x, y + 1), down_tag);
                    const pos_hash = self.canvas.coordHash(x, y);
                    const target = self.meaning.collapseToBinary(pos_hash);
                    // Converge: bundle neighbor state with the target attractor
                    self.canvas.cells[idx] = vsa.bundle(neighbor_bundle, target, target_tag);
                    const score = vsa.resonanceScore(self.canvas.cells[idx], target);
                    self.canvas.noise[idx] = score;
                    total_noise += score;
                }
            }
            if (total_noise >= prev_noise) break;
            prev_noise = total_noise;
        }
    }

    /// VSA-based 1D temporal diffusion: each cell absorbs left and right spectral
    /// context via bundling, anchored to its MeaningMatrix target at each timestep.
    pub fn resolveAudio1DTime(self: *SingularityEngine) void {
        const bins = self.canvas.width;
        const steps = self.canvas.height;
        const left_tag = vsa.generate(0xA000);
        const right_tag = vsa.generate(0xA001);
        const time_tag = vsa.generate(0xA100);
        const target_tag = vsa.generate(0xAFFF);
        var t: u32 = 0;
        while (t < steps) : (t += 1) {
            var b: u32 = 0;
            while (b < bins) : (b += 1) {
                const idx = self.canvas.cellIndex(b, t);
                if (idx >= self.canvas.cells.len) continue;
                const current = self.canvas.cells[idx];
                var ctx = current;
                if (b > 0) ctx = vsa.bundle(ctx, self.canvas.getCell(b - 1, t), left_tag);
                if (b < bins - 1) ctx = vsa.bundle(ctx, self.canvas.getCell(b + 1, t), right_tag);
                if (t > 0) ctx = vsa.bundle(ctx, self.canvas.getCell(b, t - 1), time_tag);
                const pos_hash = self.canvas.coordHash(b, t);
                const target = self.meaning.collapseToBinary(pos_hash);
                self.canvas.cells[idx] = vsa.bundle(ctx, target, target_tag);
                self.canvas.noise[idx] = vsa.resonanceScore(self.canvas.cells[idx], target);
            }
        }
    }
};

pub fn insertTopK(chars: *[REASON_TOP_K]u32, energies: *[REASON_TOP_K]u32, candidate: u32, energy: u32) void {
    var i: usize = 0;
    while (i < REASON_TOP_K) : (i += 1) {
        if (energy > energies[i]) {
            var j: usize = REASON_TOP_K - 1;
            while (j > i) : (j -= 1) {
                chars[j] = chars[j - 1];
                energies[j] = energies[j - 1];
            }
            chars[i] = candidate;
            energies[i] = energy;
            return;
        }
    }
}
