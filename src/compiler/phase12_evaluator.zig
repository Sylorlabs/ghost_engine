//! Phase 12 — LLM-guided CEGIS evaluator (stdin/stdout JSON bridge).
//!
//! Reads one JSON request from stdin; writes one JSON result to stdout.
//! No network I/O. No state. Designed to be forked by llm_orchestrator.py.
//!
//! stdin format:
//!   { "wasm_path": "...", "candidate": [ {"op": "...", "arg": N}, ... ] }
//!   Omit or empty "candidate" array → PROBE mode: returns witness info only.
//!
//! stdout format (PROBE):
//!   { "status": "PROBE", "witness": {...}, "pristine_local": N,
//!     "alloc_func_idx": N, "baseline_ops": [...],
//!     "baseline_op_count": N, "baseline_byte_count": N }
//!
//! stdout format (EVAL — success):
//!   { "status": "PASS", "guard_op_count": N, "guard_byte_count": N,
//!     "baseline_op_count": N, "baseline_byte_count": N }
//!
//! stdout format (EVAL — failure):
//!   { "status": "FAIL", "reason": "...", "detail": "..." }
//!
//! Reasons (FAIL):
//!   PARSE_ERROR        — JSON parse / unknown opcode / bad arg
//!   STACK_ERROR        — stack-effect check failed
//!   VACUOUS_GUARD      — no comparison + if_void pair found
//!   WASM_LOAD_ERROR    — could not read wasm_path
//!   ANALYZE_ERROR      — Phase 10 analyzer returned UNANALYZABLE on input
//!   MULTI_WITNESS      — wasm has >1 witness (not supported in MVP)
//!   ALREADY_UNSAT      — input binary is already UNSAT (nothing to fix)
//!   PATCH_ANALYZE_ERR  — patched binary did not analyze
//!   SAFETY_SAT         — patched binary: combined Z3 query still SAT
//!   WITNESS_SAT        — patched binary: per-witness Z3 query still SAT

const std = @import("std");
const prov = @import("phase10_provenance.zig");
const weaver = @import("phase11_weaver.zig");

const ALLOC_CFG = prov.AllocatorConfig{
    .name = "dummy_alloc",
    .kind = .import_,
    .module = "env",
    .size_arg_index = 0,
};

const FUNC_IDX: u32 = 0;

// ── Candidate op grammar ────────────────────────────────────────────────────
//
// JSON op names use Wasm convention (dots); Zig enum uses underscores.
// See opNameToCode() below for the mapping.

const OpCode = enum {
    local_get,
    i32_const,
    i32_add,
    i32_sub,
    i32_gt_u,
    i32_ge_u,
    i32_lt_u,
    i32_le_u,
    i32_eqz,
    if_void,
    unreachable_,
    end_,
};

const CandidateOp = struct {
    code: OpCode,
    arg: i64 = 0, // used by local_get (u32) and i32_const (i32 range)
};

fn opNameToCode(name: []const u8) ?OpCode {
    const table = .{
        .{ "local.get",   OpCode.local_get   },
        .{ "i32.const",   OpCode.i32_const   },
        .{ "i32.add",     OpCode.i32_add     },
        .{ "i32.sub",     OpCode.i32_sub     },
        .{ "i32.gt_u",    OpCode.i32_gt_u    },
        .{ "i32.ge_u",    OpCode.i32_ge_u    },
        .{ "i32.lt_u",    OpCode.i32_lt_u    },
        .{ "i32.le_u",    OpCode.i32_le_u    },
        .{ "i32.eqz",     OpCode.i32_eqz     },
        .{ "if_void",     OpCode.if_void     },
        .{ "unreachable", OpCode.unreachable_ },
        .{ "end",         OpCode.end_        },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn opCodeToName(code: OpCode) []const u8 {
    return switch (code) {
        .local_get   => "local.get",
        .i32_const   => "i32.const",
        .i32_add     => "i32.add",
        .i32_sub     => "i32.sub",
        .i32_gt_u    => "i32.gt_u",
        .i32_ge_u    => "i32.ge_u",
        .i32_lt_u    => "i32.lt_u",
        .i32_le_u    => "i32.le_u",
        .i32_eqz     => "i32.eqz",
        .if_void     => "if_void",
        .unreachable_ => "unreachable",
        .end_        => "end",
    };
}

// ── LEB128 helpers (duplicated from phase11_weaver for standalone auditability) ──

fn writeSlebI32(buf: *std.ArrayList(u8), value: i32) !void {
    var v = value;
    while (true) {
        const byte: u8 = @as(u8, @intCast(@as(u32, @bitCast(v)) & 0x7F));
        v >>= 7;
        const sign_bit = (byte & 0x40) != 0;
        const more = !((v == 0 and !sign_bit) or (v == -1 and sign_bit));
        if (more) {
            try buf.append(byte | 0x80);
        } else {
            try buf.append(byte);
            return;
        }
    }
}

fn writeUlebU32(buf: *std.ArrayList(u8), value: u32) !void {
    var v = value;
    while (true) {
        const byte: u8 = @as(u8, @intCast(v & 0x7F));
        v >>= 7;
        if (v == 0) {
            try buf.append(byte);
            return;
        }
        try buf.append(byte | 0x80);
    }
}

// ── Stack-effect checker ─────────────────────────────────────────────────────

const StackCheckResult = union(enum) {
    ok,
    underflow: usize,  // op index where underflow occurred
    net_nonzero: i32,  // final depth
    unclosed_if,
    spurious_end,
};

fn checkStackEffect(ops: []const CandidateOp) StackCheckResult {
    var depth: i32 = 0;
    var if_depth: u32 = 0;
    for (ops, 0..) |op, i| {
        switch (op.code) {
            .local_get, .i32_const => depth += 1,
            .i32_add, .i32_sub,
            .i32_gt_u, .i32_ge_u,
            .i32_lt_u, .i32_le_u => {
                if (depth < 2) return .{ .underflow = i };
                depth -= 1; // pop 2, push 1
            },
            .i32_eqz => {
                if (depth < 1) return .{ .underflow = i };
                // pop 1, push 1 — net 0
            },
            .if_void => {
                if (depth < 1) return .{ .underflow = i };
                depth -= 1; // consume condition
                if_depth += 1;
            },
            .unreachable_ => {},  // polymorphic, no effect to track
            .end_ => {
                if (if_depth == 0) return .spurious_end;
                if_depth -= 1;
            },
        }
    }
    if (depth != 0) return .{ .net_nonzero = depth };
    if (if_depth != 0) return .unclosed_if;
    return .ok;
}

// ── Non-vacuity syntactic check ──────────────────────────────────────────────
// Requires at least one comparison opcode AND at least one if_void.
// This catches `[unreachable]` and `[i32.const 1, if_void, unreachable, end]`
// at the syntactic level; semantic vacuity (always-true condition) is left
// to a future full Z3 non-vacuity query.

fn isNonVacuous(ops: []const CandidateOp) bool {
    var saw_compare = false;
    var saw_if = false;
    for (ops) |op| {
        switch (op.code) {
            .i32_gt_u, .i32_ge_u, .i32_lt_u, .i32_le_u, .i32_eqz => saw_compare = true,
            .if_void => saw_if = true,
            else => {},
        }
    }
    return saw_compare and saw_if;
}

// ── Opcode encoder ───────────────────────────────────────────────────────────

fn encodeOps(allocator: std.mem.Allocator, ops: []const CandidateOp) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    for (ops) |op| {
        switch (op.code) {
            .local_get   => { try buf.append(0x20); try writeUlebU32(&buf, @intCast(op.arg)); },
            .i32_const   => { try buf.append(0x41); try writeSlebI32(&buf, @intCast(op.arg)); },
            .i32_add     => try buf.append(0x6a),
            .i32_sub     => try buf.append(0x6b),
            .i32_gt_u    => try buf.append(0x4b),
            .i32_ge_u    => try buf.append(0x4f),
            .i32_lt_u    => try buf.append(0x49),
            .i32_le_u    => try buf.append(0x4d),
            .i32_eqz     => try buf.append(0x45),
            .if_void     => { try buf.append(0x04); try buf.append(0x40); },
            .unreachable_ => try buf.append(0x00),
            .end_        => try buf.append(0x0b),
        }
    }
    return buf.toOwnedSlice();
}

// ── JSON parser for candidate array ─────────────────────────────────────────

const ParseOpsError = error{
    MissingOpField,
    UnknownOpcode,
    ArgNotInteger,
    OutOfMemory,
};

fn parseOps(
    allocator: std.mem.Allocator,
    array: std.json.Value,
) ParseOpsError![]CandidateOp {
    const items = array.array.items;
    var ops = try allocator.alloc(CandidateOp, items.len);
    for (items, 0..) |item, idx| {
        const op_val = item.object.get("op") orelse return ParseOpsError.MissingOpField;
        const code = opNameToCode(op_val.string) orelse return ParseOpsError.UnknownOpcode;
        const arg: i64 = if (item.object.get("arg")) |av| switch (av) {
            .integer => |n| n,
            else => return ParseOpsError.ArgNotInteger,
        } else 0;
        ops[idx] = .{ .code = code, .arg = arg };
    }
    return ops;
}

// ── Baseline ops reconstruction ──────────────────────────────────────────────
// Mirrors synthesizeGuardBytes() structure in op-list form for the PROBE output.

fn buildBaselineOps(
    allocator: std.mem.Allocator,
    witness: prov.StoreWitness,
    pristine_local: u32,
) ![]CandidateOp {
    var ops = std.ArrayList(CandidateOp).init(allocator);
    try ops.append(.{ .code = .local_get, .arg = @intCast(witness.addr_local) });
    try ops.append(.{ .code = .local_get, .arg = @intCast(pristine_local) });
    try ops.append(.{ .code = .i32_sub });
    if (witness.addr_const_offset != 0) {
        try ops.append(.{ .code = .i32_const, .arg = @intCast(witness.addr_const_offset) });
        try ops.append(.{ .code = .i32_add });
    }
    try ops.append(.{ .code = .i32_const, .arg = @intCast(witness.alloc_size - witness.width) });
    try ops.append(.{ .code = .i32_gt_u });
    try ops.append(.{ .code = .if_void });
    try ops.append(.{ .code = .unreachable_ });
    try ops.append(.{ .code = .end_ });
    return ops.toOwnedSlice();
}

// ── Preamble surgery helper ──────────────────────────────────────────────────
// Runs injectPreservationLocal + cloneAllocBase and returns the post-surgery
// wasm + pristine_local + tee_len + alloc_call_end_pre (for offset shifting).

const PreambleResult = struct {
    wasm: []u8,
    pristine_local: u32,
    tee_len: usize,
    alloc_call_end_pre: usize,
};

fn runPreamble(
    allocator: std.mem.Allocator,
    wasm_in: []const u8,
    alloc_func_idx: u32,
) !PreambleResult {
    const preserve = try weaver.injectPreservationLocal(allocator, wasm_in, FUNC_IDX);
    // preserve.new_wasm is owned by the caller via this result.

    const after_clone = try weaver.cloneAllocBase(
        allocator,
        preserve.new_wasm,
        FUNC_IDX,
        alloc_func_idx,
        preserve.new_local_idx,
    );
    allocator.free(preserve.new_wasm);

    // Compute tee byte length: opcode(1) + ULEB(pristine_local).
    var tee_buf = std.ArrayList(u8).init(allocator);
    defer tee_buf.deinit();
    try tee_buf.append(0x22); // local.tee
    try writeUlebU32(&tee_buf, preserve.new_local_idx);
    const tee_len = tee_buf.items.len;

    // find alloc call end in the pre-clone wasm so we know which witnesses shift.
    // Re-run injectPreservationLocal to get back the preserve.new_wasm for scanning.
    const preserve2 = try weaver.injectPreservationLocal(allocator, wasm_in, FUNC_IDX);
    defer allocator.free(preserve2.new_wasm);
    const alloc_call_end = try weaver.findAllocatorCallEnd(
        allocator, preserve2.new_wasm, FUNC_IDX, alloc_func_idx,
    );

    return PreambleResult{
        .wasm = after_clone,
        .pristine_local = preserve.new_local_idx,
        .tee_len = tee_len,
        .alloc_call_end_pre = alloc_call_end,
    };
}

// ── JSON output helpers ──────────────────────────────────────────────────────

fn writeOpsJson(w: anytype, ops: []const CandidateOp) !void {
    try w.writeAll("[");
    for (ops, 0..) |op, i| {
        if (i > 0) try w.writeAll(", ");
        switch (op.code) {
            .local_get, .i32_const => try w.print(
                "{{\"op\": \"{s}\", \"arg\": {d}}}", .{ opCodeToName(op.code), op.arg },
            ),
            else => try w.print("{{\"op\": \"{s}\"}}", .{opCodeToName(op.code)}),
        }
    }
    try w.writeAll("]");
}

// ── Main ─────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // ── Read stdin ──────────────────────────────────────────────────────────
    const stdin_raw = std.io.getStdIn().reader().readAllAlloc(a, 4 << 20) catch |e| {
        try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"PARSE_ERROR\", \"detail\": \"stdin read: {s}\"}}\n", .{@errorName(e)});
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, a, stdin_raw, .{}) catch |e| {
        try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"PARSE_ERROR\", \"detail\": \"JSON: {s}\"}}\n", .{@errorName(e)});
        return;
    };
    const root = parsed.value;

    const wasm_path = (root.object.get("wasm_path") orelse {
        try stdout.writeAll("{\"status\": \"FAIL\", \"reason\": \"PARSE_ERROR\", \"detail\": \"missing wasm_path\"}\n");
        return;
    }).string;

    // ── Load wasm ───────────────────────────────────────────────────────────
    const wasm_bytes = std.fs.cwd().readFileAlloc(a, wasm_path, 4 << 20) catch |e| {
        try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"WASM_LOAD_ERROR\", \"detail\": \"{s}: {s}\"}}\n", .{ wasm_path, @errorName(e) });
        return;
    };

    // ── Step 1: analyze input binary ────────────────────────────────────────
    try stderr.writeAll("[phase12] analyzing input binary...\n");
    const r1 = prov.analyze(a, wasm_bytes, ALLOC_CFG) catch |e| {
        try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"ANALYZE_ERROR\", \"detail\": \"analyze: {s}\"}}\n", .{@errorName(e)});
        return;
    };

    if (r1.state != .analyzes) {
        try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"ANALYZE_ERROR\", \"detail\": \"{s}\"}}\n", .{r1.reason orelse "unknown"});
        return;
    }
    if (r1.witnesses.len == 0) {
        try stdout.writeAll("{\"status\": \"FAIL\", \"reason\": \"ANALYZE_ERROR\", \"detail\": \"no witnesses found\"}\n");
        return;
    }

    const v1 = prov.runZ3(a, r1.smt orelse "");
    if (v1 == .unsat) {
        try stdout.writeAll("{\"status\": \"FAIL\", \"reason\": \"ALREADY_UNSAT\", \"detail\": \"input binary already UNSAT\"}\n");
        return;
    }

    const alloc_func_idx = r1.allocator_func_idx orelse {
        try stdout.writeAll("{\"status\": \"FAIL\", \"reason\": \"ANALYZE_ERROR\", \"detail\": \"no allocator func idx\"}\n");
        return;
    };

    // Deduplicate witnesses by body_offset_of_store (loop unrolling produces
    // identical witnesses for the same source site; only one guard is needed).
    // Pick the witness with the smallest body_offset as the representative.
    var rep_witness = r1.witnesses[0];
    for (r1.witnesses[1..]) |w| {
        if (w.body_offset_of_store < rep_witness.body_offset_of_store) rep_witness = w;
    }
    const witness = rep_witness;

    // Verify all witnesses share the same structural parameters (addr_local,
    // alloc_size, width, addr_const_offset). If they differ, the single-template
    // approach doesn't apply and we need per-witness candidates.
    for (r1.witnesses) |w| {
        if (w.addr_local != witness.addr_local or
            w.alloc_size != witness.alloc_size or
            w.width != witness.width or
            w.addr_const_offset != witness.addr_const_offset)
        {
            try stdout.print(
                "{{\"status\": \"FAIL\", \"reason\": \"MULTI_WITNESS\", " ++
                "\"detail\": \"witnesses have heterogeneous parameters; per-witness synthesis not yet supported\"}}\n", .{},
            );
            return;
        }
    }

    // ── Step 2: preamble surgery (needed for both PROBE and EVAL) ───────────
    try stderr.writeAll("[phase12] running preamble surgery...\n");
    const preamble = runPreamble(a, wasm_bytes, alloc_func_idx) catch |e| {
        try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"ANALYZE_ERROR\", \"detail\": \"preamble: {s}\"}}\n", .{@errorName(e)});
        return;
    };

    // ── PROBE mode: return witness info ──────────────────────────────────────
    const candidate_node = root.object.get("candidate");
    const is_probe = candidate_node == null or candidate_node.?.array.items.len == 0;

    if (is_probe) {
        const baseline_ops = buildBaselineOps(a, witness, preamble.pristine_local) catch |e| {
            try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"ANALYZE_ERROR\", \"detail\": \"baseline: {s}\"}}\n", .{@errorName(e)});
            return;
        };
        const baseline_bytes = encodeOps(a, baseline_ops) catch |e| {
            try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"ANALYZE_ERROR\", \"detail\": \"encode baseline: {s}\"}}\n", .{@errorName(e)});
            return;
        };

        try stdout.print(
            "{{\"status\": \"PROBE\", \"witness\": {{" ++
            "\"func_idx\": {d}, \"body_offset_of_store\": {d}, " ++
            "\"addr_local\": {d}, \"addr_const_offset\": {d}, " ++
            "\"width\": {d}, \"alloc_size\": {d}}}, " ++
            "\"pristine_local\": {d}, \"alloc_func_idx\": {d}, " ++
            "\"baseline_ops\": ",
            .{
                witness.func_idx, witness.body_offset_of_store,
                witness.addr_local, witness.addr_const_offset,
                witness.width, witness.alloc_size,
                preamble.pristine_local, alloc_func_idx,
            },
        );
        try writeOpsJson(stdout, baseline_ops);
        try stdout.print(
            ", \"baseline_op_count\": {d}, \"baseline_byte_count\": {d}}}\n",
            .{ baseline_ops.len, baseline_bytes.len },
        );
        return;
    }

    // ── EVAL mode: validate + apply candidate ────────────────────────────────

    // Parse candidate ops.
    const ops = parseOps(a, candidate_node.?) catch |e| {
        try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"PARSE_ERROR\", \"detail\": \"{s}\"}}\n", .{@errorName(e)});
        return;
    };

    // Stack-effect check.
    switch (checkStackEffect(ops)) {
        .ok => {},
        .underflow => |idx| {
            try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"STACK_ERROR\", \"detail\": \"underflow at op {d}\"}}\n", .{idx});
            return;
        },
        .net_nonzero => |d| {
            try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"STACK_ERROR\", \"detail\": \"net stack depth {d} != 0\"}}\n", .{d});
            return;
        },
        .unclosed_if => {
            try stdout.writeAll("{\"status\": \"FAIL\", \"reason\": \"STACK_ERROR\", \"detail\": \"unclosed if_void\"}\n");
            return;
        },
        .spurious_end => {
            try stdout.writeAll("{\"status\": \"FAIL\", \"reason\": \"STACK_ERROR\", \"detail\": \"end without if_void\"}\n");
            return;
        },
    }

    // Non-vacuity syntactic check.
    if (!isNonVacuous(ops)) {
        try stdout.writeAll("{\"status\": \"FAIL\", \"reason\": \"VACUOUS_GUARD\", \"detail\": \"no comparison + if_void pair\"}\n");
        return;
    }

    // Encode to bytes.
    const guard_bytes = encodeOps(a, ops) catch |e| {
        try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"PARSE_ERROR\", \"detail\": \"encode: {s}\"}}\n", .{@errorName(e)});
        return;
    };

    // Build deduplicated, descending-offset list of sites to patch (mirrors
    // applyAll's dedup + sort logic so offsets stay valid across splices).
    var seen_offsets = std.AutoHashMap(usize, void).init(a);
    defer seen_offsets.deinit();
    var patch_sites = std.ArrayList(usize).init(a);
    defer patch_sites.deinit();
    for (r1.witnesses) |w| {
        if (w.func_idx != FUNC_IDX) continue;
        if (seen_offsets.contains(w.body_offset_of_store)) continue;
        try seen_offsets.put(w.body_offset_of_store, {});
        // Shift offset for the local.tee injected by cloneAllocBase.
        var off = w.body_offset_of_store;
        if (off >= preamble.alloc_call_end_pre) off += preamble.tee_len;
        try patch_sites.append(off);
    }
    std.mem.sort(usize, patch_sites.items, {}, std.sort.desc(usize));

    // Splice custom guard at each site (descending so prior splices don't
    // invalidate later offsets — same discipline as applyAll).
    try stderr.writeAll("[phase12] splicing candidate guard...\n");
    var patched = try a.dupe(u8, preamble.wasm);
    for (patch_sites.items) |site_offset| {
        const next = weaver.injectCustomGuardBytes(
            a, patched, FUNC_IDX, site_offset, guard_bytes,
        ) catch |e| {
            try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"PATCH_ANALYZE_ERR\", \"detail\": \"splice at 0x{x}: {s}\"}}\n", .{ site_offset, @errorName(e) });
            return;
        };
        a.free(patched);
        patched = next;
    }

    // Re-analyze.
    try stderr.writeAll("[phase12] re-analyzing patched binary...\n");
    const r2 = prov.analyze(a, patched, ALLOC_CFG) catch |e| {
        try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"PATCH_ANALYZE_ERR\", \"detail\": \"re-analyze: {s}\"}}\n", .{@errorName(e)});
        return;
    };
    if (r2.state != .analyzes) {
        try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"PATCH_ANALYZE_ERR\", \"detail\": \"{s}\"}}\n", .{r2.reason orelse "unanalyzable"});
        return;
    }

    // Safety check: combined SMT must be UNSAT.
    const v2 = prov.runZ3(a, r2.smt orelse "");
    if (v2 != .unsat) {
        try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"SAFETY_SAT\", \"detail\": \"combined Z3 = {s}\"}}\n", .{prov.verdictWord(v2)});
        return;
    }

    // Per-witness safety check.
    for (r2.per_witness_smts, 0..) |wsmt, wi| {
        const wv = prov.runZ3(a, wsmt);
        if (wv != .unsat) {
            try stdout.print("{{\"status\": \"FAIL\", \"reason\": \"WITNESS_SAT\", \"detail\": \"witness[{d}] Z3 = {s}\"}}\n", .{ wi, prov.verdictWord(wv) });
            return;
        }
    }

    // Compute baseline for comparison reporting.
    const baseline_ops = buildBaselineOps(a, witness, preamble.pristine_local) catch &[_]CandidateOp{};
    const baseline_bytes = encodeOps(a, baseline_ops) catch &[_]u8{};

    try stdout.print(
        "{{\"status\": \"PASS\", \"guard_op_count\": {d}, \"guard_byte_count\": {d}, " ++
        "\"baseline_op_count\": {d}, \"baseline_byte_count\": {d}}}\n",
        .{ ops.len, guard_bytes.len, baseline_ops.len, baseline_bytes.len },
    );
}
