const std = @import("std");

// Direct Z3 C API — small, focused, no dependency on the parent
// repo's z3_bridge. We only need: parse SMT-LIB2 string, check sat,
// print model on sat. That's three C calls.
const c = @cImport({
    @cInclude("z3.h");
});

pub const Verdict = enum {
    verified, // UNSAT for "exists bad input"   → property holds
    counter_example, // SAT for "exists bad input"     → property fails
    unknown, // solver timeout / incomplete
    error_smt, // bad SMT or runtime error
};

pub const VerifyResult = struct {
    verdict: Verdict,
    detail: []const u8, // borrowed; valid until next call
    elapsed_ms: u64,
};

// ─── SMT-LIB2 emitters ───────────────────────────────────────────

// Sort-net N=8 correctness via Knuth's 0/1 principle.
// A network sorts all inputs iff it sorts all binary {0,1} inputs.
// We model wires as Bool; compare-exchange (i,j) writes
//   x_i' := x_i ∧ x_j   (min over {0,1})
//   x_j' := x_i ∨ x_j   (max over {0,1})
// We track wire versions in SSA. Final assertion: exists a wire pair
// where output_k = 1 ∧ output_{k+1} = 0 (i.e. NOT sorted).
// UNSAT  ⇒ no such bad input exists ⇒ network is correct.
// SAT    ⇒ model gives a {0,1}^8 vector the network fails on.
// kind=0: regular comparator(i,j). kind=1: CALL_LIB — invoke
// extras[i % extras.len].sort(current_state). j is ignored for kind=1.
pub const SortNode = struct { i: u8, j: u8, kind: u8 = 0 };

// Legacy alias — kind defaults to 0 so existing code paths still compile.
pub const SortComparator = SortNode;

pub const SortLib = struct {
    extras: []const []const SortNode,
};

const MaxSortRecursion: u32 = 8;

fn emitSortNodes(
    w: anytype,
    n: u8,
    nodes: []const SortNode,
    lib: ?SortLib,
    version: *[16]u32,
    depth: u32,
) !void {
    for (nodes) |nd| {
        if (nd.kind == 1) {
            // CALL_LIB macro — inline the referenced prior champion.
            if (lib == null) continue; // identity fallback (matches runtime)
            const lb = lib.?;
            if (lb.extras.len == 0) continue;
            if (depth >= MaxSortRecursion) continue;
            const idx: usize = @intCast(@as(usize, nd.i) % lb.extras.len);
            try emitSortNodes(w, n, lb.extras[idx], lib, version, depth + 1);
            continue;
        }
        if (nd.i >= n or nd.j >= n or nd.i == nd.j) continue;
        const lo = if (nd.i < nd.j) nd.i else nd.j;
        const hi = if (nd.i < nd.j) nd.j else nd.i;
        const lv = version[lo];
        const hv = version[hi];
        const lv2 = lv + 1;
        const hv2 = hv + 1;
        try w.print("(declare-const x_{d}_v{d} Bool)\n", .{ lo, lv2 });
        try w.print("(declare-const x_{d}_v{d} Bool)\n", .{ hi, hv2 });
        try w.print("(assert (= x_{d}_v{d} (and x_{d}_v{d} x_{d}_v{d})))\n", .{ lo, lv2, lo, lv, hi, hv });
        try w.print("(assert (= x_{d}_v{d} (or x_{d}_v{d} x_{d}_v{d})))\n", .{ hi, hv2, lo, lv, hi, hv });
        version[lo] = lv2;
        version[hi] = hv2;
    }
}

pub fn emitSortNetCorrectness(
    allocator: std.mem.Allocator,
    n: u8,
    comps: []const SortNode,
    lib: ?SortLib,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();

    try w.writeAll("(set-logic QF_UF)\n");

    var version: [16]u32 = [_]u32{0} ** 16;

    var k: u8 = 0;
    while (k < n) : (k += 1) {
        try w.print("(declare-const x_{d}_v0 Bool)\n", .{k});
    }

    try emitSortNodes(w, n, comps, lib, &version, 0);

    // Bad-output assertion: ∃ adjacent k where out_k = 1 ∧ out_{k+1} = 0
    try w.writeAll("(assert (or");
    var p: u8 = 0;
    while (p + 1 < n) : (p += 1) {
        try w.print(" (and x_{d}_v{d} (not x_{d}_v{d}))", .{ p, version[p], p + 1, version[p + 1] });
    }
    try w.writeAll("))\n");

    try w.writeAll("(check-sat)\n");
    return buf.toOwnedSlice();
}

// u64-mixer bijectivity at a chosen bit-width.
// Bijection ⇔ ¬∃ a, b. a ≠ b ∧ P(a) = P(b)
// Encoded as: declare two distinct inputs at width W, symbolically execute
// the program on each, assert the outputs are equal. UNSAT ⇒ bijection.
//
// We narrow to a chosen bit width (W) to keep the solver tractable.
// At W=8 the search space is 256 inputs; Z3 finishes in ms. W=64 may
// time out for non-trivial programs — caller decides budget.
pub const MixerOp = enum(u8) {
    XOR = 0,
    ADD = 1,
    MUL = 2,
    ROTL = 3,
    SHL_XOR = 4,
    SHR_XOR = 5,
    SPLITMIX_STEP = 6,
    ADD_CONST = 7,
    AND_NOT = 8,
    OR_SHIFT = 9,
    CALL_LIB = 10,
    ROTR = 11,
    BSWAP = 12,
    MUM = 13,
    ADD_ROT = 14,
};

pub const MixerInstr = struct {
    op: MixerOp,
    dst: u8,
    src1: u8,
    src2: u8,
    imm: u64,
};

pub const MixerLib = struct {
    extras: []const []const MixerInstr,
};

const NumRegs: u8 = 8;
const MaxMixerRecursion: u32 = 8;

// Reg name helper. ns ("") for top-level, "_c<N>" for inlined CALL_LIB.
fn regName(
    allocator: std.mem.Allocator,
    reg: u8,
    ver: u32,
    side: []const u8,
    ns: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "reg{d}_v{d}_{s}{s}", .{ reg, ver, side, ns });
}

// Emit the body of a mixer program. ns is "" for top-level, "_c<N>" for
// each inlined CALL_LIB. input_bind, when non-null, is bound to reg0_v0
// (used by inlined calls to thread caller's value in). Returns the final
// SSA version of reg[NumRegs-1] so callers can reference it as output.
fn emitMixerProgram(
    allocator: std.mem.Allocator,
    w: anytype,
    side: []const u8,
    ns: []const u8,
    instrs: []const MixerInstr,
    num_bits: u8,
    lib: ?MixerLib,
    depth: u32,
    call_counter: *u32,
    input_bind: ?[]const u8,
) anyerror!u32 {
    const W = num_bits;
    var ver: [NumRegs]u32 = [_]u32{0} ** NumRegs;

    // Declare reg0_v0 as a fresh symbol; if input_bind is non-null, also
    // assert reg0_v0 = input_bind (this threads the caller's value in).
    try w.print("(declare-const reg0_v0_{s}{s} (_ BitVec {d}))\n", .{ side, ns, W });
    if (input_bind) |ib| {
        try w.print("(assert (= reg0_v0_{s}{s} {s}))\n", .{ side, ns, ib });
    }

    var r: u8 = 1;
    while (r < NumRegs) : (r += 1) {
        try w.print("(declare-const reg{d}_v0_{s}{s} (_ BitVec {d}))\n", .{ r, side, ns, W });
        const init_val: u64 = switch (r) {
            1 => 0x9E3779B97F4A7C15,
            2 => 0xBF58476D1CE4E5B9,
            3 => 0x94D049BB133111EB,
            else => 0,
        };
        const masked = if (W >= 64) init_val else init_val & ((@as(u64, 1) << @intCast(W)) - 1);
        try w.print("(assert (= reg{d}_v0_{s}{s} (_ bv{d} {d})))\n", .{ r, side, ns, masked, W });
    }

    for (instrs) |ins| {
        if (ins.dst >= NumRegs or ins.src1 >= NumRegs or ins.src2 >= NumRegs) continue;
        const a_ver = ver[ins.src1];
        const b_ver = ver[ins.src2];
        const d_new = ver[ins.dst] + 1;
        ver[ins.dst] = d_new;

        try w.print("(declare-const reg{d}_v{d}_{s}{s} (_ BitVec {d}))\n", .{ ins.dst, d_new, side, ns, W });

        const lhs_name_a = try std.fmt.allocPrint(allocator, "reg{d}_v{d}_{s}{s}", .{ ins.src1, a_ver, side, ns });
        defer allocator.free(lhs_name_a);
        const lhs_name_b = try std.fmt.allocPrint(allocator, "reg{d}_v{d}_{s}{s}", .{ ins.src2, b_ver, side, ns });
        defer allocator.free(lhs_name_b);
        const new_name = try std.fmt.allocPrint(allocator, "reg{d}_v{d}_{s}{s}", .{ ins.dst, d_new, side, ns });
        defer allocator.free(new_name);

        const shift_amt: u64 = if (W >= 64) (ins.imm & 63) else (ins.imm & (@as(u64, W) - 1));
        const imm_masked = if (W >= 64) ins.imm else ins.imm & ((@as(u64, 1) << @intCast(W)) - 1);

        switch (ins.op) {
            .XOR => try w.print("(assert (= {s} (bvxor {s} {s})))\n", .{ new_name, lhs_name_a, lhs_name_b }),
            .ADD => try w.print("(assert (= {s} (bvadd {s} {s})))\n", .{ new_name, lhs_name_a, lhs_name_b }),
            .MUL => {
                // Runtime semantics: regs[dst] = a *% (imm | 1). The literal
                // multiplier is imm | 1, NOT the second register. (The CSV's
                // src2 field is meaningless for MUL.)
                const imm_odd: u64 = imm_masked | 1;
                try w.print("(assert (= {s} (bvmul {s} (_ bv{d} {d}))))\n", .{ new_name, lhs_name_a, imm_odd, W });
            },
            .ROTL => {
                if (shift_amt == 0 or shift_amt >= W) {
                    try w.print("(assert (= {s} {s}))\n", .{ new_name, lhs_name_a });
                } else {
                    try w.print(
                        "(assert (= {s} (bvor (bvshl {s} (_ bv{d} {d})) (bvlshr {s} (_ bv{d} {d})))))\n",
                        .{ new_name, lhs_name_a, shift_amt, W, lhs_name_a, W - shift_amt, W },
                    );
                }
            },
            .SHL_XOR => try w.print(
                "(assert (= {s} (bvxor {s} (bvshl {s} (_ bv{d} {d})))))\n",
                .{ new_name, lhs_name_a, lhs_name_a, shift_amt, W },
            ),
            .SHR_XOR => try w.print(
                "(assert (= {s} (bvxor {s} (bvlshr {s} (_ bv{d} {d})))))\n",
                .{ new_name, lhs_name_a, lhs_name_a, shift_amt, W },
            ),
            .SPLITMIX_STEP => {
                // smix in domain_u64_mixer: SPLITMIX_STEP semantics are
                //   (a ^ (a >> (imm % 32 + 16))) *% (b | 1)
                // where `b` is regs[src2]. We model that exactly here.
                const sh: u32 = @intCast((ins.imm % 32) + 16);
                const sh_clamped: u32 = if (sh < W) sh else (W - 1);
                try w.print(
                    "(assert (= {s} (bvmul (bvxor {s} (bvlshr {s} (_ bv{d} {d}))) (bvor {s} (_ bv1 {d})))))\n",
                    .{ new_name, lhs_name_a, lhs_name_a, sh_clamped, W, lhs_name_b, W },
                );
            },
            .ADD_CONST => try w.print(
                "(assert (= {s} (bvadd {s} (_ bv{d} {d}))))\n",
                .{ new_name, lhs_name_a, imm_masked, W },
            ),
            .AND_NOT => try w.print(
                "(assert (= {s} (bvand {s} (bvnot {s}))))\n",
                .{ new_name, lhs_name_a, lhs_name_b },
            ),
            .OR_SHIFT => try w.print(
                "(assert (= {s} (bvor {s} (bvlshr {s} (_ bv{d} {d})))))\n",
                .{ new_name, lhs_name_a, lhs_name_b, shift_amt, W },
            ),
            .CALL_LIB => {
                // Inline the called program. Match runtime exactly:
                //   regs[dst] = chain_extras[imm % extras.len].execute(regs[src1])
                // If lib is null/empty or recursion bound hit, fall back to
                // identity (runtime does the same).
                const fallback_identity = blk: {
                    if (lib == null) break :blk true;
                    if (lib.?.extras.len == 0) break :blk true;
                    if (depth >= MaxMixerRecursion) break :blk true;
                    break :blk false;
                };
                if (fallback_identity) {
                    try w.print("(assert (= {s} {s}))\n", .{ new_name, lhs_name_a });
                } else {
                    const lb = lib.?;
                    const idx: usize = @intCast(ins.imm % lb.extras.len);
                    const call_id = call_counter.*;
                    call_counter.* = call_id + 1;
                    const sub_ns = try std.fmt.allocPrint(allocator, "{s}_c{d}", .{ ns, call_id });
                    defer allocator.free(sub_ns);
                    const final_ver = try emitMixerProgram(
                        allocator,
                        w,
                        side,
                        sub_ns,
                        lb.extras[idx],
                        num_bits,
                        lib,
                        depth + 1,
                        call_counter,
                        lhs_name_a,
                    );
                    try w.print("(assert (= {s} reg{d}_v{d}_{s}{s}))\n", .{ new_name, NumRegs - 1, final_ver, side, sub_ns });
                }
            },
            .ROTR => {
                if (shift_amt == 0 or shift_amt >= W) {
                    try w.print("(assert (= {s} {s}))\n", .{ new_name, lhs_name_a });
                } else {
                    try w.print(
                        "(assert (= {s} (bvor (bvlshr {s} (_ bv{d} {d})) (bvshl {s} (_ bv{d} {d})))))\n",
                        .{ new_name, lhs_name_a, shift_amt, W, lhs_name_a, W - shift_amt, W },
                    );
                }
            },
            .BSWAP => {
                if (W == 16) {
                    try w.print(
                        "(assert (= {s} (concat ((_ extract 7 0) {s}) ((_ extract 15 8) {s}))))\n",
                        .{ new_name, lhs_name_a, lhs_name_a },
                    );
                } else if (W == 32) {
                    try w.print(
                        "(assert (= {s} (concat ((_ extract 7 0) {s}) ((_ extract 15 8) {s}) ((_ extract 23 16) {s}) ((_ extract 31 24) {s}))))\n",
                        .{ new_name, lhs_name_a, lhs_name_a, lhs_name_a, lhs_name_a },
                    );
                } else if (W == 64) {
                    try w.print(
                        "(assert (= {s} (concat ((_ extract 7 0) {s}) ((_ extract 15 8) {s}) ((_ extract 23 16) {s}) ((_ extract 31 24) {s}) ((_ extract 39 32) {s}) ((_ extract 47 40) {s}) ((_ extract 55 48) {s}) ((_ extract 63 56) {s}))))\n",
                        .{ new_name, lhs_name_a, lhs_name_a, lhs_name_a, lhs_name_a, lhs_name_a, lhs_name_a, lhs_name_a, lhs_name_a },
                    );
                } else {
                    // Widths below one byte, or non-byte-aligned solver probes,
                    // treat byte-swap as identity rather than inventing
                    // fractional-byte semantics.
                    try w.print("(assert (= {s} {s}))\n", .{ new_name, lhs_name_a });
                }
            },
            .MUM => {
                const wide: u16 = @as(u16, W) * 2;
                try w.print(
                    "(assert (= {s} (let ((prod (bvmul ((_ zero_extend {d}) {s}) ((_ zero_extend {d}) (bvor {s} (_ bv1 {d})))))) (bvxor ((_ extract {d} 0) prod) ((_ extract {d} {d}) prod)))))\n",
                    .{ new_name, W, lhs_name_a, W, lhs_name_b, W, W - 1, wide - 1, W },
                );
            },
            .ADD_ROT => {
                if (shift_amt == 0 or shift_amt >= W) {
                    try w.print("(assert (= {s} (bvadd {s} {s})))\n", .{ new_name, lhs_name_a, lhs_name_b });
                } else {
                    try w.print(
                        "(assert (= {s} (let ((sum (bvadd {s} {s}))) (bvor (bvshl sum (_ bv{d} {d})) (bvlshr sum (_ bv{d} {d}))))))\n",
                        .{ new_name, lhs_name_a, lhs_name_b, shift_amt, W, W - shift_amt, W },
                    );
                }
            },
        }
    }

    return ver[NumRegs - 1];
}

pub fn emitMixerBijection(
    allocator: std.mem.Allocator,
    instrs: []const MixerInstr,
    num_bits: u8,
    lib: ?MixerLib,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();

    try w.print("(set-logic QF_BV)\n", .{});
    var cc_a: u32 = 0;
    var cc_b: u32 = 0;
    const final_a = try emitMixerProgram(allocator, w, "a", "", instrs, num_bits, lib, 0, &cc_a, null);
    const final_b = try emitMixerProgram(allocator, w, "b", "", instrs, num_bits, lib, 0, &cc_b, null);

    // a ≠ b  ∧  output_a = output_b
    try w.print("(assert (distinct reg0_v0_a reg0_v0_b))\n", .{});
    try w.print("(assert (= reg{d}_v{d}_a reg{d}_v{d}_b))\n", .{ NumRegs - 1, final_a, NumRegs - 1, final_b });
    try w.writeAll("(check-sat)\n");
    return buf.toOwnedSlice();
}

// ─── Z3 runner ───────────────────────────────────────────────────

// Z3 default error handler aborts the process with "Error: invalid argument".
// We install a no-op so errors propagate through Z3_get_error_code instead.
fn z3_silent_error_handler(_: c.Z3_context, _: c.Z3_error_code) callconv(.C) void {}

pub fn runSmtLib(allocator: std.mem.Allocator, smt_text: []const u8, timeout_ms: u32) !VerifyResult {
    const start = std.time.milliTimestamp();

    const cfg = c.Z3_mk_config() orelse return error.Z3ConfigCreate;
    defer c.Z3_del_config(cfg);

    var to_buf: [32]u8 = undefined;
    const timeout_s = try std.fmt.bufPrintZ(&to_buf, "{d}", .{timeout_ms});
    c.Z3_set_param_value(cfg, "timeout", timeout_s.ptr);

    const ctx = c.Z3_mk_context(cfg) orelse return error.Z3ContextCreate;
    defer c.Z3_del_context(ctx);

    c.Z3_set_error_handler(ctx, z3_silent_error_handler);

    const text_z = try allocator.dupeZ(u8, smt_text);
    defer allocator.free(text_z);

    // Z3_eval_smtlib2_string parses the full SMT-LIB2 program — including
    // (check-sat) and (get-model) — and returns the textual output, which
    // for our emitters is "sat\n<model>\n" or "unsat\n" or "unknown\n".
    const out_z = c.Z3_eval_smtlib2_string(ctx, text_z.ptr);
    const ec = c.Z3_get_error_code(ctx);
    const elapsed: u64 = @intCast(std.time.milliTimestamp() - start);
    if (out_z == null or ec != c.Z3_OK) {
        const err_msg = c.Z3_get_error_msg(ctx, ec);
        return VerifyResult{
            .verdict = .error_smt,
            .detail = std.mem.span(err_msg),
            .elapsed_ms = elapsed,
        };
    }
    const out = std.mem.span(out_z);

    // First non-empty line is the (check-sat) verdict
    var lines = std.mem.tokenizeAny(u8, out, "\n\r");
    const verdict_line = lines.next() orelse "";
    if (std.mem.startsWith(u8, verdict_line, "unsat")) {
        return VerifyResult{ .verdict = .verified, .detail = "no counter-example exists", .elapsed_ms = elapsed };
    } else if (std.mem.startsWith(u8, verdict_line, "sat")) {
        return VerifyResult{ .verdict = .counter_example, .detail = out, .elapsed_ms = elapsed };
    } else if (std.mem.startsWith(u8, verdict_line, "unknown")) {
        return VerifyResult{ .verdict = .unknown, .detail = "solver returned unknown (likely timeout)", .elapsed_ms = elapsed };
    }
    return VerifyResult{ .verdict = .error_smt, .detail = out, .elapsed_ms = elapsed };
}
