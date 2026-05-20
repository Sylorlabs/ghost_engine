const std = @import("std");
const flame = @import("flame");
const vsa = @import("vsa");
const void_eng = @import("void");

// --- ENGINE GENESIS ---
//
// Local geometry-to-Zig compiler for invention engines.
//
// It does not ask a model to design code. It derives an outside-envelope
// chamber fingerprint, folds that geometry and the Flame law table into a
// small genome, emits a standalone Zig adapter from the genome, then measures
// the generated engine against the VSA envelope.

const FpWords = flame.ChamberCount / 64;
const Fingerprint = [FpWords]u64;
const ConceptMax = 32;

const Metrics = struct {
    closure: u128,
    min_dist: u32,
    nearest: []const u8,
    mean_dist: f64,
    max_dist: u32,
};

const Genome = struct {
    name_hash: u64,
    seed: u64,
    repair_passes: usize,
    lock_period: usize,
    curl_stride: usize,
    curl_span: usize,
    pressure: i128,
    amplitude: i128,
};

const GenomeSearchResult = struct {
    genome: Genome,
    past: usize,
    best_closure: u128,
    avg_closure: f64,
};

fn bitAt(fp: Fingerprint, idx: usize) bool {
    return ((fp[idx / 64] >> @intCast(idx % 64)) & 1) != 0;
}

fn setBit(fp: *Fingerprint, idx: usize, value: bool) void {
    const mask = @as(u64, 1) << @intCast(idx % 64);
    if (value) {
        fp[idx / 64] |= mask;
    } else {
        fp[idx / 64] &= ~mask;
    }
}

fn flipBit(fp: *Fingerprint, idx: usize) void {
    fp[idx / 64] ^= @as(u64, 1) << @intCast(idx % 64);
}

fn hammingFp(a: Fingerprint, b: Fingerprint) u32 {
    var d: u32 = 0;
    for (a, b) |aw, bw| d += @popCount(aw ^ bw);
    return d;
}

fn conceptFingerprint(c: vsa.Concept) Fingerprint {
    const hv = vsa.getConceptHV(c);
    var fp: Fingerprint = undefined;
    for (&fp, 0..) |*w, i| w.* = hv.data[i];
    return fp;
}

fn distanceStats(dists: []const u32) struct { min: u32, sum: u32 } {
    var min: u32 = std.math.maxInt(u32);
    var sum: u32 = 0;
    for (dists) |d| {
        if (d < min) min = d;
        sum += d;
    }
    return .{ .min = min, .sum = sum };
}

fn synthesizeOutsideFingerprint(concept_fps: []const Fingerprint, seed: u64) Fingerprint {
    if (concept_fps.len > ConceptMax) @panic("too many concepts");

    var proto: Fingerprint = [_]u64{0} ** FpWords;
    var rng = seed;
    for (0..flame.ChamberCount) |bit| {
        var ones: usize = 0;
        for (concept_fps) |cfp| {
            if (bitAt(cfp, bit)) ones += 1;
        }
        const zeros = concept_fps.len - ones;
        if (ones == zeros) {
            rng = void_eng.splitMix64(rng);
            setBit(&proto, bit, (rng & 1) == 1);
        } else {
            setBit(&proto, bit, ones < zeros);
        }
    }

    var dists: [ConceptMax]u32 = [_]u32{0} ** ConceptMax;
    for (concept_fps, 0..) |cfp, idx| {
        dists[idx] = hammingFp(proto, cfp);
    }

    var pass: usize = 0;
    while (pass < 10) : (pass += 1) {
        const current = distanceStats(dists[0..concept_fps.len]);
        var best_bit: ?usize = null;
        var best_min = current.min;
        var best_sum = current.sum;

        for (0..flame.ChamberCount) |bit| {
            const old_bit = bitAt(proto, bit);
            var candidate = dists;
            for (concept_fps, 0..) |cfp, idx| {
                if (old_bit == bitAt(cfp, bit)) {
                    candidate[idx] += 1;
                } else {
                    candidate[idx] -= 1;
                }
            }
            const stats = distanceStats(candidate[0..concept_fps.len]);
            if (stats.min > best_min or (stats.min == best_min and stats.sum > best_sum)) {
                best_bit = bit;
                best_min = stats.min;
                best_sum = stats.sum;
            }
        }

        if (best_bit) |bit| {
            const old_bit = bitAt(proto, bit);
            for (concept_fps, 0..) |cfp, idx| {
                if (old_bit == bitAt(cfp, bit)) {
                    dists[idx] += 1;
                } else {
                    dists[idx] -= 1;
                }
            }
            flipBit(&proto, bit);
        } else {
            break;
        }
    }

    return proto;
}

fn fingerprintHash(fp: Fingerprint) u64 {
    var h: u64 = 0xD1CEB00C51A7E001;
    for (fp, 0..) |word, idx| {
        h = void_eng.splitMix64(h ^ word ^ (@as(u64, @intCast(idx)) *% 0x9E3779B97F4A7C15));
    }
    return h;
}

fn lawHash() u64 {
    var h: u64 = 0xA116E05EED5A17E5;
    for (flame.Laws, 0..) |law, idx| {
        h = void_eng.splitMix64(h ^ @as(u64, @intCast(law.a)) ^ (@as(u64, @intCast(law.b)) << 32) ^ @as(u64, @intCast(idx)));
        h = void_eng.splitMix64(h ^ @as(u64, @truncate(@as(u128, @bitCast(law.ca)))));
        h = void_eng.splitMix64(h ^ @as(u64, @truncate(@as(u128, @bitCast(law.cb)))));
        h = void_eng.splitMix64(h ^ @as(u64, @truncate(@as(u128, @bitCast(law.t)))));
    }
    return h;
}

fn deriveGenome(proto: Fingerprint, max_inter: u32) Genome {
    var h = fingerprintHash(proto) ^ lawHash() ^ @as(u64, max_inter);
    const name_hash = h;
    h = void_eng.splitMix64(h);
    const repair_passes = 18 + @as(usize, @intCast(h % 29));
    h = void_eng.splitMix64(h);
    const lock_period = 2 + @as(usize, @intCast(h % 7));
    h = void_eng.splitMix64(h);
    var curl_stride = 5 + @as(usize, @intCast(h % 37));
    if (curl_stride % 2 == 0) curl_stride += 1;
    h = void_eng.splitMix64(h);
    const curl_span = 3 + @as(usize, @intCast(h % 19));
    h = void_eng.splitMix64(h);
    const pressure = @as(i128, @intCast(1024 + (h % 8192)));
    h = void_eng.splitMix64(h);
    const amplitude = @as(i128, @intCast(4096 + (h % 65536)));
    return .{
        .name_hash = name_hash,
        .seed = h,
        .repair_passes = repair_passes,
        .lock_period = lock_period,
        .curl_stride = curl_stride,
        .curl_span = curl_span,
        .pressure = pressure,
        .amplitude = amplitude,
    };
}

fn absI128(v: i128) i128 {
    return if (v < 0) -v else v;
}

fn chamberSign(chamber: [flame.ChamberCount]i128, idx: usize) bool {
    return chamber[idx] > 0;
}

fn setChamberSign(chamber: *[flame.ChamberCount]i128, idx: usize, want_positive: bool, min_magnitude: i128, rng: *u64) void {
    rng.* = void_eng.splitMix64(rng.*);
    var mag = absI128(chamber[idx]);
    const jitter = @as(i128, @intCast(rng.* % 4096));
    if (mag < min_magnitude) mag = min_magnitude + jitter;
    chamber[idx] = if (want_positive) mag else -mag;
}

fn chamberFromFingerprint(fp: Fingerprint, seed: u64, magnitude: i128) [flame.ChamberCount]i128 {
    var out: [flame.ChamberCount]i128 = undefined;
    var s = seed;
    for (&out, 0..) |*slot, idx| {
        s = void_eng.splitMix64(s);
        const mag = magnitude + @as(i128, @intCast(s % 8192));
        slot.* = if (bitAt(fp, idx)) mag else -mag;
    }
    return out;
}

fn enforceFingerprint(state: *flame.FlameState, fp: Fingerprint, min_magnitude: i128, rng: *u64) void {
    for (0..flame.ChamberCount) |idx| {
        if (chamberSign(state.chamber, idx) != bitAt(fp, idx)) {
            setChamberSign(&state.chamber, idx, bitAt(fp, idx), min_magnitude, rng);
        }
    }
}

fn curlMagnitudes(state: *flame.FlameState, genome: Genome, pass: usize, rng: *u64) void {
    const start = (pass * genome.curl_stride) % flame.ChamberCount;
    var cursor = start;
    var touched: usize = 0;
    while (touched < flame.ChamberCount / genome.curl_span) : (touched += 1) {
        rng.* = void_eng.splitMix64(rng.* ^ @as(u64, @intCast(cursor)) ^ @as(u64, @intCast(pass)));
        const delta = @as(i128, @intCast(rng.* % @as(u64, @intCast(genome.amplitude))));
        const sign: i128 = if (state.chamber[cursor] >= 0) 1 else -1;
        state.chamber[cursor] += sign * delta;
        cursor = (cursor + genome.curl_stride) % flame.ChamberCount;
    }
}

fn repairGenerated(state: *flame.FlameState, proto: Fingerprint, genome: Genome, passes: usize) void {
    var rng = genome.seed ^ state.kernel;
    for (0..passes) |pass| {
        curlMagnitudes(state, genome, pass, &rng);
        for (flame.Laws) |law| {
            const got = law.ca * state.chamber[law.a] + law.cb * state.chamber[law.b];
            const err = law.t - got;
            if (err == 0) continue;
            const denom = law.ca * law.ca + law.cb * law.cb;
            if (denom == 0) continue;
            const damp = @as(i128, @intCast(1 + (pass / genome.lock_period)));
            const da = @divTrunc(err * law.ca, denom * damp);
            const db = @divTrunc(err * law.cb, denom * damp);
            state.chamber[law.a] += @max(-1_000_000_000_000, @min(1_000_000_000_000, da));
            state.chamber[law.b] += @max(-1_000_000_000_000, @min(1_000_000_000_000, db));
        }
        enforceFingerprint(state, proto, genome.pressure, &rng);
    }
    state.closure_error = flame.closureError(state);
}

fn measureFingerprint(fp: Fingerprint, closure: u128, concept_fps: []const Fingerprint, names: []const []const u8) Metrics {
    var best: u32 = std.math.maxInt(u32);
    var best_name: []const u8 = "?";
    var max_d: u32 = 0;
    var sum: u64 = 0;
    for (concept_fps, names) |cfp, name| {
        const d = hammingFp(fp, cfp);
        sum += d;
        if (d > max_d) max_d = d;
        if (d < best) {
            best = d;
            best_name = name;
        }
    }
    return .{
        .closure = closure,
        .min_dist = best,
        .nearest = best_name,
        .mean_dist = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(concept_fps.len)),
        .max_dist = max_d,
    };
}

fn chamberFingerprint(chamber: [flame.ChamberCount]i128) Fingerprint {
    var fp: Fingerprint = [_]u64{0} ** FpWords;
    for (chamber, 0..) |v, i| {
        if (v > 0) setBit(&fp, i, true);
    }
    return fp;
}

fn runGeneratedTrial(
    proto: Fingerprint,
    genome: Genome,
    trial_seed: u64,
    passes: usize,
    concept_fps: []const Fingerprint,
    names: []const []const u8,
) Metrics {
    var state = flame.FlameState{
        .chamber = chamberFromFingerprint(proto, trial_seed, genome.pressure + 24_000),
        .scar_bank = [_]u64{0} ** flame.ScarCount,
        .kernel = trial_seed,
        .closure_error = 0,
    };
    state.closure_error = flame.closureError(&state);
    repairGenerated(&state, proto, genome, passes);
    return measureFingerprint(chamberFingerprint(state.chamber), state.closure_error, concept_fps, names);
}

fn evaluateGenome(
    proto: Fingerprint,
    genome: Genome,
    concept_fps: []const Fingerprint,
    names: []const []const u8,
    max_inter: u32,
    eval_trials: usize,
    seed: u64,
) GenomeSearchResult {
    var past: usize = 0;
    var best_closure: u128 = std.math.maxInt(u128);
    var sum_closure: f64 = 0;

    for (0..eval_trials) |trial| {
        const trial_seed = void_eng.splitMix64(seed +% @as(u64, @intCast(trial)) *% 0xA24B_AED4_963E_E407);
        const m = runGeneratedTrial(proto, genome, trial_seed, genome.repair_passes, concept_fps, names);
        if (m.min_dist > max_inter) past += 1;
        if (m.closure < best_closure) best_closure = m.closure;
        sum_closure += @floatFromInt(m.closure);
    }

    return .{
        .genome = genome,
        .past = past,
        .best_closure = best_closure,
        .avg_closure = sum_closure / @as(f64, @floatFromInt(eval_trials)),
    };
}

fn betterGenome(a: GenomeSearchResult, b: GenomeSearchResult) bool {
    if (a.past != b.past) return a.past > b.past;
    if (a.best_closure != b.best_closure) return a.best_closure < b.best_closure;
    return a.avg_closure < b.avg_closure;
}

fn evolveGenome(
    proto: Fingerprint,
    base: Genome,
    concept_fps: []const Fingerprint,
    names: []const []const u8,
    max_inter: u32,
    seed: u64,
    eval_trials: usize,
) GenomeSearchResult {
    const pass_options = [_]usize{ 12, 18, 24, 32, base.repair_passes };
    const lock_options = [_]usize{ 1, 2, base.lock_period };
    const span_options = [_]usize{ 8, 13, 21, 32, base.curl_span };
    const pressure_options = [_]i128{ 1024, 2048, @divTrunc(base.pressure, 2), base.pressure };
    const amplitude_options = [_]i128{
        1,
        64,
        512,
        2048,
        @max(@as(i128, 1), @divTrunc(base.amplitude, 16)),
        @max(@as(i128, 1), @divTrunc(base.amplitude, 4)),
        base.amplitude,
    };

    var best = evaluateGenome(proto, base, concept_fps, names, max_inter, eval_trials, seed);
    for (pass_options) |passes| {
        for (lock_options) |lock| {
            for (span_options) |span| {
                for (pressure_options) |pressure| {
                    for (amplitude_options) |amplitude| {
                        var candidate = base;
                        candidate.repair_passes = passes;
                        candidate.lock_period = lock;
                        candidate.curl_span = span;
                        candidate.pressure = pressure;
                        candidate.amplitude = amplitude;
                        const result = evaluateGenome(proto, candidate, concept_fps, names, max_inter, eval_trials, seed ^ @as(u64, @intCast(passes * 131 + lock * 17 + span)));
                        if (betterGenome(result, best)) best = result;
                    }
                }
            }
        }
    }

    return best;
}

fn writeGeneratedSource(path: []const u8, proto: Fingerprint, genome: Genome) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) try std.fs.cwd().makePath(dir);
    }
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    const w = file.writer();

    try w.writeAll(
        \\const std = @import("std");
        \\const flame = @import("flame");
        \\const vsa = @import("vsa");
        \\const void_eng = @import("void");
        \\
        \\// Generated by engine_genesis.zig from outside-envelope chamber geometry.
        \\// Local deterministic engine. No model call, no service call.
        \\
        \\const FpWords = flame.ChamberCount / 64;
        \\const Fingerprint = [FpWords]u64;
        \\
    );
    try w.print("const GenomeNameHash: u64 = 0x{X};\n", .{genome.name_hash});
    try w.print("const GenomeSeed: u64 = 0x{X};\n", .{genome.seed});
    try w.print("const RepairPasses: usize = {d};\n", .{genome.repair_passes});
    try w.print("const LockPeriod: usize = {d};\n", .{genome.lock_period});
    try w.print("const CurlStride: usize = {d};\n", .{genome.curl_stride});
    try w.print("const CurlSpan: usize = {d};\n", .{genome.curl_span});
    try w.print("const NoveltyPressure: i128 = {d};\n", .{genome.pressure});
    try w.print("const CurlAmplitude: i128 = {d};\n\n", .{genome.amplitude});
    try w.writeAll("const AlienPrototype = Fingerprint{\n");
    for (proto) |word| {
        try w.print("    0x{X:0>16},\n", .{word});
    }
    try w.writeAll(
        \\};
        \\
        \\const Metrics = struct {
        \\    closure: u128,
        \\    min_dist: u32,
        \\    nearest: []const u8,
        \\    mean_dist: f64,
        \\    max_dist: u32,
        \\};
        \\
        \\fn bitAt(fp: Fingerprint, idx: usize) bool {
        \\    return ((fp[idx / 64] >> @intCast(idx % 64)) & 1) != 0;
        \\}
        \\
        \\fn setBit(fp: *Fingerprint, idx: usize, value: bool) void {
        \\    const mask = @as(u64, 1) << @intCast(idx % 64);
        \\    if (value) fp[idx / 64] |= mask else fp[idx / 64] &= ~mask;
        \\}
        \\
        \\fn hammingFp(a: Fingerprint, b: Fingerprint) u32 {
        \\    var d: u32 = 0;
        \\    for (a, b) |aw, bw| d += @popCount(aw ^ bw);
        \\    return d;
        \\}
        \\
        \\fn conceptFingerprint(c: vsa.Concept) Fingerprint {
        \\    const hv = vsa.getConceptHV(c);
        \\    var fp: Fingerprint = undefined;
        \\    for (&fp, 0..) |*w, i| w.* = hv.data[i];
        \\    return fp;
        \\}
        \\
        \\fn absI128(v: i128) i128 {
        \\    return if (v < 0) -v else v;
        \\}
        \\
        \\fn chamberSign(chamber: [flame.ChamberCount]i128, idx: usize) bool {
        \\    return chamber[idx] > 0;
        \\}
        \\
        \\fn setChamberSign(chamber: *[flame.ChamberCount]i128, idx: usize, want_positive: bool, min_magnitude: i128, rng: *u64) void {
        \\    rng.* = void_eng.splitMix64(rng.*);
        \\    var mag = absI128(chamber[idx]);
        \\    const jitter = @as(i128, @intCast(rng.* % 4096));
        \\    if (mag < min_magnitude) mag = min_magnitude + jitter;
        \\    chamber[idx] = if (want_positive) mag else -mag;
        \\}
        \\
        \\fn chamberFromPrototype(seed: u64) [flame.ChamberCount]i128 {
        \\    var out: [flame.ChamberCount]i128 = undefined;
        \\    var s = seed ^ GenomeSeed;
        \\    for (&out, 0..) |*slot, idx| {
        \\        s = void_eng.splitMix64(s);
        \\        const mag = NoveltyPressure + 24_000 + @as(i128, @intCast(s % 8192));
        \\        slot.* = if (bitAt(AlienPrototype, idx)) mag else -mag;
        \\    }
        \\    return out;
        \\}
        \\
        \\fn enforcePrototype(state: *flame.FlameState, rng: *u64) void {
        \\    for (0..flame.ChamberCount) |idx| {
        \\        if (chamberSign(state.chamber, idx) != bitAt(AlienPrototype, idx)) {
        \\            setChamberSign(&state.chamber, idx, bitAt(AlienPrototype, idx), NoveltyPressure, rng);
        \\        }
        \\    }
        \\}
        \\
        \\fn curlMagnitudes(state: *flame.FlameState, pass: usize, rng: *u64) void {
        \\    var cursor = (pass * CurlStride) % flame.ChamberCount;
        \\    var touched: usize = 0;
        \\    while (touched < flame.ChamberCount / CurlSpan) : (touched += 1) {
        \\        rng.* = void_eng.splitMix64(rng.* ^ @as(u64, @intCast(cursor)) ^ @as(u64, @intCast(pass)));
        \\        const delta = @as(i128, @intCast(rng.* % @as(u64, @intCast(CurlAmplitude))));
        \\        const sign: i128 = if (state.chamber[cursor] >= 0) 1 else -1;
        \\        state.chamber[cursor] += sign * delta;
        \\        cursor = (cursor + CurlStride) % flame.ChamberCount;
        \\    }
        \\}
        \\
        \\fn repair(state: *flame.FlameState, passes: usize) void {
        \\    var rng = GenomeSeed ^ state.kernel ^ GenomeNameHash;
        \\    for (0..passes) |pass| {
        \\        curlMagnitudes(state, pass, &rng);
        \\        for (flame.Laws) |law| {
        \\            const got = law.ca * state.chamber[law.a] + law.cb * state.chamber[law.b];
        \\            const err = law.t - got;
        \\            if (err == 0) continue;
        \\            const denom = law.ca * law.ca + law.cb * law.cb;
        \\            if (denom == 0) continue;
        \\            const damp = @as(i128, @intCast(1 + (pass / LockPeriod)));
        \\            const da = @divTrunc(err * law.ca, denom * damp);
        \\            const db = @divTrunc(err * law.cb, denom * damp);
        \\            state.chamber[law.a] += @max(-1_000_000_000_000, @min(1_000_000_000_000, da));
        \\            state.chamber[law.b] += @max(-1_000_000_000_000, @min(1_000_000_000_000, db));
        \\        }
        \\        enforcePrototype(state, &rng);
        \\    }
        \\    state.closure_error = flame.closureError(state);
        \\}
        \\
        \\fn chamberFingerprint(chamber: [flame.ChamberCount]i128) Fingerprint {
        \\    var fp: Fingerprint = [_]u64{0} ** FpWords;
        \\    for (chamber, 0..) |v, i| if (v > 0) setBit(&fp, i, true);
        \\    return fp;
        \\}
        \\
        \\fn measure(fp: Fingerprint, closure: u128, concept_fps: []const Fingerprint, names: []const []const u8) Metrics {
        \\    var best: u32 = std.math.maxInt(u32);
        \\    var best_name: []const u8 = "?";
        \\    var max_d: u32 = 0;
        \\    var sum: u64 = 0;
        \\    for (concept_fps, names) |cfp, name| {
        \\        const d = hammingFp(fp, cfp);
        \\        sum += d;
        \\        if (d > max_d) max_d = d;
        \\        if (d < best) {
        \\            best = d;
        \\            best_name = name;
        \\        }
        \\    }
        \\    return .{
        \\        .closure = closure,
        \\        .min_dist = best,
        \\        .nearest = best_name,
        \\        .mean_dist = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(concept_fps.len)),
        \\        .max_dist = max_d,
        \\    };
        \\}
        \\
        \\pub fn main() !void {
        \\    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\    defer arena.deinit();
        \\    const aa = arena.allocator();
        \\    var args = try std.process.argsWithAllocator(aa);
        \\    defer args.deinit();
        \\    _ = args.next();
        \\    var trials: usize = 16;
        \\    var passes: usize = RepairPasses;
        \\    var csv_path: []const u8 = "results/generated_geometry_invention.csv";
        \\    var base_seed: u64 = GenomeSeed;
        \\    while (args.next()) |arg| {
        \\        if (std.mem.startsWith(u8, arg, "--trials=")) trials = try std.fmt.parseInt(usize, arg["--trials=".len..], 10)
        \\        else if (std.mem.startsWith(u8, arg, "--passes=")) passes = try std.fmt.parseInt(usize, arg["--passes=".len..], 10)
        \\        else if (std.mem.startsWith(u8, arg, "--seed=")) base_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16)
        \\        else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..];
        \\    }
        \\
        \\    const fields = std.meta.fields(vsa.Concept);
        \\    var concept_fps = try aa.alloc(Fingerprint, fields.len);
        \\    var names = try aa.alloc([]const u8, fields.len);
        \\    inline for (fields, 0..) |field, i| {
        \\        concept_fps[i] = conceptFingerprint(@as(vsa.Concept, @enumFromInt(field.value)));
        \\        names[i] = field.name;
        \\    }
        \\    var max_inter: u32 = 0;
        \\    for (concept_fps, 0..) |a, i| for (i + 1..concept_fps.len) |j| {
        \\        const d = hammingFp(a, concept_fps[j]);
        \\        if (d > max_inter) max_inter = d;
        \\    };
        \\
        \\    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
        \\    var csv = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
        \\    defer csv.close();
        \\    try csv.writer().writeAll("trial,min_dist,nearest,closure,mean_dist,max_dist,past_envelope\n");
        \\
        \\    const stdout = std.io.getStdOut().writer();
        \\    try stdout.print("=== GENERATED GEOMETRY INVENTION ENGINE ===\n", .{});
        \\    try stdout.print("genome=0x{X} passes={d} lock={d} stride={d} span={d} pressure={d} amplitude={d}\n", .{
        \\        GenomeNameHash, passes, LockPeriod, CurlStride, CurlSpan, NoveltyPressure, CurlAmplitude,
        \\    });
        \\    try stdout.print("VSA max envelope={d}\n", .{max_inter});
        \\    try stdout.writeAll("trial | min_dist | nearest          | closure      | mean  | max | past?\n");
        \\    try stdout.writeAll("------|----------|------------------|--------------|-------|-----|------\n");
        \\
        \\    var past: usize = 0;
        \\    var best = Metrics{ .closure = std.math.maxInt(u128), .min_dist = 0, .nearest = "?", .mean_dist = 0, .max_dist = 0 };
        \\    for (0..trials) |trial| {
        \\        const seed = void_eng.splitMix64(base_seed +% @as(u64, @intCast(trial)) *% 0x9E3779B97F4A7C15);
        \\        var state = flame.FlameState{
        \\            .chamber = chamberFromPrototype(seed),
        \\            .scar_bank = [_]u64{0} ** flame.ScarCount,
        \\            .kernel = seed,
        \\            .closure_error = 0,
        \\        };
        \\        state.closure_error = flame.closureError(&state);
        \\        repair(&state, passes);
        \\        const m = measure(chamberFingerprint(state.chamber), state.closure_error, concept_fps, names);
        \\        const is_past = m.min_dist > max_inter;
        \\        if (is_past) past += 1;
        \\        if (m.min_dist > best.min_dist or (m.min_dist == best.min_dist and m.closure < best.closure)) best = m;
        \\        try stdout.print("{d: >5} | {d: >8} | {s: <16} | {d: >12} | {d: >5.1} | {d: >3} | {s}\n", .{
        \\            trial, m.min_dist, m.nearest, m.closure, m.mean_dist, m.max_dist, if (is_past) "YES" else "no",
        \\        });
        \\        try csv.writer().print("{d},{d},{s},{d},{d:.4},{d},{d}\n", .{
        \\            trial, m.min_dist, m.nearest, m.closure, m.mean_dist, m.max_dist, @intFromBool(is_past),
        \\        });
        \\    }
        \\
        \\    try stdout.print("\nVERDICT: past_envelope={d}/{d}; best_min={d}; best_closure={d}; csv={s}\n", .{
        \\        past, trials, best.min_dist, best.closure, csv_path,
        \\    });
        \\}
        \\
    );
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next();

    var trials: usize = 16;
    var passes_override: ?usize = null;
    var evolve_trials: usize = 3;
    var emit_path: []const u8 = "src/adapters/generated_geometry_invention.zig";
    var csv_path: []const u8 = "results/engine_genesis.csv";
    var base_seed: u64 = 0x6E0A_1DE5_1A5E_BA5E;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--trials=")) trials = try std.fmt.parseInt(usize, arg["--trials=".len..], 10) else if (std.mem.startsWith(u8, arg, "--passes=")) passes_override = try std.fmt.parseInt(usize, arg["--passes=".len..], 10) else if (std.mem.startsWith(u8, arg, "--evolve-trials=")) evolve_trials = try std.fmt.parseInt(usize, arg["--evolve-trials=".len..], 10) else if (std.mem.startsWith(u8, arg, "--emit=")) emit_path = arg["--emit=".len..] else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..] else if (std.mem.startsWith(u8, arg, "--seed=")) base_seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
    }

    const fields = std.meta.fields(vsa.Concept);
    var concept_fps = try aa.alloc(Fingerprint, fields.len);
    var names = try aa.alloc([]const u8, fields.len);
    inline for (fields, 0..) |field, i| {
        concept_fps[i] = conceptFingerprint(@as(vsa.Concept, @enumFromInt(field.value)));
        names[i] = field.name;
    }

    var min_inter: u32 = std.math.maxInt(u32);
    var max_inter: u32 = 0;
    var sum_inter: u64 = 0;
    var pair_count: usize = 0;
    for (concept_fps, 0..) |a, i| {
        for (i + 1..concept_fps.len) |j| {
            const d = hammingFp(a, concept_fps[j]);
            if (d < min_inter) min_inter = d;
            if (d > max_inter) max_inter = d;
            sum_inter += d;
            pair_count += 1;
        }
    }

    const proto = synthesizeOutsideFingerprint(concept_fps, base_seed);
    var base_genome = deriveGenome(proto, max_inter);
    if (passes_override) |passes| base_genome.repair_passes = passes;
    const search_result = evolveGenome(
        proto,
        base_genome,
        concept_fps,
        names,
        max_inter,
        base_seed ^ 0xE901_37E5_15EA_7C4D,
        evolve_trials,
    );
    const genome = search_result.genome;
    const passes = genome.repair_passes;

    const proto_metrics = measureFingerprint(proto, 0, concept_fps, names);
    try writeGeneratedSource(emit_path, proto, genome);

    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var csv = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv.close();
    try csv.writer().writeAll("trial,min_dist,nearest,closure,mean_dist,max_dist,past_envelope\n");

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== ENGINE GENESIS ===\n", .{});
    try stdout.print("VSA inter-concept: min={d} mean={d:.1} max={d}\n", .{
        min_inter,
        @as(f64, @floatFromInt(sum_inter)) / @as(f64, @floatFromInt(pair_count)),
        max_inter,
    });
    try stdout.print("outside geometry: min_dist={d} nearest={s} mean={d:.1} max={d}\n", .{
        proto_metrics.min_dist,
        proto_metrics.nearest,
        proto_metrics.mean_dist,
        proto_metrics.max_dist,
    });
    try stdout.print("emitted: {s}\n", .{emit_path});
    try stdout.print("genome search: eval_trials={d} past={d}/{d} best_closure={d} avg_closure={d:.1}\n", .{
        evolve_trials,
        search_result.past,
        evolve_trials,
        search_result.best_closure,
        search_result.avg_closure,
    });
    try stdout.print("genome=0x{X} seed=0x{X} passes={d} lock={d} stride={d} span={d} pressure={d} amplitude={d}\n\n", .{
        genome.name_hash,
        genome.seed,
        genome.repair_passes,
        genome.lock_period,
        genome.curl_stride,
        genome.curl_span,
        genome.pressure,
        genome.amplitude,
    });

    try stdout.writeAll("trial | min_dist | nearest          | closure      | mean  | max | past?\n");
    try stdout.writeAll("------|----------|------------------|--------------|-------|-----|------\n");

    var past: usize = 0;
    var best = Metrics{ .closure = std.math.maxInt(u128), .min_dist = 0, .nearest = "?", .mean_dist = 0, .max_dist = 0 };
    for (0..trials) |trial| {
        const seed = void_eng.splitMix64(base_seed +% @as(u64, @intCast(trial)) *% 0xD1B5_4A32_D192_ED03);
        const m = runGeneratedTrial(proto, genome, seed, passes, concept_fps, names);
        const is_past = m.min_dist > max_inter;
        if (is_past) past += 1;
        if (m.min_dist > best.min_dist or (m.min_dist == best.min_dist and m.closure < best.closure)) best = m;
        try stdout.print("{d: >5} | {d: >8} | {s: <16} | {d: >12} | {d: >5.1} | {d: >3} | {s}\n", .{
            trial,
            m.min_dist,
            m.nearest,
            m.closure,
            m.mean_dist,
            m.max_dist,
            if (is_past) "YES" else "no",
        });
        try csv.writer().print("{d},{d},{s},{d},{d:.4},{d},{d}\n", .{
            trial,
            m.min_dist,
            m.nearest,
            m.closure,
            m.mean_dist,
            m.max_dist,
            @intFromBool(is_past),
        });
    }

    try stdout.print("\nVERDICT: generated_engine_past_envelope={d}/{d}; best_min={d}; best_closure={d}; csv={s}\n", .{
        past,
        trials,
        best.min_dist,
        best.closure,
        csv_path,
    });
}
