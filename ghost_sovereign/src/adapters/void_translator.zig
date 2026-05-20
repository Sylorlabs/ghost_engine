const std = @import("std");
const void_eng = @import("void");
const flame = @import("flame");

// --- Void Translator ---
// Calibrates the engine's response to 8 canonical labeled prompts, then
// translates an arbitrary query into a nearest-neighbor label by Hamming
// distance on the post-ingestion chamber sign-bit fingerprint.
//
// Fingerprint construction is deterministic given (seed, text):
//   1. VoidEngine.init(CANONICAL_SEED)
//   2. ingestTextSequence(seed_ingest, text, text.len * REPEAT_FACTOR)
//   3. shapeTextPressure(seed_pressure, text)
//   4. fingerprint[i] = (chamber[i] > 0) ? 1 : 0     for i in 0..512
//
// All calibration prompts and the query use the same canonical seeds, so
// the only varying input is the text. Distance is Hamming popcount of XOR.

pub const CANONICAL_SEED: u64 = 0x145F2EA61D0202D9;
pub const SEED_INGEST: u64 = 0xA11CEF00DBABEC0D;
pub const SEED_PRESSURE: u64 = 0xBEEFDEADC0DEF00D;
pub const REPEAT_FACTOR: usize = 4;

pub const Fingerprint = [flame.ChamberCount / 64]u64; // 512 bits = 8 u64s

pub const LabeledPrompt = struct {
    label: []const u8,
    text: []const u8,
};

pub const CALIBRATION_PROMPTS = [_]LabeledPrompt{
    .{ .label = "technical-low-level", .text = "Explain the memory layout of a Zig struct with aligned fields." },
    .{ .label = "creative-poetic", .text = "Write a haiku about the silence of a motherboard at night." },
    .{ .label = "math-hard", .text = "Solve for x where 7x^2 + 13x - 5000 = 0 using Diophantine approximation." },
    .{ .label = "typo-adversarial", .text = "hw do i fix teh broken lgc in my asic core??" },
    .{ .label = "instruction-complex", .text = "Refactor the existing Sovereign meta-architecture to use a sharded ring buffer for voxel persistence." },
    .{ .label = "casual-greeting", .text = "Hello, how is the weather in the cloud today?" },
    .{ .label = "system-status", .text = "Report on current manifold resonance and L1 cache utilization." },
    .{ .label = "code-zig", .text = "const std = @import(\"std\"); pub fn main() !void { std.debug.print(\"hello\", .{}); }" },
};

pub fn fingerprintOf(text: []const u8) Fingerprint {
    var engine = void_eng.VoidEngine.init(CANONICAL_SEED);
    engine.ingestTextSequence(SEED_INGEST, text, text.len * REPEAT_FACTOR);
    engine.shapeTextPressure(SEED_PRESSURE, text);

    var fp: Fingerprint = [_]u64{0} ** (flame.ChamberCount / 64);
    for (engine.state.chamber, 0..) |val, i| {
        if (val > 0) {
            fp[i / 64] |= (@as(u64, 1) << @intCast(i % 64));
        }
    }
    return fp;
}

pub fn hammingDistance(a: Fingerprint, b: Fingerprint) u32 {
    var dist: u32 = 0;
    for (a, b) |aw, bw| dist += @popCount(aw ^ bw);
    return dist;
}

pub fn closureAfterIngest(text: []const u8) u128 {
    var engine = void_eng.VoidEngine.init(CANONICAL_SEED);
    engine.ingestTextSequence(SEED_INGEST, text, text.len * REPEAT_FACTOR);
    engine.shapeTextPressure(SEED_PRESSURE, text);
    return flame.closureError(&engine.state);
}

const Neighbor = struct {
    label: []const u8,
    distance: u32,
};

fn lessByDistance(_: void, a: Neighbor, b: Neighbor) bool {
    return a.distance < b.distance;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next();
    var message: ?[]const u8 = null;
    var dump_calibration = false;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--message=")) {
            message = arg["--message=".len..];
        } else if (std.mem.eql(u8, arg, "--dump-calibration")) {
            dump_calibration = true;
        }
    }

    const stdout = std.io.getStdOut().writer();

    // Compute calibration fingerprints
    var calib_fps: [CALIBRATION_PROMPTS.len]Fingerprint = undefined;
    var calib_closures: [CALIBRATION_PROMPTS.len]u128 = undefined;
    for (CALIBRATION_PROMPTS, 0..) |lp, i| {
        calib_fps[i] = fingerprintOf(lp.text);
        calib_closures[i] = closureAfterIngest(lp.text);
    }

    if (dump_calibration) {
        try stdout.print("=== Calibration table (post-ingestion chamber fingerprints, seed 0x{X}) ===\n", .{CANONICAL_SEED});
        try stdout.print("{s: <22} | popcount | closure              | fingerprint (64-bit words, low->high)\n", .{"label"});
        try stdout.print("-----------------------|----------|----------------------|----------------------------------\n", .{});
        for (CALIBRATION_PROMPTS, 0..) |lp, i| {
            var pc: u32 = 0;
            for (calib_fps[i]) |w| pc += @popCount(w);
            try stdout.print("{s: <22} | {d: >8} | {d: >20} |", .{ lp.label, pc, calib_closures[i] });
            for (calib_fps[i]) |w| try stdout.print(" {X:0>16}", .{w});
            try stdout.print("\n", .{});
        }
        try stdout.print("\n", .{});

        // Show inter-calibration Hamming distances so we can see if the
        // calibration set itself is well-separated.
        try stdout.print("=== Inter-calibration Hamming distance matrix ===\n", .{});
        try stdout.print("{s: <22} |", .{""});
        for (CALIBRATION_PROMPTS) |lp| try stdout.print(" {s: <5}", .{lp.label[0..@min(5, lp.label.len)]});
        try stdout.print("\n", .{});
        for (CALIBRATION_PROMPTS, 0..) |lp_i, i| {
            try stdout.print("{s: <22} |", .{lp_i.label});
            for (0..CALIBRATION_PROMPTS.len) |j| {
                try stdout.print(" {d: >5}", .{hammingDistance(calib_fps[i], calib_fps[j])});
            }
            try stdout.print("\n", .{});
        }
        try stdout.print("\n", .{});
    }

    const query = message orelse return;

    const query_fp = fingerprintOf(query);
    const query_closure = closureAfterIngest(query);

    var neighbors: [CALIBRATION_PROMPTS.len]Neighbor = undefined;
    for (CALIBRATION_PROMPTS, 0..) |lp, i| {
        neighbors[i] = .{ .label = lp.label, .distance = hammingDistance(query_fp, calib_fps[i]) };
    }
    std.sort.heap(Neighbor, &neighbors, {}, lessByDistance);

    try stdout.print("=== Query translation ===\n", .{});
    try stdout.print("Text: {s}\n", .{query});
    try stdout.print("Post-ingestion closure: {d}\n", .{query_closure});
    var qpc: u32 = 0;
    for (query_fp) |w| qpc += @popCount(w);
    try stdout.print("Fingerprint popcount: {d}/512\n\n", .{qpc});

    try stdout.print("Nearest calibration neighbors:\n", .{});
    for (neighbors, 0..) |n, rank| {
        const marker = if (rank == 0) " <-- VERDICT" else "";
        try stdout.print("  {d}. {s: <22}  distance={d: >3}/512{s}\n", .{ rank + 1, n.label, n.distance, marker });
    }

    const top_margin = neighbors[1].distance - neighbors[0].distance;
    const max_inter: u32 = blk: {
        var m: u32 = 0;
        for (0..CALIBRATION_PROMPTS.len) |i| for (i + 1..CALIBRATION_PROMPTS.len) |j| {
            const d = hammingDistance(calib_fps[i], calib_fps[j]);
            if (d > m) m = d;
        };
        break :blk m;
    };
    try stdout.print("\nMargin to runner-up: {d} bits (max inter-calibration distance is {d})\n", .{ top_margin, max_inter });
    try stdout.print("Confidence note: a margin of 0-2 bits is essentially a tie; >10 bits is decisive on this scale.\n", .{});
}

// --- Tests ---

test "fingerprint is deterministic for same text" {
    const a = fingerprintOf("hello world");
    const b = fingerprintOf("hello world");
    try std.testing.expectEqual(@as(u32, 0), hammingDistance(a, b));
}

test "different texts produce different fingerprints" {
    const a = fingerprintOf("hello world");
    const b = fingerprintOf("qzx vrnp khlb gjwm");
    try std.testing.expect(hammingDistance(a, b) > 0);
}

test "calibration prompts are not all collapsed onto one fingerprint" {
    // At least one pair of canonical prompts must produce different fingerprints
    var seen_diff = false;
    for (CALIBRATION_PROMPTS, 0..) |lp_i, i| {
        const fp_i = fingerprintOf(lp_i.text);
        for (i + 1..CALIBRATION_PROMPTS.len) |j| {
            const fp_j = fingerprintOf(CALIBRATION_PROMPTS[j].text);
            if (hammingDistance(fp_i, fp_j) > 0) {
                seen_diff = true;
                break;
            }
        }
        if (seen_diff) break;
    }
    try std.testing.expect(seen_diff);
}
