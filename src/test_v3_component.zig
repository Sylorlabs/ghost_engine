const std = @import("std");
const smt_syn = @import("compiler/smt_synthesizer.zig");
const axiom_learner = @import("compiler/axiom_learner.zig");

fn test3(a: u64, b: u64) u64 {
    return ((a +% b) ^ (a -% b)) | 0xFF;
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

    std.debug.print("==================================================\n", .{});
    std.debug.print("GHOST ENGINE 3.0: CDCL COMPONENT SYNTHESIS (CEGIS)\n", .{});
    std.debug.print("Target: (a + b) ^ (a - b) | 0xFF\n", .{});
    std.debug.print("==================================================\n\n", .{});

    // Component Pool Budget for the target Crucible
    const budget = [_]smt_syn.Component{
        .{ .tag = .const_val, .const_val = 0xFF },
        .{ .tag = .add },
        .{ .tag = .sub },
        .{ .tag = .xor },
        .{ .tag = .or_ },
    };

    const start_time = std.time.milliTimestamp();

    if (try smt_syn.cegisSynthesis(allocator, test3, &budget)) |result_expr| {
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
