const std = @import("std");

// Synthesized from the previous alien_breakthrough_inventor geometry constants.
// Runtime is VSA-free and Flame-free: std only, no concept dictionary, no
// VSA envelope, no Flame law table.

const Dim = 512;
const Words = Dim / 64;
const RefCount = 24;
const LawCount = 1536;

const Field = [Words]u64;

const SourcePrototype = [_]u64{
    0xF2DCCF1A5A1D0117,
    0xC5C4A2648F483958,
    0x9D9A4E17C31AAB1A,
    0x20994509E40FD925,
    0xAA72C6F33870B680,
    0x3F8882177B4652B5,
    0x7D67BE7E88144C7C,
    0x3F110F1907D7D281,
};

const SourceGenomeHash: u64 = 0xAF63CF03E028E569;
const SourceGenomeSeed: u64 = 0x5604D7E8AC1D9E6A;

const Law = struct {
    a: usize,
    b: usize,
    c: usize,
    rotate: u6,
    mask: u64,
};

const Metrics = struct {
    min_ref_dist: u32,
    mean_ref_dist: f64,
    violations: usize,
    orbit: u64,
    score: i128,
};

fn splitMix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn sourceHash() u64 {
    var h = SourceGenomeHash ^ SourceGenomeSeed ^ 0xC0DE1E55_B17F1E55;
    for (SourcePrototype, 0..) |word, idx| {
        h = splitMix64(h ^ word ^ @as(u64, @intCast(idx * 4099)));
    }
    return h;
}

fn bitAt(field: Field, idx: usize) bool {
    return ((field[idx / 64] >> @intCast(idx % 64)) & 1) != 0;
}

fn setBit(field: *Field, idx: usize, value: bool) void {
    const mask = @as(u64, 1) << @intCast(idx % 64);
    if (value) {
        field[idx / 64] |= mask;
    } else {
        field[idx / 64] &= ~mask;
    }
}

fn flipBit(field: *Field, idx: usize) void {
    field[idx / 64] ^= @as(u64, 1) << @intCast(idx % 64);
}

fn randomField(seed: u64) Field {
    var out: Field = undefined;
    var s = seed;
    for (&out, 0..) |*slot, idx| {
        s = splitMix64(s ^ @as(u64, @intCast(idx)));
        slot.* = s;
    }
    return out;
}

fn hamming(a: Field, b: Field) u32 {
    var dist: u32 = 0;
    for (a, b) |aw, bw| dist += @popCount(aw ^ bw);
    return dist;
}

fn fieldHash(field: Field) u64 {
    var h: u64 = sourceHash();
    for (field, 0..) |word, idx| h = splitMix64(h ^ word ^ @as(u64, @intCast(idx * 257)));
    return h;
}

fn deriveRefs(seed: u64) [RefCount]Field {
    var refs: [RefCount]Field = undefined;
    var s = seed ^ sourceHash();
    for (&refs, 0..) |*ref, idx| {
        s = splitMix64(s ^ @as(u64, @intCast(idx)));
        ref.* = randomField(s);
    }
    return refs;
}

fn deriveLaws(seed: u64) [LawCount]Law {
    var laws: [LawCount]Law = undefined;
    var s = seed ^ 0x51A7E1E55A11E1E5;
    for (&laws, 0..) |*law, idx| {
        s = splitMix64(s ^ @as(u64, @intCast(idx)));
        const a = @as(usize, @intCast(s % Words));
        s = splitMix64(s);
        const b = @as(usize, @intCast(s % Words));
        s = splitMix64(s);
        const c = @as(usize, @intCast(s % Words));
        s = splitMix64(s);
        law.* = .{
            .a = a,
            .b = b,
            .c = c,
            .rotate = @intCast(s % 63 + 1),
            .mask = splitMix64(s ^ SourceGenomeHash),
        };
    }
    return laws;
}

fn lawSatisfied(field: Field, law: Law) bool {
    const lhs = std.math.rotl(u64, field[law.a] ^ law.mask, law.rotate);
    const rhs = (field[law.b] +% splitMix64(field[law.c] ^ law.mask)) ^ std.math.rotr(u64, law.mask, law.rotate);
    return @popCount(lhs ^ rhs) <= 24;
}

fn countViolations(field: Field, laws: []const Law) usize {
    var count: usize = 0;
    for (laws) |law| {
        if (!lawSatisfied(field, law)) count += 1;
    }
    return count;
}

fn orbit(field: Field) u64 {
    var energy: u64 = 0;
    for (field, 0..) |word, idx| {
        const r: u6 = @intCast((idx * 11) % 63 + 1);
        const mixed = word ^ std.math.rotl(u64, word, r) ^ SourcePrototype[idx % SourcePrototype.len];
        energy +%= @as(u64, @popCount(mixed)) *% @as(u64, @intCast(idx + 1));
    }
    return energy;
}

fn measure(field: Field, refs: []const Field, laws: []const Law, target: u32) Metrics {
    var min_ref: u32 = std.math.maxInt(u32);
    var sum_ref: u64 = 0;
    for (refs) |ref| {
        const d = hamming(field, ref);
        min_ref = @min(min_ref, d);
        sum_ref += d;
    }
    const violations = countViolations(field, laws);
    const energy = orbit(field);
    const gap: i128 = if (min_ref < target) @intCast(target - min_ref) else 0;
    const score =
        @as(i128, @intCast(min_ref)) * 1_000_000 +
        @as(i128, @intCast(sum_ref)) * 100 +
        @as(i128, @intCast(energy & 0xFFFF)) -
        @as(i128, @intCast(violations)) * 500 -
        gap * 2_000_000;
    return .{
        .min_ref_dist = min_ref,
        .mean_ref_dist = @as(f64, @floatFromInt(sum_ref)) / @as(f64, @floatFromInt(refs.len)),
        .violations = violations,
        .orbit = energy,
        .score = score,
    };
}

fn interEnvelope(refs: []const Field) struct { min: u32, max: u32, mean: f64 } {
    var min_d: u32 = std.math.maxInt(u32);
    var max_d: u32 = 0;
    var sum: u64 = 0;
    var pairs: usize = 0;
    for (refs, 0..) |a, i| {
        for (i + 1..refs.len) |j| {
            const d = hamming(a, refs[j]);
            min_d = @min(min_d, d);
            max_d = @max(max_d, d);
            sum += d;
            pairs += 1;
        }
    }
    return .{ .min = min_d, .max = max_d, .mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(pairs)) };
}

fn antiMajority(refs: []const Field, seed: u64) Field {
    var field: Field = [_]u64{0} ** Words;
    var rng = seed ^ sourceHash();
    for (0..Dim) |bit| {
        var ones: usize = 0;
        for (refs) |ref| {
            if (bitAt(ref, bit)) ones += 1;
        }
        const zeros = refs.len - ones;
        if (ones == zeros) {
            rng = splitMix64(rng);
            setBit(&field, bit, (rng & 1) == 1);
        } else {
            setBit(&field, bit, ones < zeros);
        }
    }
    return field;
}

fn optimizeMaximin(start: Field, refs: []const Field, laws: []const Law, target: u32, rounds: usize) struct { field: Field, metrics: Metrics } {
    var field = start;
    var best = measure(field, refs, laws, target);
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        var best_bit: ?usize = null;
        var best_metrics = best;
        for (0..Dim) |bit| {
            flipBit(&field, bit);
            const m = measure(field, refs, laws, target);
            if (m.score > best_metrics.score or (m.score == best_metrics.score and m.min_ref_dist > best_metrics.min_ref_dist)) {
                best_bit = bit;
                best_metrics = m;
            }
            flipBit(&field, bit);
        }
        if (best_bit) |bit| {
            flipBit(&field, bit);
            best = best_metrics;
        } else {
            break;
        }
    }
    return .{ .field = field, .metrics = best };
}

fn invent(seed: u64, refs: []const Field, laws: []const Law, target: u32) struct { field: Field, metrics: Metrics } {
    var best_field = antiMajority(refs, seed);
    var best_metrics = measure(best_field, refs, laws, target);
    var rng = seed ^ SourceGenomeSeed;

    for (0..18) |restart| {
        var start = antiMajority(refs, splitMix64(rng ^ @as(u64, @intCast(restart))));
        rng = splitMix64(rng);
        const shake = @as(usize, @intCast(8 + (rng % 41)));
        for (0..shake) |_| {
            rng = splitMix64(rng);
            flipBit(&start, @as(usize, @intCast(rng % Dim)));
        }
        const result = optimizeMaximin(start, refs, laws, target, 96);
        if (result.metrics.score > best_metrics.score) {
            best_field = result.field;
            best_metrics = result.metrics;
        }
    }

    return .{ .field = best_field, .metrics = best_metrics };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next();

    var trials: usize = 12;
    var seed: u64 = sourceHash();
    var csv_path: []const u8 = "results/synthesized_conceptless_breakthrough.csv";
    var target_override: ?u32 = null;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--trials=")) trials = try std.fmt.parseInt(usize, arg["--trials=".len..], 10) else if (std.mem.startsWith(u8, arg, "--seed=")) seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16) else if (std.mem.startsWith(u8, arg, "--target=")) target_override = try std.fmt.parseInt(u32, arg["--target=".len..], 10) else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..];
    }

    const refs = deriveRefs(seed);
    const laws = deriveLaws(seed);
    const envelope = interEnvelope(refs[0..]);
    const target = target_override orelse envelope.max + 1;

    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var csv = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv.close();
    try csv.writer().writeAll("trial,min_ref_dist,mean_ref_dist,violations,orbit,score,past_target,field_hash\n");

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== SYNTHESIZED CONCEPTLESS BREAKTHROUGH ===\n", .{});
    try stdout.print("imports=std_only source_genome=0x{X} refs={d} envelope_min={d} envelope_mean={d:.1} envelope_max={d} target={d}\n", .{
        SourceGenomeHash,
        RefCount,
        envelope.min,
        envelope.mean,
        envelope.max,
        target,
    });
    try stdout.writeAll("trial | min_ref | mean  | violations | score      | past?\n");
    try stdout.writeAll("------|---------|-------|------------|------------|------\n");

    var past: usize = 0;
    var best = Metrics{ .min_ref_dist = 0, .mean_ref_dist = 0, .violations = std.math.maxInt(usize), .orbit = 0, .score = std.math.minInt(i128) };
    var best_hash: u64 = 0;
    for (0..trials) |trial| {
        const trial_seed = splitMix64(seed +% @as(u64, @intCast(trial)) *% 0xD1B54A32D192ED03);
        const result = invent(trial_seed, refs[0..], laws[0..], target);
        const m = result.metrics;
        const is_past = m.min_ref_dist >= target;
        if (is_past) past += 1;
        const hash = fieldHash(result.field);
        if (m.score > best.score) {
            best = m;
            best_hash = hash;
        }
        try stdout.print("{d: >5} | {d: >7} | {d: >5.1} | {d: >10} | {d: >10} | {s}\n", .{
            trial,
            m.min_ref_dist,
            m.mean_ref_dist,
            m.violations,
            m.score,
            if (is_past) "YES" else "no",
        });
        try csv.writer().print("{d},{d},{d:.4},{d},{d},{d},{d},0x{X}\n", .{
            trial,
            m.min_ref_dist,
            m.mean_ref_dist,
            m.violations,
            m.orbit,
            m.score,
            @intFromBool(is_past),
            hash,
        });
    }

    try stdout.print("\nVERDICT: synthesized_conceptless_past_target={d}/{d}; best_min_ref={d}; best_violations={d}; best_score={d}; best_hash=0x{X}; csv={s}\n", .{
        past,
        trials,
        best.min_ref_dist,
        best.violations,
        best.score,
        best_hash,
        csv_path,
    });
}
