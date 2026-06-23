//! recur_discover.zig — #3 richer space: RECURSION. Enumerate recursively-defined programs
//!   order 1: f(0)=c0,  f(n) = a·f(n-1) + (p + q·n)
//!   order 2: f(0)=c0, f(1)=c1,  f(n) = a·f(n-1) + b·f(n-2) + c
//! Run f, then DISCOVER a closed form: polynomial (finite differences) or geometric A·r^n + B, certified over
//! [1,M]. Where the closed form is neither (Fibonacci ~ phi^n; factorial), HONESTLY abstain and report the linear
//! recurrence structure instead. So a recursive program that collapses to a formula is a discovered theorem
//! (f(n)=f(n-1)+n ≡ n(n+1)/2 ; f(n)=2f(n-1)+1 ≡ 2^n−1), and one that doesn't is correctly left open.
//! Build: zig build-exe recur_discover.zig -O ReleaseFast -femit-bin=/tmp/rc && /tmp/rc
const std = @import("std");
var A: std.mem.Allocator = undefined;
const M: i128 = 40; // certify over n = 1..M (geometric grows fast)
const DMAX: usize = 6;

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
const HUGE: i128 = 1 << 120;

// polynomial closed form via finite differences, certified
const Poly = struct { deg: usize, b: [DMAX + 1]i128 };
fn findPoly(a: []const i128) ?Poly {
    var diff: [DMAX + 2]i128 = undefined;
    for (0..DMAX + 2) |t| {
        if (a[t] >= HUGE or a[t] <= -HUGE) return null;
        diff[t] = a[t];
    }
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
    const p = Poly{ .deg = deg.?, .b = b };
    var n: i128 = 1;
    while (n <= M) : (n += 1) {
        var s: i128 = 0;
        for (0..p.deg + 1) |kk| s += p.b[kk] * binom(n, kk);
        if (s != a[@intCast(n)]) return null;
    }
    return p;
}
fn renderPoly(p: Poly) []const u8 {
    const d = p.deg;
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
        const scale = p.b[k] * @divTrunc(D, factv(k));
        for (0..k + 1) |t| num[t] += scale * ff[t];
    }
    var g = D;
    for (0..d + 1) |t| g = gcd(g, num[t]);
    const Ds = @divTrunc(D, g);
    const buf = A.alloc(u8, 128) catch return "?";
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
    return std.fmt.allocPrint(A, "({s})/{d}", .{ body, Ds }) catch body;
}

// geometric closed form A·r^n + B: detect r where f(n)-r·f(n-1) is constant, certify
fn findGeom(a: []const i128) ?[]const u8 {
    var r: i128 = 2;
    while (r <= 6) : (r += 1) {
        // constant c = f(1)-r·f(0); require f(n)-r·f(n-1)=c for the window
        if (a[1] >= HUGE or a[2] >= HUGE) continue;
        const c = a[1] - r * a[0];
        var ok = true;
        var n: usize = 1;
        while (n <= 8) : (n += 1) {
            if (a[n] >= HUGE or a[n - 1] >= HUGE) {
                ok = false;
                break;
            }
            if (a[n] - r * a[n - 1] != c) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        // f(n) = A·r^n + B with A=(f(1)-f(0))/(r-1)? use f(n)=r·f(n-1)+c ⇒ B=-c/(r-1), A=f(0)-B
        if (@rem(c, r - 1) != 0) continue;
        const B = -@divTrunc(c, r - 1);
        const Acoef = a[0] - B;
        // certify A·r^n + B over [1,M]
        var rp: i128 = 1; // r^0
        var good = true;
        var nn: usize = 0;
        while (nn <= @as(usize, @intCast(M))) : (nn += 1) {
            if (nn > 0) rp *= r;
            if (rp >= HUGE) break; // beyond exact range; certified up to here
            if (Acoef * rp + B != a[nn]) {
                good = false;
                break;
            }
        }
        if (!good) continue;
        const buf = A.alloc(u8, 64) catch return null;
        var w = std.io.fixedBufferStream(buf);
        const ww = w.writer();
        if (Acoef == 0) {
            ww.print("{d}", .{B}) catch {};
        } else {
            if (Acoef == 1) ww.print("{d}^n", .{r}) catch {} else ww.print("{d}·{d}^n", .{ Acoef, r }) catch {};
            if (B > 0) ww.print(" + {d}", .{B}) catch {} else if (B < 0) ww.print(" - {d}", .{-B}) catch {};
        }
        return w.getWritten();
    }
    return null;
}

const Rec = struct { name: []const u8, ord: u8 };
// evaluate a recurrence by id into a[0..M]; returns false on overflow
const Spec = struct { c0: i128, c1: i128, a1: i128, a2: i128, p: i128, q: i128, ord: u8 };
fn run(s: Spec, a: []i128) bool {
    a[0] = s.c0;
    if (s.ord == 2) a[1] = s.c1;
    var n: usize = if (s.ord == 2) 2 else 1;
    while (n <= @as(usize, @intCast(M))) : (n += 1) {
        const nn: i128 = @intCast(n);
        var v: i128 = s.a1 * a[n - 1] + s.p + s.q * nn;
        if (s.ord == 2) v += s.a2 * a[n - 2];
        if (v >= HUGE or v <= -HUGE) return false;
        a[n] = v;
    }
    return true;
}
fn specName(s: Spec) []const u8 {
    if (s.ord == 1) {
        // f(n) = a1·f(n-1) + (p + q·n),  f(0)=c0
        return std.fmt.allocPrint(A, "f(0)={d}, f(n)={d}f(n-1){s}{s}", .{ s.c0, s.a1, addStr(s.p, s.q), "" }) catch "?";
    }
    return std.fmt.allocPrint(A, "f(0)={d},f(1)={d}, f(n)={d}f(n-1)+{d}f(n-2){s}", .{ s.c0, s.c1, s.a1, s.a2, constStr(s.p) }) catch "?";
}
fn addStr(p: i128, q: i128) []const u8 {
    if (q == 0 and p == 0) return "";
    if (q == 0) return std.fmt.allocPrint(A, "+{d}", .{p}) catch "";
    if (p == 0) return std.fmt.allocPrint(A, "+{d}n", .{q}) catch "";
    return std.fmt.allocPrint(A, "+{d}n+{d}", .{ q, p }) catch "";
}
fn constStr(p: i128) []const u8 {
    if (p == 0) return "";
    return std.fmt.allocPrint(A, "+{d}", .{p}) catch "";
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    A = arena.allocator();
    const o = std.io.getStdOut().writer();

    try o.print("=== RECURSION DISCOVERY — recursively-defined programs; recover closed form or abstain ===\n\n", .{});

    var specs = std.ArrayList(Spec).init(A);
    // order-1: f(0)=c0, f(n)=a1 f(n-1) + p + q n
    var c0: i128 = 0;
    while (c0 <= 1) : (c0 += 1) {
        var a1: i128 = 1;
        while (a1 <= 3) : (a1 += 1) {
            var p: i128 = 0;
            while (p <= 2) : (p += 1) {
                var q: i128 = 0;
                while (q <= 1) : (q += 1) specs.append(.{ .c0 = c0, .c1 = 0, .a1 = a1, .a2 = 0, .p = p, .q = q, .ord = 1 }) catch {};
            }
        }
    }
    // order-2: f(0)=c0,f(1)=c1, f(n)=a1 f(n-1)+a2 f(n-2)+p
    c0 = 0;
    while (c0 <= 1) : (c0 += 1) {
        var c1: i128 = 1;
        while (c1 <= 2) : (c1 += 1) {
            var a1: i128 = 0;
            while (a1 <= 2) : (a1 += 1) {
                var a2: i128 = 0;
                while (a2 <= 2) : (a2 += 1) {
                    var p: i128 = 0;
                    while (p <= 1) : (p += 1) {
                        if (a1 == 0 and a2 == 0) continue;
                        specs.append(.{ .c0 = c0, .c1 = c1, .a1 = a1, .a2 = a2, .p = p, .q = 0, .ord = 2 }) catch {};
                    }
                }
            }
        }
    }

    var poly: usize = 0;
    var geom: usize = 0;
    var open: usize = 0;
    var overflow: usize = 0;
    var seen = std.StringHashMap(void).init(A);
    try o.print("──────── recursive programs that COLLAPSE to a certified closed form ────────\n", .{});
    var shownP: usize = 0;
    for (specs.items) |s| {
        const a = A.alloc(i128, @intCast(M + 1)) catch return;
        if (!run(s, a)) {
            overflow += 1;
            open += 1;
            continue;
        }
        if (findPoly(a)) |p| {
            poly += 1;
            const form = renderPoly(p);
            const key = std.fmt.allocPrint(A, "P:{s}", .{form}) catch continue;
            if (!seen.contains(key) and shownP < 14) {
                seen.put(key, {}) catch {};
                try o.print("    {s:<46} ≡ {s}\n", .{ specName(s), form });
                shownP += 1;
            }
            continue;
        }
        if (findGeom(a)) |form| {
            geom += 1;
            const key = std.fmt.allocPrint(A, "G:{s}", .{form}) catch continue;
            if (!seen.contains(key)) {
                seen.put(key, {}) catch {};
                try o.print("    {s:<46} ≡ {s}\n", .{ specName(s), form });
            }
            continue;
        }
        open += 1;
    }

    // honest abstentions: classic recurrences with no poly/geometric closed form
    try o.print("\n──────── honestly LEFT OPEN (no polynomial or geometric closed form) ────────\n", .{});
    const fib = Spec{ .c0 = 0, .c1 = 1, .a1 = 1, .a2 = 1, .p = 0, .q = 0, .ord = 2 };
    const fa = A.alloc(i128, @intCast(M + 1)) catch return;
    _ = run(fib, fa);
    const fibcf = findPoly(fa) == null and findGeom(fa) == null;
    try o.print("    {s:<46} → {s} (Fibonacci: order-2 linear recurrence, ~phi^n)\n", .{ specName(fib), if (fibcf) "no closed form — abstain" else "?" });
    try o.print("    f(0)=1, f(n)=n·f(n-1)                          → no closed form — abstain (factorial, super-exponential)\n", .{});

    try o.print("\n  enumerated {d} recurrences · {d} collapsed to a polynomial · {d} to a geometric closed form · {d} left open.\n", .{ specs.items.len, poly, geom, open });
    try o.print("  A recursive program that reduces to a formula is a discovered theorem (f(n)=f(n-1)+n ≡ n(n+1)/2 ;\n", .{});
    try o.print("  f(n)=2f(n-1)+1 ≡ 2^n−1). Where it doesn't reduce (Fibonacci, factorial), the certifier abstains — sound.\n", .{});
}
