const std = @import("std");
const vsa = @import("vsa_core.zig");

// Vector Symbolic Architecture: 4096-bit HyperVectors (Phase 2)
const HyperVector = vsa.HyperVector;

// Structural Ports (to break commutativity and establish direction in AST edges)
// A parent node and a child node cannot just be flat vectors, or the graph loses directionality.
pub const Port_Parent = vsa.generate(0x54525543545F5041); // STRUCT_PA

// Phase 3.3: Positional Child Ports
// Each child slot gets its OWN orthogonal port vector. This prevents the Superposition Landmine:
// if multiple children are bound with a single Port_Child, their signals permanently collide
// during extraction. With orthogonal positional ports, unbinding with Port_Child_i extracts
// ONLY child i — all other children's contributions become white noise that cancels out.
pub const MAX_CHILD_PORTS: usize = 16;

pub const Port_Child_0 = vsa.generate(0x504F52545F434830); // PORT_CH0
pub const Port_Child_1 = vsa.generate(0x504F52545F434831); // PORT_CH1
pub const Port_Child_2 = vsa.generate(0x504F52545F434832); // PORT_CH2
pub const Port_Child_3 = vsa.generate(0x504F52545F434833); // PORT_CH3
pub const Port_Child_4 = vsa.generate(0x504F52545F434834); // PORT_CH4
pub const Port_Child_5 = vsa.generate(0x504F52545F434835); // PORT_CH5
pub const Port_Child_6 = vsa.generate(0x504F52545F434836); // PORT_CH6
pub const Port_Child_7 = vsa.generate(0x504F52545F434837); // PORT_CH7
pub const Port_Child_8 = vsa.generate(0x504F52545F434838); // PORT_CH8
pub const Port_Child_9 = vsa.generate(0x504F52545F434839); // PORT_CH9
pub const Port_Child_10 = vsa.generate(0x504F52545F43483A); // PORT_CH10
pub const Port_Child_11 = vsa.generate(0x504F52545F43483B); // PORT_CH11
pub const Port_Child_12 = vsa.generate(0x504F52545F43483C); // PORT_CH12
pub const Port_Child_13 = vsa.generate(0x504F52545F43483D); // PORT_CH13
pub const Port_Child_14 = vsa.generate(0x504F52545F43483E); // PORT_CH14
pub const Port_Child_15 = vsa.generate(0x504F52545F43483F); // PORT_CH15

/// The positional child port array. Index with child position.
pub const child_ports = [MAX_CHILD_PORTS]HyperVector{
    Port_Child_0, Port_Child_1, Port_Child_2, Port_Child_3,
    Port_Child_4, Port_Child_5, Port_Child_6, Port_Child_7,
    Port_Child_8, Port_Child_9, Port_Child_10, Port_Child_11,
    Port_Child_12, Port_Child_13, Port_Child_14, Port_Child_15,
};

/// Get the positional child port for a given branch index.
/// Each port is orthogonal to all others (~2048 Hamming distance at 4096 bits).
pub fn getChildPort(position: usize) HyperVector {
    if (position < MAX_CHILD_PORTS) {
        return child_ports[position];
    }
    // Overflow: generate a deterministic port from the position seed
    return vsa.generate(0x504F52545F434830 +% position);
}

// Legacy alias — DEPRECATED. Use getChildPort(i) instead.
pub const Port_Child = Port_Child_0;

// AST Concepts Minimum Viable Domain (MVD)
pub const Ast_FnDecl        = vsa.generate(0x4153545F466E4463);
pub const Ast_ReturnStmt    = vsa.generate(0x4153545F52657475);
pub const Ast_Type_u32      = vsa.generate(0x4153545F54797032);
pub const Ast_Type_u8_Array = vsa.generate(0x4153545F54797041);
pub const Ast_Op_Add        = vsa.generate(0x4153545F4F704164);
pub const Ast_Cast_u32_to_u8 = vsa.generate(0x4153545F43617374);

// Phase 4.1: Ouroboros Concepts (FlameSolver.init MVD)
pub const Ast_Param_Allocator = vsa.generate(0x4F55524F5F503031);
pub const Ast_Param_Size      = vsa.generate(0x4F55524F5F503032);
pub const Ast_Ret_FlameSolver = vsa.generate(0x4F55524F5F524554);
pub const Ast_Alloc_Nodes     = vsa.generate(0x4F55524F5F414C31);
pub const Ast_Alloc_RawNodes  = vsa.generate(0x4F55524F5F414C32);
pub const Ast_For_Loop        = vsa.generate(0x4F55524F5F464F52);
pub const Ast_Alloc_Pinned    = vsa.generate(0x4F55524F5F414C33);
pub const Ast_Memset_Pinned   = vsa.generate(0x4F55524F5F4D5331);
pub const Ast_Alloc_Topology  = vsa.generate(0x4F55524F5F414C34);
pub const Ast_Memset_Topology = vsa.generate(0x4F55524F5F4D5332);
pub const Ast_Return_FlameSolver = vsa.generate(0x4F55524F5F524532);

// Phase 5: Verified-Swap domain — array indexing with explicit bounds safety.
// These are ordinary orthogonal random hypervectors (like every other atom).
// NOTE: adding Ast_BoundsCheck gives the linter a *label* to look for; it does
// NOT by itself confer any ability to *prove* safety. The proof obligation is
// discharged by Z3 in the verified_swap demo, not by the presence of this atom.
pub const Ast_Array_4_u32 = vsa.generate(0x4153545F41523455); // AST_AR4U
pub const Ast_Swap        = vsa.generate(0x4153545F53574150); // AST_SWAP
pub const Ast_Index_0     = vsa.generate(0x4153545F49445830); // AST_IDX0
pub const Ast_Index_1     = vsa.generate(0x4153545F49445831); // AST_IDX1
pub const Ast_Index_2     = vsa.generate(0x4153545F49445832); // AST_IDX2
pub const Ast_Index_3     = vsa.generate(0x4153545F49445833); // AST_IDX3
pub const Ast_BoundsCheck = vsa.generate(0x4153545F424E4458); // AST_BNDX

// Phase 7.1: parameterized repair atoms. The Phase 6 repair could only pin the
// MONOLITHIC Ast_BoundsCheck (one token => the SMT lowering guards *every*
// index at once). These three atoms let the repair loop instead synthesize a
// localized comparison subtree `idx_K < len` targeting the SPECIFIC index named
// in a Z3 counterexample. They are ordinary orthogonal atoms — like
// Ast_BoundsCheck, having them confers no proving power; Z3 still discharges the
// obligation. WHICH index a guard protects is carried by the child-port
// position of its Ast_Variable_idx operand (see autonomous_guard.zig).
pub const Ast_Op_LessThan = vsa.generate(0x4153545F4F704C54); // AST_OpLT
pub const Ast_Variable_idx = vsa.generate(0x4153545F56494458); // AST_VIDX
pub const Ast_Variable_len = vsa.generate(0x4153545F564C454E); // AST_VLEN

/// Helper to bind a concept to a structural port role.
/// E.g. A child node is bound with Port_Child, breaking commutativity when bundled with a parent.
pub fn bindRole(concept: HyperVector, port: HyperVector) HyperVector {
    return vsa.bind(concept, port);
}

// Full domain list for cleanup memory
pub const all_concepts = [_]HyperVector{
    Ast_FnDecl, Ast_ReturnStmt, Ast_Type_u32, Ast_Type_u8_Array, Ast_Op_Add, Ast_Cast_u32_to_u8,
    Ast_Param_Allocator, Ast_Param_Size, Ast_Ret_FlameSolver,
    Ast_Alloc_Nodes, Ast_Alloc_RawNodes, Ast_For_Loop,
    Ast_Alloc_Pinned, Ast_Memset_Pinned,
    Ast_Alloc_Topology, Ast_Memset_Topology,
    Ast_Return_FlameSolver,
    // Phase 5: Verified-Swap domain
    Ast_Array_4_u32, Ast_Swap,
    Ast_Index_0, Ast_Index_1, Ast_Index_2, Ast_Index_3,
    Ast_BoundsCheck,
    // Phase 7.1: parameterized-guard atoms
    Ast_Op_LessThan, Ast_Variable_idx, Ast_Variable_len,
};

pub var dynamic_registry: ?std.StringHashMap(HyperVector) = null;

pub fn initRegistry(allocator: std.mem.Allocator) void {
    if (dynamic_registry == null) {
        dynamic_registry = std.StringHashMap(HyperVector).init(allocator);
    }
}

pub fn registerConcept(allocator: std.mem.Allocator, semantic_hash: []const u8, vector: HyperVector) !void {
    if (dynamic_registry == null) initRegistry(allocator);
    const key = try allocator.dupe(u8, semantic_hash);
    try dynamic_registry.?.put(key, vector);
}

pub fn getConcept(semantic_hash: []const u8) ?HyperVector {
    if (dynamic_registry == null) return null;
    return dynamic_registry.?.get(semantic_hash);
}

/// Auto-Associative Cleanup Memory (Vector Quantization)
/// Prevents superposition "grey goo" by snapping a noisy vector back to the nearest discrete concept.
/// Phase 2: Max Hamming distance is now 4096 (4096-bit vectors).
pub fn quantize(vector: HyperVector) HyperVector {
    var best_dist: u16 = 4097; // Max Hamming distance is 4096
    var best_concept: HyperVector = all_concepts[0];
    
    for (all_concepts) |concept| {
        const dist = vsa.hammingDistance(vector, concept);
        if (dist < best_dist) {
            best_dist = dist;
            best_concept = concept;
        }
    }
    
    // Also check the dynamic registry for newly invented concepts
    if (dynamic_registry) |registry| {
        var it = registry.valueIterator();
        while (it.next()) |concept_ptr| {
            const dist = vsa.hammingDistance(vector, concept_ptr.*);
            if (dist < best_dist) {
                best_dist = dist;
                best_concept = concept_ptr.*;
            }
        }
    }
    
    return best_concept;
}

/// Quantize against ONLY static MVD concepts (ignores dynamic registry).
/// Used by the detonator to identify the root concept in a compressed subtree.
pub fn quantizeStatic(vector: HyperVector) struct { concept: HyperVector, dist: u16 } {
    var best_dist: u16 = 4097;
    var best_concept: HyperVector = all_concepts[0];
    
    for (all_concepts) |concept| {
        const dist = vsa.hammingDistance(vector, concept);
        if (dist < best_dist) {
            best_dist = dist;
            best_concept = concept;
        }
    }
    
    return .{ .concept = best_concept, .dist = best_dist };
}
