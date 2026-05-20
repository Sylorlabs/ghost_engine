const std = @import("std");
const void_eng = @import("void");
const flame = @import("flame");
const vsa = @import("vsa");
const manifold = @import("manifold");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var args = try std.process.argsWithAllocator(aa);
    defer args.deinit();
    _ = args.next();
    var message: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--message=")) {
            message = arg["--message=".len..];
        }
    }
    const question = message orelse
        "Should we ingest 1 million English sentences into the reservoir so that it actually learns English?";

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n=== PROPER CONSULTATION ===\n", .{});
    try stdout.print("Question: {s}\n\n", .{question});

    // --- Void engine: ingest question, then invent ---
    const base_seed: u64 = 0x145F2EA61D0202D9;
    var any_candidate = false;
    var best_delta: i128 = 0;
    var best_mark: u64 = 0;
    var best_scar: u64 = 0;
    var best_before: u128 = 0;
    var best_after: u128 = 0;

    try stdout.print("--- Void inversion (question INGESTED first) ---\n", .{});
    for (0..6) |trial| {
        var engine = void_eng.VoidEngine.init(base_seed ^ trial);
        const seed_ingest = void_eng.splitMix64(base_seed ^ trial ^ 0xA11CE);
        engine.ingestTextSequence(seed_ingest, question, question.len * 4);
        engine.shapeTextPressure(seed_ingest ^ 0xBEEF, question);
        const closure_before = flame.closureError(&engine.state);

        if (engine.maybeInventText(question, @intCast(trial + 1))) |cand| {
            any_candidate = true;
            try stdout.print(
                "  trial {d}: closure {d} -> {d}  delta {d}  mark 0x{X}  scar 0x{X}\n",
                .{ trial, cand.closure_before, cand.closure_after, cand.closure_delta, cand.child_mark, cand.scar },
            );
            if (cand.closure_delta < best_delta or best_mark == 0) {
                best_delta = cand.closure_delta;
                best_mark = cand.child_mark;
                best_scar = cand.scar;
                best_before = cand.closure_before;
                best_after = cand.closure_after;
            }
        } else {
            try stdout.print("  trial {d}: NULL  (control closure was {d}, no branch hit 99% drop)\n", .{ trial, closure_before });
        }
    }

    try stdout.print("\n", .{});
    if (any_candidate) {
        try stdout.print(
            "VERDICT: closure {d} -> {d}  (delta {d})  mark 0x{X}  scar 0x{X}\n",
            .{ best_before, best_after, best_delta, best_mark, best_scar },
        );
    } else {
        try stdout.print("VERDICT: null. Across 6 ingested trials no branch achieved 99% closure drop.\n", .{});
    }

    // --- Aetheric: full per-concept resonance vector, not just argmax ---
    try stdout.print("\n--- Aetheric resonance (full 20-concept vector) ---\n", .{});
    var aeth = try AethericProbe.init(aa);
    defer aeth.deinit();
    try aeth.ingest(question);
    try aeth.dumpResonance(stdout);
}

const AethericProbe = struct {
    voxels: manifold.Manifold,
    vsa_dict: std.AutoHashMap(u64, vsa.Hypervector),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !AethericProbe {
        var self = AethericProbe{
            .voxels = try manifold.Manifold.init(allocator),
            .vsa_dict = std.AutoHashMap(u64, vsa.Hypervector).init(allocator),
            .allocator = allocator,
        };
        inline for (std.meta.fields(vsa.Concept)) |f| {
            const c = @as(vsa.Concept, @enumFromInt(f.value));
            const hv = vsa.getConceptHV(c);
            const anchor_coord = @as(u64, f.value) * 100;
            for (hv.data, 0..) |word_bits, word_idx| {
                self.voxels.add(anchor_coord + word_idx, @as(i128, @intCast(word_bits)));
            }
        }
        return self;
    }

    fn deinit(self: *AethericProbe) void {
        self.voxels.deinit();
        self.vsa_dict.deinit();
    }

    fn ingest(self: *AethericProbe, text: []const u8) !void {
        var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
        while (it.next()) |word| {
            const h = void_eng.textHash(word);
            const g = try self.vsa_dict.getOrPut(h);
            if (!g.found_existing) g.value_ptr.* = vsa.Hypervector.initRandom(h);
            const hv = g.value_ptr.*;
            for (hv.data, 0..) |word_bits, word_idx| {
                const coord = (h ^ word_idx) % manifold.VoxelCount;
                self.voxels.add(coord, @as(i128, @intCast(word_bits)) ^ @as(i128, @intCast(h % 500)));
            }
        }
    }

    fn dumpResonance(self: *AethericProbe, writer: anytype) !void {
        var max_abs: i128 = 0;
        var best_name: []const u8 = "?";

        inline for (std.meta.fields(vsa.Concept)) |f| {
            const anchor_coord = @as(u64, f.value) * 100;
            var resonance: i128 = 0;
            var word_idx: usize = 0;
            while (word_idx < vsa.WordCount) : (word_idx += 1) {
                resonance = resonance +% self.voxels.get(anchor_coord + word_idx);
            }
            try writer.print("  {s: <10} = {d}\n", .{ f.name, resonance });
            if (@abs(resonance) > @abs(max_abs)) {
                max_abs = resonance;
                best_name = f.name;
            }
        }
        try writer.print("  ARGMAX: {s}\n", .{best_name});
    }
};
