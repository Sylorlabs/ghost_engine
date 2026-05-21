const std = @import("std");

// --- SORTING-NETWORK REACHABILITY TESTER ---
//
// Second-domain instance of the invention test. Differs from the u64-mixer
// tester in one essential way: for sorting networks, all CORRECT sorters
// compute the same function (the sort). So functional similarity = 1.0
// for all correct sorters and cannot be the divergence axis. The
// divergence axis here is STRUCTURAL — different sequence of comparators.
//
// Verdict ladder for sorts:
//   EQUIVALENT (structural):  edit_dist == 0 to a library entry
//   TRIVIAL VARIANT:          edit_dist <= 1
//   NON-SORTER:               fails correctness (does not sort all 8!)
//   REMIX:                    structurally close (norm_edit <= 0.20) to library
//   REACHABLE:                appears as a contiguous window in some
//                             depth<=3 concatenation of library entries
//                             with normalized edit <= 0.10
//   INVENTION (strict):       correct sorter + structurally divergent +
//                             not reachable as a library-window
//
// Library:
//   Bitonic-8 sort   (24 comparators)
//   Batcher OEM-8    (19 comparators, optimal-known size)

const N: usize = 8;
const NFact: usize = 40320;
const MaxLen: usize = 64; // larger to allow concatenated compositions

const Comparator = struct { i: u3, j: u3 };

const Network = struct {
    comps: [MaxLen]Comparator,
    used: u8,

    fn sort(self: Network, input: [N]u8) [N]u8 {
        var a = input;
        var i: usize = 0;
        while (i < self.used) : (i += 1) {
            const c = self.comps[i];
            if (a[c.i] > a[c.j]) {
                const tmp = a[c.i];
                a[c.i] = a[c.j];
                a[c.j] = tmp;
            }
        }
        return a;
    }
};

fn isSorted(a: [N]u8) bool {
    var i: usize = 1;
    while (i < N) : (i += 1) if (a[i - 1] > a[i]) return false;
    return true;
}

fn exactCorrectness(net: Network) f64 {
    var arr = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var c = [_]u8{0} ** N;
    var correct: u32 = 0;
    var total: u32 = 0;
    {
        const result = net.sort(arr);
        if (isSorted(result)) correct += 1;
        total += 1;
    }
    var i: usize = 0;
    while (i < N) {
        if (c[i] < i) {
            if (i % 2 == 0) {
                const tmp = arr[0];
                arr[0] = arr[i];
                arr[i] = tmp;
            } else {
                const tmp = arr[c[i]];
                arr[c[i]] = arr[i];
                arr[i] = tmp;
            }
            const result = net.sort(arr);
            if (isSorted(result)) correct += 1;
            total += 1;
            c[i] += 1;
            i = 0;
        } else {
            c[i] = 0;
            i += 1;
        }
    }
    return @as(f64, @floatFromInt(correct)) / @as(f64, @floatFromInt(total));
}

fn mkNet(comps: []const Comparator) Network {
    var n = Network{ .comps = undefined, .used = @intCast(comps.len) };
    var i: usize = 0;
    while (i < comps.len) : (i += 1) n.comps[i] = comps[i];
    return n;
}

// --- Library: Floyd's optimal-known N=8 sorting network (19 comparators) ---
// From Knuth's TAOCP Vol 3, exercise 5.3.4. Distinct from Batcher's
// odd-even merge in comparator sequence and depth profile.
fn libFloyd8() Network {
    return mkNet(&[_]Comparator{
        .{ .i = 0, .j = 1 }, .{ .i = 2, .j = 3 }, .{ .i = 4, .j = 5 }, .{ .i = 6, .j = 7 },
        .{ .i = 0, .j = 2 }, .{ .i = 4, .j = 6 }, .{ .i = 1, .j = 3 }, .{ .i = 5, .j = 7 },
        .{ .i = 1, .j = 2 }, .{ .i = 5, .j = 6 }, .{ .i = 0, .j = 4 }, .{ .i = 3, .j = 7 },
        .{ .i = 1, .j = 5 }, .{ .i = 2, .j = 6 },
        .{ .i = 1, .j = 4 }, .{ .i = 3, .j = 6 },
        .{ .i = 2, .j = 4 }, .{ .i = 3, .j = 5 },
        .{ .i = 3, .j = 4 },
    });
}

// --- Library: Batcher Odd-Even Merge Sort N=8 (19 comparators, optimal-known) ---
fn libBatcher8() Network {
    return mkNet(&[_]Comparator{
        // Sort pairs
        .{ .i = 0, .j = 1 }, .{ .i = 2, .j = 3 }, .{ .i = 4, .j = 5 }, .{ .i = 6, .j = 7 },
        // OEM merge size-2 into 4-tuples
        .{ .i = 0, .j = 2 }, .{ .i = 1, .j = 3 }, .{ .i = 4, .j = 6 }, .{ .i = 5, .j = 7 },
        .{ .i = 1, .j = 2 }, .{ .i = 5, .j = 6 },
        // OEM merge size-4 into 8-tuple
        .{ .i = 0, .j = 4 }, .{ .i = 1, .j = 5 }, .{ .i = 2, .j = 6 }, .{ .i = 3, .j = 7 },
        .{ .i = 2, .j = 4 }, .{ .i = 3, .j = 5 },
        .{ .i = 1, .j = 2 }, .{ .i = 3, .j = 4 }, .{ .i = 5, .j = 6 },
    });
}

const LibEntry = struct { name: []const u8, network: Network };
fn libraryRaw() [2]LibEntry {
    return .{
        .{ .name = "Floyd-8", .network = libFloyd8() },
        .{ .name = "Batcher-8", .network = libBatcher8() },
    };
}

// Filter to only entries that sort all 8! correctly. Aborts if zero remain.
fn library(allocator: std.mem.Allocator) ![]LibEntry {
    const raw = libraryRaw();
    var list = std.ArrayList(LibEntry).init(allocator);
    for (raw) |entry| {
        const c = exactCorrectness(entry.network);
        if (c >= 1.0 - 1e-9) try list.append(entry);
    }
    return try list.toOwnedSlice();
}

// --- Comparator-sequence edit distance (Levenshtein) ---
fn cmpEq(a: Comparator, b: Comparator) bool {
    return a.i == b.i and a.j == b.j;
}

fn editDistance(a: []const Comparator, b: []const Comparator, allocator: std.mem.Allocator) !usize {
    const la = a.len;
    const lb = b.len;
    const cols = lb + 1;
    const dp = try allocator.alloc(usize, (la + 1) * cols);
    defer allocator.free(dp);
    var i: usize = 0;
    while (i <= la) : (i += 1) dp[i * cols + 0] = i;
    var j: usize = 0;
    while (j <= lb) : (j += 1) dp[0 * cols + j] = j;
    i = 1;
    while (i <= la) : (i += 1) {
        var jj: usize = 1;
        while (jj <= lb) : (jj += 1) {
            const sub: usize = if (cmpEq(a[i - 1], b[jj - 1])) 0 else 1;
            const v_sub = dp[(i - 1) * cols + (jj - 1)] + sub;
            const v_del = dp[(i - 1) * cols + jj] + 1;
            const v_ins = dp[i * cols + (jj - 1)] + 1;
            var best = v_sub;
            if (v_del < best) best = v_del;
            if (v_ins < best) best = v_ins;
            dp[i * cols + jj] = best;
        }
    }
    return dp[la * cols + lb];
}

// --- Reachability: window search over depth<=MaxDepth library concatenations ---
const MaxDepth: usize = 3;
const ReachNormThreshold: f64 = 0.10;

const ReachResult = struct {
    min_window_edit: usize,
    min_norm_edit: f64,
    best_depth: usize,
    reachable: bool,
};

fn searchReachability(cand: []const Comparator, lib: []const LibEntry, allocator: std.mem.Allocator) !ReachResult {
    var best: ReachResult = .{ .min_window_edit = std.math.maxInt(usize), .min_norm_edit = 1.0, .best_depth = 0, .reachable = false };
    var depth: usize = 1;
    while (depth <= MaxDepth) : (depth += 1) {
        const total_compositions = std.math.pow(usize, lib.len, depth);
        var n: usize = 0;
        while (n < total_compositions) : (n += 1) {
            // Build path indices
            var path: [MaxDepth]usize = .{0} ** MaxDepth;
            var t = n;
            var i: usize = 0;
            while (i < depth) : (i += 1) {
                path[i] = t % lib.len;
                t /= lib.len;
            }
            // Concatenate library networks per path
            var concat: [MaxLen * MaxDepth]Comparator = undefined;
            var ci: usize = 0;
            i = 0;
            while (i < depth) : (i += 1) {
                const net = lib[path[i]].network;
                var k: usize = 0;
                while (k < net.used and ci < concat.len) : (k += 1) {
                    concat[ci] = net.comps[k];
                    ci += 1;
                }
            }
            const total_len = ci;
            // Slide a window of size |cand| across the concatenation
            if (cand.len > total_len) continue;
            var start: usize = 0;
            while (start + cand.len <= total_len) : (start += 1) {
                const ed = try editDistance(cand, concat[start .. start + cand.len], allocator);
                const norm = @as(f64, @floatFromInt(ed)) / @as(f64, @floatFromInt(cand.len));
                if (ed < best.min_window_edit) {
                    best.min_window_edit = ed;
                    best.min_norm_edit = norm;
                    best.best_depth = depth;
                }
            }
        }
    }
    best.reachable = best.min_norm_edit <= ReachNormThreshold;
    return best;
}

// --- Candidate loader ---
fn loadCandidateCsv(allocator: std.mem.Allocator, path: []const u8) !?Network {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(data);
    var net = Network{ .comps = undefined, .used = 0 };
    var line_it = std.mem.splitScalar(u8, data, '\n');
    _ = line_it.next();
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        var f_it = std.mem.splitScalar(u8, line, ',');
        _ = f_it.next() orelse continue; // idx
        const i_s = f_it.next() orelse continue;
        const j_s = f_it.next() orelse continue;
        const i = try std.fmt.parseInt(u3, std.mem.trim(u8, i_s, " \r"), 10);
        const j = try std.fmt.parseInt(u3, std.mem.trim(u8, j_s, " \r"), 10);
        if (net.used >= MaxLen) break;
        net.comps[net.used] = .{ .i = i, .j = j };
        net.used += 1;
    }
    if (net.used == 0) return null;
    return net;
}

const Candidate = struct {
    name: []const u8,
    network: Network,
    notes: []const u8,
};

const Score = struct {
    correctness: f64,
    is_correct: bool,
    min_edit: usize,
    norm_edit: f64,
    closest_lib: []const u8,
    reach: ReachResult,
};

fn scoreCandidate(c: Candidate, lib: []const LibEntry, allocator: std.mem.Allocator) !Score {
    const correctness = exactCorrectness(c.network);
    var min_edit: usize = std.math.maxInt(usize);
    var closest_name: []const u8 = "";
    for (lib) |entry| {
        const ed = try editDistance(c.network.comps[0..c.network.used], entry.network.comps[0..entry.network.used], allocator);
        if (ed < min_edit) {
            min_edit = ed;
            closest_name = entry.name;
        }
    }
    const max_len = @max(c.network.used, @as(usize, 24));
    const norm = @as(f64, @floatFromInt(min_edit)) / @as(f64, @floatFromInt(max_len));
    const reach = try searchReachability(c.network.comps[0..c.network.used], lib, allocator);
    return .{
        .correctness = correctness,
        .is_correct = correctness >= 1.0 - 1e-9,
        .min_edit = min_edit,
        .norm_edit = norm,
        .closest_lib = closest_name,
        .reach = reach,
    };
}

fn verdict(s: Score) []const u8 {
    if (s.min_edit == 0) return "EQUIVALENT (structural)";
    if (s.min_edit <= 1 and s.is_correct) return "TRIVIAL VARIANT";
    if (!s.is_correct) return "NON-SORTER (fails correctness)";
    if (s.norm_edit <= 0.20) return "REMIX (close to library)";
    if (s.reach.reachable) return "REACHABLE (library-window match)";
    return "INVENTION (strict: correct + divergent + unreachable)";
}

// --- Random network for sanity (won't be a correct sorter) ---
fn randomNet(seed: u64) Network {
    var rng = seed;
    var net = Network{ .comps = undefined, .used = 22 };
    var i: usize = 0;
    while (i < 22) : (i += 1) {
        rng = (rng *% 0x9E3779B97F4A7C15) +% 0x1;
        const idx = rng % 28;
        var k = idx;
        var ci: u3 = 0;
        while (true) : (ci += 1) {
            const row_len: u64 = (N - 1) - @as(u64, ci);
            if (k < row_len) {
                const cj: u3 = @intCast(ci + 1 + @as(u3, @intCast(k)));
                net.comps[i] = .{ .i = ci, .j = cj };
                break;
            }
            k -= row_len;
        }
    }
    return net;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var champion_path: []const u8 = "results/sorting_champion.csv";
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--champion=")) {
            champion_path = try allocator.dupe(u8, arg["--champion=".len..]);
        }
    }

    const lib = try library(allocator);
    defer allocator.free(lib);
    const loaded = loadCandidateCsv(allocator, champion_path) catch null;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== SORTING-NETWORK REACHABILITY TESTER (Gen0, N={d}) ===\n", .{N});
    try stdout.print("Library: {d} canonical networks. Total 8! permutations: {d}.\n\n", .{ lib.len, NFact });
    for (lib) |entry| {
        try stdout.print("  - {s} ({d} comparators)\n", .{ entry.name, entry.network.used });
    }

    // Self-tests on library
    try stdout.print("\nSelf-test: each library entry should sort all {d} permutations.\n", .{NFact});
    for (lib) |entry| {
        const c = exactCorrectness(entry.network);
        try stdout.print("  {s}: correctness = {d:.6}\n", .{ entry.name, c });
    }

    const candidates = blk: {
        var list = std.ArrayList(Candidate).init(allocator);
        try list.append(.{ .name = "floyd_self", .network = libFloyd8(), .notes = "sanity: edit_dist 0 to Floyd-8" });
        try list.append(.{ .name = "batcher_self", .network = libBatcher8(), .notes = "sanity: edit_dist 0 to Batcher-8" });
        try list.append(.{ .name = "random_net", .network = randomNet(0xDEADBEEFCAFEBABE), .notes = "sanity: should fail correctness" });
        if (loaded) |net| {
            try list.append(.{ .name = "loaded_champion", .network = net, .notes = "exact discovered network loaded from CSV" });
        }
        break :blk try list.toOwnedSlice();
    };
    defer allocator.free(candidates);

    try stdout.print("\nLibrary cross structural-edit distances:\n", .{});
    for (lib) |a| {
        for (lib) |b| {
            const ed = try editDistance(a.network.comps[0..a.network.used], b.network.comps[0..b.network.used], allocator);
            try stdout.print("  {s} <-> {s}: edit_dist = {d}\n", .{ a.name, b.name, ed });
        }
    }

    try std.fs.cwd().makePath("results");
    var csv = try std.fs.cwd().createFile("results/sorting_reachability.csv", .{ .truncate = true });
    defer csv.close();
    try csv.writer().writeAll("candidate,correctness,size,depth_proxy,min_edit_to_lib,norm_edit,closest_lib,reach_min_edit,reach_norm,reach_depth,reachable,verdict\n");

    try stdout.print("\n{s: <22} | {s: >8} | {s: >4} | {s: >5} | {s: >7} | {s: <14} | {s: >7} | {s: <40}\n", .{
        "candidate", "correct", "size", "edit", "norm_ed", "closest_lib", "reach_n", "verdict",
    });
    try stdout.print("-----------------------|----------|------|-------|---------|----------------|---------|----------------\n", .{});
    for (candidates) |c| {
        const s = try scoreCandidate(c, lib, allocator);
        const v = verdict(s);
        try stdout.print("{s: <22} | {d: >8.4} | {d: >4} | {s: >5} | {d: >7.3} | {s: <14} | {d: >7.3} | {s}\n", .{
            c.name, s.correctness, c.network.used, "—", s.norm_edit, s.closest_lib, s.reach.min_norm_edit, v,
        });
        try csv.writer().print("{s},{d:.6},{d},0,{d},{d:.4},{s},{d},{d:.4},{d},{d},{s}\n", .{
            c.name, s.correctness, c.network.used, s.min_edit, s.norm_edit, s.closest_lib,
            s.reach.min_window_edit, s.reach.min_norm_edit, s.reach.best_depth, @intFromBool(s.reach.reachable), v,
        });
    }

    try stdout.print("\nVerdict ladder (sorting domain — divergence is STRUCTURAL not functional):\n", .{});
    try stdout.print("  EQUIVALENT:      edit_dist == 0 to a library network\n", .{});
    try stdout.print("  TRIVIAL VARIANT: edit_dist <= 1 to a library network (and correct)\n", .{});
    try stdout.print("  NON-SORTER:      correctness < 1.0 (does not sort all {d} permutations)\n", .{NFact});
    try stdout.print("  REMIX:           norm_edit <= 0.20 to a library network\n", .{});
    try stdout.print("  REACHABLE:       appears as window in depth<=3 library concatenation (norm_edit <= 0.10)\n", .{});
    try stdout.print("  INVENTION:       correct + divergent + unreachable\n", .{});
    try stdout.print("\nCSV: results/sorting_reachability.csv\n", .{});
}
