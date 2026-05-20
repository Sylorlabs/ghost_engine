const std = @import("std");

const HV_BITS = 1024;
const HV_WORDS = HV_BITS / 64;
const SPARSITY = 8; // K +1 bits and K -1 bits per index vector (total 2K = 16 nonzero of 1024)

fn splitMix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

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

fn contextToFingerprint(ctx: ContextVec) [HV_WORDS]u64 {
    var fp: [HV_WORDS]u64 = [_]u64{0} ** HV_WORDS;
    var i: usize = 0;
    while (i < HV_BITS) : (i += 1) {
        if (ctx[i] > 0) fp[i / 64] |= (@as(u64, 1) << @intCast(i % 64));
    }
    return fp;
}

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

fn absoluteHashWord(word: []const u8) u64 {
    var h: u64 = 0xCBF29CE484222325;
    for (word) |b| {
        h ^= @as(u64, b);
        h *%= 0x100000001B3;
    }
    return h;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var corpus_path: []const u8 = "corpus/curated_pairs.txt";
    var out_path: []const u8 = "state/trained_hv.bin";
    var window: usize = 4;
    var max_lines: usize = 1_300_000;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--corpus=")) corpus_path = arg["--corpus=".len..]
        else if (std.mem.startsWith(u8, arg, "--out=")) out_path = arg["--out=".len..]
        else if (std.mem.startsWith(u8, arg, "--window=")) window = try std.fmt.parseInt(usize, arg["--window=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--max=")) max_lines = try std.fmt.parseInt(usize, arg["--max=".len..], 10);
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== TRAIN HYPERVECTORS ===\n", .{});
    try stdout.print("corpus={s} window={d} max_lines={d} out={s}\n", .{ corpus_path, window, max_lines, out_path });

    const file = try std.fs.cwd().openFile(corpus_path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    defer allocator.free(buf);
    _ = try file.readAll(buf);
    try stdout.print("Corpus loaded: {d} bytes\n", .{stat.size});

    var index_vecs = std.AutoHashMap(u64, IndexVec).init(allocator);
    defer index_vecs.deinit();
    var context_vecs = std.AutoHashMap(u64, ContextVec).init(allocator);
    defer context_vecs.deinit();

    const tok_buf = try allocator.alloc(u8, 64);
    defer allocator.free(tok_buf);

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
            const h = absoluteHashWord(tok);
            if (!index_vecs.contains(h)) {
                try index_vecs.put(h, makeIndexVec(h));
                try context_vecs.put(h, [_]i32{0} ** HV_BITS);
            }
            try tokens_in_line.append(h);
            token_count += 1;
        }

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

    try stdout.print("Trained on {d} lines, {d} tokens, vocabulary size: {d}\n", .{
        line_count, token_count, index_vecs.count(),
    });

    if (std.fs.path.dirname(out_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var out_file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out_file.close();
    var out_writer = out_file.writer();
    
    var out_count: usize = 0;
    var it = context_vecs.iterator();
    while (it.next()) |entry| {
        const hash = entry.key_ptr.*;
        const fp = contextToFingerprint(entry.value_ptr.*);
        try out_writer.writeInt(u64, hash, .little);
        for (fp) |w| {
            try out_writer.writeInt(u64, w, .little);
        }
        out_count += 1;
    }
    
    try stdout.print("Saved {d} hypervectors to {s}\n", .{ out_count, out_path });
}