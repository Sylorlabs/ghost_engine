const std = @import("std");

// --- TRAINED HYPERVECTOR SEMANTIC BENCH ---
//
// Direct follow-up to Mega Plan Track 5. Track 5 showed:
//   raw byte ingest       cohens_d = 1.92  (strong spelling bias)
//   random hypervector    cohens_d = 0.31  (spelling bias mostly removed)
//   target                cohens_d < 0     (semantic clustering wins)
//
// To push past 0, the hypervectors need to encode co-occurrence, not be
// freshly random per word. This binary implements Random Indexing — a
// well-known, decades-old technique for building distributional word
// vectors WITHOUT any neural network, gradient descent, or external
// model. It uses only co-occurrence counts from the corpus.
//
// Algorithm:
//   1. For each unique word in the corpus, generate a sparse random
//      "index vector" of width 1024 with ~K +1 bits and ~K -1 bits.
//   2. Walk the corpus with a sliding window. For each word w with
//      neighbors c_1..c_N in the window, accumulate:
//          context[w] += index_vector[c_1] + ... + index_vector[c_N]
//   3. After training, context[w] is a signed integer vector encoding
//      the co-occurrence neighborhood of w. The SIGN of each position
//      gives a binary fingerprint.
//   4. Hamming distance between the binary fingerprints of two words
//      reflects whether they appeared in similar contexts.
//
// Runtime boundary:
//   - std only (no VSA module — we hand-roll Random Indexing here)
//   - no Flame import
//   - no neural network, no gradient, no external model
//   - corpus is read from disk; nothing trained "from the cloud"
//
// Measured against the same 89 related + 87 overlap pairs as
// understanding_bench. If cohens_d goes below the random-HV baseline
// of 0.31, the trained encoding is doing real semantic work.

const HV_BITS = 1024;
const HV_WORDS = HV_BITS / 64;
const SPARSITY = 8; // K +1 bits and K -1 bits per index vector (total 2K = 16 nonzero of 1024)

const ConceptPair = struct { a: []const u8, b: []const u8 };

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

fn splitMix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn textHash(text: []const u8) u64 {
    var h: u64 = 0x811C9DC5;
    for (text) |b| h = (h ^ @as(u64, b)) *% 0x01000193;
    return h;
}

fn lowercaseInPlace(buf: []u8) void {
    for (buf) |*c| {
        if (c.* >= 'A' and c.* <= 'Z') c.* = c.* + 32;
    }
}

// --- Index vector: sparse ±1 vector for each word, stored as two
//     bitsets (positive bits, negative bits). 2*SPARSITY nonzeros total.
const IndexVec = struct {
    pos: [HV_WORDS]u64,
    neg: [HV_WORDS]u64,
};

fn makeIndexVec(word_hash: u64) IndexVec {
    var v = IndexVec{ .pos = [_]u64{0} ** HV_WORDS, .neg = [_]u64{0} ** HV_WORDS };
    var s = word_hash ^ 0xC0FFEEBABEF00D17;
    var placed: usize = 0;
    while (placed < SPARSITY) {
        s = splitMix64(s);
        const bit_idx = @as(usize, @intCast(s % HV_BITS));
        const mask = @as(u64, 1) << @intCast(bit_idx % 64);
        if ((v.pos[bit_idx / 64] & mask) == 0 and (v.neg[bit_idx / 64] & mask) == 0) {
            v.pos[bit_idx / 64] |= mask;
            placed += 1;
        }
    }
    placed = 0;
    while (placed < SPARSITY) {
        s = splitMix64(s);
        const bit_idx = @as(usize, @intCast(s % HV_BITS));
        const mask = @as(u64, 1) << @intCast(bit_idx % 64);
        if ((v.pos[bit_idx / 64] & mask) == 0 and (v.neg[bit_idx / 64] & mask) == 0) {
            v.neg[bit_idx / 64] |= mask;
            placed += 1;
        }
    }
    return v;
}

// Context vector: signed accumulator across all observed contexts.
const ContextVec = [HV_BITS]i32;

fn addIndexToContext(ctx: *ContextVec, idx: IndexVec) void {
    var w: usize = 0;
    while (w < HV_WORDS) : (w += 1) {
        var bit: u6 = 0;
        while (true) {
            const mask = @as(u64, 1) << bit;
            if ((idx.pos[w] & mask) != 0) ctx[w * 64 + bit] += 1;
            if ((idx.neg[w] & mask) != 0) ctx[w * 64 + bit] -= 1;
            if (bit == 63) break;
            bit += 1;
        }
    }
}

// Reduce signed context to a 1024-bit fingerprint: positive → 1, else → 0.
fn contextToFingerprint(ctx: ContextVec) [HV_WORDS]u64 {
    var fp: [HV_WORDS]u64 = [_]u64{0} ** HV_WORDS;
    var i: usize = 0;
    while (i < HV_BITS) : (i += 1) {
        if (ctx[i] > 0) fp[i / 64] |= (@as(u64, 1) << @intCast(i % 64));
    }
    return fp;
}

fn hammingFp(a: [HV_WORDS]u64, b: [HV_WORDS]u64) u32 {
    var d: u32 = 0;
    for (a, b) |aw, bw| d += @popCount(aw ^ bw);
    return d;
}

// --- Tokenizer: alphabetic-only, lowercase, length>=2 ---
fn nextToken(text: []const u8, pos: *usize, out_buf: []u8) ?[]u8 {
    while (pos.* < text.len) {
        const c = text[pos.*];
        const is_alpha = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
        if (is_alpha) break;
        pos.* += 1;
    }
    if (pos.* >= text.len) return null;
    var len: usize = 0;
    while (pos.* < text.len) {
        const c = text[pos.*];
        const is_alpha = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
        if (!is_alpha) break;
        if (len < out_buf.len) {
            out_buf[len] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            len += 1;
        }
        pos.* += 1;
    }
    if (len < 2) return nextToken(text, pos, out_buf);
    return out_buf[0..len];
}

const Stats = struct { mean: f64, variance: f64 };

fn meanAndVar(samples: []const u32) Stats {
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
fn normalCdf(z: f64) f64 { return 0.5 * (1.0 + erfApprox(z / @sqrt(@as(f64, 2.0)))); }

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var corpus_path: []const u8 = "corpus/curated_pairs.txt";
    var window: usize = 4;
    var max_lines: usize = 1_300_000;
    var csv_path: []const u8 = "results/trained_semantic_bench.csv";

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--corpus=")) corpus_path = arg["--corpus=".len..]
        else if (std.mem.startsWith(u8, arg, "--window=")) window = try std.fmt.parseInt(usize, arg["--window=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--max=")) max_lines = try std.fmt.parseInt(usize, arg["--max=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..];
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== TRAINED HYPERVECTOR SEMANTIC BENCH ===\n", .{});
    try stdout.print("corpus={s} window={d} max_lines={d}\n", .{ corpus_path, window, max_lines });
    try stdout.print("HV_BITS={d} SPARSITY={d}\n\n", .{ HV_BITS, SPARSITY });

    // Load corpus into a single buffer.
    const file = try std.fs.cwd().openFile(corpus_path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    defer allocator.free(buf);
    _ = try file.readAll(buf);
    try stdout.print("Corpus loaded: {d} bytes\n", .{stat.size});

    // First pass: tokenize line-by-line, build vocabulary and index vectors.
    var index_vecs = std.AutoHashMap(u64, IndexVec).init(allocator);
    defer index_vecs.deinit();
    var context_vecs = std.AutoHashMap(u64, ContextVec).init(allocator);
    defer context_vecs.deinit();

    const tok_buf = try allocator.alloc(u8, 64);
    defer allocator.free(tok_buf);

    // Walking: split on \n, tokenize each line, then accumulate context within
    // a sliding window inside that line.
    var line_count: usize = 0;
    var token_count: usize = 0;
    var line_iter = std.mem.splitScalar(u8, buf, '\n');
    while (line_iter.next()) |line_raw| {
        if (line_count >= max_lines) break;
        line_count += 1;
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        var tokens_in_line = std.ArrayList(u64).init(allocator);
        defer tokens_in_line.deinit();

        var pos: usize = 0;
        while (nextToken(line, &pos, tok_buf)) |tok| {
            const h = textHash(tok);
            if (!index_vecs.contains(h)) {
                try index_vecs.put(h, makeIndexVec(h));
                try context_vecs.put(h, [_]i32{0} ** HV_BITS);
            }
            try tokens_in_line.append(h);
            token_count += 1;
        }

        // Accumulate context: for each position i, add neighbors' index vecs.
        const ts = tokens_in_line.items;
        for (ts, 0..) |center_h, i| {
            const ctx_ptr = context_vecs.getPtr(center_h).?;
            const start = if (i >= window) i - window else 0;
            const end = @min(ts.len, i + window + 1);
            var j: usize = start;
            while (j < end) : (j += 1) {
                if (j == i) continue;
                const neighbor_h = ts[j];
                const idx_v = index_vecs.get(neighbor_h).?;
                addIndexToContext(ctx_ptr, idx_v);
            }
        }
    }

    try stdout.print("Trained on {d} lines, {d} tokens, vocabulary size: {d}\n\n", .{
        line_count, token_count, index_vecs.count(),
    });

    // Measure: for each pair, compute Hamming on context fingerprints.
    var related_h = try allocator.alloc(u32, related_pairs.len);
    defer allocator.free(related_h);
    var overlap_h = try allocator.alloc(u32, overlap_pairs.len);
    defer allocator.free(overlap_h);

    var missing_count: usize = 0;
    for (related_pairs, 0..) |p, i| {
        const ha = textHash(p.a);
        const hb = textHash(p.b);
        const ca = context_vecs.get(ha) orelse {
            missing_count += 1;
            related_h[i] = HV_BITS / 2;
            continue;
        };
        const cb = context_vecs.get(hb) orelse {
            missing_count += 1;
            related_h[i] = HV_BITS / 2;
            continue;
        };
        related_h[i] = hammingFp(contextToFingerprint(ca), contextToFingerprint(cb));
    }
    for (overlap_pairs, 0..) |p, i| {
        const ha = textHash(p.a);
        const hb = textHash(p.b);
        const ca = context_vecs.get(ha) orelse {
            missing_count += 1;
            overlap_h[i] = HV_BITS / 2;
            continue;
        };
        const cb = context_vecs.get(hb) orelse {
            missing_count += 1;
            overlap_h[i] = HV_BITS / 2;
            continue;
        };
        overlap_h[i] = hammingFp(contextToFingerprint(ca), contextToFingerprint(cb));
    }

    if (missing_count > 0) {
        try stdout.print("WARNING: {d} pair endpoints not in vocabulary (counted as midpoint distance)\n\n", .{missing_count});
    }

    const rs = meanAndVar(related_h);
    const os = meanAndVar(overlap_h);
    const n_r: f64 = @floatFromInt(related_pairs.len);
    const n_o: f64 = @floatFromInt(overlap_pairs.len);
    const se = @sqrt(rs.variance / n_r + os.variance / n_o);
    const t_stat = if (se > 0) (rs.mean - os.mean) / se else 0.0;
    const pooled_num = (n_r - 1.0) * rs.variance + (n_o - 1.0) * os.variance;
    const pooled_sd = @sqrt(pooled_num / (n_r + n_o - 2.0));
    const cohens_d = if (pooled_sd > 0) (rs.mean - os.mean) / pooled_sd else 0;
    const p_R_lt_O = normalCdf(t_stat);

    try stdout.print("related_pairs:           {d}\n", .{related_pairs.len});
    try stdout.print("overlap_pairs:           {d}\n", .{overlap_pairs.len});
    try stdout.print("related_mean_hamming:    {d:.4} (of {d})\n", .{ rs.mean, HV_BITS });
    try stdout.print("related_variance:        {d:.4}\n", .{rs.variance});
    try stdout.print("overlap_mean_hamming:    {d:.4} (of {d})\n", .{ os.mean, HV_BITS });
    try stdout.print("overlap_variance:        {d:.4}\n", .{os.variance});
    try stdout.print("welch_t:                 {d:.4}\n", .{t_stat});
    try stdout.print("cohens_d (R - O / sd):   {d:.4}\n", .{cohens_d});
    try stdout.print("p(R<O) one-tailed:       {d:.6}\n\n", .{p_R_lt_O});

    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var csv = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer csv.close();
    try csv.writer().writeAll("class,a,b,hamming\n");
    for (related_pairs, 0..) |p, i| try csv.writer().print("related,{s},{s},{d}\n", .{ p.a, p.b, related_h[i] });
    for (overlap_pairs, 0..) |p, i| try csv.writer().print("overlap,{s},{s},{d}\n", .{ p.a, p.b, overlap_h[i] });

    try stdout.writeAll("--- COMPARISON ---\n");
    try stdout.writeAll("byte ingest (Track 5 baseline):     cohens_d ≈ 1.92  (massive spelling wins)\n");
    try stdout.writeAll("random HV (Track 5 semantic mode):  cohens_d ≈ 0.31  (spelling bias reduced)\n");
    try stdout.print("trained HV (this run):              cohens_d = {d:.4}\n\n", .{cohens_d});

    if (cohens_d < -0.1 and p_R_lt_O < 0.05) {
        try stdout.writeAll("BREAKTHROUGH: Cohen's d is significantly NEGATIVE — related word pairs are\n");
        try stdout.writeAll("closer to each other in trained-HV space than spelling-overlap pairs.\n");
        try stdout.writeAll("Semantic clustering wins. The trained-HV bridge is the architectural fix.\n");
    } else if (cohens_d < 0.31 - 0.1) {
        try stdout.writeAll("PARTIAL: trained HVs reduced spelling bias below random-HV baseline\n");
        try stdout.writeAll("but did not flip sign. Distributional encoding is doing real work but\n");
        try stdout.writeAll("not enough to win on this benchmark.\n");
    } else {
        try stdout.writeAll("NO IMPROVEMENT: trained HVs did not beat random-HV baseline. Random\n");
        try stdout.writeAll("Indexing with this corpus and window is insufficient. Larger window,\n");
        try stdout.writeAll("better corpus, or different encoding (e.g. PPMI-weighted) would be needed.\n");
    }
    try stdout.print("\nCSV: {s}\n", .{csv_path});
}