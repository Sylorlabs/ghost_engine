const std = @import("std");
const smt_syn = @import("compiler/smt_synthesizer.zig");
const axiom_learner = @import("compiler/axiom_learner.zig");

fn nativeSolverCore(clause_state: u64, assignment: u64) u64 {
    // Simulates an ultra-fast, stateful bit-parallel constraint evaluation step
    const mask = (clause_state ^ assignment) & 0x0F0F0F0F0F0F0F0F;
    const step = (mask << 4) | (mask >> 60);
    return step +% 0x64736f6c76657221; // "dsolver!" magic constant string as u64
}

var current_clause_state: u64 = 0x0000000000000000;

fn statefulWrapper(assignment: u64) u64 {
    current_clause_state = nativeSolverCore(current_clause_state, assignment);
    return current_clause_state;
}

fn freeExpr(allocator: std.mem.Allocator, expr: *const axiom_learner.SmtExpr) void {
    switch (expr.*) {
        .binary => |b| {
            freeExpr(allocator, b.lhs);
            freeExpr(allocator, b.rhs);
        },
        .unary => |u| {
            freeExpr(allocator, u.operand);
        },
        else => {},
    }
    allocator.destroy(expr);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.debug.print("========================================================\n", .{});
    std.debug.print("GHOST ENGINE 4.0: THE RECURSIVE BOOTSTRAP (CEGIS)\n", .{});
    std.debug.print("Target: Native Micro-SAT Bit-Vector Constraint Solver Core\n", .{});
    std.debug.print("========================================================\n\n", .{});

    // Topologically ordered budget to support the complex bit-masking DAG
    // 1 XOR, 1 AND, 1 SHL, 1 LSHR, 1 OR, 1 ADD
    // Constants: 0x0F0F0F0F0F0F0F0F, 4, 60, 0x64736f6c76657221
    const budget = [_]smt_syn.Component{
        .{ .tag = .const_val, .const_val = 0x0F0F0F0F0F0F0F0F },
        .{ .tag = .const_val, .const_val = 4 },
        .{ .tag = .const_val, .const_val = 60 },
        .{ .tag = .const_val, .const_val = 0x64736f6c76657221 },
        .{ .tag = .xor },
        .{ .tag = .and_ },
        .{ .tag = .shl },
        .{ .tag = .lshr },
        .{ .tag = .or_ },
        .{ .tag = .add },
    };

    const initial_state: u64 = 0x0000000000000000;
    const start_time = std.time.milliTimestamp();

    if (try smt_syn.cegisStatefulSynthesis(allocator, statefulWrapper, &budget, initial_state)) |result_expr| {
        const elapsed = std.time.milliTimestamp() - start_time;
        defer freeExpr(allocator, result_expr);
        
        std.debug.print("\n=== SYNTHESIS SUCCESS ===\n", .{});
        std.debug.print("Time: {d}ms\n", .{elapsed});
        
        var out = std.ArrayList(u8).init(allocator);
        defer out.deinit();
        try axiom_learner.emitSmt(result_expr, out.writer());
        
        std.debug.print("SMT Expression: {s}\n", .{out.items});
    } else {
        std.debug.print("\n=== SYNTHESIS FAILED ===\n", .{});
    }
}
