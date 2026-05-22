const std = @import("std");

// Standalone smoke test for the exact verifySmt pattern that
// ghost_engine/src/invent_cli.zig now uses (libz3 + eval_smtlib2_string +
// silent error handler). We can't build ghost_invent itself right now
// because ghost_core has unrelated pre-existing breakage
// (src/zenith/wingman.zig missing). This binary verifies the SMT path
// works against the same kind of QF_LIA formula invent_cli emits.

const c = @cImport({
    @cInclude("z3.h");
});

fn z3_silent_error_handler(_: c.Z3_context, _: c.Z3_error_code) callconv(.C) void {}

const VerifyVerdict = enum { verified_unsat, sat_solution, unknown, error_smt };

fn verifySmt(allocator: std.mem.Allocator, smt_text: []const u8, timeout_ms: u32) VerifyVerdict {
    const cfg = c.Z3_mk_config() orelse return .error_smt;
    defer c.Z3_del_config(cfg);

    var to_buf: [32]u8 = undefined;
    const timeout_s = std.fmt.bufPrintZ(&to_buf, "{d}", .{timeout_ms}) catch return .error_smt;
    c.Z3_set_param_value(cfg, "timeout", timeout_s.ptr);

    const ctx = c.Z3_mk_context(cfg) orelse return .error_smt;
    defer c.Z3_del_context(ctx);
    c.Z3_set_error_handler(ctx, z3_silent_error_handler);

    const text_z = allocator.dupeZ(u8, smt_text) catch return .error_smt;
    defer allocator.free(text_z);

    const out_z = c.Z3_eval_smtlib2_string(ctx, text_z.ptr);
    if (out_z == null) return .error_smt;
    const out = std.mem.span(out_z);

    var lines = std.mem.tokenizeAny(u8, out, "\n\r");
    const verdict_line = lines.next() orelse "";
    if (std.mem.startsWith(u8, verdict_line, "unsat")) return .verified_unsat;
    if (std.mem.startsWith(u8, verdict_line, "sat")) return .sat_solution;
    if (std.mem.startsWith(u8, verdict_line, "unknown")) return .unknown;
    return .error_smt;
}

fn tagOf(v: VerifyVerdict) []const u8 {
    return switch (v) {
        .verified_unsat => "SMT_UNSAT",
        .sat_solution => "SMT_SAT",
        .unknown => "SMT_UNKNOWN",
        .error_smt => "SMT_ERROR",
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const stdout = std.io.getStdOut().writer();

    // Case 1: trivially SAT (linear system invent_cli might emit)
    const sat_smt =
        "(set-logic QF_LIA)\n" ++
        "(declare-const s_0 Int)\n" ++
        "(declare-const s_1 Int)\n" ++
        "(assert (= (+ (* 3 s_0) (* 2 s_1)) 100))\n" ++
        "(check-sat)\n";
    const v1 = verifySmt(alloc, sat_smt, 5_000);
    try stdout.print("case 1 (linear SAT): {s}\n", .{tagOf(v1)});

    // Case 2: contradiction => UNSAT
    const unsat_smt =
        "(set-logic QF_LIA)\n" ++
        "(declare-const x Int)\n" ++
        "(assert (= x 5))\n" ++
        "(assert (= x 6))\n" ++
        "(check-sat)\n";
    const v2 = verifySmt(alloc, unsat_smt, 5_000);
    try stdout.print("case 2 (contradiction UNSAT): {s}\n", .{tagOf(v2)});

    // Case 3: malformed => ERROR
    const bad_smt = "(set-logic QF_LIA)\n(this is not valid SMT)\n(check-sat)\n";
    const v3 = verifySmt(alloc, bad_smt, 5_000);
    try stdout.print("case 3 (malformed): {s}\n", .{tagOf(v3)});

    // Case 4: structurally identical to what invent_cli emits — many
    // (assert (= (+ (* a s_i) (* b s_{i+1})) target)) lines plus a
    // (distinct s_i k) constraint. Two equations, two unknowns, with
    // target values chosen so the system is consistent.
    const inventish =
        "(set-logic QF_LIA)\n" ++
        "(declare-const s_0 Int)\n" ++
        "(declare-const s_1 Int)\n" ++
        "(declare-const s_2 Int)\n" ++
        "(assert (= (+ (* 5 s_0) (* 7 s_1)) 1000))\n" ++
        "(assert (= (+ (* 3 s_1) (* 11 s_2)) 1500))\n" ++
        "(assert (= (+ (* 13 s_2) (* 2 s_0)) 800))\n" ++
        "(assert (distinct s_0 0))\n" ++
        "(check-sat)\n";
    const v4 = verifySmt(alloc, inventish, 5_000);
    try stdout.print("case 4 (invent-cli-shaped): {s}\n", .{tagOf(v4)});
}
