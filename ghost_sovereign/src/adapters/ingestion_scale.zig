const std = @import("std");
const absolute = @import("absolute_final");

const ConceptPair = struct { a: []const u8, b: []const u8 };
const IngestMode = enum { byte, semantic, trained, contextual };
const ReadoutMode = enum { edge, fingerprint };

const related_pairs = [_]ConceptPair{
    .{ .a = "gravity", .b = "mass" },       .{ .a = "star", .b = "planet" },
    .{ .a = "dog", .b = "animal" },         .{ .a = "red", .b = "color" },
    .{ .a = "fire", .b = "heat" },          .{ .a = "water", .b = "liquid" },
    .{ .a = "book", .b = "page" },          .{ .a = "sun", .b = "day" },
    .{ .a = "moon", .b = "night" },         .{ .a = "tree", .b = "forest" },
    .{ .a = "car", .b = "wheel" },          .{ .a = "apple", .b = "fruit" },
    .{ .a = "doctor", .b = "patient" },     .{ .a = "river", .b = "flow" },
    .{ .a = "bird", .b = "fly" },           .{ .a = "ocean", .b = "wave" },
    .{ .a = "mountain", .b = "peak" },      .{ .a = "snow", .b = "cold" },
    .{ .a = "music", .b = "song" },         .{ .a = "light", .b = "bulb" },
    .{ .a = "baby", .b = "child" },         .{ .a = "key", .b = "lock" },
    .{ .a = "bread", .b = "wheat" },        .{ .a = "horse", .b = "saddle" },
    .{ .a = "gun", .b = "bullet" },         .{ .a = "pen", .b = "write" },
    .{ .a = "bee", .b = "honey" },          .{ .a = "shoe", .b = "foot" },
    .{ .a = "door", .b = "room" },          .{ .a = "window", .b = "glass" },
    .{ .a = "clock", .b = "time" },         .{ .a = "map", .b = "direction" },
    .{ .a = "piano", .b = "music" },        .{ .a = "pencil", .b = "draw" },
    .{ .a = "rain", .b = "wet" },           .{ .a = "desert", .b = "sand" },
    .{ .a = "knife", .b = "cut" },          .{ .a = "table", .b = "chair" },
    .{ .a = "forest", .b = "leaf" },        .{ .a = "bear", .b = "cave" },
    .{ .a = "cow", .b = "milk" },           .{ .a = "chicken", .b = "egg" },
    .{ .a = "knee", .b = "leg" },           .{ .a = "ankle", .b = "foot" },
    .{ .a = "eye", .b = "vision" },         .{ .a = "ear", .b = "sound" },
    .{ .a = "nose", .b = "smell" },         .{ .a = "mouth", .b = "taste" },
    .{ .a = "hand", .b = "finger" },        .{ .a = "heart", .b = "blood" },
    .{ .a = "brain", .b = "thought" },      .{ .a = "lung", .b = "breath" },
    .{ .a = "stomach", .b = "food" },       .{ .a = "skin", .b = "touch" },
    .{ .a = "bone", .b = "skeleton" },      .{ .a = "tongue", .b = "lick" },
    .{ .a = "ship", .b = "sea" },           .{ .a = "engine", .b = "motor" },
    .{ .a = "cup", .b = "coffee" },         .{ .a = "spoon", .b = "soup" },
    .{ .a = "fork", .b = "pasta" },         .{ .a = "plate", .b = "dinner" },
    .{ .a = "pan", .b = "cook" },           .{ .a = "oven", .b = "bake" },
    .{ .a = "fridge", .b = "cold" },        .{ .a = "ice", .b = "freeze" },
    .{ .a = "smoke", .b = "fire" },         .{ .a = "ash", .b = "burn" },
    .{ .a = "candle", .b = "wax" },         .{ .a = "match", .b = "spark" },
    .{ .a = "hammer", .b = "nail" },        .{ .a = "saw", .b = "wood" },
    .{ .a = "drill", .b = "hole" },         .{ .a = "screw", .b = "twist" },
    .{ .a = "bolt", .b = "nut" },           .{ .a = "chain", .b = "link" },
    .{ .a = "rope", .b = "knot" },          .{ .a = "net", .b = "fish" },
    .{ .a = "hook", .b = "bait" },          .{ .a = "boat", .b = "row" },
    .{ .a = "sail", .b = "wind" },          .{ .a = "anchor", .b = "harbor" },
    .{ .a = "shore", .b = "beach" },        .{ .a = "cliff", .b = "fall" },
    .{ .a = "valley", .b = "low" },         .{ .a = "hill", .b = "climb" },
    .{ .a = "summit", .b = "top" },         .{ .a = "cave", .b = "dark" },
    .{ .a = "tunnel", .b = "underground" },
};

const overlap_pairs = [_]ConceptPair{
    .{ .a = "gravity", .b = "granite" }, .{ .a = "star", .b = "stare" },
    .{ .a = "star", .b = "starch" },     .{ .a = "car", .b = "card" },
    .{ .a = "car", .b = "carbon" },      .{ .a = "cat", .b = "cap" },
    .{ .a = "cat", .b = "cane" },        .{ .a = "cat", .b = "case" },
    .{ .a = "dog", .b = "does" },        .{ .a = "red", .b = "read" },
    .{ .a = "red", .b = "reed" },        .{ .a = "moon", .b = "mood" },
    .{ .a = "moon", .b = "moor" },       .{ .a = "tree", .b = "trek" },
    .{ .a = "tree", .b = "trend" },      .{ .a = "sun", .b = "sung" },
    .{ .a = "book", .b = "boot" },       .{ .a = "book", .b = "boost" },
    .{ .a = "fire", .b = "firm" },       .{ .a = "fire", .b = "first" },
    .{ .a = "water", .b = "wafer" },     .{ .a = "water", .b = "wager" },
    .{ .a = "bird", .b = "birch" },      .{ .a = "bird", .b = "birth" },
    .{ .a = "horse", .b = "horde" },     .{ .a = "horse", .b = "horror" },
    .{ .a = "pen", .b = "pet" },         .{ .a = "pen", .b = "pew" },
    .{ .a = "key", .b = "keg" },         .{ .a = "gun", .b = "gum" },
    .{ .a = "gun", .b = "gust" },        .{ .a = "bread", .b = "breed" },
    .{ .a = "bread", .b = "breath" },    .{ .a = "breath", .b = "breach" },
    .{ .a = "snow", .b = "snore" },      .{ .a = "snow", .b = "snob" },
    .{ .a = "glass", .b = "glade" },     .{ .a = "glass", .b = "gland" },
    .{ .a = "glass", .b = "glare" },     .{ .a = "light", .b = "litmus" },
    .{ .a = "rain", .b = "rang" },       .{ .a = "rain", .b = "rank" },
    .{ .a = "rain", .b = "range" },      .{ .a = "bear", .b = "beat" },
    .{ .a = "bear", .b = "bead" },       .{ .a = "bear", .b = "beak" },
    .{ .a = "knee", .b = "knew" },       .{ .a = "knife", .b = "knight" },
    .{ .a = "knife", .b = "knit" },      .{ .a = "mouth", .b = "mound" },
    .{ .a = "mouth", .b = "mourn" },     .{ .a = "nose", .b = "nosy" },
    .{ .a = "nose", .b = "nominal" },    .{ .a = "bone", .b = "bond" },
    .{ .a = "bone", .b = "bonus" },      .{ .a = "hair", .b = "haiku" },
    .{ .a = "hair", .b = "hail" },       .{ .a = "ship", .b = "shin" },
    .{ .a = "ship", .b = "shift" },      .{ .a = "ship", .b = "shirt" },
    .{ .a = "engine", .b = "engulf" },   .{ .a = "engine", .b = "engrave" },
    .{ .a = "bike", .b = "bilk" },       .{ .a = "bike", .b = "bind" },
    .{ .a = "map", .b = "mar" },         .{ .a = "map", .b = "mash" },
    .{ .a = "ski", .b = "skim" },        .{ .a = "ski", .b = "skin" },
    .{ .a = "ski", .b = "skill" },       .{ .a = "boat", .b = "boast" },
    .{ .a = "boat", .b = "boa" },        .{ .a = "hill", .b = "hilt" },
    .{ .a = "hill", .b = "hilum" },      .{ .a = "shore", .b = "shorn" },
    .{ .a = "shore", .b = "short" },     .{ .a = "candle", .b = "candor" },
    .{ .a = "candle", .b = "candy" },    .{ .a = "match", .b = "math" },
    .{ .a = "match", .b = "matte" },     .{ .a = "hammer", .b = "hamper" },
    .{ .a = "drill", .b = "drilling" },  .{ .a = "rope", .b = "rove" },
    .{ .a = "rope", .b = "rosy" },       .{ .a = "fork", .b = "form" },
    .{ .a = "fork", .b = "fort" },       .{ .a = "plate", .b = "plait" },
    .{ .a = "plate", .b = "plait" },
};

fn signatureAfterIngest(core: *absolute.AbsoluteCore, snapshot: []const u64, word: []const u8, mode: IngestMode, readout: ReadoutMode) u64 {
    @memcpy(core.field, snapshot);
    const report = switch (mode) {
        .byte => core.ingestMeasured(word),
        .semantic => core.ingestSemantic(word),
        .trained => core.ingestSemanticTrained(word),
        .contextual => core.ingestContextualized(word),
    };
    return switch (readout) {
        .edge => core.field[report.dominant_edge],
        .fingerprint => report.edge_fingerprint,
    };
}

fn hammingPairOnSnapshot(core: *absolute.AbsoluteCore, snapshot: []const u64, pair: ConceptPair, mode: IngestMode, readout: ReadoutMode) u8 {
    const sig_a = signatureAfterIngest(core, snapshot, pair.a, mode, readout);
    const sig_b = signatureAfterIngest(core, snapshot, pair.b, mode, readout);
    return @intCast(@popCount(sig_a ^ sig_b));
}

const Stats = struct { mean: f64, variance: f64 };

fn meanAndVar(samples: []const u8) Stats {
    if (samples.len == 0) return .{ .mean = 0, .variance = 0 };
    var sum: f64 = 0;
    for (samples) |s| sum += @floatFromInt(s);
    const mean = sum / @as(f64, @floatFromInt(samples.len));
    var sse: f64 = 0;
    for (samples) |s| {
        const d = @as(f64, @floatFromInt(s)) - mean;
        sse += d * d;
    }
    const variance = if (samples.len > 1)
        sse / @as(f64, @floatFromInt(samples.len - 1))
    else
        0;
    return .{ .mean = mean, .variance = variance };
}

fn erfApprox(x: f64) f64 {
    const a1: f64 = 0.254829592;
    const a2: f64 = -0.284496736;
    const a3: f64 = 1.421413741;
    const a4: f64 = -1.453152027;
    const a5: f64 = 1.061405429;
    const p: f64 = 0.3275911;
    const sign: f64 = if (x < 0.0) -1.0 else 1.0;
    const ax = @abs(x);
    const t = 1.0 / (1.0 + p * ax);
    const poly = ((((a5 * t + a4) * t) + a3) * t + a2) * t + a1;
    return sign * (1.0 - poly * t * @exp(-ax * ax));
}
fn normalCdf(z: f64) f64 {
    return 0.5 * (1.0 + erfApprox(z / @sqrt(@as(f64, 2.0))));
}

const BenchResult = struct {
    related_mean: f64,
    related_var: f64,
    overlap_mean: f64,
    overlap_var: f64,
    welch_t: f64,
    cohens_d: f64,
    p_one_tailed_R_lt_O: f64,
};

fn runBenchOnSnapshot(core: *absolute.AbsoluteCore, snapshot: []const u64, allocator: std.mem.Allocator, mode: IngestMode, readout: ReadoutMode) !BenchResult {
    var related_h = try allocator.alloc(u8, related_pairs.len);
    defer allocator.free(related_h);
    var overlap_h = try allocator.alloc(u8, overlap_pairs.len);
    defer allocator.free(overlap_h);

    for (related_pairs, 0..) |p, i| related_h[i] = hammingPairOnSnapshot(core, snapshot, p, mode, readout);
    for (overlap_pairs, 0..) |p, i| overlap_h[i] = hammingPairOnSnapshot(core, snapshot, p, mode, readout);

    const rs = meanAndVar(related_h);
    const os = meanAndVar(overlap_h);
    const n_r: f64 = @floatFromInt(related_pairs.len);
    const n_o: f64 = @floatFromInt(overlap_pairs.len);
    const se = @sqrt(rs.variance / n_r + os.variance / n_o);
    const t_stat = if (se > 0) (rs.mean - os.mean) / se else 0.0;
    const pooled_num = (n_r - 1.0) * rs.variance + (n_o - 1.0) * os.variance;
    const pooled_sd = @sqrt(pooled_num / (n_r + n_o - 2.0));
    const d = if (pooled_sd > 0) (rs.mean - os.mean) / pooled_sd else 0;
    return .{
        .related_mean = rs.mean,
        .related_var = rs.variance,
        .overlap_mean = os.mean,
        .overlap_var = os.variance,
        .welch_t = t_stat,
        .cohens_d = d,
        .p_one_tailed_R_lt_O = normalCdf(t_stat),
    };
}

fn parseCheckpoints(allocator: std.mem.Allocator, csv: []const u8) ![]usize {
    var list = std.ArrayList(usize).init(allocator);
    var it = std.mem.tokenizeAny(u8, csv, ", ");
    while (it.next()) |tok| try list.append(try std.fmt.parseInt(usize, tok, 10));
    return list.toOwnedSlice();
}

fn loadCorpusLines(allocator: std.mem.Allocator, path: []const u8, max_lines: usize) ![][]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    _ = try file.readAll(buf);
    var lines = std.ArrayList([]const u8).init(allocator);
    var it = std.mem.tokenizeScalar(u8, buf, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try lines.append(trimmed);
        if (lines.items.len >= max_lines) break;
    }
    return lines.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var corpus_path: ?[]const u8 = null;
    var state_path: []const u8 = "state/ingestion_scale.bin";
    var csv_path: []const u8 = "results/ingestion_scale.csv";
    var checkpoints_csv: []const u8 = "0,10,100,1000";
    var max_lines: usize = 1_000_000;
    var mode: IngestMode = .byte;
    var readout: ReadoutMode = .edge;
    var hv_path: []const u8 = absolute.AbsoluteCore.DefaultTrainedHvPath;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--corpus=")) corpus_path = arg["--corpus=".len..] else if (std.mem.startsWith(u8, arg, "--state=")) state_path = arg["--state=".len..] else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..] else if (std.mem.startsWith(u8, arg, "--checkpoints=")) checkpoints_csv = arg["--checkpoints=".len..] else if (std.mem.startsWith(u8, arg, "--max=")) max_lines = try std.fmt.parseInt(usize, arg["--max=".len..], 10) else if (std.mem.startsWith(u8, arg, "--hv=")) hv_path = arg["--hv=".len..] else if (std.mem.startsWith(u8, arg, "--readout=")) {
            const value = arg["--readout=".len..];
            if (std.mem.eql(u8, value, "edge")) readout = .edge else if (std.mem.eql(u8, value, "fingerprint")) readout = .fingerprint else return error.InvalidReadout;
        } else if (std.mem.eql(u8, arg, "--semantic")) mode = .semantic else if (std.mem.startsWith(u8, arg, "--mode=")) {
            const value = arg["--mode=".len..];
            if (std.mem.eql(u8, value, "byte")) mode = .byte else if (std.mem.eql(u8, value, "semantic")) mode = .semantic else if (std.mem.eql(u8, value, "trained")) mode = .trained else if (std.mem.eql(u8, value, "contextual")) mode = .contextual else return error.InvalidMode;
        }
    }

    const stdout = std.io.getStdOut().writer();
    if (corpus_path == null) {
        try stdout.writeAll("usage: ingestion_scale --corpus=PATH [--mode=byte|semantic|trained|contextual] [--readout=edge|fingerprint] [--hv=PATH] [--checkpoints=0,10,100,1000] [--max=N] [--csv=PATH] [--state=PATH]\n");
        try stdout.writeAll("\nReads newline-separated sentences. At each checkpoint N, ingests the first N\n");
        try stdout.writeAll("sentences, snapshots the manifold, runs the understanding_bench against the\n");
        try stdout.writeAll("snapshot, and emits one CSV row: corpus_size,related_mean,overlap_mean,cohens_d,p_one_tailed,welch_t.\n");
        return error.MissingCorpus;
    }

    const corpus = try loadCorpusLines(allocator, corpus_path.?, max_lines);
    defer allocator.free(corpus);
    const checkpoints = try parseCheckpoints(allocator, checkpoints_csv);
    defer allocator.free(checkpoints);

    try stdout.print("Corpus: {s} ({d} lines loaded)\n", .{ corpus_path.?, corpus.len });
    try stdout.print("Checkpoints: {any}\n", .{checkpoints});
    try stdout.print("Mode:   {s}\n", .{@tagName(mode)});
    try stdout.print("Readout:{s}\n", .{@tagName(readout)});
    try stdout.print("State:  {s}\n", .{state_path});
    try stdout.print("CSV:    {s}\n\n", .{csv_path});

    var core = try absolute.AbsoluteCore.initAt(state_path, 16 * 1024 * 1024);
    defer core.deinit();
    if (mode == .trained or mode == .contextual) {
        core.setTrainedHypervectorPath(hv_path);
        core.loadTrainedHypervectors();
        const info = core.trainedHypervectorInfo();
        try stdout.print("Trained HV: path={s} loaded={} mode={s} count={d} flags=0x{X} checksum=0x{X} expected=0x{X} checksum_ok={}\n\n", .{
            info.path,
            info.loaded,
            @tagName(info.mode),
            info.count,
            info.flags,
            info.checksum,
            info.expected_checksum,
            info.checksum_ok,
        });
    }
    const snapshot = try allocator.alloc(u64, core.field.len);
    defer allocator.free(snapshot);

    if (std.fs.path.dirname(csv_path)) |dir| {
        if (dir.len != 0) try std.fs.cwd().makePath(dir);
    }
    var csv_file = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv_file.close();
    var csv_w = csv_file.writer();
    try csv_w.writeAll("mode,readout,corpus_size,sentences_used,related_mean,overlap_mean,cohens_d,welch_t,p_one_tailed_R_lt_O\n");

    try stdout.writeAll("corpus_N | used | related_mean | overlap_mean | cohens_d | welch_t | p(R<O)  | semantic_wins?\n");
    try stdout.writeAll("---------|------|--------------|--------------|----------|---------|---------|----------------\n");

    for (checkpoints) |target_n| {
        const used = @min(target_n, corpus.len);
        core.reset();
        for (corpus[0..used]) |line| {
            switch (mode) {
                .byte => {
                    core.ingest(line);
                    core.ingest("\n");
                },
                .semantic => _ = core.ingestSemantic(line),
                .trained => _ = core.ingestSemanticTrained(line),
                .contextual => _ = core.ingestContextualized(line),
            }
        }
        @memcpy(snapshot, core.field);
        const result = try runBenchOnSnapshot(&core, snapshot, allocator, mode, readout);
        const semantic_wins = result.related_mean < result.overlap_mean and result.p_one_tailed_R_lt_O < 0.01;
        try stdout.print("{d: >8} | {d: >4} | {d: >12.4} | {d: >12.4} | {d: >8.4} | {d: >7.3} | {d: >7.5} | {s}\n", .{
            target_n,       used,                       result.related_mean,                result.overlap_mean, result.cohens_d,
            result.welch_t, result.p_one_tailed_R_lt_O, if (semantic_wins) "YES" else "no",
        });
        try csv_w.print("{s},{s},{d},{d},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6}\n", .{
            @tagName(mode), @tagName(readout),          target_n,            used,                result.related_mean, result.overlap_mean, result.cohens_d,
            result.welch_t, result.p_one_tailed_R_lt_O,
        });
    }

    try stdout.print("\nDone. CSV at {s}\n", .{csv_path});
}

test "snapshot restore is exact" {
    var core = try absolute.AbsoluteCore.initAt("state/ingestion_scale_test.bin", 16 * 1024 * 1024);
    defer core.deinit();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const snap = try allocator.alloc(u64, core.field.len);
    defer allocator.free(snap);

    core.reset();
    core.ingest("the quick brown fox jumps over the lazy dog");
    @memcpy(snap, core.field);

    core.ingest("contamination contamination contamination");
    var changed = false;
    for (core.field, snap) |word, saved| {
        if (word != saved) {
            changed = true;
            break;
        }
    }
    try std.testing.expect(changed);

    @memcpy(core.field, snap);
    for (core.field, snap) |word, saved| {
        try std.testing.expectEqual(saved, word);
    }
}
