//! Phase 5.1 — The Topological Validator (a structural graph linter).
//!
//! HONEST SCOPE: this is a *well-formedness* check on the decoded VSA graph,
//! NOT a verifier. It decides whether the relaxed topology has the structural
//! shape we require (every index is guarded, nothing is orphaned). It says
//! nothing about semantic correctness — that is Z3's job (see z3_verifier.zig).
//!
//! It operates on the post-relaxation state of a FlameSolver:
//!   - `solver.nodes[i]`  is the quantized concept (snapped to nearest atom),
//!   - `solver.topology[i]` is the Positional-Child-Port edge to the parent.
//! Decoding a node therefore means reading `nodes[i]` and matching it against
//! the codebook by exact (Hamming==0) identity.

const std = @import("std");
const vsa = @import("../vsa_core.zig");
const codebook = @import("../concept_codebook.zig");
const flame = @import("../flame.zig");

/// Concepts the validator reasons about. Everything else decodes to `.other`.
pub const Concept = enum {
    fn_decl,
    return_stmt,
    array_4_u32,
    swap,
    index_0,
    index_1,
    index_2,
    index_3,
    bounds_check,
    op_less_than, // Phase 7.1: root of a synthesized `idx_K < len` guard
    variable_idx, // Phase 7.1: the index operand of a guard (port position = K)
    variable_len, // Phase 7.1: the length operand of a guard
    pointer,      // Phase 8: UAF pointer handle
    alloc,        // Phase 8: UAF alloc
    free,         // Phase 8: UAF free
    deref,        // Phase 8: UAF deref
    state_freed,  // Phase 8: UAF state tag
    literal_null, // Phase 8: UAF null check/reset
    op_not_equal, // Phase 8: UAF guard condition
    op_div,
    literal_zero,
    other,

    pub fn isIndex(self: Concept) bool {
        return switch (self) {
            .index_0, .index_1, .index_2, .index_3 => true,
            else => false,
        };
    }

    pub fn name(self: Concept) []const u8 {
        return switch (self) {
            .fn_decl => "Ast_FnDecl",
            .return_stmt => "Ast_ReturnStmt",
            .array_4_u32 => "Ast_Array_4_u32",
            .swap => "Ast_Swap",
            .index_0 => "Ast_Index_0",
            .index_1 => "Ast_Index_1",
            .index_2 => "Ast_Index_2",
            .index_3 => "Ast_Index_3",
            .bounds_check => "Ast_BoundsCheck",
            .op_less_than => "Ast_Op_LessThan",
            .variable_idx => "Ast_Variable_idx",
            .variable_len => "Ast_Variable_len",
            .pointer      => "Ast_Pointer",
            .alloc        => "Ast_Alloc",
            .free         => "Ast_Free",
            .deref        => "Ast_Deref",
            .state_freed  => "Ast_State_Freed",
            .literal_null => "Ast_Literal_Null",
            .op_not_equal => "Ast_Op_NotEqual",
            .op_div => "Ast_Op_Div",
            .literal_zero => "Ast_Literal_Zero",
            .other => "(other)",
        };
    }
};

pub const Reason = enum {
    no_root, // no Ast_FnDecl present to anchor the tree
    missing_return, // no Ast_ReturnStmt — the function never returns
    index_without_bounds_check, // an Ast_Index_* has no sibling Ast_BoundsCheck
    orphan_node, // a non-root node with no directed path up to the root

    pub fn explain(self: Reason) []const u8 {
        return switch (self) {
            .no_root => "no Ast_FnDecl root anchors the graph",
            .missing_return => "no Ast_ReturnStmt — control never returns",
            .index_without_bounds_check => "an array index has no sibling Ast_BoundsCheck guard",
            .orphan_node => "a node has no directed path to the root (dead/disconnected)",
        };
    }
};

pub const WellFormed = struct {
    node_count: usize,
    index_nodes: usize,
    bounds_checks: usize, // count of monolithic Ast_BoundsCheck nodes (Phase 5)
    localized_guards: usize = 0, // count of localized Ast_Op_LessThan guards (Phase 7.1)
};

pub const Malformed = struct {
    reason: Reason,
    /// The offending node, or — when the violation is diffuse — the node
    /// carrying the highest localized geometric tension ("error heat").
    worst_node: usize,
    /// Localized relaxation energy at `worst_node` (sum of port-bound Hamming
    /// distances on its parent edge, 0..8192). Diagnostic only.
    tension: u64,
};

pub const ValidationResult = union(enum) {
    well_formed: WellFormed,
    malformed: Malformed,
};

/// Decode a (quantized) node vector to its codebook concept by exact identity.
pub fn decode(node: vsa.HyperVector) Concept {
    if (vsa.hammingDistance(node, codebook.Ast_FnDecl) == 0) return .fn_decl;
    if (vsa.hammingDistance(node, codebook.Ast_ReturnStmt) == 0) return .return_stmt;
    if (vsa.hammingDistance(node, codebook.Ast_Array_4_u32) == 0) return .array_4_u32;
    if (vsa.hammingDistance(node, codebook.Ast_Swap) == 0) return .swap;
    if (vsa.hammingDistance(node, codebook.Ast_Index_0) == 0) return .index_0;
    if (vsa.hammingDistance(node, codebook.Ast_Index_1) == 0) return .index_1;
    if (vsa.hammingDistance(node, codebook.Ast_Index_2) == 0) return .index_2;
    if (vsa.hammingDistance(node, codebook.Ast_Index_3) == 0) return .index_3;
    if (vsa.hammingDistance(node, codebook.Ast_BoundsCheck) == 0) return .bounds_check;
    if (vsa.hammingDistance(node, codebook.Ast_Op_LessThan) == 0) return .op_less_than;
    if (vsa.hammingDistance(node, codebook.Ast_Variable_idx) == 0) return .variable_idx;
    if (vsa.hammingDistance(node, codebook.Ast_Variable_len) == 0) return .variable_len;
    if (vsa.hammingDistance(node, codebook.Ast_Pointer) == 0) return .pointer;
    if (vsa.hammingDistance(node, codebook.Ast_Alloc) == 0) return .alloc;
    if (vsa.hammingDistance(node, codebook.Ast_Free) == 0) return .free;
    if (vsa.hammingDistance(node, codebook.Ast_Deref) == 0) return .deref;
    if (vsa.hammingDistance(node, codebook.Ast_State_Freed) == 0) return .state_freed;
    if (vsa.hammingDistance(node, codebook.Ast_Literal_Null) == 0) return .literal_null;
    if (vsa.hammingDistance(node, codebook.Ast_Op_NotEqual) == 0) return .op_not_equal;
    if (vsa.hammingDistance(node, codebook.Ast_Op_Div) == 0) return .op_div;
    if (vsa.hammingDistance(node, codebook.Ast_Literal_Zero) == 0) return .literal_zero;
    return .other;
}

pub fn decodeNode(solver: *flame.FlameSolver, i: usize) Concept {
    return decode(solver.nodes[i]);
}

/// A slot participates in the program iff it is pinned or topologically linked.
/// Unpinned + unlinked slots are LATENT dimensions — free space the relaxer can
/// later be told to fill (used by the Phase 6 repair loop). They are NOT program
/// nodes: relaxation drives them to arbitrary quantized noise, so the linter and
/// the SMT lowering must ignore them or that noise would masquerade as structure.
pub fn isCommitted(solver: *flame.FlameSolver, i: usize) bool {
    return solver.pinned_slots[i] or solver.topology[i] != null;
}

/// Localized relaxation energy on node `i`'s parent edge. Mirrors the per-link
/// term of FlameSolver.calculateTotalEnergy so the "error heat" we report is the
/// same quantity the solver minimized — not an independent ad-hoc metric.
pub fn localizedTension(solver: *flame.FlameSolver, i: usize) u64 {
    if (solver.topology[i]) |link| {
        const port = codebook.getChildPort(link.position);
        const child_bound = vsa.bind(solver.raw_nodes[i], port);
        const t1: u64 = vsa.hammingDistance(solver.raw_nodes[link.parent], child_bound);
        const parent_unbound = vsa.bind(solver.raw_nodes[link.parent], port);
        const t2: u64 = vsa.hammingDistance(solver.raw_nodes[i], parent_unbound);
        return t1 + t2;
    }
    return 0;
}

/// Does node `i` share a parent with some Ast_BoundsCheck node? This is the
/// MONOLITHIC (Phase 5) guard form: a single bounds-check sibling that the SMT
/// lowering treats as covering every index at once. Kept for back-compat with
/// verified_swap.zig.
fn hasSiblingBoundsCheck(solver: *flame.FlameSolver, i: usize, parent: usize) bool {
    for (0..solver.nodes.len) |j| {
        if (j == i) continue;
        if (!isCommitted(solver, j)) continue;
        const lj = solver.topology[j] orelse continue;
        if (lj.parent == parent and decode(solver.nodes[j]) == .bounds_check) return true;
    }
    return false;
}

/// Phase 7.1 — the index ordinal K that an `Ast_Op_LessThan` guard protects.
/// A localized guard is the subtree `LessThan(Variable_idx, Variable_len)`; the
/// repair loop encodes WHICH index it guards in the child-port POSITION of the
/// Variable_idx operand (port K). Decoding that position here is how a
/// synthesized guard maps back to a specific index — the same Positional-Child-
/// Port mechanism every other AST edge uses, not a side-channel.
pub fn guardTargetOrdinal(solver: *flame.FlameSolver, less_than_slot: usize) ?usize {
    for (0..solver.nodes.len) |j| {
        if (!isCommitted(solver, j)) continue;
        const link = solver.topology[j] orelse continue;
        if (link.parent != less_than_slot) continue;
        if (decode(solver.nodes[j]) == .variable_idx) return link.position;
    }
    return null;
}

/// Mark which index ORDINALS are covered by a localized Ast_Op_LessThan guard.
/// Ordinal = position in the ascending committed-slot scan of Ast_Index_* nodes,
/// matching the `idxK` numbering used by z3_verifier and the repair loop.
pub fn collectGuardedOrdinals(solver: *flame.FlameSolver, out: []bool) void {
    for (out) |*b| b.* = false;
    for (0..solver.nodes.len) |i| {
        if (!isCommitted(solver, i)) continue;
        if (decode(solver.nodes[i]) != .op_less_than) continue;
        if (guardTargetOrdinal(solver, i)) |k| {
            if (k < out.len) out[k] = true;
        }
    }
}

/// Follow parent links upward; true if node `i` reaches `root` within N steps.
fn reachesRoot(solver: *flame.FlameSolver, i: usize, root: usize) bool {
    var cur = i;
    var steps: usize = 0;
    while (steps < solver.nodes.len) : (steps += 1) {
        const link = solver.topology[cur] orelse return false;
        if (link.parent == root) return true;
        cur = link.parent;
    }
    return false; // exceeded node count => a cycle, never reaches root
}

/// Phase 5.1 entry point — STRICT lint: shape invariants AND the safety policy
/// that every array index must be guarded by a sibling Ast_BoundsCheck. This is
/// the post-repair acceptance gate.
pub fn validateTopology(solver: *flame.FlameSolver) ValidationResult {
    return run(solver, true);
}

/// SHAPE-ONLY lint: root + return present, no orphans, indices have parents —
/// but does NOT require a bounds check. Used as the Phase 6 loop entry so that a
/// well-formed-but-UNSAFE program reaches Z3 (the layer that owns the "needs a
/// guard?" question). Separating these is the honest split: shape is structural,
/// bounds safety is semantic.
pub fn validateStructure(solver: *flame.FlameSolver) ValidationResult {
    return run(solver, false);
}

fn run(solver: *flame.FlameSolver, require_guard: bool) ValidationResult {
    // --- Locate the root (Ast_FnDecl) among committed nodes ---
    var root: ?usize = null;
    for (0..solver.nodes.len) |i| {
        if (!isCommitted(solver, i)) continue;
        if (decode(solver.nodes[i]) == .fn_decl) {
            root = i;
            break;
        }
    }
    const root_idx = root orelse return .{ .malformed = .{
        .reason = .no_root,
        .worst_node = 0,
        .tension = 0,
    } };

    // --- Tally indices, bounds checks, and presence of a return ---
    var index_nodes: usize = 0;
    var bounds_checks: usize = 0;
    var has_return = false;
    for (0..solver.nodes.len) |i| {
        if (!isCommitted(solver, i)) continue;
        const c = decode(solver.nodes[i]);
        if (c.isIndex()) index_nodes += 1;
        if (c == .bounds_check) bounds_checks += 1;
        if (c == .return_stmt) has_return = true;
    }

    // --- Safety policy (strict mode only): every index must be guarded, by
    // EITHER a monolithic sibling Ast_BoundsCheck (Phase 5 form) OR a localized
    // Ast_Op_LessThan guard targeting that index ordinal (Phase 7.1 form). The
    // ordinal `k` is counted in ascending slot scan so it lines up with both
    // collectGuardedOrdinals and z3_verifier's idxK numbering. ---
    if (require_guard) {
        var guarded: [codebook.MAX_CHILD_PORTS]bool = undefined;
        collectGuardedOrdinals(solver, &guarded);
        var k: usize = 0;
        for (0..solver.nodes.len) |i| {
            if (!isCommitted(solver, i)) continue;
            if (!decode(solver.nodes[i]).isIndex()) continue;
            const link = solver.topology[i] orelse return .{ .malformed = .{
                .reason = .orphan_node, // an index with no parent is also disconnected
                .worst_node = i,
                .tension = localizedTension(solver, i),
            } };
            const covered = (k < guarded.len and guarded[k]) or
                hasSiblingBoundsCheck(solver, i, link.parent);
            if (!covered) {
                return .{ .malformed = .{
                    .reason = .index_without_bounds_check,
                    .worst_node = i,
                    .tension = localizedTension(solver, i),
                } };
            }
            k += 1;
        }
    }

    // --- Shape invariant: no orphan nodes — every non-root reaches the root ---
    for (0..solver.nodes.len) |i| {
        if (!isCommitted(solver, i)) continue;
        if (i == root_idx) continue;
        if (!reachesRoot(solver, i, root_idx)) {
            return .{ .malformed = .{
                .reason = .orphan_node,
                .worst_node = i,
                .tension = localizedTension(solver, i),
            } };
        }
    }

    // --- A well-formed function must actually return ---
    if (!has_return) return .{ .malformed = .{
        .reason = .missing_return,
        .worst_node = root_idx,
        .tension = 0,
    } };

    var guarded_tally: [codebook.MAX_CHILD_PORTS]bool = undefined;
    collectGuardedOrdinals(solver, &guarded_tally);
    var localized_guards: usize = 0;
    for (guarded_tally) |g| {
        if (g) localized_guards += 1;
    }

    return .{ .well_formed = .{
        .node_count = solver.nodes.len,
        .index_nodes = index_nodes,
        .bounds_checks = bounds_checks,
        .localized_guards = localized_guards,
    } };
}
