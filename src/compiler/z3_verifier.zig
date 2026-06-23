//! Phase 5.2 — Faithful SMT lowering for array bounds safety.
//!
//! WHAT CHANGED AND WHY: the previous version of this file emitted SMT-LIB text
//! with a HARDCODED verdict — it always wrote `(assert (= tension_reachable false))`
//! followed by `(assert tension_reachable)`, an unconditional contradiction, so the
//! "proof" was predetermined regardless of the actual graph. Nothing consumed the
//! output, and the verdict was a fiction. That is the SMT_VERIFIED-lie pattern.
//!
//! This version emits a FAITHFUL model whose satisfiability depends on the decoded
//! graph, not on a constant:
//!   - each Ast_Index_* node becomes a symbolic index ranging over the full u32
//!     domain (0 .. 4294967295),
//!   - the array length is a real constant (Ast_Array_4_u32 => len = 4),
//!   - the bounds-check GUARD `(and (>= idx 0) (< idx len))` is asserted per
//!     index that is covered, by EITHER a monolithic Ast_BoundsCheck node
//!     (Phase 5: covers every index at once) OR a localized Ast_Op_LessThan
//!     guard targeting that specific index ordinal (Phase 7.1),
//!   - we then assert the negation of safety: that some index reaches the access
//!     out of bounds. An index left UNGUARDED therefore keeps the model SAT —
//!     which is exactly what forces the repair loop to localize another guard.
//!
//! Reading the verdict (∀ over all u32 inputs):
//!   guarded   => guard ∧ (∃ oob) is contradictory => UNSAT => PROVEN SAFE
//!   unguarded => (∃ oob) is satisfiable (e.g. idx = 4) => SAT => UNSAFE (counterexample)
//!
//! This module only PRODUCES SMT text — it deliberately does not link libz3, so it
//! stays safe to include in the whole module graph. The actual solver call lives in
//! the executable (verified_swap.zig), mirroring invent_cli.zig's decoupling.

const std = @import("std");
const vsa = @import("../vsa_core.zig");
const codebook = @import("../concept_codebook.zig");
const flame = @import("../flame.zig");
// Single source of truth for "which index ordinal does a localized guard
// protect" — shared with the validator so the two stages can never disagree
// about what counts as a guard.
const validator = @import("topological_validator.zig");

fn isIndexConcept(node: vsa.HyperVector) bool {
    return vsa.hammingDistance(node, codebook.Ast_Index_0) == 0 or
        vsa.hammingDistance(node, codebook.Ast_Index_1) == 0 or
        vsa.hammingDistance(node, codebook.Ast_Index_2) == 0 or
        vsa.hammingDistance(node, codebook.Ast_Index_3) == 0;
}

/// A slot participates iff pinned or topologically linked; latent slots (free
/// dimensions the relaxer hasn't been told to fill) are ignored so relaxation
/// noise cannot masquerade as an index or a guard. Mirrors the validator.
fn isCommitted(solver: *flame.FlameSolver, i: usize) bool {
    return solver.pinned_slots[i] or solver.topology[i] != null;
}

/// Summary of the bounds-safety-relevant structure decoded from the graph.
pub const SafetyShape = struct {
    array_len: u32, // 0 if no array node found
    index_count: usize, // number of Ast_Index_* nodes
    has_bounds_check: bool, // is a MONOLITHIC Ast_BoundsCheck node present? (covers all indices)
    /// Phase 7.1 — per-index localized coverage. guarded[k] is true iff an
    /// Ast_Op_LessThan guard targets index ordinal k. Indexed 0..index_count.
    guarded: [codebook.MAX_CHILD_PORTS]bool,

    /// Is index ordinal k covered by *some* guard (monolithic or localized)?
    pub fn isGuarded(self: SafetyShape, k: usize) bool {
        return self.has_bounds_check or (k < self.guarded.len and self.guarded[k]);
    }
};

pub fn analyzeShape(solver: *flame.FlameSolver) SafetyShape {
    var shape = SafetyShape{
        .array_len = 0,
        .index_count = 0,
        .has_bounds_check = false,
        .guarded = [_]bool{false} ** codebook.MAX_CHILD_PORTS,
    };
    for (0..solver.nodes.len) |i| {
        if (!isCommitted(solver, i)) continue;
        const n = solver.nodes[i];
        if (vsa.hammingDistance(n, codebook.Ast_Array_4_u32) == 0) shape.array_len = 4;
        if (vsa.hammingDistance(n, codebook.Ast_BoundsCheck) == 0) shape.has_bounds_check = true;
        if (isIndexConcept(n)) shape.index_count += 1;
    }
    // Localized Phase 7.1 guards (decoded by the shared validator helper).
    validator.collectGuardedOrdinals(solver, &shape.guarded);
    return shape;
}

/// Lower the decoded graph to a faithful bounds-safety proof obligation.
/// UNSAT  ==> proven safe for all u32 inputs.
/// SAT    ==> an out-of-bounds access is reachable (unsafe).
pub fn generateBoundsSafetySmt(allocator: std.mem.Allocator, solver: *flame.FlameSolver) ![]const u8 {
    return emit(allocator, solver, false);
}

/// Same obligation, but requests a concrete model so a SAT verdict yields the
/// offending index values via `(get-value ...)`. The Phase 6 repair loop uses
/// this to target the failing index node ("error heat") instead of guessing.
pub fn generateBoundsSafetySmtWithModel(allocator: std.mem.Allocator, solver: *flame.FlameSolver) ![]const u8 {
    return emit(allocator, solver, true);
}

fn emit(allocator: std.mem.Allocator, solver: *flame.FlameSolver, want_model: bool) ![]const u8 {
    const shape = analyzeShape(solver);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    if (want_model) try w.writeAll("(set-option :produce-models true)\n");
    try w.writeAll(";; --- BOUNDS-SAFETY PROOF OBLIGATION (faithful lowering) ---\n");
    try w.print(";; decoded: array_len={d}, indices={d}, monolithic_bounds_check={s}\n", .{
        shape.array_len, shape.index_count, if (shape.has_bounds_check) "present" else "ABSENT",
    });
    try w.writeAll(";; localized guards: ");
    if (shape.index_count == 0) {
        try w.writeAll("(none)");
    } else for (0..shape.index_count) |k| {
        try w.print("idx{d}={s} ", .{ k, if (shape.isGuarded(k)) "GUARDED" else "open" });
    }
    try w.writeAll("\n\n");

    if (shape.array_len == 0 or shape.index_count == 0) {
        // Nothing indexable to reason about; emit a vacuously-safe problem.
        try w.writeAll(";; no array/index structure to verify\n(check-sat)\n");
        return out.toOwnedSlice();
    }

    try w.print("(declare-const len Int)\n(assert (= len {d}))\n\n", .{shape.array_len});

    // Each index is a symbolic value over the FULL u32 domain — this is what
    // makes UNSAT a genuine ∀-quantified result rather than a check of constants.
    try w.writeAll(";; symbolic indices over the entire u32 input domain\n");
    for (0..shape.index_count) |k| {
        try w.print("(declare-const idx{d} Int)\n", .{k});
        try w.print("(assert (and (>= idx{d} 0) (<= idx{d} 4294967295)))\n", .{ k, k });
    }
    try w.writeAll("\n");

    // Emit `(< idxK len)` only for indices that are actually covered. A
    // localized guard constrains ITS index alone — any index left open keeps the
    // negation-of-safety satisfiable, so Z3 returns SAT and the repair loop must
    // localize another guard. (A monolithic Ast_BoundsCheck covers all at once.)
    var any_guarded = false;
    for (0..shape.index_count) |k| {
        if (shape.isGuarded(k)) any_guarded = true;
    }
    if (any_guarded) {
        try w.writeAll(";; per-index guards asserted (monolithic Ast_BoundsCheck and/or localized Ast_Op_LessThan):\n");
        for (0..shape.index_count) |k| {
            if (shape.isGuarded(k)) {
                try w.print("(assert (and (>= idx{d} 0) (< idx{d} len)))\n", .{ k, k });
            }
        }
        try w.writeAll("\n");
    } else {
        try w.writeAll(";; NO guard: no Ast_BoundsCheck and no localized Ast_Op_LessThan guard present\n\n");
    }

    // Negation of safety: some index reaches the access out of bounds.
    try w.writeAll(";; assert an out-of-bounds access is reachable (negation of safety)\n");
    try w.writeAll("(assert (or");
    for (0..shape.index_count) |k| {
        try w.print(" (>= idx{d} len) (< idx{d} 0)", .{ k, k });
    }
    try w.writeAll("))\n\n");

    try w.writeAll("(check-sat)\n");

    // On SAT, surface the counterexample so the repair loop can localize it.
    if (want_model) {
        try w.writeAll("(get-value (");
        for (0..shape.index_count) |k| {
            if (k != 0) try w.writeAll(" ");
            try w.print("idx{d}", .{k});
        }
        try w.writeAll("))\n");
    }

    return out.toOwnedSlice();
}

/// Lower the decoded graph to a temporal UAF proof obligation.
/// Extract the execution order (child port position) of Alloc, Free, and Deref.
/// Emits SMT tracking memory state: 0=UNALLOCATED, 1=ALLOCATED, 2=FREED.
/// Negation of safety: Deref occurs when the state is FREED.
pub fn generateUafSafetySmt(allocator: std.mem.Allocator, solver: *flame.FlameSolver) ![]const u8 {
    var t_alloc: i32 = -1;
    var t_free: i32 = -1;
    var t_deref: i32 = -1;
    var t_reset: i32 = -1;
    var has_guard = false;

    for (0..solver.nodes.len) |i| {
        if (!isCommitted(solver, i)) continue;
        const link = solver.topology[i] orelse continue;
        const c = validator.decodeNode(solver, i);
        if (c == .alloc) t_alloc = @intCast(link.position);
        if (c == .free) t_free = @intCast(link.position);
        if (c == .deref) t_deref = @intCast(link.position);
        if (c == .literal_null) t_reset = @intCast(link.position);
        if (c == .op_not_equal) has_guard = true;
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("(set-option :produce-models true)\n");
    try w.writeAll(";; --- USE-AFTER-FREE (UAF) PROOF OBLIGATION ---\n");
    try w.print(";; decoded execution order: t_alloc={d}, t_free={d}, t_deref={d}, t_reset={d}, has_guard={any}\n\n", .{ t_alloc, t_free, t_deref, t_reset, has_guard });

    try w.print("(declare-const t_alloc Int)\n(assert (= t_alloc {d}))\n", .{t_alloc});
    try w.print("(declare-const t_free Int)\n(assert (= t_free {d}))\n", .{t_free});
    try w.print("(declare-const t_deref Int)\n(assert (= t_deref {d}))\n", .{t_deref});
    try w.print("(declare-const t_reset Int)\n(assert (= t_reset {d}))\n", .{t_reset});
    try w.print("(declare-const has_guard Bool)\n(assert (= has_guard {s}))\n\n", .{if (has_guard) "true" else "false"});

    try w.writeAll(";; Temporal Memory State Tracking (0=Unallocated/Null, 1=Allocated, 2=Freed)\n");
    try w.writeAll("(define-fun ptr_state ((t Int)) Int\n");
    try w.writeAll("  (ite (and (>= t_reset 0) (> t t_reset)) 0\n");
    try w.writeAll("  (ite (and (>= t_free 0) (> t t_free)) 2\n");
    try w.writeAll("  (ite (and (>= t_alloc 0) (> t t_alloc)) 1\n");
    try w.writeAll("  0))))\n\n");

    try w.writeAll(";; Path condition: if guarded (ptr != null), deref is only reachable if state != 0\n");
    try w.writeAll("(define-fun reachable () Bool\n");
    try w.writeAll("  (or (not has_guard) (not (= (ptr_state t_deref) 0))))\n\n");

    try w.writeAll(";; Negation of Safety: Access is reachable AND state is either FREED (2) or NULL (0)\n");
    try w.writeAll("(assert (and reachable (or (= (ptr_state t_deref) 2) (= (ptr_state t_deref) 0))))\n\n");
    
    try w.writeAll("(check-sat)\n");
    try w.writeAll("(get-value (t_alloc t_free t_deref t_reset has_guard (ptr_state t_deref) reachable))\n");

    return out.toOwnedSlice();
}

/// Lower the decoded graph to a Zero-Division proof obligation.
/// Extract the divisor operand (we'll just use a generic 'b' for the divisor).
/// Negation of safety: Access is reachable AND divisor is ZERO.
pub fn generateZeroDivSafetySmt(allocator: std.mem.Allocator, solver: *flame.FlameSolver) ![]const u8 {
    var has_guard = false;

    for (0..solver.nodes.len) |i| {
        if (!isCommitted(solver, i)) continue;
        const c = validator.decodeNode(solver, i);
        if (c == .op_not_equal) has_guard = true;
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("(set-option :produce-models true)\n");
    try w.writeAll(";; --- ZERO-DIVISION PROOF OBLIGATION ---\n");
    try w.print(";; decoded execution: has_guard={any}\n\n", .{has_guard});

    try w.writeAll("(declare-const b Int)\n\n");

    if (has_guard) {
        try w.writeAll(";; Path condition: guarded by `if (b != 0)`\n");
        try w.writeAll("(assert (not (= b 0)))\n\n");
    }

    try w.writeAll(";; Negation of Safety: Divisor is ZERO\n");
    try w.writeAll("(assert (= b 0))\n\n");
    
    try w.writeAll("(check-sat)\n");
    try w.writeAll("(get-value (b))\n");

    return out.toOwnedSlice();
}
