const std = @import("std");
const engine = @import("invention_engine.zig");

// --- DOMAIN: sorting networks N=8 ---
//
// Spec-conforming module. Program = sequence of compare-exchange comparators.
// Quality = exact correctness over all 8! = 40320 permutations.
// Library = Floyd-8 + Batcher-8 (both 19 comparators, optimal-known).
// Divergence axis: STRUCTURAL (edit distance on comparator sequence).
// Reachability: contiguous-window search across depth ≤ 3 library concatenations.

pub const DOMAIN_NAME: []const u8 = "sort-net-N8";

const N: usize = 8;
const NFact: usize = 40320;
const MaxLen: usize = 32;
const MaxConcatLen: usize = MaxLen * 4;

// Comparator is either a normal compare-exchange (kind=0) on wires (i,j),
// or (kind=1) a "call prior champion" macro that executes
// chain_extras[i % chain_extras.len] inline. When chain_extras is empty
// (the default for general_inventor), kind=1 comparators are never
// emitted and are a sort-network no-op if encountered — substrate stays
// byte-identical to pre-chain behavior.
const Comparator = struct { i: u3, j: u3, kind: u2 = 0 };

pub const MaxChainExtras: usize = 16;
pub var chain_extras: std.BoundedArray(Program, MaxChainExtras) = .{ .buffer = undefined, .len = 0 };

pub fn chainExtrasReset() void { chain_extras.len = 0; }
pub fn chainExtrasAppend(p: Program) !void { try chain_extras.append(p); }
pub fn chainExtrasLen() usize { return chain_extras.len; }

// Recursion bound — without this, a champion that uses CALL_LIB(k)
// referencing another champion that uses CALL_LIB(j) could blow the
// stack on deeper chains.
const MaxCallLibDepth: u32 = 8;
threadlocal var call_lib_depth: u32 = 0;

pub const Program = struct {
    comps: [MaxLen]Comparator,
    used: u8,

    pub fn sort(self: Program, input: [N]u8) [N]u8 {
        var a = input;
        var i: usize = 0;
        while (i < self.used) : (i += 1) {
            const c = self.comps[i];
            if (c.kind == 1) {
                // CALL_LIB macro: execute prior champion inline.
                if (chain_extras.len == 0) continue; // no-op fallback
                if (call_lib_depth >= MaxCallLibDepth) continue;
                call_lib_depth += 1;
                defer call_lib_depth -= 1;
                const idx: usize = @intCast(@as(usize, c.i) % chain_extras.len);
                a = chain_extras.buffer[idx].sort(a);
                continue;
            }
            if (a[c.i] > a[c.j]) {
                const tmp = a[c.i]; a[c.i] = a[c.j]; a[c.j] = tmp;
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

fn exactCorrectness(net: Program) f64 {
    var arr = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var c = [_]u8{0} ** N;
    var correct: u32 = 0;
    var total: u32 = 0;
    {
        const r = net.sort(arr);
        if (isSorted(r)) correct += 1;
        total += 1;
    }
    var i: usize = 0;
    while (i < N) {
        if (c[i] < i) {
            if (i % 2 == 0) {
                const t = arr[0]; arr[0] = arr[i]; arr[i] = t;
            } else {
                const t = arr[c[i]]; arr[c[i]] = arr[i]; arr[i] = t;
            }
            const r = net.sort(arr);
            if (isSorted(r)) correct += 1;
            total += 1;
            c[i] += 1;
            i = 0;
        } else { c[i] = 0; i += 1; }
    }
    return @as(f64, @floatFromInt(correct)) / @as(f64, @floatFromInt(total));
}

fn sampledCorrectness(net: Program, seed: u64) f64 {
    var rng = seed;
    var correct: u32 = 0;
    const samples: u32 = 256;
    var n: u32 = 0;
    while (n < samples) : (n += 1) {
        rng = engine.smix(rng);
        var arr = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
        var k: usize = N - 1;
        while (k > 0) : (k -= 1) {
            rng = engine.smix(rng);
            const swap_idx: usize = rng % (k + 1);
            const t = arr[k]; arr[k] = arr[swap_idx]; arr[swap_idx] = t;
        }
        const r = net.sort(arr);
        if (isSorted(r)) correct += 1;
    }
    return @as(f64, @floatFromInt(correct)) / @as(f64, @floatFromInt(samples));
}

fn depth(net: Program) u8 {
    var wire_layer = [_]u8{0} ** N;
    var max_d: u8 = 0;
    var k: usize = 0;
    while (k < net.used) : (k += 1) {
        const c = net.comps[k];
        if (c.kind == 1) {
            // Macro: add prior champion's depth to all wires it touches
            // (which is all of them, since sort networks operate on all
            // wires). Conservative — assumes macro saturates the layer.
            if (chain_extras.len == 0) continue;
            const idx: usize = @intCast(@as(usize, c.i) % chain_extras.len);
            const sub_depth = depth(chain_extras.buffer[idx]);
            var w: usize = 0;
            var max_wire: u8 = 0;
            while (w < N) : (w += 1) if (wire_layer[w] > max_wire) { max_wire = wire_layer[w]; };
            const new_layer: u8 = max_wire + sub_depth;
            w = 0;
            while (w < N) : (w += 1) wire_layer[w] = new_layer;
            if (new_layer > max_d) max_d = new_layer;
            continue;
        }
        const nl: u8 = @intCast(@max(wire_layer[c.i], wire_layer[c.j]) + 1);
        wire_layer[c.i] = nl; wire_layer[c.j] = nl;
        if (nl > max_d) max_d = nl;
    }
    return max_d;
}

// Exposed for chain_runner_sort progress-axis measurement.
pub fn programDepth(p: Program) u8 {
    return depth(p);
}

pub fn programSize(p: Program) u8 {
    return p.used;
}

pub const Quality = struct {
    correctness: f64,
    sampled: f64,
    size: u8,
    d: u8,
    composite: f64,
};

pub fn evaluateQuality(p: Program) Quality {
    const sc = sampledCorrectness(p, 0xA1B2C3D4E5F60718);
    // Exact correctness is expensive (8! permutations) — only compute when
    // sampled correctness is already 1.0 to save cycles in the SA loop.
    const cc: f64 = if (sc >= 1.0 - 1e-9) exactCorrectness(p) else sc;
    const d = depth(p);
    const composite = 200.0 * sc - @as(f64, @floatFromInt(p.used)) * 0.5 - @as(f64, @floatFromInt(d)) * 1.0;
    return .{ .correctness = cc, .sampled = sc, .size = p.used, .d = d, .composite = composite };
}

pub fn qualityScalar(q: Quality) f64 { return q.composite; }
pub fn qualityPasses(q: Quality) bool { return q.correctness >= 1.0 - 1e-9; }
pub fn isFinite(q: Quality) bool { return std.math.isFinite(q.composite); }

// --- Library ---
fn mkNet(comps: []const Comparator) Program {
    var n = Program{ .comps = undefined, .used = @intCast(comps.len) };
    var i: usize = 0;
    while (i < comps.len) : (i += 1) n.comps[i] = comps[i];
    return n;
}

fn libFloyd() Program {
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

fn libBatcher() Program {
    return mkNet(&[_]Comparator{
        .{ .i = 0, .j = 1 }, .{ .i = 2, .j = 3 }, .{ .i = 4, .j = 5 }, .{ .i = 6, .j = 7 },
        .{ .i = 0, .j = 2 }, .{ .i = 1, .j = 3 }, .{ .i = 4, .j = 6 }, .{ .i = 5, .j = 7 },
        .{ .i = 1, .j = 2 }, .{ .i = 5, .j = 6 },
        .{ .i = 0, .j = 4 }, .{ .i = 1, .j = 5 }, .{ .i = 2, .j = 6 }, .{ .i = 3, .j = 7 },
        .{ .i = 2, .j = 4 }, .{ .i = 3, .j = 5 },
        .{ .i = 1, .j = 2 }, .{ .i = 3, .j = 4 }, .{ .i = 5, .j = 6 },
    });
}

const LibEntry = struct { name: []const u8, program: Program };
fn library() [2]LibEntry {
    return .{
        .{ .name = "Floyd-8", .program = libFloyd() },
        .{ .name = "Batcher-8", .program = libBatcher() },
    };
}

// --- Distance ---
pub const DistanceResult = struct {
    closest_name: []const u8,
    min_edit: usize,
    norm_edit: f64,
    correctness: f64,
};

fn cmpEq(a: Comparator, b: Comparator) bool { return a.kind == b.kind and a.i == b.i and a.j == b.j; }

fn editDistance(a: []const Comparator, b: []const Comparator, allocator: std.mem.Allocator) !usize {
    const la = a.len; const lb = b.len;
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

pub fn distanceToLibrary(p: Program, allocator: std.mem.Allocator) !DistanceResult {
    const lib = library();
    var min_ed: usize = std.math.maxInt(usize);
    var min_idx: usize = 0;
    for (lib, 0..) |entry, idx| {
        const ed = try editDistance(p.comps[0..p.used], entry.program.comps[0..entry.program.used], allocator);
        if (ed < min_ed) { min_ed = ed; min_idx = idx; }
    }
    const max_len = @max(p.used, @as(usize, 24));
    return .{
        .closest_name = lib[min_idx].name,
        .min_edit = min_ed,
        .norm_edit = @as(f64, @floatFromInt(min_ed)) / @as(f64, @floatFromInt(max_len)),
        .correctness = exactCorrectness(p),
    };
}

pub fn isEquivalent(d: DistanceResult) bool { return d.min_edit == 0; }
pub fn isTrivialVariant(d: DistanceResult) bool { return d.min_edit <= 1 and d.correctness >= 1.0 - 1e-9; }
pub fn isRemix(d: DistanceResult) bool { return d.norm_edit <= 0.20; }

// --- Reachability ---
pub const ReachabilityResult = struct {
    min_window_edit: usize,
    min_norm_edit: f64,
    best_depth: usize,
    reachable: bool,
};
const MaxDepth: usize = 3;
const ReachNormThreshold: f64 = 0.10;

pub fn reachability(p: Program, allocator: std.mem.Allocator) !ReachabilityResult {
    const lib = library();
    var best: ReachabilityResult = .{ .min_window_edit = std.math.maxInt(usize), .min_norm_edit = 1.0, .best_depth = 0, .reachable = false };
    var depth_iter: usize = 1;
    while (depth_iter <= MaxDepth) : (depth_iter += 1) {
        const total = std.math.pow(usize, lib.len, depth_iter);
        var n: usize = 0;
        while (n < total) : (n += 1) {
            var path: [MaxDepth]usize = .{0} ** MaxDepth;
            var t = n; var i: usize = 0;
            while (i < depth_iter) : (i += 1) { path[i] = t % lib.len; t /= lib.len; }
            var concat: [MaxConcatLen]Comparator = undefined;
            var ci: usize = 0;
            i = 0;
            while (i < depth_iter) : (i += 1) {
                const net = lib[path[i]].program;
                var k: usize = 0;
                while (k < net.used and ci < concat.len) : (k += 1) { concat[ci] = net.comps[k]; ci += 1; }
            }
            if (p.used > ci) continue;
            var start: usize = 0;
            while (start + p.used <= ci) : (start += 1) {
                const ed = try editDistance(p.comps[0..p.used], concat[start .. start + p.used], allocator);
                const norm = @as(f64, @floatFromInt(ed)) / @as(f64, @floatFromInt(p.used));
                if (ed < best.min_window_edit) {
                    best.min_window_edit = ed;
                    best.min_norm_edit = norm;
                    best.best_depth = depth_iter;
                }
            }
        }
    }
    best.reachable = best.min_norm_edit <= ReachNormThreshold;
    return best;
}

pub fn isReachable(r: ReachabilityResult) bool { return r.reachable; }

// --- Random / mutate / crossover ---
fn randomComparator(rng: *u64) Comparator {
    // With chain_extras populated, ~1/(NumComps+chain_extras.len) chance
    // of emitting a CALL_LIB-style macro comparator. This makes priors
    // composable atoms in mutate/random just like CALL_LIB in u64-mixer.
    if (chain_extras.len > 0) {
        rng.* = engine.smix(rng.*);
        const NumComps: u64 = (N * (N - 1)) / 2; // 28
        const total: u64 = NumComps + chain_extras.len;
        const draw: u64 = rng.* % total;
        if (draw >= NumComps) {
            const lib_idx: u3 = @intCast((draw - NumComps) % chain_extras.len);
            return .{ .i = lib_idx, .j = 0, .kind = 1 };
        }
    }
    rng.* = engine.smix(rng.*);
    const NumComps: u64 = (N * (N - 1)) / 2;
    var k: u64 = rng.* % NumComps;
    var ci: u3 = 0;
    while (true) : (ci += 1) {
        const row_len: u64 = (N - 1) - @as(u64, ci);
        if (k < row_len) {
            const cj: u3 = @intCast(@as(u64, ci) + 1 + k);
            return .{ .i = ci, .j = cj, .kind = 0 };
        }
        k -= row_len;
    }
}

pub fn randomProgram(rng: *u64) Program {
    rng.* = engine.smix(rng.*);
    const len: u8 = @intCast(20 + (rng.* % 9)); // 20..28
    var p = Program{ .comps = undefined, .used = len };
    var i: usize = 0;
    while (i < len) : (i += 1) p.comps[i] = randomComparator(rng);
    return p;
}

pub fn mutate(p: Program, rng: *u64) Program {
    var q = p;
    rng.* = engine.smix(rng.*);
    const mode = rng.* % 16;
    if (mode < 10) {
        rng.* = engine.smix(rng.*);
        const idx: usize = rng.* % q.used;
        q.comps[idx] = randomComparator(rng);
    } else if (mode < 13 and q.used < MaxLen) {
        rng.* = engine.smix(rng.*);
        const idx: usize = rng.* % (q.used + 1);
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.comps[i] = q.comps[i - 1];
        q.comps[idx] = randomComparator(rng);
        q.used += 1;
    } else if (q.used > 16) {
        rng.* = engine.smix(rng.*);
        const idx: usize = rng.* % q.used;
        var i: usize = idx;
        while (i < q.used - 1) : (i += 1) q.comps[i] = q.comps[i + 1];
        q.used -= 1;
    } else {
        rng.* = engine.smix(rng.*);
        const a: usize = rng.* % q.used;
        rng.* = engine.smix(rng.*);
        const b: usize = rng.* % q.used;
        const t = q.comps[a]; q.comps[a] = q.comps[b]; q.comps[b] = t;
    }
    return q;
}

pub fn crossover(a: Program, b: Program, rng: *u64) Program {
    rng.* = engine.smix(rng.*);
    const min_len = @min(a.used, b.used);
    if (min_len < 16) return a;
    const cut: usize = rng.* % min_len;
    var q = a;
    var i: usize = cut;
    while (i < b.used and i < MaxLen) : (i += 1) q.comps[i] = b.comps[i];
    q.used = b.used;
    return q;
}

pub fn printProgram(p: Program, writer: anytype) !void {
    var i: usize = 0;
    while (i < p.used) : (i += 1) try writer.print("  [{d: >2}] ({d},{d})\n", .{ i, p.comps[i].i, p.comps[i].j });
}

pub fn programToCsv(p: Program, writer: anytype) !void {
    try writer.writeAll("idx,kind,i,j,size\n");
    var i: usize = 0;
    while (i < p.used) : (i += 1) try writer.print("{d},{d},{d},{d},{d}\n", .{
        i, p.comps[i].kind, p.comps[i].i, p.comps[i].j, p.used,
    });
}
