//! Phase 7.1 — Parameterized Counterexample-Guided Repair.
//!
//! HONEST DESCRIPTION (read before believing any hype):
//! This is still a counterexample-guided repair loop (the CEGIS family); Z3 is
//! still the sole soundness authority. What changed from Phase 6 is the GRANULARITY
//! of the repair:
//!   * Phase 6 pinned a single MONOLITHIC Ast_BoundsCheck token. The SMT lowering
//!     treated its mere presence as guarding *every* index at once — a coarse,
//!     fixed, one-entry action.
//!   * Phase 7.1 reads the index ordinal K named in Z3's counterexample model and
//!     SYNTHESIZES a localized comparison subtree `idx_K < len`, parameterized to
//!     that specific index. A guard for idx0 does NOT cover idx1, so Z3 stays SAT
//!     on the still-open index and forces a second, differently-parameterized
//!     patch. The repair adapts to the LOCATION of the fault.
//!
//! WHAT THIS IS NOT: the *template* (the relation "an out-of-bounds index needs
//! index < len") is still engineer-supplied knowledge, not abductive inference.
//! What is now data-driven is WHICH index the guard names and how many guards are
//! needed — both read from counterexamples, not hardcoded. So this is a finer,
//! parameterized fixed template, NOT an engine that "understands" bounds. The
//! intelligence remains the closed loop (discover -> localize -> re-verify); the
//! honesty is that every synthesized guard must still EARN UNSAT from real Z3.
//!
//! Trace it proves (two indexes => two passes):
//!   naive (unguarded) swap -> Z3 SAT (idx0 = 4)
//!     -> synthesize `idx0 < len` (LessThan(Variable_idx@port0, Variable_len)) -> re-relax
//!   -> Z3 SAT (idx1 = 4)            [proof that idx0's guard did NOT cover idx1]
//!     -> synthesize `idx1 < len` -> re-relax
//!   -> strict validator WELL-FORMED -> Z3 UNSAT -> emit guarded Zig.

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

const Z3Result = struct {
    verdict: Verdict,
    output: []u8, // owned by caller
};

/// Real libz3 call. Returns the verdict AND the full solver output (duped),
/// so a SAT result's `(get-value ...)` model can be parsed by the caller.
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
    // Must copy out before del_context frees Z3's internal buffer.
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

/// Parse `(get-value ...)` output for the value bound to `idxK`.
/// Expected fragments like: `(idx0 4)`. Indices are constrained >= 0, so the
/// value is a plain non-negative integer.
fn parseIndexValue(output: []const u8, k: usize) ?u64 {
    var name_buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "idx{d}", .{k}) catch return null;
    const pos = std.mem.indexOf(u8, output, name) orelse return null;
    var i = pos + name.len;
    // skip to first digit
    while (i < output.len and (output[i] < '0' or output[i] > '9')) : (i += 1) {}
    const start = i;
    while (i < output.len and output[i] >= '0' and output[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(u64, output[start..i], 10) catch null;
}

/// Build the list of committed index-node solver-indices, in the same ascending
/// scan order z3_verifier numbers them, so `idxK` maps to indexNodes()[K].
fn collectIndexNodes(solver: *flame.FlameSolver, buf: []usize) []usize {
    var n: usize = 0;
    for (0..solver.nodes.len) |i| {
        if (!validator.isCommitted(solver, i)) continue;
        if (validator.decodeNode(solver, i).isIndex()) {
            buf[n] = i;
            n += 1;
        }
    }
    return buf[0..n];
}

fn firstLatentSlot(solver: *flame.FlameSolver) ?usize {
    for (0..solver.nodes.len) |i| {
        if (!solver.pinned_slots[i] and solver.topology[i] == null) return i;
    }
    return null;
}

fn verdictName(v: Verdict) []const u8 {
    return switch (v) {
        .unsat => "UNSAT (proven safe for all u32 inputs)",
        .sat => "SAT (out-of-bounds counterexample exists)",
        .unknown => "UNKNOWN",
        .err => "ERROR",
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  PHASE 7.1: PARAMETERIZED CE-GUIDED REPAIR            ║\n", .{});
    std.debug.print("║  synthesize idx_K < len, localized to the fault       ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    // ── The NAIVE intent: swap two elements of [4]u32, with NO bounds check. ──
    // Slots [0..5] are the program; slots [6..11] are LATENT (unpinned, unlinked)
    // — free dimensions the repair loop fills with synthesized guard subtrees.
    // Each localized guard costs 3 nodes (LessThan + Variable_idx + Variable_len),
    // so 6 latent slots leave room for up to two guards. Latent slots are
    // invisible to the linter and the SMT lowering until something is pinned in.
    const root = 0;
    var solver = try flame.FlameSolver.init(allocator, 12);
    defer solver.deinit();
    solver.pin(0, codebook.Ast_FnDecl);
    solver.pin(1, codebook.Ast_Array_4_u32);
    solver.pin(2, codebook.Ast_Index_0);
    solver.pin(3, codebook.Ast_Index_1);
    solver.pin(4, codebook.Ast_Swap);
    solver.pin(5, codebook.Ast_ReturnStmt);
    // slots 6..11: latent — deliberately NOT pinned, NOT linked.
    solver.pinTopology(1, 0, 0);
    solver.pinTopology(2, 0, 1);
    solver.pinTopology(3, 0, 2);
    solver.pinTopology(4, 0, 3);
    solver.pinTopology(5, 0, 4);

    std.debug.print("\nPinned intent (NO guard): FnDecl, Array_4_u32, Index_0, Index_1, Swap, Return\n", .{});
    std.debug.print("Latent dimensions reserved at slots [6..11] for synthesized guards.\n", .{});

    // Track which index ordinals we have already guarded, and how many guards we
    // have synthesized (used to give each new guard its own body child-port).
    var guarded_local = [_]bool{false} ** codebook.MAX_CHILD_PORTS;
    var guard_count: usize = 0;

    const max_passes = 4;
    var pass: usize = 0;
    var proven_safe = false;

    while (pass < max_passes) : (pass += 1) {
        std.debug.print("\n────────────────────────── PASS {d} ──────────────────────────\n", .{pass + 1});

        solver.relax(0);
        std.debug.print("relaxed: {d} iters, energy={d}\n", .{ solver.convergence_iterations, solver.last_total_energy });

        // Stage 1: shape-only lint (does NOT require a guard) — lets an unsafe
        // but well-formed program reach Z3.
        const structure = validator.validateStructure(&solver);
        switch (structure) {
            .well_formed => |wf| std.debug.print("Stage 1 (shape lint): WELL-FORMED (indices={d}, localized_guards={d}, monolithic_checks={d})\n", .{ wf.index_nodes, wf.localized_guards, wf.bounds_checks }),
            .malformed => |mf| {
                std.debug.print("Stage 1: MALFORMED ({s}) — aborting\n", .{mf.reason.explain()});
                return;
            },
        }

        // Stage 2: real Z3, with a model so SAT gives us the counterexample.
        const smt = try z3v.generateBoundsSafetySmtWithModel(allocator, &solver);
        defer allocator.free(smt);
        const z3 = runZ3(allocator, smt);
        defer allocator.free(z3.output);
        std.debug.print("Stage 2 (Z3): {s}\n", .{verdictName(z3.verdict)});

        if (z3.verdict == .unsat) {
            // Final acceptance: strict validator must also pass.
            const strict = validator.validateTopology(&solver);
            switch (strict) {
                .well_formed => |wf| {
                    std.debug.print("Strict validator: WELL-FORMED (indices={d}, localized_guards={d}, monolithic_checks={d})\n", .{ wf.index_nodes, wf.localized_guards, wf.bounds_checks });
                    proven_safe = true;
                },
                .malformed => |mf| {
                    std.debug.print("Strict validator disagrees with Z3: {s} (BUG)\n", .{mf.reason.explain()});
                },
            }
            break;
        }

        if (z3.verdict != .sat) {
            std.debug.print("Z3 inconclusive — aborting.\n", .{});
            break;
        }

        // ── Localized guard synthesis (the Phase 7.1 step) ──
        // Read the counterexample, find the ordinal K of an index that is out of
        // bounds and not yet guarded, then BUILD `idx_K < len` out of atoms —
        // parameterized to K — instead of pinning a blanket Ast_BoundsCheck.
        const shape = z3v.analyzeShape(&solver);
        var idx_buf: [16]usize = undefined;
        const index_nodes = collectIndexNodes(&solver, &idx_buf);

        var failing_k: usize = 0;
        var failing_val: u64 = 0;
        var found = false;
        for (0..shape.index_count) |k| {
            if (guarded_local[k]) continue; // already protected — Z3 can't report it OOB
            const v = parseIndexValue(z3.output, k) orelse continue;
            if (v >= shape.array_len) {
                failing_k = k;
                failing_val = v;
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("Z3 SAT but no unguarded out-of-bounds index in the model — aborting.\n", .{});
            break;
        }
        const failing_node = index_nodes[failing_k];
        std.debug.print("counterexample: idx{d} = {d}  (>= len {d}) at node [{d}] {s}\n", .{
            failing_k, failing_val, shape.array_len, failing_node, validator.decodeNode(&solver, failing_node).name(),
        });

        // Grab three latent slots and assemble the comparison subtree.
        const g_lt = firstLatentSlot(&solver) orelse {
            std.debug.print("no latent slot for LessThan — aborting.\n", .{});
            break;
        };
        solver.pin(g_lt, codebook.Ast_Op_LessThan);
        const g_idx = firstLatentSlot(&solver) orelse {
            std.debug.print("no latent slot for Variable_idx — aborting.\n", .{});
            break;
        };
        solver.pin(g_idx, codebook.Ast_Variable_idx);
        const g_len = firstLatentSlot(&solver) orelse {
            std.debug.print("no latent slot for Variable_len — aborting.\n", .{});
            break;
        };
        solver.pin(g_len, codebook.Ast_Variable_len);

        // LessThan sits beside the indices (under the function root) at its own
        // body child-port. Its Variable_idx operand is bound into child-port K —
        // THAT port position is the parameter we set from the counterexample, and
        // is how the verifier later recovers which index the guard protects. The
        // Variable_len operand goes to a reserved high port.
        const body_pos: u8 = @intCast(5 + guard_count);
        const len_port: u8 = codebook.MAX_CHILD_PORTS - 1;
        solver.pinTopology(g_lt, root, body_pos);
        solver.pinTopology(g_idx, g_lt, @intCast(failing_k));
        solver.pinTopology(g_len, g_lt, len_port);

        guarded_local[failing_k] = true;
        guard_count += 1;
        std.debug.print("SYNTHESIZE: built `idx{d} < len` = LessThan[{d}](Variable_idx[{d}]@port{d}, Variable_len[{d}]@port{d}). Re-relaxing.\n", .{
            failing_k, g_lt, g_idx, failing_k, g_len, len_port,
        });
    }

    std.debug.print("\n══════════════════════════════════════════════════════\n", .{});
    if (proven_safe) {
        std.debug.print("CONVERGED ON SAFETY — emitting guarded Zig:\n", .{});
        std.debug.print("══════════════════════════════════════════════════════\n", .{});
        // Emit the guards that were ACTUALLY synthesized, one per guarded ordinal,
        // so the printed program reflects the repair trace rather than a canned
        // string. (swap's two index params are i and j.)
        const param_names = [_][]const u8{ "i", "j", "k", "l" };
        std.debug.print("fn swap(a: *[4]u32, i: u32, j: u32) void {{\n", .{});
        std.debug.print("    // {d} guard(s), each synthesized from its own Z3 counterexample and\n", .{guard_count});
        std.debug.print("    // parameterized to the index it names; all re-proven UNSAT by Z3.\n", .{});
        for (0..codebook.MAX_CHILD_PORTS) |k| {
            if (!guarded_local[k]) continue;
            const nm = if (k < param_names.len) param_names[k] else "i";
            std.debug.print("    if ({s} >= a.len) return; // localized guard: idx{d} < len\n", .{ nm, k });
        }
        std.debug.print("    const tmp = a[i];\n", .{});
        std.debug.print("    a[i] = a[j];\n", .{});
        std.debug.print("    a[j] = tmp;\n", .{});
        std.debug.print("}}\n", .{});
        std.debug.print("\nSequence: naive SAT -> localize idx_K<len per counterexample -> re-relax -> strict WELL-FORMED -> Z3 UNSAT. PASS.\n", .{});
    } else {
        std.debug.print("DID NOT converge on a proven-safe program. FAIL.\n", .{});
        std.process.exit(1);
    }
}
