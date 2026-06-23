//! zag_verify — a thin ghost_engine bridge that discharges a single SMT-LIB2 verification
//! condition through the engine's Z3 path (the same `Z3_eval_smtlib2_string` call used by
//! verified_swap.zig / invent_cli.zig). It is intentionally self-contained (std + libz3 only,
//! like verified_swap) so it builds even while the rest of ghost_core is mid-change.
//!
//! Contract — the stable interface the Zag compiler depends on:
//!   stdin :  an SMT-LIB2 query, e.g.
//!              (set-logic ALL)
//!              (declare-const d Int)
//!              (assert (not (= d 0)))   ; path condition
//!              (assert (= d 0))         ; can the divisor be zero here?
//!              (check-sat)
//!              (get-model)
//!   stdout:  {"verdict":"unsat|sat|unknown|err","output":"<raw z3 reply>"}
//!            unsat => obligation proven safe; sat => counterexample in output; unknown => not proven.
const std = @import("std");

const c = @cImport({
    @cInclude("z3.h");
});

fn z3SilentErrorHandler(_: c.Z3_context, _: c.Z3_error_code) callconv(.C) void {}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn emit(verdict: []const u8, output: []const u8) !void {
    const w = std.io.getStdOut().writer();
    try w.writeAll("{\"verdict\":\"");
    try w.writeAll(verdict);
    try w.writeAll("\",\"output\":");
    try writeJsonString(w, output);
    try w.writeAll("}\n");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const smt = try std.io.getStdIn().reader().readAllAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(smt);

    const cfg = c.Z3_mk_config() orelse return emit("err", "Z3_mk_config failed");
    defer c.Z3_del_config(cfg);
    c.Z3_set_param_value(cfg, "timeout", "5000");

    const ctx = c.Z3_mk_context(cfg) orelse return emit("err", "Z3_mk_context failed");
    defer c.Z3_del_context(ctx);
    c.Z3_set_error_handler(ctx, z3SilentErrorHandler);

    const text_z = try allocator.dupeZ(u8, smt);
    defer allocator.free(text_z);

    const out_z = c.Z3_eval_smtlib2_string(ctx, text_z.ptr);
    if (out_z == null) return emit("err", "Z3 returned null");
    const out = std.mem.span(out_z);

    var it = std.mem.tokenizeAny(u8, out, "\n\r");
    const first = it.next() orelse "";
    const verdict: []const u8 = if (std.mem.startsWith(u8, first, "unsat"))
        "unsat"
    else if (std.mem.startsWith(u8, first, "unknown"))
        "unknown"
    else if (std.mem.startsWith(u8, first, "sat"))
        "sat"
    else
        "err";

    try emit(verdict, out);
}
