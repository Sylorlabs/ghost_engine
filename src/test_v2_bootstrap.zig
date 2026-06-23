//! Ghost Engine V2 Bootstrap — integration test for the Phase 2.1 pipeline.
//!
//! Two test cases:
//!   Case 1 (XOR):      catalog path — single primitive, found in Tier 1.
//!   Case 2 (compound): synthesis path — (a + b) ^ 0x0F, not in catalog,
//!                      discovered by Tier 2 enumerative tree search.
//!
//! Validation gates per case:
//!   [A] Dynamic VSA atom is near-orthogonal to all static codebook atoms
//!   [B] Correct SMT expression discovered via expected method (catalog/synthesis)
//!   [C] Z3 integration proof (unguarded) → SAT
//!   [D] Z3 integration proof (guarded)   → UNSAT
//!
//! Run with:  zig build v2-bootstrap

const std = @import("std");
const codebook = @import("concept_codebook.zig");
const vsa = @import("vsa_core.zig");
const learner = @import("compiler/axiom_learner.zig");

const c = @cImport({
    @cInclude("z3.h");
});

fn z3SilentErrorHandler(_: c.Z3_context, _: c.Z3_error_code) callconv(.C) void {}

const Verdict = enum { unsat, sat, unknown, err };

fn runZ3(allocator: std.mem.Allocator, smt: []const u8) Verdict {
    const cfg = c.Z3_mk_config() orelse return .err;
    defer c.Z3_del_config(cfg);
    c.Z3_set_param_value(cfg, "timeout", "5000");

    const ctx = c.Z3_mk_context(cfg) orelse return .err;
    defer c.Z3_del_context(ctx);
    c.Z3_set_error_handler(ctx, z3SilentErrorHandler);

    const smt_z = allocator.dupeZ(u8, smt) catch return .err;
    defer allocator.free(smt_z);

    const out_z = c.Z3_eval_smtlib2_string(ctx, smt_z.ptr);
    if (out_z == null) return .err;
    const out = std.mem.span(out_z);

    var lines = std.mem.tokenizeAny(u8, out, "\n\r");
    const first = lines.next() orelse return .err;
    if (std.mem.startsWith(u8, first, "unsat")) return .unsat;
    if (std.mem.startsWith(u8, first, "sat"))   return .sat;
    return .unknown;
}

fn xor_impl(a: u64, b: u64) u64 { return a ^ b; }
fn compound_impl(a: u64, b: u64) u64 { return (a +% b) ^ 0x0F; }

fn runCase(
    allocator: std.mem.Allocator,
    stdout: anytype,
    label: []const u8,
    atom_name: []const u8,
    op: *const fn (u64, u64) u64,
    expected_smt_fragment: []const u8,
    expected_method: learner.Method,
) !bool {
    try stdout.print("\n── Case: {s} ──\n", .{label});

    // Phase 1: dynamic vector allocation
    const vec = try codebook.getOrCreate(allocator, atom_name);
    var min_dist: u16 = 4097;
    for (codebook.all_concepts) |atom| {
        const d = vsa.hammingDistance(vec, atom);
        if (d < min_dist) min_dist = d;
    }
    const gate_a = min_dist > 1800;
    try stdout.print(
        "  [A] Min Hamming to static codebook: {d}  -> {s}\n",
        .{ min_dist, if (gate_a) "PASS" else "FAIL" },
    );

    // Phase 2: discovery
    const t0 = std.time.nanoTimestamp();
    const result = try learner.discoverOrSynthesize(allocator, op);
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - t0, 1_000_000);

    const gate_b = blk: {
        if (result) |disc| {
            defer allocator.free(disc.smt_expr);

            const correct_expr = std.mem.containsAtLeast(u8, disc.smt_expr, 1, expected_smt_fragment);
            const correct_method = disc.method == expected_method;
            try stdout.print(
                "  [B] {s} | method={s} | expr={s}  -> {s}\n",
                .{
                    @tagName(disc.method),
                    @tagName(expected_method),
                    disc.smt_expr,
                    if (correct_expr and correct_method) "PASS" else "FAIL",
                },
            );
            try stdout.print("      elapsed: {d} ms\n", .{elapsed_ms});

            // Integration proof uses the discovered expr
            const proofs = try learner.generateIntegrationProof(allocator, disc.smt_expr, 4);
            defer {
                allocator.free(proofs[0]);
                allocator.free(proofs[1]);
            }

            const v_unguarded = runZ3(allocator, proofs[0]);
            const gate_c = v_unguarded == .sat;
            try stdout.print(
                "  [C] Unguarded (expect SAT):   {s}  -> {s}\n",
                .{ @tagName(v_unguarded), if (gate_c) "PASS" else "FAIL" },
            );

            const v_guarded = runZ3(allocator, proofs[1]);
            const gate_d = v_guarded == .unsat;
            try stdout.print(
                "  [D] Guarded   (expect UNSAT): {s}  -> {s}\n",
                .{ @tagName(v_guarded), if (gate_d) "PASS" else "FAIL" },
            );

            break :blk correct_expr and correct_method and gate_c and gate_d;
        } else {
            try stdout.writeAll("  [B] FAIL — no result returned\n");
            break :blk false;
        }
    };

    return gate_a and gate_b;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("\n=== Ghost Engine V2.1 Bootstrap ===\n");

    codebook.initRegistry(allocator);
    defer codebook.deinitRegistry(allocator);

    var smt_lowering_map = std.StringHashMap([]const u8).init(allocator);
    defer smt_lowering_map.deinit();

    // Case 1: simple XOR — catalog should find "(bvxor a b)"
    const ok1 = try runCase(
        allocator,
        stdout,
        "XOR (catalog path)",
        "Ast_Op_BitwiseXor",
        &xor_impl,
        "bvxor",
        .catalog,
    );

    // Case 2: compound (a + b) ^ 0x0F — catalog fails, synthesis finds the tree
    const ok2 = try runCase(
        allocator,
        stdout,
        "Compound (a+b)^0x0F (synthesis path)",
        "Ast_Op_CompoundXorAdd",
        &compound_impl,
        "bvxor",  // synthesized expr will contain "bvxor" and "bvadd"
        .synthesis,
    );

    const all_pass = ok1 and ok2;
    try stdout.print(
        "\n=== {s} ===\n",
        .{if (all_pass) "ALL GATES GREEN" else "SOME GATES FAILED"},
    );
    if (!all_pass) std.process.exit(1);
}
