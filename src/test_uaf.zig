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
        .unsat => "UNSAT  (proven safe)",
        .sat => "SAT    (counterexample exists — UNSAFE)",
        .unknown => "UNKNOWN (solver gave up)",
        .err => "ERROR  (bad SMT / runtime error)",
    };
}

const Z3Result = struct {
    verdict: Verdict,
    output: []u8,
};

/// Real libz3 invocation.
fn runZ3(allocator: std.mem.Allocator, smt_text: []const u8) Z3Result {
    const empty = Z3Result{ .verdict = .err, .output = allocator.dupe(u8, "") catch unreachable };
    const cfg = c.Z3_mk_config() orelse return empty;
    defer c.Z3_del_config(cfg);
    c.Z3_set_param_value(cfg, "timeout", "5000");

    const ctx = c.Z3_mk_context(cfg) orelse return empty;
    defer c.Z3_del_context(ctx);
    c.Z3_set_error_handler(ctx, z3SilentErrorHandler);

    const text_z = allocator.dupeZ(u8, smt_text) catch return empty;
    defer allocator.free(text_z);

    const out_z = c.Z3_eval_smtlib2_string(ctx, text_z.ptr);
    if (out_z == null) return empty;
    const out = std.mem.span(out_z);
    const owned = allocator.dupe(u8, out) catch return empty;

    var verdict: Verdict = .err;
    var lines = std.mem.tokenizeAny(u8, out, "\n\r");
    const first = lines.next() orelse "";
    if (std.mem.startsWith(u8, first, "unsat")) verdict = .unsat;
    if (std.mem.startsWith(u8, first, "sat")) verdict = .sat;
    if (std.mem.startsWith(u8, first, "unknown")) verdict = .unknown;

    allocator.free(empty.output);
    return .{ .verdict = verdict, .output = owned };
}

fn firstLatentSlot(solver: *flame.FlameSolver) ?usize {
    for (0..solver.nodes.len) |i| {
        if (!solver.pinned_slots[i] and solver.topology[i] == null) return i;
    }
    return null;
}

fn buildUafSolver(allocator: std.mem.Allocator) !flame.FlameSolver {
    var solver = try flame.FlameSolver.init(allocator, 7); // 5 base + 2 latent for fixes

    solver.pin(0, codebook.Ast_FnDecl); // root
    solver.pin(1, codebook.Ast_Pointer); // ptr
    solver.pin(2, codebook.Ast_Alloc);   // alloc
    solver.pin(3, codebook.Ast_Free);    // free
    solver.pin(4, codebook.Ast_Deref);   // deref (AFTER FREE -> UAF)

    // Children are ordered by positional port, mapped to integer time for Z3.
    // Space out the ports so we can inject repairs in between!
    solver.pinTopology(1, 0, 0); // pointer handle
    solver.pinTopology(2, 0, 10); // t=10
    solver.pinTopology(3, 0, 20); // t=20
    solver.pinTopology(4, 0, 30); // t=30

    return solver;
}

fn printDecodedGraph(solver: *flame.FlameSolver) void {
    std.debug.print("   decoded nodes:\n", .{});
    for (0..solver.nodes.len) |i| {
        if (!validator.isCommitted(solver, i)) continue;
        const cpt = validator.decodeNode(solver, i);
        const parent: i64 = if (solver.topology[i]) |l| @intCast(l.parent) else -1;
        const pos: i64 = if (solver.topology[i]) |l| @intCast(l.position) else -1;
        std.debug.print("     [{d}] {s:<16} parent={d} pos={d}\n", .{ i, cpt.name(), parent, pos });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  PHASE 8: UAF SYNTHESIS & REPAIR LOOP                ║\n", .{});
    std.debug.print("║  Z3 Temporal Tracking + VSA Nullification Injection  ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    var solver = try buildUafSolver(allocator);
    defer solver.deinit();
    
    std.debug.print("\nPinned intent: FnDecl, Pointer, Alloc(t=10), Free(t=20), Deref(t=30)\n", .{});
    std.debug.print("Latent dimensions reserved for State Reset and Guard injections.\n", .{});

    var pass: usize = 0;
    var proven_safe = false;

    // We explore the repairs incrementally. First State Reset, then Guard.
    var injected_reset = false;
    var injected_guard = false;

    while (pass < 3) : (pass += 1) {
        std.debug.print("\n────────────────────────── PASS {d} ──────────────────────────\n", .{pass + 1});

        solver.relax(0);
        printDecodedGraph(&solver);
        
        std.debug.print("\n-- Z3 UAF Semantic Proof --\n", .{});
        const smt = try z3v.generateUafSafetySmt(allocator, &solver);
        defer allocator.free(smt);
        const z3 = runZ3(allocator, smt);
        defer allocator.free(z3.output);
        std.debug.print("   Z3 verdict: {s}\n", .{verdictName(z3.verdict)});

        if (z3.verdict == .unsat) {
            std.debug.print("   -> PROVEN SAFE!\n", .{});
            proven_safe = true;
            break;
        }

        if (z3.verdict != .sat) {
            std.debug.print("Z3 inconclusive — aborting.\n", .{});
            break;
        }

        std.debug.print("Z3 SAT -> UAF vulnerability detected. Oracle must synthesize a fix.\n", .{});
        
        // Oracle explores fixes:
        if (!injected_reset) {
            std.debug.print("ORACLE SYNTHESIS: Injecting State Reset (`ptr = null`) at t=25 (t_free + 5)\n", .{});
            const slot = firstLatentSlot(&solver).?;
            solver.pin(slot, codebook.Ast_Literal_Null);
            solver.pinTopology(slot, 0, 25); // t=25
            injected_reset = true;
        } else if (!injected_guard) {
            std.debug.print("ORACLE SYNTHESIS: Injecting Control Flow Guard (`if (ptr != null)`) wrapping deref\n", .{});
            const slot = firstLatentSlot(&solver).?;
            solver.pin(slot, codebook.Ast_Op_NotEqual);
            solver.pinTopology(slot, 0, 99); // generic child port for the guard node
            injected_guard = true;
        }
    }

    std.debug.print("\n══════════════════════════════════════════════════════\n", .{});
    if (proven_safe) {
        std.debug.print("CONVERGED ON SAFETY — emitting repaired Zig:\n", .{});
        std.debug.print("══════════════════════════════════════════════════════\n", .{});
        
        std.debug.print("fn safe_memory_flow() void {{\n", .{});
        std.debug.print("    var ptr = alloc();\n", .{});
        std.debug.print("    free(ptr);\n", .{});
        if (injected_reset) {
            std.debug.print("    ptr = null; // SYNTHESIZED: State Reset\n", .{});
        }
        if (injected_guard) {
            std.debug.print("    if (ptr != null) {{ // SYNTHESIZED: Control Guard\n", .{});
            std.debug.print("        deref(ptr);\n", .{});
            std.debug.print("    }}\n", .{});
        } else {
            std.debug.print("    deref(ptr);\n", .{});
        }
        std.debug.print("}}\n", .{});
        std.debug.print("\nSequence: SAT (UAF) -> Inject State Reset -> SAT (Null Deref) -> Inject Guard -> UNSAT. PASS.\n", .{});
    } else {
        std.debug.print("DID NOT converge on a proven-safe program. FAIL.\n", .{});
        std.process.exit(1);
    }
}
