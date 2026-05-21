const std = @import("std");

// --- SORTING-NETWORK INVENTOR ---
//
// Second domain instance of the invention-engine pattern.
//   - I/O type:      [8]u8 permutation -> [8]u8 sorted
//   - Operators:     28 distinct compare-exchange (i,j), 0 <= i < j < 8
//   - Program form:  sequence of comparators (up to MaxLen)
//   - Quality:       correctness over ALL 8! = 40320 permutations + size + depth
//   - Library:       Bitonic-8 (24 comp), Batcher odd-even merge-8 (19 comp)
//
// Mirrors program_synthesis_inventor.zig structurally:
//   - SA + mutation + crossover on a champion pool
//   - Persists final champion to results/sorting_champion.csv
//   - Std-only, no VSA / Flame / Concept / network / model.

const N: usize = 8;
const NFact: usize = 40320; // 8!
const MaxLen: usize = 32;

const Comparator = struct {
    i: u3,
    j: u3,
    fn from_idx(idx: u8) Comparator {
        var k: usize = idx;
        var i: u3 = 0;
        while (true) : (i += 1) {
            const row_len: usize = (N - 1) - @as(usize, i);
            if (k < row_len) {
                const j: u3 = @intCast(@as(usize, i) + 1 + k);
                return .{ .i = i, .j = j };
            }
            k -= row_len;
        }
    }
    fn to_idx(self: Comparator) u8 {
        var idx: usize = 0;
        var ii: u3 = 0;
        while (ii < self.i) : (ii += 1) idx += (N - 1) - @as(usize, ii);
        idx += @as(usize, self.j) - @as(usize, self.i) - 1;
        return @intCast(idx);
    }
};
const NumComparators: u8 = (N * (N - 1)) / 2; // 28

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

    fn depth(self: Network) u8 {
        // Each comparator advances to the layer = 1 + max(layer of last touch
        // on wire i, layer of last touch on wire j).
        var wire_layer = [_]u8{0} ** N;
        var max_d: u8 = 0;
        var k: usize = 0;
        while (k < self.used) : (k += 1) {
            const c = self.comps[k];
            const li = wire_layer[c.i];
            const lj = wire_layer[c.j];
            const nl: u8 = @intCast(@max(li, lj) + 1);
            wire_layer[c.i] = nl;
            wire_layer[c.j] = nl;
            if (nl > max_d) max_d = nl;
        }
        return max_d;
    }
};

// --- Exhaustive correctness check over all 8! permutations ---
fn permutationCorrectness(net: Network) f64 {
    // Generate all 8! permutations via Heap's algorithm and count how many
    // the network sorts correctly.
    var arr = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var c = [_]u8{0} ** N;
    var correct: u32 = 0;
    var total: u32 = 0;

    // Check initial permutation
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

fn isSorted(a: [N]u8) bool {
    var i: usize = 1;
    while (i < N) : (i += 1) {
        if (a[i - 1] > a[i]) return false;
    }
    return true;
}

// --- Sampled correctness for fast fitness gradient ---
fn sampledCorrectness(net: Network, rng_seed: u64) f64 {
    var rng = rng_seed;
    var correct: u32 = 0;
    const samples: u32 = 256;
    var n: u32 = 0;
    while (n < samples) : (n += 1) {
        rng = smix(rng);
        var arr = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
        // Fisher-Yates shuffle
        var k: usize = N - 1;
        while (k > 0) : (k -= 1) {
            rng = smix(rng);
            const swap_idx: usize = rng % (k + 1);
            const tmp = arr[k];
            arr[k] = arr[swap_idx];
            arr[swap_idx] = tmp;
        }
        const result = net.sort(arr);
        if (isSorted(result)) correct += 1;
    }
    return @as(f64, @floatFromInt(correct)) / @as(f64, @floatFromInt(samples));
}

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

const Fitness = struct {
    correctness: f64,     // exact, over all 8!
    sampled_corr: f64,    // fast, for SA loop
    size: u8,
    depth: u8,
    composite: f64,
};

fn evaluate(net: Network, exact: bool) Fitness {
    const sc = sampledCorrectness(net, 0xA1B2C3D4E5F60718);
    const cc: f64 = if (exact) permutationCorrectness(net) else sc;
    const d = net.depth();
    // Composite: heavily reward correctness, mildly penalize size and depth.
    const composite = 200.0 * sc - @as(f64, @floatFromInt(net.used)) * 0.5 - @as(f64, @floatFromInt(d)) * 1.0;
    return .{ .correctness = cc, .sampled_corr = sc, .size = net.used, .depth = d, .composite = composite };
}

// --- Mutation / crossover ---
fn randomComparator(rng: *u64) Comparator {
    rng.* = smix(rng.*);
    const idx: u8 = @intCast(rng.* % NumComparators);
    return Comparator.from_idx(idx);
}

fn randomNetwork(rng: *u64, min_len: u8, max_len: u8) Network {
    rng.* = smix(rng.*);
    const len: u8 = @intCast(min_len + (rng.* % (max_len - min_len + 1)));
    var net = Network{ .comps = undefined, .used = len };
    var i: usize = 0;
    while (i < len) : (i += 1) {
        net.comps[i] = randomComparator(rng);
    }
    return net;
}

fn mutate(net: Network, rng: *u64) Network {
    var q = net;
    rng.* = smix(rng.*);
    const mode = rng.* % 16;
    if (mode < 10) {
        // Point mutation: change one comparator
        rng.* = smix(rng.*);
        const idx: usize = rng.* % q.used;
        q.comps[idx] = randomComparator(rng);
    } else if (mode < 13 and q.used < MaxLen) {
        // Insert
        rng.* = smix(rng.*);
        const idx: usize = rng.* % (q.used + 1);
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.comps[i] = q.comps[i - 1];
        q.comps[idx] = randomComparator(rng);
        q.used += 1;
    } else if (q.used > 16) {
        // Delete
        rng.* = smix(rng.*);
        const idx: usize = rng.* % q.used;
        var i: usize = idx;
        while (i < q.used - 1) : (i += 1) q.comps[i] = q.comps[i + 1];
        q.used -= 1;
    } else {
        // Swap two comparators
        rng.* = smix(rng.*);
        const a: usize = rng.* % q.used;
        rng.* = smix(rng.*);
        const b: usize = rng.* % q.used;
        const tmp = q.comps[a];
        q.comps[a] = q.comps[b];
        q.comps[b] = tmp;
    }
    return q;
}

fn crossover(a: Network, b: Network, rng: *u64) Network {
    rng.* = smix(rng.*);
    const min_len = @min(a.used, b.used);
    if (min_len < 16) return a;
    const cut: usize = rng.* % min_len;
    var q = a;
    var i: usize = cut;
    while (i < b.used and i < MaxLen) : (i += 1) q.comps[i] = b.comps[i];
    q.used = b.used;
    return q;
}

// --- Champion pool ---
const PoolSize: usize = 16;
const Pool = struct {
    nets: [PoolSize]Network,
    fits: [PoolSize]Fitness,
    count: usize = 0,

    fn consider(self: *@This(), net: Network, f: Fitness) bool {
        if (self.count < PoolSize) {
            self.nets[self.count] = net;
            self.fits[self.count] = f;
            self.count += 1;
            return true;
        }
        var worst: usize = 0;
        for (1..self.count) |i| if (self.fits[i].composite < self.fits[worst].composite) {
            worst = i;
        };
        if (f.composite > self.fits[worst].composite) {
            self.nets[worst] = net;
            self.fits[worst] = f;
            return true;
        }
        return false;
    }

    fn best(self: *const @This()) struct { net: Network, fit: Fitness, idx: usize } {
        var b: usize = 0;
        for (1..self.count) |i| if (self.fits[i].composite > self.fits[b].composite) {
            b = i;
        };
        return .{ .net = self.nets[b], .fit = self.fits[b], .idx = b };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var iterations: usize = 30000;
    var seed: u64 = 0xCAFEBABE12345678;
    var csv_path: []const u8 = "results/sorting_champion.csv";

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--iters=")) iterations = try std.fmt.parseInt(usize, arg["--iters=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--seed=")) seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16)
        else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..];
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== SORTING-NETWORK INVENTOR (N={d}) ===\n", .{N});
    try stdout.print("iterations={d} seed=0x{X}\n\n", .{ iterations, seed });

    var rng: u64 = seed;
    var pool = Pool{ .nets = undefined, .fits = undefined };

    // Seed pool with random networks of length 20-28 (likely to be near optimal range)
    var s: usize = 0;
    while (s < PoolSize) : (s += 1) {
        const net = randomNetwork(&rng, 20, 28);
        const f = evaluate(net, false);
        _ = pool.consider(net, f);
    }
    var best_sc: f64 = 0;
    try stdout.print("iter | best_sampled | size | depth | composite\n", .{});
    try stdout.print("-----|--------------|------|-------|----------\n", .{});

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const t_progress = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(iterations));
        const t = 50.0 * std.math.pow(f64, 0.001, t_progress);

        rng = smix(rng);
        const parent_idx = rng % pool.count;
        const parent = pool.nets[parent_idx];

        rng = smix(rng);
        const candidate: Network = if ((rng & 3) == 0 and pool.count > 1) blk: {
            rng = smix(rng);
            const other_idx = rng % pool.count;
            break :blk crossover(parent, pool.nets[other_idx], &rng);
        } else mutate(parent, &rng);

        const cand_fit = evaluate(candidate, false);
        var worst: usize = 0;
        for (1..pool.count) |k| if (pool.fits[k].composite < pool.fits[worst].composite) {
            worst = k;
        };
        const delta = cand_fit.composite - pool.fits[worst].composite;
        var accept = false;
        if (delta >= 0) accept = true else {
            rng = smix(rng);
            const draw = @as(f64, @floatFromInt(rng % 1_000_000)) / 1_000_000.0;
            accept = draw < std.math.exp(delta / t);
        }
        if (accept) {
            pool.nets[worst] = candidate;
            pool.fits[worst] = cand_fit;
        }

        const cur = pool.best();
        if (cur.fit.sampled_corr > best_sc) best_sc = cur.fit.sampled_corr;
        if ((i + 1) % 2000 == 0 or i == 0) {
            try stdout.print("{d: >4} | {d: >12.4} | {d: >4} | {d: >5} | {d: >9.2}\n", .{
                i + 1, cur.fit.sampled_corr, cur.fit.size, cur.fit.depth, cur.fit.composite,
            });
        }
    }

    // Final exact evaluation of best champion + verify correctness on 8!
    const final = pool.best();
    const final_fit = evaluate(final.net, true);
    try stdout.print("\n=== FINAL DISCOVERED NETWORK ===\n", .{});
    try stdout.print("size={d} depth={d} sampled_correctness={d:.4} EXACT_correctness={d:.6}\n", .{
        final_fit.size, final_fit.depth, final_fit.sampled_corr, final_fit.correctness,
    });
    if (final_fit.correctness >= 1.0 - 1e-9) {
        try stdout.print("VERDICT: CORRECT SORTER (sorts all {d} permutations of {d} elements).\n", .{ NFact, N });
    } else {
        try stdout.print("VERDICT: incorrect (misses {d:.0} of {d} permutations). Increase --iters or rerun.\n", .{
            (1.0 - final_fit.correctness) * @as(f64, @floatFromInt(NFact)), NFact,
        });
    }

    try stdout.writeAll("\nDiscovered network (decodable comparator sequence):\n");
    var k: usize = 0;
    while (k < final.net.used) : (k += 1) {
        try stdout.print("  [{d: >2}] ({d},{d})\n", .{ k, final.net.comps[k].i, final.net.comps[k].j });
    }

    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var f = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer f.close();
    try f.writer().writeAll("idx,i,j,size,depth,correctness\n");
    k = 0;
    while (k < final.net.used) : (k += 1) {
        try f.writer().print("{d},{d},{d},{d},{d},{d:.6}\n", .{
            k, final.net.comps[k].i, final.net.comps[k].j, final.net.used, final_fit.depth, final_fit.correctness,
        });
    }
    try stdout.print("\nChampion persisted: {s}\n", .{csv_path});
}
