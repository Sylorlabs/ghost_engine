const std = @import("std");
const smt_syn = @import("compiler/smt_synthesizer.zig");
const axiom_learner = @import("compiler/axiom_learner.zig");

// Persistent state tracker
var dynamic_state: u64 = 0x123456789ABCDEF0;

fn statefulAccumulator(input: u64) u64 {
    // The invention target mixes the input with persistent history
    dynamic_state = (dynamic_state ^ input) +% 0x0123456789ABCDEF;
    dynamic_state = (dynamic_state << 13) | (dynamic_state >> 51);
    return dynamic_state;
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
    std.debug.print("GHOST ENGINE 3.2: SEQUENTIAL STATE SYNTHESIS (CEGIS)\n", .{});
    std.debug.print("Target: Cryptographic State Accumulator / PRNG Engine\n", .{});
    std.debug.print("========================================================\n\n", .{});

    // Topologically ordered budget ensuring necessary DAG dependencies can be formed
    // 1 XOR, 1 ADD, 1 SHL, 1 LSHR, 1 OR
    // Constants: 0x0123456789ABCDEF, 13, 51
    const budget = [_]smt_syn.Component{
        .{ .tag = .const_val, .const_val = 0x0123456789ABCDEF },
        .{ .tag = .const_val, .const_val = 13 },
        .{ .tag = .const_val, .const_val = 51 },
        .{ .tag = .xor },
        .{ .tag = .add },
        .{ .tag = .shl },
        .{ .tag = .lshr },
        .{ .tag = .or_ },
    };

    const initial_state: u64 = 0x123456789ABCDEF0;
    const start_time = std.time.milliTimestamp();

    if (try smt_syn.cegisStatefulSynthesis(allocator, statefulAccumulator, &budget, initial_state)) |result_expr| {
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
