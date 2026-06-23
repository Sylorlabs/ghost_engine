//! auto_discover.zig — point the generator at itself. Instead of 11 curated sequences, ENUMERATE the loop/branch
//! program space: a(n) = sum_{i=1..n, cond(i)} term(i,n) for every term (small expression grammar over i,n) and
//! every branch condition. Run the closed-form certifier over all of them — recover a polynomial (or
//! quasi-polynomial, period 2/3) by finite differences and CERTIFY over [1,M], else abstain. Then surface what a
//! curated set can't: the breadth of certified closed forms, and CROSS-PROGRAM IDENTITIES (structurally different
//! loops with the same certified closed form — discovered equalities). This is where rediscovery turns into
//! proposal: nothing is hand-picked; the machine poses the programs and keeps only what it can prove.
//! Build: zig build-exe auto_discover.zig -O ReleaseFast -femit-bin=/tmp/ad && /tmp/ad
const std = @import("std");
var A: std.mem.Allocator = undefined;
const M: i128 = 120; // certify over n = 1..M
const DMAX: usize = 6; // closed-form polynomial degree cap
const GS: i128 = 9; // grid size for term dedup

// ── term grammar over (i, n): leaves i, n, 1, 2, 3 ; ops + - * ; trees up to a few nodes ──
const T = struct { op: u8, a: u16, b: u16, k: i8 }; // op 0=i,1=n,2=const(k),3=+,4=-,5=*
var terms: std.ArrayList(T) = undefined;
fn evalT(id: u16, i: i128, n: i128) i128 {
    const t = terms.items[id];
    return switch (t.op) {
        0 => i,
        1 => n,
        2 => t.k,
        3 => evalT(t.a, i, n) +% evalT(t.b, i, n),
        4 => evalT(t.a, i, n) -% evalT(t.b, i, n),
        else => evalT(t.a, i, n) *% evalT(t.b, i, n),
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
        1 => w.put(buf, pos, "n"),
        2 => {
            var nb: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d}", .{t.k}) catch "?";
            w.put(buf, pos, s);
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
    const buf = A.alloc(u8, 96) catch return "?";
    var pos: usize = 0;
    termName(id, buf, &pos);
    return buf[0..@min(pos, 96)];
}

fn condTrue(c: u8, i: i128) bool {
    return switch (c) {
        0 => true,
        1 => @rem(i, 2) == 0,
        2 => @rem(i, 2) == 1,
        3 => @rem(i, 3) == 0,
        4 => @rem(i, 3) == 1,
        else => @rem(i, 3) == 2,
    };
}
fn condName(c: u8) []const u8 {
    return switch (c) {
        0 => "",
        1 => " [i even]",
        2 => " [i odd]",
        3 => " [i%3==0]",
        4 => " [i%3==1]",
        else => " [i%3==2]",
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

// closed-form: quasi-polynomial of period q (q=1 → plain polynomial). Per-residue Newton coeffs.
const CF = struct { q: usize, deg: [3]usize, coef: [3][DMAX + 1]i128 };
fn findCF(a: []const i128) ?CF {
    var q: usize = 1;
    while (q <= 3) : (q += 1) {
        var cf = CF{ .q = q, .deg = .{ 0, 0, 0 }, .coef = undefined };
        var ok = true;
        var r: usize = 0;
        while (r < q) : (r += 1) {
            // samples along n = r, r+q, r+2q, ... (need DMAX+2 of them within [0,M])
            var s: [DMAX + 2]i128 = undefined;
            var got: usize = 0;
            var m: usize = 0;
            while (got < DMAX + 2) : (m += 1) {
                const n = @as(i128, @intCast(r)) + @as(i128, @intCast(m)) * @as(i128, @intCast(q));
                if (n > M) {
                    ok = false;
                    break;
                }
                s[got] = a[@intCast(n)];
                got += 1;
            }
            if (!ok) break;
            // finite differences → degree + Newton coeffs
            var diff = s;
            var deg: ?usize = null;
            var b: [DMAX + 1]i128 = undefined;
            var kk: usize = 0;
            while (kk < DMAX + 1) : (kk += 1) {
                b[kk] = diff[0];
                var allz = true;
                for (0..DMAX + 1 - kk) |j| if (diff[j] != 0) {
                    allz = false;
                    break;
                };
                if (allz) {
                    deg = if (kk == 0) 0 else kk - 1;
                    break;
                }
                for (0..DMAX + 1 - kk) |j| diff[j] = diff[j + 1] - diff[j];
            }
            if (deg == null) {
                ok = false;
                break;
            }
            cf.deg[r] = deg.?;
            cf.coef[r] = b;
        }
        if (!ok) continue;
        // certify over [1,M]
        var good = true;
        var n: i128 = 1;
        while (n <= M) : (n += 1) {
            const r2: usize = @intCast(@mod(n, @as(i128, @intCast(q))));
            const m2 = @divTrunc(n - @as(i128, @intCast(r2)), @as(i128, @intCast(q)));
            var val: i128 = 0;
            for (0..cf.deg[r2] + 1) |kk| val += cf.coef[r2][kk] * binom(m2, kk);
            if (val != a[@intCast(n)]) {
                good = false;
                break;
            }
        }
        if (good) return cf;
    }
    return null;
}

// render a PLAIN polynomial (q==1) in n as (monomial...)/D
fn renderPoly(cf: CF) []const u8 {
    const d = cf.deg[0];
    const D = factv(d);
    var num = [_]i128{0} ** (DMAX + 1);
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
        const scale = cf.coef[0][k] * @divTrunc(D, factv(k));
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
    const out = std.fmt.allocPrint(A, "({s}) / {d}", .{ body, Ds }) catch return body;
    return out;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    A = arena.allocator();
    const o = std.io.getStdOut().writer();
    terms = std.ArrayList(T).init(A);

    try o.print("=== AUTO-DISCOVER — enumerate the loop/branch program space; certify every closed form ===\n", .{});
    try o.print("a(n) = sum_{{i=1..n, cond}} term(i,n). recover (quasi-)polynomial closed form + certify over [1,{d}], else abstain.\n\n", .{M});

    // 1. enumerate terms (bottom-up, dedup by behavior over the (i,n) grid, magnitude-pruned to low degree)
    terms.append(.{ .op = 0, .a = 0, .b = 0, .k = 0 }) catch {}; // i
    terms.append(.{ .op = 1, .a = 0, .b = 0, .k = 0 }) catch {}; // n
    terms.append(.{ .op = 2, .a = 0, .b = 0, .k = 1 }) catch {}; // 1
    terms.append(.{ .op = 2, .a = 0, .b = 0, .k = 2 }) catch {}; // 2
    terms.append(.{ .op = 2, .a = 0, .b = 0, .k = 3 }) catch {}; // 3
    var seenT = std.AutoHashMap(u64, void).init(A);
    const BOUND: i128 = 12 * GS * GS * GS * GS * GS;
    var fstart: usize = 0;
    var round: usize = 0;
    const TCAP = 520;
    while (round < 3 and terms.items.len < TCAP) : (round += 1) {
        const start = fstart;
        const end = terms.items.len;
        fstart = end;
        var i: usize = start;
        outer: while (i < end) : (i += 1) {
            var j: usize = 0;
            while (j < terms.items.len) : (j += 1) {
                var op: u8 = 3;
                while (op <= 5) : (op += 1) {
                    // behavior over grid + magnitude prune
                    var h: u64 = 1469598103934665603;
                    var big = false;
                    var gi: i128 = 1;
                    while (gi <= GS) : (gi += 1) {
                        var gn: i128 = 1;
                        while (gn <= GS) : (gn += 1) {
                            const va = evalT(@intCast(i), gi, gn);
                            const vb = evalT(@intCast(j), gi, gn);
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
    try o.print("[enumerate] {d} distinct terms × 6 branch conditions = {d} programs\n", .{ terms.items.len, terms.items.len * 6 });

    // 2. run the certifier over every program (q==1 plain polynomials kept; formStr = exact rendered closed form)
    const Prog = struct { term: u16, cond: u8, deg: usize, form: []const u8 };
    var poly = std.ArrayList(Prog).init(A);
    var quasi: usize = 0;
    var abstain: usize = 0;

    var tid: u16 = 0;
    while (tid < terms.items.len) : (tid += 1) {
        var c: u8 = 0;
        while (c < 6) : (c += 1) {
            const a = A.alloc(i128, @intCast(M + 1)) catch return;
            var of = false;
            var n: i128 = 0;
            while (n <= M) : (n += 1) {
                var s: i128 = 0;
                var i: i128 = 1;
                while (i <= n) : (i += 1) {
                    if (!condTrue(c, i)) continue;
                    s +%= evalT(tid, i, n);
                    if (s > (1 << 110) or s < -(1 << 110)) {
                        of = true;
                        break;
                    }
                }
                if (of) break;
                a[@intCast(n)] = s;
            }
            if (of) {
                abstain += 1;
                continue;
            }
            const cf = findCF(a) orelse {
                abstain += 1;
                continue;
            };
            if (cf.q == 1) {
                poly.append(.{ .term = tid, .cond = c, .deg = cf.deg[0], .form = renderPoly(cf) }) catch {};
            } else quasi += 1;
        }
    }
    const total = terms.items.len * 6;
    try o.print("[certify] {d} plain-polynomial closed forms · {d} quasi-polynomial (period 2/3) · {d} abstained (no closed form ≤deg {d})\n\n", .{ poly.items.len, quasi, abstain, DMAX });

    // 3. sample discovered closed forms, highest degree first, one representative per distinct formula
    std.mem.sort(Prog, poly.items, {}, struct {
        fn lt(_: void, x: Prog, y: Prog) bool {
            if (x.deg != y.deg) return x.deg > y.deg;
            return std.mem.lessThan(u8, x.form, y.form);
        }
    }.lt);
    try o.print("──────── sample discovered closed forms (auto-posed loop ≡ certified formula; spread across degrees) ────────\n", .{});
    var perdeg = [_]usize{0} ** (DMAX + 2);
    var i: usize = 0;
    while (i < poly.items.len) : (i += 1) {
        if (i > 0 and std.mem.eql(u8, poly.items[i].form, poly.items[i - 1].form)) continue; // one per formula
        const p = poly.items[i];
        if (perdeg[p.deg] >= 5) continue; // up to 5 per degree → a readable cross-section, not 20 near-equal quintics
        perdeg[p.deg] += 1;
        try o.print("    sum_{{i=1..n{s}}} {s:<18}  ≡  {s}\n", .{ condName(p.cond), termStr(p.term), p.form });
    }

    // 4. cross-program identities: GROUP by exact rendered closed form (no hashing) → runs of ≥2 distinct programs.
    //    These are equalities between structurally different loops that the engine PROVED (both certified to the
    //    same closed form over [1,M]). Only show non-trivial (degree ≥ 2) and genuinely different programs.
    var byform = std.StringHashMap(usize).init(A);
    for (poly.items) |p| {
        const e = byform.getOrPut(p.form) catch continue;
        if (!e.found_existing) e.value_ptr.* = 0;
        e.value_ptr.* += 1;
    }
    try o.print("\n──────── discovered IDENTITIES (different loops, SAME certified closed form) ────────\n", .{});
    var shown: usize = 0;
    i = 0;
    while (i < poly.items.len and shown < 16) {
        var j = i + 1;
        while (j < poly.items.len and std.mem.eql(u8, poly.items[j].form, poly.items[i].form)) j += 1;
        // run [i, j) shares one closed form; pick two structurally different programs from it
        if (j - i >= 2 and poly.items[i].deg >= 2) {
            const pa = poly.items[i];
            var bi = i + 1;
            while (bi < j and poly.items[bi].term == pa.term and poly.items[bi].cond == pa.cond) bi += 1;
            if (bi < j) {
                const pb = poly.items[bi];
                try o.print("    sum_{{i=1..n{s}}} {s} ≡ sum_{{i=1..n{s}}} {s}   [= {s}]\n", .{ condName(pa.cond), termStr(pa.term), condName(pb.cond), termStr(pb.term), pa.form });
                shown += 1;
            }
        }
        i = j;
    }

    try o.print("\n  Nothing was hand-picked: the machine enumerated {d} programs, certified {d} closed forms + {d} quasi-poly,\n", .{ total, poly.items.len, quasi });
    try o.print("  and abstained on {d} with no closed form of degree ≤{d}. Each identity is an equality between different\n", .{ abstain, DMAX });
    try o.print("  iterative programs it PROVED (both certified to the same closed form) — posed and certified end to end.\n", .{});
}
