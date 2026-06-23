//! double_discover.zig — #1 richer space: MULTIPLE VARIABLES (double sums). Enumerate
//!   a(n) = sum_{i=1..n} sum_{j=1..n, rel(i,j)} term(i,j),  term over {i,j,1,2,3} with + - *, rel in
//!   {all, i<j, i<=j, i==j, i>j}, recover a polynomial closed form by finite differences, certify over [1,M].
//! Surfaces double-sum closed forms and — the point of two indices — SYMMETRY identities the single-index engine
//! can't pose: sum_{i,j} i ≡ sum_{i,j} j, sum_{i,j}(i-j) ≡ 0, sum_{i<j} 1 ≡ sum_{i>j} 1, etc. All certified.
//! Build: zig build-exe double_discover.zig -O ReleaseFast -femit-bin=/tmp/dbl && /tmp/dbl
const std = @import("std");
var A: std.mem.Allocator = undefined;
const M: i128 = 60; // certify over n = 1..M (double sums are O(n^2) so keep M modest)
const DMAX: usize = 6;

// term over (i,j)
const T = struct { op: u8, a: u16, b: u16, k: i8 }; // op 0=i,1=j,2=const,3=+,4=-,5=*
var terms: std.ArrayList(T) = undefined;
fn evalT(id: u16, i: i128, j: i128) i128 {
    const t = terms.items[id];
    return switch (t.op) {
        0 => i,
        1 => j,
        2 => t.k,
        3 => evalT(t.a, i, j) +% evalT(t.b, i, j),
        4 => evalT(t.a, i, j) -% evalT(t.b, i, j),
        else => evalT(t.a, i, j) *% evalT(t.b, i, j),
    };
}
fn termName(id: u16, buf: []u8, pos: *usize) void {
    const t = terms.items[id];
    const w = struct {
        fn put(b: []u8, p: *usize, s: []const u8) void {
            for (s) |c| {
                if (p.* < b.len) b[p.*] = c;
                p.* += 1;
            }
        }
    };
    switch (t.op) {
        0 => w.put(buf, pos, "i"),
        1 => w.put(buf, pos, "j"),
        2 => {
            var nb: [8]u8 = undefined;
            w.put(buf, pos, std.fmt.bufPrint(&nb, "{d}", .{t.k}) catch "?");
        },
        else => {
            w.put(buf, pos, "(");
            termName(t.a, buf, pos);
            w.put(buf, pos, switch (t.op) {
                3 => "+",
                4 => "-",
                else => "*",
            });
            termName(t.b, buf, pos);
            w.put(buf, pos, ")");
        },
    }
}
fn termStr(id: u16) []const u8 {
    const buf = A.alloc(u8, 64) catch return "?";
    var pos: usize = 0;
    termName(id, buf, &pos);
    return buf[0..@min(pos, 64)];
}
fn relTrue(r: u8, i: i128, j: i128) bool {
    return switch (r) {
        0 => true,
        1 => i < j,
        2 => i <= j,
        3 => i == j,
        else => i > j,
    };
}
fn relName(r: u8) []const u8 {
    return switch (r) {
        0 => "",
        1 => " [i<j]",
        2 => " [i<=j]",
        3 => " [i==j]",
        else => " [i>j]",
    };
}

fn gcd(a: i128, b: i128) i128 {
    var x = if (a < 0) -a else a;
    var y = if (b < 0) -b else b;
    while (y != 0) {
        const t = @rem(x, y);
        x = y;
        y = t;
    }
    return if (x == 0) 1 else x;
}
fn factv(k: usize) i128 {
    var f: i128 = 1;
    var j: usize = 2;
    while (j <= k) : (j += 1) f *= @intCast(j);
    return f;
}
fn binom(n: i128, k: usize) i128 {
    if (k == 0) return 1;
    if (n < 0) return 0;
    var num: i128 = 1;
    var j: usize = 0;
    while (j < k) : (j += 1) num *= (n - @as(i128, @intCast(j)));
    return @divTrunc(num, factv(k));
}

const CF = struct { deg: usize, b: [DMAX + 1]i128 };
fn findPoly(a: []const i128) ?CF {
    var diff: [DMAX + 2]i128 = undefined;
    for (0..DMAX + 2) |t| diff[t] = a[t];
    var b: [DMAX + 1]i128 = undefined;
    var deg: ?usize = null;
    var k: usize = 0;
    while (k < DMAX + 1) : (k += 1) {
        b[k] = diff[0];
        var allz = true;
        for (0..DMAX + 1 - k) |j| if (diff[j] != 0) {
            allz = false;
            break;
        };
        if (allz) {
            deg = if (k == 0) 0 else k - 1;
            break;
        }
        for (0..DMAX + 1 - k) |j| diff[j] = diff[j + 1] - diff[j];
    }
    if (deg == null) return null;
    const cf = CF{ .deg = deg.?, .b = b };
    // certify over [1,M]
    var n: i128 = 1;
    while (n <= M) : (n += 1) {
        var s: i128 = 0;
        for (0..cf.deg + 1) |kk| s += cf.b[kk] * binom(n, kk);
        if (s != a[@intCast(n)]) return null;
    }
    return cf;
}
fn renderPoly(cf: CF) []const u8 {
    const d = cf.deg;
    const D = factv(d);
    var num = [_]i128{0} ** (DMAX + 2);
    for (0..d + 1) |k| {
        var ff = [_]i128{0} ** (DMAX + 2);
        ff[0] = 1;
        var hi: usize = 0;
        for (0..k) |j| {
            var nf = [_]i128{0} ** (DMAX + 2);
            for (0..hi + 1) |t| {
                nf[t + 1] += ff[t];
                nf[t] -= ff[t] * @as(i128, @intCast(j));
            }
            ff = nf;
            hi += 1;
        }
        const scale = cf.b[k] * @divTrunc(D, factv(k));
        for (0..k + 1) |t| num[t] += scale * ff[t];
    }
    var g = D;
    for (0..d + 1) |t| g = gcd(g, num[t]);
    const Ds = @divTrunc(D, g);
    const buf = A.alloc(u8, 160) catch return "?";
    var w = std.io.fixedBufferStream(buf);
    const ww = w.writer();
    var first = true;
    var t: usize = d + 1;
    while (t > 0) {
        t -= 1;
        const c = @divTrunc(num[t], g);
        if (c == 0) continue;
        const neg = c < 0;
        const ac = if (neg) -c else c;
        if (first) {
            if (neg) ww.print("-", .{}) catch {};
        } else if (neg) ww.print(" - ", .{}) catch {} else ww.print(" + ", .{}) catch {};
        first = false;
        if (t == 0) ww.print("{d}", .{ac}) catch {} else if (t == 1) {
            if (ac == 1) ww.print("n", .{}) catch {} else ww.print("{d}n", .{ac}) catch {};
        } else {
            if (ac == 1) ww.print("n^{d}", .{t}) catch {} else ww.print("{d}n^{d}", .{ ac, t }) catch {};
        }
    }
    if (first) ww.print("0", .{}) catch {};
    const body = w.getWritten();
    if (Ds == 1) return body;
    return std.fmt.allocPrint(A, "({s}) / {d}", .{ body, Ds }) catch body;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    A = arena.allocator();
    const o = std.io.getStdOut().writer();
    terms = std.ArrayList(T).init(A);

    try o.print("=== DOUBLE-SUM DISCOVERY — two indices: a(n) = sum_{{i,j=1..n, rel}} term(i,j), certified ===\n\n", .{});

    // enumerate terms over (i,j)
    terms.append(.{ .op = 0, .a = 0, .b = 0, .k = 0 }) catch {}; // i
    terms.append(.{ .op = 1, .a = 0, .b = 0, .k = 0 }) catch {}; // j
    terms.append(.{ .op = 2, .a = 0, .b = 0, .k = 1 }) catch {}; // 1
    terms.append(.{ .op = 2, .a = 0, .b = 0, .k = 2 }) catch {}; // 2
    var seenT = std.AutoHashMap(u64, void).init(A);
    const GS: i128 = 7;
    const BOUND: i128 = 8 * GS * GS * GS;
    var fstart: usize = 0;
    var round: usize = 0;
    const TCAP = 160;
    while (round < 2 and terms.items.len < TCAP) : (round += 1) {
        const start = fstart;
        const end = terms.items.len;
        fstart = end;
        var i: usize = start;
        outer: while (i < end) : (i += 1) {
            var j: usize = 0;
            while (j < terms.items.len) : (j += 1) {
                var op: u8 = 3;
                while (op <= 5) : (op += 1) {
                    var h: u64 = 1469598103934665603;
                    var big = false;
                    var gi: i128 = 1;
                    while (gi <= GS) : (gi += 1) {
                        var gj: i128 = 1;
                        while (gj <= GS) : (gj += 1) {
                            const va = evalT(@intCast(i), gi, gj);
                            const vb = evalT(@intCast(j), gi, gj);
                            const v = switch (op) {
                                3 => va +% vb,
                                4 => va -% vb,
                                else => va *% vb,
                            };
                            if (v > BOUND or v < -BOUND) big = true;
                            h = (h ^ @as(u64, @bitCast(@as(i64, @truncate(v))))) *% 1099511628211;
                        }
                    }
                    if (big) continue;
                    if (seenT.contains(h)) continue;
                    seenT.put(h, {}) catch {};
                    terms.append(.{ .op = op, .a = @intCast(i), .b = @intCast(j), .k = 0 }) catch {};
                    if (terms.items.len >= TCAP) break :outer;
                }
            }
        }
    }
    try o.print("[enumerate] {d} distinct (i,j)-terms × 5 relations = {d} double-sum programs\n", .{ terms.items.len, terms.items.len * 5 });

    const Prog = struct { term: u16, rel: u8, deg: usize, form: []const u8 };
    var poly = std.ArrayList(Prog).init(A);
    var abstain: usize = 0;
    var tid: u16 = 0;
    while (tid < terms.items.len) : (tid += 1) {
        var r: u8 = 0;
        while (r < 5) : (r += 1) {
            const a = A.alloc(i128, @intCast(M + 1)) catch return;
            a[0] = 0;
            var n: i128 = 1;
            while (n <= M) : (n += 1) {
                var s: i128 = 0;
                var i: i128 = 1;
                while (i <= n) : (i += 1) {
                    var j: i128 = 1;
                    while (j <= n) : (j += 1) if (relTrue(r, i, j)) {
                        s += evalT(tid, i, j);
                    };
                }
                a[@intCast(n)] = s;
            }
            const cf = findPoly(a) orelse {
                abstain += 1;
                continue;
            };
            poly.append(.{ .term = tid, .rel = r, .deg = cf.deg, .form = renderPoly(cf) }) catch {};
        }
    }
    try o.print("[certify] {d} double-sum closed forms certified · {d} abstained\n\n", .{ poly.items.len, abstain });

    std.mem.sort(Prog, poly.items, {}, struct {
        fn lt(_: void, x: Prog, y: Prog) bool {
            if (x.deg != y.deg) return x.deg > y.deg;
            return std.mem.lessThan(u8, x.form, y.form);
        }
    }.lt);
    try o.print("──────── sample discovered double-sum closed forms (spread across degrees) ────────\n", .{});
    var perdeg = [_]usize{0} ** (DMAX + 2);
    var i: usize = 0;
    while (i < poly.items.len) : (i += 1) {
        if (i > 0 and std.mem.eql(u8, poly.items[i].form, poly.items[i - 1].form)) continue;
        const p = poly.items[i];
        if (perdeg[p.deg] >= 4) continue;
        perdeg[p.deg] += 1;
        var tb: [64]u8 = undefined;
        var tp: usize = 0;
        termName(p.term, &tb, &tp);
        try o.print("    sum_{{i,j=1..n{s}}} {s:<14}  ≡  {s}\n", .{ relName(p.rel), tb[0..@min(tp, 64)], p.form });
    }

    try o.print("\n──────── SYMMETRY & cross-program identities (different double sums, same certified form) ────────\n", .{});
    var shown: usize = 0;
    i = 0;
    while (i < poly.items.len and shown < 14) {
        var j = i + 1;
        while (j < poly.items.len and std.mem.eql(u8, poly.items[j].form, poly.items[i].form)) j += 1;
        if (j - i >= 2) {
            const pa = poly.items[i];
            var bi = i + 1;
            while (bi < j and poly.items[bi].term == pa.term and poly.items[bi].rel == pa.rel) bi += 1;
            if (bi < j) {
                const pb = poly.items[bi];
                try o.print("    sum_{{i,j{s}}} {s} ≡ sum_{{i,j{s}}} {s}   [= {s}]\n", .{ relName(pa.rel), termStr(pa.term), relName(pb.rel), termStr(pb.term), pa.form });
                shown += 1;
            }
        }
        i = j;
    }

    try o.print("\n  Two indices let it pose what the single-index engine can't: symmetry (sum i ≡ sum j), antisymmetry\n", .{});
    try o.print("  (sum (i-j) ≡ 0), and relation-swaps (sum_{{i<j}} ≡ sum_{{i>j}}) — all posed from primitives and certified.\n", .{});
}
