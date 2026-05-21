const std = @import("std");

// --- GENERIC INVENTION ENGINE ---
//
// Comptime-parameterized over a Spec module. The engine owns the SA
// search loop, champion pool, temperature schedule, and verdict ladder;
// the Spec owns the domain semantics (program representation, operators,
// quality, library, distance, reachability).
//
// Interface a Spec module must expose:
//   pub const Program: type
//   pub const Quality: type
//   pub const DistanceResult: type
//   pub const ReachabilityResult: type
//   pub fn randomProgram(rng: *u64) Program
//   pub fn mutate(p: Program, rng: *u64) Program
//   pub fn crossover(a: Program, b: Program, rng: *u64) Program
//   pub fn evaluateQuality(p: Program) Quality
//   pub fn qualityScalar(q: Quality) f64        // SA composite signal
//   pub fn qualityPasses(q: Quality) bool       // gate for INVENTION
//   pub fn isFinite(q: Quality) bool
//   pub fn distanceToLibrary(p: Program, allocator) !DistanceResult
//   pub fn reachability(p: Program, allocator) !ReachabilityResult
//   pub fn isEquivalent(d: DistanceResult) bool
//   pub fn isTrivialVariant(d: DistanceResult) bool
//   pub fn isRemix(d: DistanceResult) bool
//   pub fn isReachable(r: ReachabilityResult) bool
//   pub fn printProgram(p: Program, writer: anytype) !void
//   pub fn programToCsv(p: Program, writer: anytype) !void
//
// The engine never inspects Program internals — it only calls Spec ops.
//
// Constraints (carried from u64-mixer / sorting lineages):
//   - std only
//   - no VSA / Flame / Concept / network / model dependencies
//   - all randomness via splitMix64 step on a u64 state

pub const Verdict = enum {
    equivalent,
    trivial_variant,
    near_equivalent,
    remix,
    reachable,
    non_quality,
    invention_strict,

    pub fn label(self: Verdict) []const u8 {
        return switch (self) {
            .equivalent => "EQUIVALENT",
            .trivial_variant => "TRIVIAL VARIANT",
            .near_equivalent => "NEAR-EQUIVALENT",
            .remix => "REMIX",
            .reachable => "REACHABLE",
            .non_quality => "NON-QUALITY (fails gate)",
            .invention_strict => "INVENTION (strict)",
        };
    }
};

pub fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub const ParentSelection = enum(u2) {
    random_pool,
    tournament_best,
    rank_biased,
    best,
};

pub const ReplacementPolicy = enum(u2) {
    worst,
    random_pool,
    tournament_worst,
};

pub const AcceptancePolicy = enum(u2) {
    metropolis,
    greedy,
    threshold,
};

pub const CoolingSchedule = enum(u2) {
    exponential,
    linear,
    inverse,
    constant,
};

pub fn Engine(comptime Spec: type) type {
    return struct {
        const Self = @This();
        pub const PoolSize: usize = 16;
        pub const MaxPoolSize: usize = 64;

        pub const SearchConfig = struct {
            mutation_rate: f64 = 0.75,
            crossover_rate: f64 = 0.25,
            t_start: f64 = 8.0,
            cooling_exponent: f64 = 1.0,
            restart_period: usize = 0,
            parent_selection: ParentSelection = .random_pool,
            replacement_policy: ReplacementPolicy = .worst,
            acceptance_policy: AcceptancePolicy = .metropolis,
            cooling_schedule: CoolingSchedule = .exponential,
        };

        const PoolEntry = struct {
            program: Spec.Program,
            quality: Spec.Quality,
            score: f64,
        };

        pub const SearchResult = struct {
            best_program: Spec.Program,
            best_quality: Spec.Quality,
            best_score: f64,
            accepted: usize,
            iterations: usize,
        };

        pub const GradeResult = struct {
            quality: Spec.Quality,
            distance: Spec.DistanceResult,
            reach: Spec.ReachabilityResult,
            verdict: Verdict,
        };

        pool: [MaxPoolSize]PoolEntry,
        count: usize,
        rng: u64,

        pub fn init(seed: u64) Self {
            return .{ .pool = undefined, .count = 0, .rng = seed };
        }

        pub fn seedPool(self: *Self, n: usize) void {
            var s: usize = 0;
            const limit = @min(n, MaxPoolSize);
            while (s < limit) : (s += 1) {
                const p = Spec.randomProgram(&self.rng);
                const q = Spec.evaluateQuality(p);
                if (!Spec.isFinite(q)) continue;
                self.consider(p, q);
            }
        }

        pub fn seedProgram(self: *Self, p: Spec.Program) bool {
            const q = Spec.evaluateQuality(p);
            if (!Spec.isFinite(q)) return false;
            self.consider(p, q);
            return true;
        }

        fn consider(self: *Self, p: Spec.Program, q: Spec.Quality) void {
            const score = Spec.qualityScalar(q);
            if (self.count < MaxPoolSize) {
                self.pool[self.count] = .{ .program = p, .quality = q, .score = score };
                self.count += 1;
                return;
            }
            var worst: usize = 0;
            for (1..self.count) |i| if (self.pool[i].score < self.pool[worst].score) {
                worst = i;
            };
            if (score > self.pool[worst].score) {
                self.pool[worst] = .{ .program = p, .quality = q, .score = score };
            }
        }

        fn worstIdx(self: *const Self) usize {
            var w: usize = 0;
            for (1..self.count) |i| if (self.pool[i].score < self.pool[w].score) {
                w = i;
            };
            return w;
        }

        pub fn bestEntry(self: *const Self) PoolEntry {
            return self.pool[self.bestIdx()];
        }

        fn bestIdx(self: *const Self) usize {
            var b: usize = 0;
            for (1..self.count) |i| if (self.pool[i].score > self.pool[b].score) {
                b = i;
            };
            return b;
        }

        fn clamp01(x: f64) f64 {
            if (!std.math.isFinite(x)) return 0.0;
            if (x < 0.0) return 0.0;
            if (x > 1.0) return 1.0;
            return x;
        }

        fn positiveOr(x: f64, fallback: f64) f64 {
            if (!std.math.isFinite(x) or x <= 0.0) return fallback;
            return x;
        }

        fn unitDraw(self: *Self) f64 {
            self.rng = smix(self.rng);
            return @as(f64, @floatFromInt(self.rng % 1_000_000)) / 1_000_000.0;
        }

        fn randomIdx(self: *Self) usize {
            self.rng = smix(self.rng);
            return self.rng % self.count;
        }

        fn tournamentBestIdx(self: *Self) usize {
            var best = self.randomIdx();
            var i: usize = 0;
            while (i < 2) : (i += 1) {
                const idx = self.randomIdx();
                if (self.pool[idx].score > self.pool[best].score) best = idx;
            }
            return best;
        }

        fn tournamentWorstIdx(self: *Self) usize {
            var worst = self.randomIdx();
            var i: usize = 0;
            while (i < 2) : (i += 1) {
                const idx = self.randomIdx();
                if (self.pool[idx].score < self.pool[worst].score) worst = idx;
            }
            return worst;
        }

        fn parentIdx(self: *Self, policy: ParentSelection) usize {
            return switch (policy) {
                .random_pool => self.randomIdx(),
                .tournament_best => self.tournamentBestIdx(),
                .rank_biased => if (self.unitDraw() < 0.65) self.tournamentBestIdx() else self.randomIdx(),
                .best => self.bestIdx(),
            };
        }

        fn replacementIdx(self: *Self, policy: ReplacementPolicy) usize {
            return switch (policy) {
                .worst => self.worstIdx(),
                .random_pool => self.randomIdx(),
                .tournament_worst => self.tournamentWorstIdx(),
            };
        }

        fn temperature(config: SearchConfig, iteration: usize, iterations: usize) f64 {
            const denom = @max(iterations, 1);
            const progress = @as(f64, @floatFromInt(iteration)) / @as(f64, @floatFromInt(denom));
            const shaped = std.math.pow(f64, progress, positiveOr(config.cooling_exponent, 1.0));
            const t_start = positiveOr(config.t_start, 8.0);
            return switch (config.cooling_schedule) {
                .exponential => t_start * std.math.pow(f64, 0.001, shaped),
                .linear => t_start * @max(0.001, 1.0 - shaped),
                .inverse => t_start / (1.0 + 20.0 * shaped),
                .constant => t_start,
            };
        }

        fn acceptDelta(self: *Self, delta: f64, t: f64, policy: AcceptancePolicy) bool {
            if (delta >= 0) return true;
            return switch (policy) {
                .greedy => false,
                .threshold => delta >= -t,
                .metropolis => blk: {
                    self.rng = smix(self.rng);
                    const accept_draw = @as(f64, @floatFromInt(self.rng % 1_000_000)) / 1_000_000.0;
                    break :blk accept_draw < std.math.exp(delta / t);
                },
            };
        }

        pub fn search(self: *Self, iterations: usize, t_start: f64, progress_writer: ?std.fs.File.Writer) !SearchResult {
            var accepted: usize = 0;
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                const t_progress = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(iterations));
                const t = t_start * std.math.pow(f64, 0.001, t_progress);

                self.rng = smix(self.rng);
                const parent_idx = self.rng % self.count;
                const parent = self.pool[parent_idx].program;

                self.rng = smix(self.rng);
                const candidate: Spec.Program = if ((self.rng & 3) == 0 and self.count > 1) blk: {
                    self.rng = smix(self.rng);
                    const other_idx = self.rng % self.count;
                    break :blk Spec.crossover(parent, self.pool[other_idx].program, &self.rng);
                } else Spec.mutate(parent, &self.rng);

                const cand_q = Spec.evaluateQuality(candidate);
                if (!Spec.isFinite(cand_q)) continue;
                const cand_score = Spec.qualityScalar(cand_q);

                const w = self.worstIdx();
                const delta = cand_score - self.pool[w].score;
                var accept = false;
                if (delta >= 0) accept = true else {
                    self.rng = smix(self.rng);
                    const accept_draw = @as(f64, @floatFromInt(self.rng % 1_000_000)) / 1_000_000.0;
                    accept = accept_draw < std.math.exp(delta / t);
                }
                if (accept) {
                    self.pool[w] = .{ .program = candidate, .quality = cand_q, .score = cand_score };
                    accepted += 1;
                }

                if (progress_writer) |pw| {
                    if ((i + 1) % @max(iterations / 20, 1) == 0 or i == 0) {
                        const best = self.bestEntry();
                        try pw.print("{d: >6} | t={d: >8.3} | best_score={d: >10.3}\n", .{ i + 1, t, best.score });
                    }
                }
            }
            const best = self.bestEntry();
            return .{
                .best_program = best.program,
                .best_quality = best.quality,
                .best_score = best.score,
                .accepted = accepted,
                .iterations = iterations,
            };
        }

        pub fn searchWithConfig(self: *Self, iterations: usize, config: SearchConfig, progress_writer: ?std.fs.File.Writer) !SearchResult {
            var accepted: usize = 0;
            var i: usize = 0;
            const mutation_rate = clamp01(config.mutation_rate);
            const crossover_rate = clamp01(config.crossover_rate);
            while (i < iterations) : (i += 1) {
                const t = temperature(config, i, iterations);

                const parent_idx = self.parentIdx(config.parent_selection);
                const parent = self.pool[parent_idx].program;

                const draw = self.unitDraw();
                const candidate: Spec.Program = if (draw < crossover_rate and self.count > 1) blk: {
                    self.rng = smix(self.rng);
                    const other_idx = self.rng % self.count;
                    break :blk Spec.crossover(parent, self.pool[other_idx].program, &self.rng);
                } else if (draw < crossover_rate + mutation_rate or self.count <= 1) blk: {
                    break :blk Spec.mutate(parent, &self.rng);
                } else parent;

                const cand_q = Spec.evaluateQuality(candidate);
                if (!Spec.isFinite(cand_q)) continue;
                const cand_score = Spec.qualityScalar(cand_q);

                const w = self.replacementIdx(config.replacement_policy);
                const delta = cand_score - self.pool[w].score;
                const accept = self.acceptDelta(delta, t, config.acceptance_policy);
                if (accept) {
                    self.pool[w] = .{ .program = candidate, .quality = cand_q, .score = cand_score };
                    accepted += 1;
                }

                if (config.restart_period != 0 and (i + 1) % config.restart_period == 0) {
                    const restarts = @max(self.count / 4, 1);
                    var r: usize = 0;
                    while (r < restarts) : (r += 1) {
                        const rp = Spec.randomProgram(&self.rng);
                        const rq = Spec.evaluateQuality(rp);
                        if (!Spec.isFinite(rq)) continue;
                        const rw = self.worstIdx();
                        self.pool[rw] = .{ .program = rp, .quality = rq, .score = Spec.qualityScalar(rq) };
                    }
                }

                if (progress_writer) |pw| {
                    if ((i + 1) % @max(iterations / 20, 1) == 0 or i == 0) {
                        const best = self.bestEntry();
                        try pw.print("{d: >6} | t={d: >8.3} | best_score={d: >10.3}\n", .{ i + 1, t, best.score });
                    }
                }
            }
            const best = self.bestEntry();
            return .{
                .best_program = best.program,
                .best_quality = best.quality,
                .best_score = best.score,
                .accepted = accepted,
                .iterations = iterations,
            };
        }

        pub fn grade(p: Spec.Program, allocator: std.mem.Allocator) !GradeResult {
            const q = Spec.evaluateQuality(p);
            const d = try Spec.distanceToLibrary(p, allocator);
            const r = try Spec.reachability(p, allocator);
            const v: Verdict = blk: {
                if (Spec.isEquivalent(d)) break :blk .equivalent;
                if (Spec.isTrivialVariant(d)) break :blk .trivial_variant;
                if (Spec.isRemix(d)) break :blk .remix;
                if (Spec.isReachable(r)) break :blk .reachable;
                if (!Spec.qualityPasses(q)) break :blk .non_quality;
                break :blk .invention_strict;
            };
            return .{ .quality = q, .distance = d, .reach = r, .verdict = v };
        }
    };
}
