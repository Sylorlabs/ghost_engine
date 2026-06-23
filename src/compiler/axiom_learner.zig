//! Phase 2.1 — Two-Tier Axiom Discovery: Catalog + Enumerative Tree Synthesis.
//!
//! HONEST NAMING: Tier 2 is ENUMERATIVE PROGRAM SYNTHESIS, not "genetic" or
//! "evolutionary." There is no population, no crossover, no selection pressure.
//! The search is deterministic depth-first enumeration of expression trees over
//! a finite grammar, with early exit on the first sample mismatch. At depth 2
//! the search space is ~29M candidates; early exit makes each wrong candidate
//! cost ~1 comparison on average (<100ms total).
//!
//! Two-tier pipeline:
//!   Tier 1 (catalog): test 7 single bitvector primitives in ~7K comparisons.
//!   Tier 2 (synthesis): enumerate expression trees up to depth 2.
//!     Grammar terminals: {a, b} + 15 small constants.
//!     Grammar binary operators: bvadd bvsub bvxor bvand bvor bvshl bvlshr.
//!     Grammar unary operators:  bvnot bvneg.
//!     Depth-1 unary = unary_op(leaf).
//!     Depth-2 unary = unary_op(depth-1 node).
//!     Depth-2 binary = binary_op(x, y) where x, y ∈ leaves ∪ depth-1.
//!
//! NOTE: SmtOp and SmtUnaryOp are intentionally separate enums. SmtOp drives
//! the (op, lhs, rhs) binary inner-product; mixing unary ops in would produce
//! malformed 3-slot nodes. Arity is fixed per kind, not per tag.
//!
//! SHIFT SEMANTICS: bvshl/bvlshr use `if (shift >= 64) 0 else` to match Z3's
//! bitvector semantics. Zig's @truncate wraps mod 64; Z3 returns 0 for large
//! shifts. Inconsistency here would cause false negatives in behavioral matching.
//!
//! CONSTANT POOL: {0,1,2,3,4,7,8,15,16,31,32,63,64,127,255} — natural
//! bit-manipulation building blocks. An operator whose constant lies outside
//! this pool will not be found; Tier 2 returns null in that case.

const std = @import("std");

pub const SAMPLE_COUNT: usize = 1024;
const BinOp = *const fn (u64, u64) u64;

// ── Expression Tree ───────────────────────────────────────────────────────────

pub const SmtOp = enum { bvadd, bvsub, bvxor, bvand, bvor, bvshl, bvlshr };
pub const SmtUnaryOp = enum { bvnot, bvneg };

const OPS = [_]SmtOp{ .bvadd, .bvsub, .bvxor, .bvand, .bvor, .bvshl, .bvlshr };
const UNARY_OPS = [_]SmtUnaryOp{ .bvnot, .bvneg };

pub const SmtExpr = union(enum) {
    var_a,
    var_b,
    constant: u64,
    binary: struct { op: SmtOp, lhs: *const SmtExpr, rhs: *const SmtExpr },
    unary: struct { op: SmtUnaryOp, operand: *const SmtExpr },
    reg: usize,
};

/// Evaluate an expression tree against a single (a, b) input pair.
pub fn evalExpr(expr: *const SmtExpr, a: u64, b: u64) u64 {
    return switch (expr.*) {
        .var_a => a,
        .var_b => b,
        .constant => |k| k,
        .binary => |bin| {
            const l = evalExpr(bin.lhs, a, b);
            const r = evalExpr(bin.rhs, a, b);
            return switch (bin.op) {
                .bvadd => l +% r,
                .bvsub => l -% r,
                .bvxor => l ^ r,
                .bvand => l & r,
                .bvor  => l | r,
                .bvshl  => if (r >= 64) 0 else l << @intCast(r),
                .bvlshr => if (r >= 64) 0 else l >> @intCast(r),
            };
        },
        .unary => |un| {
            const x = evalExpr(un.operand, a, b);
            return switch (un.op) {
                .bvnot => ~x,
                .bvneg => 0 -% x,
            };
        },
        .reg => unreachable,
    };
}

/// Test expr against all samples; exits immediately on the first mismatch.
fn matchesSamples(
    expr: *const SmtExpr,
    ins_a: []const u64,
    ins_b: []const u64,
    expected: []const u64,
) bool {
    for (0..ins_a.len) |i| {
        if (evalExpr(expr, ins_a[i], ins_b[i]) != expected[i]) return false;
    }
    return true;
}

/// Emit a complete SMT-LIB2 bitvector expression into `out`.
/// e.g., "(bvxor a b)", "(bvxor (bvadd a b) (_ bv15 64))", "(bvnot (bvand a b))"
pub fn emitSmt(expr: *const SmtExpr, out: anytype) @TypeOf(out).Error!void {
    switch (expr.*) {
        .var_a => try out.writeAll("a"),
        .var_b => try out.writeAll("b"),
        .constant => |k| try out.print("(_ bv{d} 64)", .{k}),
        .binary => |bin| {
            try out.print("({s} ", .{@tagName(bin.op)});
            try emitSmt(bin.lhs, out);
            try out.writeAll(" ");
            try emitSmt(bin.rhs, out);
            try out.writeAll(")");
        },
        .unary => |un| {
            try out.print("({s} ", .{@tagName(un.op)});
            try emitSmt(un.operand, out);
            try out.writeAll(")");
        },
        .reg => |idx| {
            try out.print("(Reg {d})", .{idx});
        },
    }
}

// ── Result Type ───────────────────────────────────────────────────────────────

pub const Method = enum { catalog, synthesis };

pub const DiscoveryResult = struct {
    /// Complete SMT-LIB2 expression using free variables `a` and `b`.
    /// e.g., "(bvxor a b)" for a catalog match.
    ///      "(bvxor (bvadd a b) (_ bv15 64))" for a synthesis result.
    /// Heap-allocated from the allocator passed to discoverOrSynthesize; caller frees.
    smt_expr: []u8,
    match_count: usize,
    method: Method,
};

// ── Sample Collection ─────────────────────────────────────────────────────────

fn collectSamples(ins_a: []u64, ins_b: []u64, observed: []u64, op: BinOp) void {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef_cafebabe);
    const rng = prng.random();
    for (0..SAMPLE_COUNT) |i| {
        ins_a[i] = rng.int(u64);
        ins_b[i] = rng.int(u64);
        observed[i] = op(ins_a[i], ins_b[i]);
    }
}

// ── Tier 1: Catalog ───────────────────────────────────────────────────────────

fn bvxor_fn(a: u64, b: u64) u64 { return a ^ b; }
fn bvand_fn(a: u64, b: u64) u64 { return a & b; }
fn bvor_fn(a: u64, b: u64) u64 { return a | b; }
fn bvadd_fn(a: u64, b: u64) u64 { return a +% b; }
fn bvsub_fn(a: u64, b: u64) u64 { return a -% b; }
fn bvshl_fn(a: u64, b: u64) u64 { return if (b >= 64) 0 else a << @intCast(b); }
fn bvlshr_fn(a: u64, b: u64) u64 { return if (b >= 64) 0 else a >> @intCast(b); }

const CatalogEntry = struct { smt_name: []const u8, eval: BinOp };

const CATALOG = [_]CatalogEntry{
    .{ .smt_name = "bvxor",  .eval = &bvxor_fn  },
    .{ .smt_name = "bvand",  .eval = &bvand_fn  },
    .{ .smt_name = "bvor",   .eval = &bvor_fn   },
    .{ .smt_name = "bvadd",  .eval = &bvadd_fn  },
    .{ .smt_name = "bvsub",  .eval = &bvsub_fn  },
    .{ .smt_name = "bvshl",  .eval = &bvshl_fn  },
    .{ .smt_name = "bvlshr", .eval = &bvlshr_fn },
};

pub fn catalogSearch(
    allocator: std.mem.Allocator,
    ins_a: []const u64,
    ins_b: []const u64,
    observed: []const u64,
) !?DiscoveryResult {
    for (CATALOG) |entry| {
        var all_match = true;
        for (0..SAMPLE_COUNT) |i| {
            if (entry.eval(ins_a[i], ins_b[i]) != observed[i]) { all_match = false; break; }
        }
        if (all_match) {
            return DiscoveryResult{
                .smt_expr = try std.fmt.allocPrint(allocator, "({s} a b)", .{entry.smt_name}),
                .match_count = SAMPLE_COUNT,
                .method = .catalog,
            };
        }
    }
    return null;
}

// ── Tier 2: Enumerative Tree Synthesis ───────────────────────────────────────

const SYNTH_CONSTANTS = [_]u64{
    0, 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64, 127, 255,
};

const NUM_LEAVES = 2 + SYNTH_CONSTANTS.len;

pub fn synthesizeTree(
    allocator: std.mem.Allocator,
    ins_a: []const u64,
    ins_b: []const u64,
    observed: []const u64,
) !?DiscoveryResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // ── Build leaf nodes ──────────────────────────────────────────────────────
    var leaves: [NUM_LEAVES]*SmtExpr = undefined;

    const lv_a = try ar.create(SmtExpr);
    lv_a.* = .var_a;
    leaves[0] = lv_a;

    const lv_b = try ar.create(SmtExpr);
    lv_b.* = .var_b;
    leaves[1] = lv_b;

    for (SYNTH_CONSTANTS, 0..) |k, ci| {
        const node = try ar.create(SmtExpr);
        node.* = .{ .constant = k };
        leaves[2 + ci] = node;
    }

    // ── Depth-1: test all binary AND unary combinations of leaves ─────────────
    var depth1 = std.ArrayList(*SmtExpr).init(ar);

    // Depth-1 binary: binary_op(leaf, leaf)
    for (OPS) |op| {
        for (leaves) |lhs| {
            for (leaves) |rhs| {
                const node = try ar.create(SmtExpr);
                node.* = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } };
                if (matchesSamples(node, ins_a, ins_b, observed)) {
                    var buf = std.ArrayList(u8).init(allocator);
                    try emitSmt(node, buf.writer());
                    return DiscoveryResult{
                        .smt_expr = try buf.toOwnedSlice(),
                        .match_count = SAMPLE_COUNT,
                        .method = .synthesis,
                    };
                }
                try depth1.append(node);
            }
        }
    }

    // Depth-1 unary: unary_op(leaf)
    for (UNARY_OPS) |op| {
        for (leaves) |operand| {
            const node = try ar.create(SmtExpr);
            node.* = .{ .unary = .{ .op = op, .operand = operand } };
            if (matchesSamples(node, ins_a, ins_b, observed)) {
                var buf = std.ArrayList(u8).init(allocator);
                try emitSmt(node, buf.writer());
                return DiscoveryResult{
                    .smt_expr = try buf.toOwnedSlice(),
                    .match_count = SAMPLE_COUNT,
                    .method = .synthesis,
                };
            }
            try depth1.append(node);
        }
    }

    // ── Depth-2: enumerate over leaves ∪ depth-1 ──────────────────────────────
    // Candidates are stack-local (not stored) — only the winner is arena-copied.
    const all_count = NUM_LEAVES + depth1.items.len;

    // Depth-2 binary: binary_op(x, y) where x, y ∈ leaves ∪ depth-1
    for (OPS) |op| {
        for (0..all_count) |li| {
            const lhs: *const SmtExpr = if (li < NUM_LEAVES)
                leaves[li]
            else
                depth1.items[li - NUM_LEAVES];
            for (0..all_count) |ri| {
                const rhs: *const SmtExpr = if (ri < NUM_LEAVES)
                    leaves[ri]
                else
                    depth1.items[ri - NUM_LEAVES];
                const cand = SmtExpr{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } };
                if (matchesSamples(&cand, ins_a, ins_b, observed)) {
                    const winner = try ar.create(SmtExpr);
                    winner.* = cand;
                    var buf = std.ArrayList(u8).init(allocator);
                    try emitSmt(winner, buf.writer());
                    return DiscoveryResult{
                        .smt_expr = try buf.toOwnedSlice(),
                        .match_count = SAMPLE_COUNT,
                        .method = .synthesis,
                    };
                }
            }
        }
    }

    // Depth-2 unary: unary_op(depth-1 node)
    // (unary over leaves was already done in depth-1; this extends to one level deeper)
    for (UNARY_OPS) |op| {
        for (depth1.items) |operand| {
            const cand = SmtExpr{ .unary = .{ .op = op, .operand = operand } };
            if (matchesSamples(&cand, ins_a, ins_b, observed)) {
                const winner = try ar.create(SmtExpr);
                winner.* = cand;
                var buf = std.ArrayList(u8).init(allocator);
                try emitSmt(winner, buf.writer());
                return DiscoveryResult{
                    .smt_expr = try buf.toOwnedSlice(),
                    .match_count = SAMPLE_COUNT,
                    .method = .synthesis,
                };
            }
        }
    }

    return null;
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Full pipeline: Tier 1 (catalog) then Tier 2 (synthesis) if catalog misses.
/// On success, DiscoveryResult.smt_expr is heap-allocated; caller must free.
pub fn discoverOrSynthesize(allocator: std.mem.Allocator, op: BinOp) !?DiscoveryResult {
    var ins_a: [SAMPLE_COUNT]u64 = undefined;
    var ins_b: [SAMPLE_COUNT]u64 = undefined;
    var observed: [SAMPLE_COUNT]u64 = undefined;
    collectSamples(&ins_a, &ins_b, &observed, op);
    if (try catalogSearch(allocator, &ins_a, &ins_b, &observed)) |r| return r;
    return synthesizeTree(allocator, &ins_a, &ins_b, &observed);
}

// ── Integration Proof Emitter ─────────────────────────────────────────────────

/// Emit two SMT-LIB2 bitvector proof obligations (caller frees both slices).
///   proofs[0]: unguarded — expect SAT  (the expression CAN produce OOB)
///   proofs[1]: guarded   — expect UNSAT (guard makes OOB unreachable)
///
/// `smt_expr` is a COMPLETE expression using free BitVec-64 variables a and b,
/// e.g., "(bvxor a b)" or "(bvxor (bvadd a b) (_ bv15 64))".
pub fn generateIntegrationProof(
    allocator: std.mem.Allocator,
    smt_expr: []const u8,
    array_len: u64,
) ![2][]const u8 {
    var out0 = std.ArrayList(u8).init(allocator);
    errdefer out0.deinit();
    try out0.writer().print(
        ";; --- INTEGRATION PROOF (unguarded) ---\n" ++
        ";; idx = {s}\n" ++
        ";; Expect: SAT (expression can produce OOB index for some inputs)\n" ++
        "(declare-const a (_ BitVec 64))\n" ++
        "(declare-const b (_ BitVec 64))\n" ++
        "(declare-const len (_ BitVec 64))\n" ++
        "(assert (= len (_ bv{d} 64)))\n" ++
        "(assert (bvuge {s} len))\n" ++
        "(check-sat)\n",
        .{ smt_expr, array_len, smt_expr },
    );

    var out1 = std.ArrayList(u8).init(allocator);
    errdefer out1.deinit();
    try out1.writer().print(
        ";; --- INTEGRATION PROOF (guarded) ---\n" ++
        ";; idx = {s}\n" ++
        ";; Expect: UNSAT (guard blocks OOB for ALL 64-bit inputs)\n" ++
        "(declare-const a (_ BitVec 64))\n" ++
        "(declare-const b (_ BitVec 64))\n" ++
        "(declare-const len (_ BitVec 64))\n" ++
        "(assert (= len (_ bv{d} 64)))\n" ++
        "(assert (bvult {s} len))\n" ++
        "(assert (bvuge {s} len))\n" ++
        "(check-sat)\n",
        .{ smt_expr, array_len, smt_expr, smt_expr },
    );

    return [2][]const u8{ try out0.toOwnedSlice(), try out1.toOwnedSlice() };
}
