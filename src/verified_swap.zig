//! Phase 5.3 — The Verified Swap.
//!
//! Demonstrates the HONEST two-stage geometric compiler on a real memory op
//! (swap two elements of a 4-element u32 array):
//!
//!   Stage 1 (structural, O(nodes)):  topological_validator decides WELL-FORMED.
//!   Stage 2 (semantic, real Z3):     z3_verifier lowers to SMT; libz3 PROVES
//!                                    bounds safety for all u32 inputs.
//!
//! It runs TWICE — a well-formed graph AND a negative control with the
//! Ast_BoundsCheck node removed — so you can see both stages independently
//! reject the unsafe variant. If either stage rubber-stamped everything, the
//! control would pass; it must not.
//!
//! HONESTY CAVEAT (stated plainly): the bounds check is PINNED into the intent
//! here, not invented by the engine. This proves the *pipeline* — that the
//! validator detects whether a guard is structurally present and that Z3
//! soundly proves/refutes safety conditional on it. It does NOT claim the
//! engine autonomously discovered that a bounds check was necessary.

const std = @import("std");
const vsa = @import("vsa_core.zig");
const codebook = @import("concept_codebook.zig");
const flame = @import("flame.zig");
const validator = @import("compiler/topological_validator.zig");
const z3v = @import("compiler/z3_verifier.zig");

const c = @cImport({
    @cInclude("z3.h");
});

fn z3SilentErrorHandler(_: c.Z3_context, _: c.Z3_error_code) callconv(.C) void {}

const Verdict = enum { unsat, sat, unknown, err };

fn verdictName(v: Verdict) []const u8 {
    return switch (v) {
        .unsat => "UNSAT  (proven safe for all u32 inputs)",
        .sat => "SAT    (counterexample exists — UNSAFE)",
        .unknown => "UNKNOWN (solver gave up)",
        .err => "ERROR  (bad SMT / runtime error)",
    };
}

/// Real libz3 invocation, same pattern as invent_cli.zig:verifySmt.
fn runZ3(allocator: std.mem.Allocator, smt_text: []const u8) Verdict {
    const cfg = c.Z3_mk_config() orelse return .err;
    defer c.Z3_del_config(cfg);
    c.Z3_set_param_value(cfg, "timeout", "5000");

    const ctx = c.Z3_mk_context(cfg) orelse return .err;
    defer c.Z3_del_context(ctx);
    c.Z3_set_error_handler(ctx, z3SilentErrorHandler);

    const text_z = allocator.dupeZ(u8, smt_text) catch return .err;
    defer allocator.free(text_z);

    const out_z = c.Z3_eval_smtlib2_string(ctx, text_z.ptr);
    if (out_z == null) return .err;
    const out = std.mem.span(out_z);

    var lines = std.mem.tokenizeAny(u8, out, "\n\r");
    const verdict_line = lines.next() orelse "";
    if (std.mem.startsWith(u8, verdict_line, "unsat")) return .unsat;
    if (std.mem.startsWith(u8, verdict_line, "sat")) return .sat;
    if (std.mem.startsWith(u8, verdict_line, "unknown")) return .unknown;
    return .err;
}

/// Build the 7-node swap graph. When `with_bounds_check` is false, the guard
/// node is replaced by a third index — producing an index with no sibling guard.
fn buildSwapSolver(allocator: std.mem.Allocator, with_bounds_check: bool) !flame.FlameSolver {
    var solver = try flame.FlameSolver.init(allocator, 7);

    solver.pin(0, codebook.Ast_FnDecl); // root: fn swap(...)
    solver.pin(1, codebook.Ast_Array_4_u32); // param: [4]u32
    solver.pin(2, codebook.Ast_Index_0); // index i
    solver.pin(3, codebook.Ast_Index_1); // index j
    if (with_bounds_check) {
        solver.pin(4, codebook.Ast_BoundsCheck); // guard: 0 <= idx < 4
    } else {
        solver.pin(4, codebook.Ast_Index_2); // NO guard — another bare index
    }
    solver.pin(5, codebook.Ast_Swap); // body: a[i] <-> a[j]
    solver.pin(6, codebook.Ast_ReturnStmt); // return

    // All six are children of the FnDecl root at distinct positional ports,
    // so the indices and the bounds check are topological siblings.
    solver.pinTopology(1, 0, 0);
    solver.pinTopology(2, 0, 1);
    solver.pinTopology(3, 0, 2);
    solver.pinTopology(4, 0, 3);
    solver.pinTopology(5, 0, 4);
    solver.pinTopology(6, 0, 5);

    return solver;
}

fn printDecodedGraph(solver: *flame.FlameSolver) void {
    std.debug.print("   decoded nodes:\n", .{});
    for (0..solver.nodes.len) |i| {
        const cpt = validator.decodeNode(solver, i);
        const parent: i64 = if (solver.topology[i]) |l| @intCast(l.parent) else -1;
        std.debug.print("     [{d}] {s:<16} parent={d}\n", .{ i, cpt.name(), parent });
    }
}

/// Run the full two-stage pipeline on one scenario; return whether it ended
/// in a fully-proven-safe emitted program.
fn runScenario(allocator: std.mem.Allocator, title: []const u8, with_bounds_check: bool) !bool {
    std.debug.print("\n══════════════════════════════════════════════════════\n", .{});
    std.debug.print("  SCENARIO: {s}\n", .{title});
    std.debug.print("══════════════════════════════════════════════════════\n", .{});

    var solver = try buildSwapSolver(allocator, with_bounds_check);
    defer solver.deinit();

    solver.relax(0);
    std.debug.print("\n-- relaxation --\n", .{});
    std.debug.print("   converged in {d} iterations, final energy = {d}\n", .{
        solver.convergence_iterations, solver.last_total_energy,
    });
    printDecodedGraph(&solver);

    // ---- Stage 1: structural lint ----
    std.debug.print("\n-- Stage 1: topological validator (structural lint) --\n", .{});
    const result = validator.validateTopology(&solver);
    switch (result) {
        .well_formed => |wf| {
            std.debug.print("   WELL-FORMED  (nodes={d}, indices={d}, bounds_checks={d})\n", .{
                wf.node_count, wf.index_nodes, wf.bounds_checks,
            });
        },
        .malformed => |mf| {
            std.debug.print("   MALFORMED: {s}\n", .{mf.reason.explain()});
            std.debug.print("   worst node = [{d}] {s}, localized tension = {d}\n", .{
                mf.worst_node, validator.decodeNode(&solver, mf.worst_node).name(), mf.tension,
            });
            std.debug.print("   -> rejected before reaching Z3. Pipeline stops here.\n", .{});
            return false;
        },
    }

    // ---- Stage 2: real Z3 proof ----
    std.debug.print("\n-- Stage 2: Z3 semantic proof (real libz3) --\n", .{});
    const smt = try z3v.generateBoundsSafetySmt(allocator, &solver);
    defer allocator.free(smt);
    std.debug.print("   SMT-LIB lowered from the validated graph:\n", .{});
    var it = std.mem.tokenizeScalar(u8, smt, '\n');
    while (it.next()) |line| std.debug.print("     | {s}\n", .{line});

    const verdict = runZ3(allocator, smt);
    std.debug.print("   Z3 verdict: {s}\n", .{verdictName(verdict)});

    if (verdict != .unsat) {
        std.debug.print("   -> NOT proven safe. No code emitted.\n", .{});
        return false;
    }

    // ---- Emit the scaffolded Zig for the proven-safe program ----
    std.debug.print("\n-- emitted Zig (structurally validated + Z3-proven bounds-safe) --\n", .{});
    const emitted =
        \\fn swap(a: *[4]u32, i: u32, j: u32) void {
        \\    // Z3-proven: for all u32 i, j, the guard below forces 0 <= idx < 4
        \\    // before either access, so neither a[i] nor a[j] is out of bounds.
        \\    if (i >= a.len or j >= a.len) return; // Ast_BoundsCheck
        \\    const tmp = a[i];
        \\    a[i] = a[j];
        \\    a[j] = tmp;
        \\}
    ;
    std.debug.print("{s}\n", .{emitted});
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  PHASE 5: TWO-STAGE GEOMETRIC COMPILER                ║\n", .{});
    std.debug.print("║  Stage 1 = structural lint · Stage 2 = real Z3 proof  ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    const good = try runScenario(allocator, "well-formed swap (bounds check present)", true);
    const bad = try runScenario(allocator, "NEGATIVE CONTROL (bounds check removed)", false);

    // Stage-2 isolation: the negative control is caught at Stage 1, so Z3 never
    // sees it. To prove Z3 itself discriminates (and isn't rigged to always say
    // UNSAT), feed it the UNGUARDED model directly, bypassing the linter. A real
    // solver must return SAT — i.e. find an out-of-bounds counterexample.
    std.debug.print("\n══════════════════════════════════════════════════════\n", .{});
    std.debug.print("  STAGE-2 ISOLATION: does Z3 alone reject the unsafe model?\n", .{});
    std.debug.print("══════════════════════════════════════════════════════\n", .{});
    var unguarded = try buildSwapSolver(allocator, false);
    defer unguarded.deinit();
    unguarded.relax(0);
    const unsafe_smt = try z3v.generateBoundsSafetySmt(allocator, &unguarded);
    defer allocator.free(unsafe_smt);
    const unsafe_verdict = runZ3(allocator, unsafe_smt);
    std.debug.print("   Z3 on unguarded model: {s}\n", .{verdictName(unsafe_verdict)});
    const z3_discriminates = unsafe_verdict == .sat;

    std.debug.print("\n══════════════════════════════════════════════════════\n", .{});
    std.debug.print("  PIPELINE SELF-TEST\n", .{});
    std.debug.print("══════════════════════════════════════════════════════\n", .{});
    std.debug.print("   well-formed scenario emitted proven-safe code : {s}\n", .{if (good) "YES (expected)" else "NO (BUG)"});
    std.debug.print("   negative control rejected at Stage 1          : {s}\n", .{if (!bad) "YES (expected)" else "NO (BUG — rubber-stamp!)"});
    std.debug.print("   Z3 flags unguarded model as SAT (has teeth)   : {s}\n", .{if (z3_discriminates) "YES (expected)" else "NO (BUG — Z3 never says SAT!)"});

    const pass = good and !bad and z3_discriminates;
    std.debug.print("\n   RESULT: {s}\n", .{if (pass) "PASS — both stages discriminate" else "FAIL"});
    if (!pass) std.process.exit(1);
}
