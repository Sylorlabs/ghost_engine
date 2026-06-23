//! Ghost Engine V2.1 — Boundary Characterization Protocol.
//!
//! This executable characterizes the absolute limits of the depth-2 enumerative
//! synthesizer after the unary grammar expansion (bvnot, bvneg). It does NOT
//! hardcode expected SMT strings; the engine constructs every tree organically.
//!
//! Three cases:
//!   Test 1 (Unary Mix):       ~(a & b)         → expect FOUND  (depth-2 unary)
//!   Test 2 (Hardest Depth-2): (a + b) & ~a     → expect FOUND  (depth-2 binary)
//!   Test 3 (Depth-3 wall):    (a+b)^(a-b)|0xFF → expect BOUNDARY REACHED
//!
//! Run with:  zig build v2-boundary

const std = @import("std");
const learner = @import("compiler/axiom_learner.zig");

// ── Test functions (unknown to the synthesizer — it only sees their outputs) ──

fn test1(a: u64, b: u64) u64 { return ~(a & b); }
fn test2(a: u64, b: u64) u64 { return (a +% b) & ~a; }
// Zig precedence: | < ^ so this parses as ((a+b)^(a-b))|0xFF = bvor(bvxor(...), 0xFF)
// The outer bvor receives a depth-2 bvxor as its lhs — making the full tree depth-3.
fn test3(a: u64, b: u64) u64 { return (a +% b) ^ (a -% b) | 0xFF; }

// ── Case runner ────────────────────────────────────────────────────────────────

const CaseResult = enum { found, boundary_reached };

fn runCase(
    allocator: std.mem.Allocator,
    stdout: anytype,
    label: []const u8,
    op: *const fn (u64, u64) u64,
    expect: CaseResult,
) !bool {
    try stdout.print("\n── Case: {s} ──\n", .{label});

    const t0 = std.time.nanoTimestamp();
    const result = try learner.discoverOrSynthesize(allocator, op);
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - t0, 1_000_000);

    switch (expect) {
        .found => {
            if (result) |disc| {
                defer allocator.free(disc.smt_expr);
                try stdout.print(
                    "  [FOUND]  method={s}  expr={s}\n",
                    .{ @tagName(disc.method), disc.smt_expr },
                );
                try stdout.print(
                    "           samples={d}/1024  elapsed={d}ms\n",
                    .{ disc.match_count, elapsed_ms },
                );
                try stdout.print("  [PASS]\n", .{});
                return true;
            } else {
                try stdout.print(
                    "  [FAIL]  expected synthesis to succeed but engine returned null\n",
                    .{},
                );
                return false;
            }
        },
        .boundary_reached => {
            if (result) |disc| {
                defer allocator.free(disc.smt_expr);
                // A match here means a depth-<=2 expression accidentally covers the
                // depth-3 function on all 1024 samples — statistically impossible
                // for random 64-bit inputs, but we surface it rather than hide it.
                try stdout.print(
                    "  [UNEXPECTED MATCH]  expr={s}  method={s}\n",
                    .{ disc.smt_expr, @tagName(disc.method) },
                );
                try stdout.print(
                    "  [FAIL]  expected boundary but got a result — investigate\n",
                    .{},
                );
                return false;
            } else {
                try stdout.print(
                    "  [BOUNDARY REACHED]  elapsed={d}ms — depth-2 search exhausted, no match\n",
                    .{elapsed_ms},
                );
                try stdout.print(
                    "  [PASS]  engine exited gracefully; depth-3 wall confirmed empirically\n",
                    .{},
                );
                return true;
            }
        },
    }
}

// ── Entry point ────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("\n=== Ghost Engine V2.1 — Boundary Characterization Protocol ===\n");
    try stdout.writeAll("Grammar: bvadd bvsub bvxor bvand bvor bvshl bvlshr | bvnot bvneg\n");
    try stdout.writeAll("Search depth: max 2  |  Samples: 1024  |  No SMT hardcoding\n");

    const ok1 = try runCase(
        allocator, stdout,
        "Test 1 — Unary Mix: ~(a & b)  [depth-2 unary over depth-1 binary]",
        &test1,
        .found,
    );

    const ok2 = try runCase(
        allocator, stdout,
        "Test 2 — Hardest Depth-2: (a + b) & ~a  [depth-2 binary, lhs=depth-1 binary, rhs=depth-1 unary]",
        &test2,
        .found,
    );

    const ok3 = try runCase(
        allocator, stdout,
        "Test 3 — Depth-3 Wall: (a+b)^(a-b)|0xFF  [bvor(bvxor(depth-1,depth-1), const) = depth-3]",
        &test3,
        .boundary_reached,
    );

    const all_pass = ok1 and ok2 and ok3;
    try stdout.print(
        "\n=== {s} ===\n",
        .{if (all_pass) "ALL GATES GREEN — boundary confirmed" else "SOME GATES FAILED"},
    );
    if (!all_pass) std.process.exit(1);
}
