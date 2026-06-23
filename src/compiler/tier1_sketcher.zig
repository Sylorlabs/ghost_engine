const std = @import("std");
const vsa_tensor = @import("vsa_tensor.zig");
const HyperVector = vsa_tensor.HyperVector;

pub const MacroDef = struct {
    id: usize,
    num_inputs: usize,
    smt_body: []const u8,
};

pub const SketchPayload = struct {
    islands: []const MacroDef,
    num_state_registers: usize, 
};

const AST_SOURCE = 
    \\fn productionVectorPipeline(input_vector_chunk: u64) u64 {
    \\    var mixed = (input_vector_chunk ^ history_accumulator) & 0xFFFFFFFFFFFFFFF0;
    \\    mixed = (mixed << 9) | (mixed >> 55);
    \\    history_accumulator = (mixed +% entropy_counter) ^ 0x53595354454d4f4b;
    \\    entropy_counter +%= 1;
    \\    return history_accumulator;
    \\}
;

fn evaluateNodeVector(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) HyperVector {
    if (node == 0) return @as(HyperVector, @splat(0));
    const tags = tree.nodes.items(.tag);
    const tag = tags[node];
    
    // Hash the tag as seed
    const seed: u64 = @as(u64, @intCast(@intFromEnum(tag))) *% 0x9E3779B185EBCA87;
    const base_vec = vsa_tensor.generateLexicon(seed);
    
    var children = std.ArrayList(HyperVector).init(std.heap.page_allocator);
    defer children.deinit();

    switch (tag) {
        .bit_or, .bit_xor, .bit_and, .shl, .shr, .add_wrap, .assign, .assign_add_wrap => {
            const data = tree.nodes.items(.data)[node];
            if (data.lhs != 0) children.append(evaluateNodeVector(tree, data.lhs)) catch {};
            if (data.rhs != 0) children.append(evaluateNodeVector(tree, data.rhs)) catch {};
        },
        .grouped_expression => {
            const data = tree.nodes.items(.data)[node];
            if (data.lhs != 0) children.append(evaluateNodeVector(tree, data.lhs)) catch {};
        },
        .local_var_decl => {
            const data = tree.nodes.items(.data)[node];
            // The RHS is the init expr
            if (data.rhs != 0) children.append(evaluateNodeVector(tree, data.rhs)) catch {};
        },
        else => {},
    }

    if (children.items.len > 0) {
        const bundled = vsa_tensor.bundle(children.items);
        return vsa_tensor.bind(base_vec, bundled);
    }
    return base_vec;
}

fn emitSmtForNode(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index, allocator: std.mem.Allocator, mixed_subst: ?std.zig.Ast.Node.Index) ![]const u8 {
    const tags = tree.nodes.items(.tag);
    const tag = tags[node];

    if (tag == .identifier) {
        const token = tree.nodes.items(.main_token)[node];
        const name = tree.tokenSlice(token);
        if (std.mem.eql(u8, name, "input_vector_chunk")) return try std.fmt.allocPrint(allocator, "in_0", .{});
        if (std.mem.eql(u8, name, "history_accumulator")) return try std.fmt.allocPrint(allocator, "in_1", .{});
        if (std.mem.eql(u8, name, "entropy_counter")) return try std.fmt.allocPrint(allocator, "in_1", .{});
        if (std.mem.eql(u8, name, "mixed")) {
            if (mixed_subst) |sub_node| {
                return try emitSmtForNode(tree, sub_node, allocator, null);
            } else {
                return try std.fmt.allocPrint(allocator, "in_0", .{});
            }
        }
        return try std.fmt.allocPrint(allocator, "{s}", .{name});
    }
    
    if (tag == .number_literal) {
        const token = tree.nodes.items(.main_token)[node];
        const text = tree.tokenSlice(token);
        if (std.mem.startsWith(u8, text, "0x")) {
            var hex_upper = std.ArrayList(u8).init(allocator);
            for (text[2..]) |c| {
                try hex_upper.append(std.ascii.toUpper(c));
            }
            return try std.fmt.allocPrint(allocator, "#x{s}", .{hex_upper.items});
        } else {
            const val = try std.fmt.parseInt(u64, text, 10);
            return try std.fmt.allocPrint(allocator, "#x{x:0>16}", .{val});
        }
    }

    if (tag == .grouped_expression) {
        const data = tree.nodes.items(.data)[node];
        return emitSmtForNode(tree, data.lhs, allocator, mixed_subst);
    }

    const data = tree.nodes.items(.data)[node];
    const lhs_smt = try emitSmtForNode(tree, data.lhs, allocator, mixed_subst);
    const rhs_smt = try emitSmtForNode(tree, data.rhs, allocator, mixed_subst);
    
    const op_str = switch (tag) {
        .bit_and => "bvand",
        .bit_or => "bvor",
        .bit_xor => "bvxor",
        .shl => "bvshl",
        .shr => "bvlshr",
        .add_wrap, .assign_add_wrap => "bvadd",
        else => "unknown",
    };

    return try std.fmt.allocPrint(allocator, "({s} {s} {s})", .{op_str, lhs_smt, rhs_smt});
}

// --- Dataflow role detection (specific to this pipeline's `mixed` SSA edge) -
fn stmtRhs(tree: *const std.zig.Ast, stmt: std.zig.Ast.Node.Index) std.zig.Ast.Node.Index {
    // For both `var mixed = <init>` and `lhs = <value>`, the value subtree is data.rhs.
    return tree.nodes.items(.data)[stmt].rhs;
}

fn subtreeReadsIdent(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index, name: []const u8) bool {
    if (node == 0) return false;
    const tag = tree.nodes.items(.tag)[node];
    const data = tree.nodes.items(.data)[node];
    return switch (tag) {
        .identifier => std.mem.eql(u8, tree.tokenSlice(tree.nodes.items(.main_token)[node]), name),
        .grouped_expression => subtreeReadsIdent(tree, data.lhs, name),
        .bit_or, .bit_xor, .bit_and, .shl, .shr, .add_wrap, .assign, .assign_add_wrap => subtreeReadsIdent(tree, data.lhs, name) or subtreeReadsIdent(tree, data.rhs, name),
        else => false,
    };
}

fn stmtDefinesMixed(tree: *const std.zig.Ast, stmt: std.zig.Ast.Node.Index) bool {
    const tag = tree.nodes.items(.tag)[stmt];
    const data = tree.nodes.items(.data)[stmt];
    switch (tag) {
        .assign, .assign_add_wrap => {
            if (tree.nodes.items(.tag)[data.lhs] != .identifier) return false;
            return std.mem.eql(u8, tree.tokenSlice(tree.nodes.items(.main_token)[data.lhs]), "mixed");
        },
        else => {
            if (tree.fullVarDecl(stmt)) |vd| {
                return std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token + 1), "mixed");
            }
            return false;
        },
    }
}

fn stmtConsumesMixed(tree: *const std.zig.Ast, stmt: std.zig.Ast.Node.Index) bool {
    return subtreeReadsIdent(tree, stmtRhs(tree, stmt), "mixed");
}

// --- Union-Find over the measured Hamming distance matrix ---------------
fn ufFind(parent: []usize, x: usize) usize {
    var r = x;
    while (parent[r] != r) r = parent[r];
    // path compression
    var c = x;
    while (parent[c] != r) {
        const next = parent[c];
        parent[c] = r;
        c = next;
    }
    return r;
}

fn ufUnion(parent: []usize, a: usize, b: usize) void {
    const ra = ufFind(parent, a);
    const rb = ufFind(parent, b);
    if (ra != rb) parent[@max(ra, rb)] = @min(ra, rb);
}

/// The output ("returned") statement of a dataflow cluster is the one with the
/// highest source index — execution order means later statements consume the
/// earlier ones. We emit one macro per cluster rooted at that statement.
pub fn generateSketch() SketchPayload {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    var tree = std.zig.Ast.parse(allocator, AST_SOURCE, .zig) catch unreachable;
    defer tree.deinit(allocator);

    // Get the function block
    const root_decls = tree.rootDecls();
    const fn_decl = root_decls[0];
    const fn_body = tree.nodes.items(.data)[fn_decl].rhs; // The block

    const block_statements = tree.extra_data[tree.nodes.items(.data)[fn_body].lhs..tree.nodes.items(.data)[fn_body].rhs];

    // Keep only COMPUTATIONAL statements (var-decls and assignments). Control
    // flow like `return history_accumulator;` is not a combinational island —
    // it is the output selector. The previous hardcode dodged this by assuming
    // exactly 4 statements; iterating the real block (5 statements) surfaces it.
    var comp = std.ArrayList(std.zig.Ast.Node.Index).init(allocator);
    var orig = std.ArrayList(usize).init(allocator);
    for (block_statements, 0..) |stmt, idx| {
        const tag = tree.nodes.items(.tag)[stmt];
        const is_comp = (tree.fullVarDecl(stmt) != null) or tag == .assign or tag == .assign_add_wrap;
        if (is_comp) {
            comp.append(stmt) catch unreachable;
            orig.append(idx) catch unreachable;
        }
    }
    const n = comp.items.len;

    // Compute the geometric HyperVector for every computational statement.
    const vecs = allocator.alloc(HyperVector, n) catch unreachable;
    for (0..n) |i| vecs[i] = evaluateNodeVector(&tree, comp.items[i]);

    // Calibrate the clustering threshold from the encoder's OWN distance
    // distribution rather than a magic constant. Two statements are "in the
    // same combinational datapath" only if their distance sits well below the
    // chance baseline (mean - k*sigma).
    const stats = vsa_tensor.calibrate(0x5EED_C0DE, 128);
    const k_sigma: f64 = 6.0;
    const threshold = stats.thresholdAt(k_sigma);

    std.debug.print("[VSA Cartographer] Distance distribution (chance baseline):\n", .{});
    std.debug.print("  mean = {d:.1} bits, stddev = {d:.1} bits over {d} pairs\n", .{ stats.mean, stats.stddev, stats.samples });
    std.debug.print("  clustering threshold = mean - {d:.0}*sigma = {d} bits\n", .{ k_sigma, threshold });
    std.debug.print("[VSA Cartographer] Pairwise statement distances:\n", .{});

    // Union-Find: build clusters from the measured distance matrix.
    const uf = allocator.alloc(usize, n) catch unreachable;
    for (0..n) |i| uf[i] = i;

    for (0..n) |i| {
        for (i + 1..n) |j| {
            const d = vsa_tensor.hammingDistance(vecs[i], vecs[j]);
            const clustered = d < threshold;
            std.debug.print("  dist(Stmt{d}, Stmt{d}) = {d} bits -> {s}\n", .{ orig.items[i], orig.items[j], d, if (clustered) "CLUSTER" else "distinct" });
            if (clustered) ufUnion(uf, i, j);
        }
    }

    var islands = std.ArrayList(MacroDef).init(allocator);
    var emitted_root: [256]bool = [_]bool{false} ** 256;

    // Emit one island per cluster. The cluster's "output" statement is its
    // highest-index member (latest in execution order); earlier members that
    // define `mixed` are inlined into it via dataflow substitution.
    for (0..n) |i| {
        const root = ufFind(uf, i);
        if (emitted_root[root]) continue;
        emitted_root[root] = true;

        // Collect cluster members in ascending source order.
        var members: [64]usize = undefined;
        var m: usize = 0;
        for (0..n) |j| {
            if (ufFind(uf, j) == root) {
                members[m] = j;
                m += 1;
            }
        }
        const output_stmt_idx = members[m - 1];

        // Find a co-clustered `mixed` producer that precedes the output stmt.
        // (Composition operator is specific to this pipeline's `mixed` SSA edge;
        // the GROUPING above is fully geometry-driven and general.)
        var mixed_producer_rhs: ?std.zig.Ast.Node.Index = null;
        if (stmtConsumesMixed(&tree, comp.items[output_stmt_idx])) {
            var p: usize = 0;
            while (p < m - 1) : (p += 1) {
                if (stmtDefinesMixed(&tree, comp.items[members[p]])) {
                    mixed_producer_rhs = stmtRhs(&tree, comp.items[members[p]]);
                }
            }
        }

        const out_emit_node = if (stmtConsumesMixed(&tree, comp.items[output_stmt_idx]) or stmtDefinesMixed(&tree, comp.items[output_stmt_idx]))
            stmtRhs(&tree, comp.items[output_stmt_idx])
        else
            comp.items[output_stmt_idx];

        // Re-label members by their original statement index for the log.
        var member_labels: [64]usize = undefined;
        for (0..m) |mi| member_labels[mi] = orig.items[members[mi]];

        std.debug.print("  -> Island {d}: statements {any} (output Stmt{d}{s})\n", .{ islands.items.len, member_labels[0..m], orig.items[output_stmt_idx], if (mixed_producer_rhs != null) ", inlined mixed-producer" else "" });

        const body = emitSmtForNode(&tree, out_emit_node, allocator, mixed_producer_rhs) catch unreachable;
        // An island must lower to a well-formed SMT bitvector term. If the emitter
        // hit a node it cannot translate it leaves an `unknown` op — refuse to ship
        // that to Z3 (a malformed term either errors or, worse, verifies vacuously).
        if (std.mem.indexOf(u8, body, "unknown") != null) {
            std.debug.panic("tier1_sketcher: island {d} (output Stmt{d}) lowered to a non-SMT term: {s}", .{ islands.items.len, orig.items[output_stmt_idx], body });
        }

        islands.append(.{
            .id = islands.items.len,
            .num_inputs = 2,
            .smt_body = body,
        }) catch unreachable;
    }

    // Allocate persistent memory for the returned slice
    const payload_islands = allocator.alloc(MacroDef, islands.items.len) catch unreachable;
    @memcpy(payload_islands, islands.items);

    return SketchPayload{
        .islands = payload_islands,
        .num_state_registers = 2,
    };
}
