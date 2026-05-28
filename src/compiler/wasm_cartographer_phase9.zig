//! ⚠ FROZEN REGRESSION BASELINE — do not extend this file.
//! New analysis goes into `phase10_provenance.zig`. This file is preserved
//! verbatim so `zig build wasm-spike-phase9-regression` continues to prove the
//! Phase 9.1 single-load array-theory pipeline still works; any improvement
//! belongs in the Phase 10 substrate, which is a strict superset for store-
//! bounds + provenance + loop unrolling. See [[project-phase10-provenance]].
//!
//! Phase 9.1 — The Wasm Spike.
//!
//! Reverse-engineers a REAL compiled `.wasm` binary (embedded `wprobe.wasm`,
//! produced by:
//!   zig build-exe wprobe.zig -target wasm32-freestanding -fno-entry \
//!       -rdynamic -OReleaseSmall -femit-bin=wprobe.wasm
//! from source:
//!   export fn risky(buf: [*]u32, idx: u32, len: u32) u32 {
//!       if (idx < len) return buf[idx];
//!       return 0;
//!   }
//! ) into the substrate-agnostic `IrModule`, then hands it to the SAME
//! define-fun + libz3 honest gate used by the Phase-8 leviathan stream.
//!
//! SCOPE: only the section kinds and opcodes this one function uses are parsed.
//! It is a spike, not a Wasm validator. Compiler-emitted reality (NOT the
//! directive's guesses): the guard is `i32.ge_u` + `br_if` (inverted), and `*4`
//! is `i32.shl 2`. We parse what the binary actually contains.

const std = @import("std");
const ir = @import("ir_module_phase9.zig");

const c = @cImport({
    @cInclude("z3.h");
});

const WASM_PROBE = @embedFile("wprobe.wasm");

fn z3SilentErrorHandler(_: c.Z3_context, _: c.Z3_error_code) callconv(.C) void {}

// ── minimal byte reader with LEB128 ─────────────────────────────────────────
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *Reader) !u8 {
        if (self.pos >= self.bytes.len) return error.UnexpectedEof;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    fn slice(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return error.UnexpectedEof;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn uleb(self: *Reader) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.byte();
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        return result;
    }

    fn sleb(self: *Reader) !i64 {
        var result: i64 = 0;
        var shift: u7 = 0;
        var b: u8 = 0;
        while (true) {
            b = try self.byte();
            result |= @as(i64, @intCast(b & 0x7f)) << @intCast(shift);
            shift += 7;
            if (b & 0x80 == 0) break;
        }
        if (shift < 64 and (b & 0x40) != 0) {
            result |= @as(i64, -1) << @intCast(shift);
        }
        return result;
    }

    fn eof(self: *Reader) bool {
        return self.pos >= self.bytes.len;
    }
};

// Wasm opcodes we accept (everything the probe emits).
const Op = struct {
    const i32_const = 0x41;
    const local_get = 0x20;
    const local_set = 0x21;
    const block = 0x02;
    const br_if = 0x0d;
    const i32_lt_u = 0x49;
    const i32_ge_u = 0x4f;
    const i32_add = 0x6a;
    const i32_shl = 0x74;
    const i32_load = 0x28;
    const end = 0x0b;
    const ret = 0x0f;
};

/// Frontend entrypoint — satisfies ir.Frontend.parseFn.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) anyerror!ir.IrModule {
    var r = Reader{ .bytes = bytes };

    const magic = try r.slice(4);
    if (!std.mem.eql(u8, magic, "\x00asm")) return error.NotWasm;
    const version = try r.slice(4);
    if (!std.mem.eql(u8, version, "\x01\x00\x00\x00")) return error.BadWasmVersion;

    var num_params: usize = 0;
    var memory_bytes: u64 = 0;
    var func: ?ir.IrFunction = null;

    while (!r.eof()) {
        const id = try r.byte();
        const size = try r.uleb();
        const content = try r.slice(@intCast(size));
        var sr = Reader{ .bytes = content };

        switch (id) {
            1 => { // Type section — read func0's parameter count.
                const count = try sr.uleb();
                if (count >= 1) {
                    const form = try sr.byte(); // 0x60 functype
                    if (form != 0x60) return error.BadFuncType;
                    num_params = @intCast(try sr.uleb());
                }
            },
            5 => { // Memory section — linear memory size.
                const count = try sr.uleb();
                if (count >= 1) {
                    const flags = try sr.byte();
                    const min_pages = try sr.uleb();
                    if (flags & 0x01 != 0) _ = try sr.uleb(); // skip max
                    memory_bytes = min_pages * 65536;
                }
            },
            10 => { // Code section — parse func0's body into universal IR.
                const count = try sr.uleb();
                if (count >= 1) {
                    const body_size = try sr.uleb();
                    const body = try sr.slice(@intCast(body_size));
                    func = try parseBody(allocator, body, num_params);
                }
            },
            else => {}, // Function/Export/Global/etc. — not needed by the spike.
        }
    }

    const f = func orelse return error.NoCodeSection;
    const funcs = try allocator.alloc(ir.IrFunction, 1);
    funcs[0] = f;
    return ir.IrModule{ .substrate = "wasm", .memory_bytes = memory_bytes, .funcs = funcs };
}

fn parseBody(allocator: std.mem.Allocator, body: []const u8, num_params: usize) !ir.IrFunction {
    var r = Reader{ .bytes = body };

    // Local declarations: count of (count, valtype) groups.
    const decl_groups = try r.uleb();
    var extra_locals: usize = 0;
    for (0..decl_groups) |_| {
        const cnt = try r.uleb();
        _ = try r.byte(); // valtype
        extra_locals += @intCast(cnt);
    }

    var insts = std.ArrayList(ir.IrInst).init(allocator);
    var depth: usize = 0;

    while (true) {
        const op = try r.byte();
        switch (op) {
            Op.i32_const => {
                const v = try r.sleb();
                try insts.append(.{ .op = .const_i32, .imm = @as(u32, @truncate(@as(u64, @bitCast(v)))) });
            },
            Op.local_get => try insts.append(.{ .op = .local_get, .imm = try r.uleb() }),
            Op.local_set => try insts.append(.{ .op = .local_set, .imm = try r.uleb() }),
            Op.block => {
                _ = try r.byte(); // blocktype (0x40 void for the probe)
                depth += 1;
                try insts.append(.{ .op = .block_begin });
            },
            Op.br_if => try insts.append(.{ .op = .br_if, .imm = try r.uleb() }),
            Op.i32_lt_u => try insts.append(.{ .op = .i_lt_u }),
            Op.i32_ge_u => try insts.append(.{ .op = .i_ge_u }),
            Op.i32_add => try insts.append(.{ .op = .i_add }),
            Op.i32_shl => try insts.append(.{ .op = .i_shl }),
            Op.i32_load => {
                const al = try r.uleb();
                const off = try r.uleb();
                try insts.append(.{ .op = .load_i32, .imm = off, .align_log2 = @intCast(al) });
            },
            Op.ret => try insts.append(.{ .op = .ret }),
            Op.end => {
                if (depth == 0) break; // function end
                depth -= 1;
                try insts.append(.{ .op = .block_end });
            },
            else => {
                std.debug.print("wasm_cartographer: unsupported opcode 0x{x:0>2} (spike scope)\n", .{op});
                return error.UnsupportedOpcode;
            },
        }
    }

    return ir.IrFunction{
        .num_params = num_params,
        .num_extra_locals = extra_locals,
        .insts = try insts.toOwnedSlice(),
    };
}

// ── real libz3 gate (mirrors autonomous_guard.zig / leviathan_stream.zig) ────
const Verdict = enum { sat, unsat, unknown, err };

fn runZ3(allocator: std.mem.Allocator, smt_text: []const u8) Verdict {
    const cfg = c.Z3_mk_config() orelse return .err;
    defer c.Z3_del_config(cfg);
    c.Z3_set_param_value(cfg, "timeout", "5000");
    const ctx = c.Z3_mk_context(cfg) orelse return .err;
    defer c.Z3_del_context(ctx);
    c.Z3_set_error_handler(ctx, z3SilentErrorHandler);

    const text_z = allocator.dupeZ(u8, smt_text) catch return .err;
    defer allocator.free(text_z);
    const out_z = c.Z3_eval_smtlib2_string(ctx, text_z.ptr);
    if (out_z == null) return .err;
    const out = std.mem.span(out_z);

    var lines = std.mem.tokenizeAny(u8, out, "\n\r");
    const first = lines.next() orelse "";
    if (std.mem.startsWith(u8, first, "unsat")) return .unsat;
    if (std.mem.startsWith(u8, first, "sat")) return .sat;
    if (std.mem.startsWith(u8, first, "unknown")) return .unknown;
    return .err;
}

fn word(v: Verdict) []const u8 {
    return switch (v) {
        .sat => "SAT",
        .unsat => "UNSAT",
        .unknown => "UNKNOWN",
        .err => "ERR",
    };
}

fn opName(op: ir.IrOpcode) []const u8 {
    return switch (op) {
        .const_i32 => "const_i32",
        .local_get => "local_get",
        .local_set => "local_set",
        .i_add => "i_add",
        .i_shl => "i_shl",
        .i_lt_u => "i_lt_u",
        .i_ge_u => "i_ge_u",
        .load_i32 => "load_i32",
        .block_begin => "block_begin",
        .block_end => "block_end",
        .br_if => "br_if",
        .ret => "ret",
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    std.debug.print("=== GHOST ENGINE: Wasm Spike (Phase 9.1) ===\n\n", .{});

    // The substrate boundary in action: the core only sees `ir.Frontend`.
    const frontend = ir.Frontend{ .name = "wasm", .parseFn = parse };
    std.debug.print("[FRONTEND] substrate = {s}, bytes = {d}\n", .{ frontend.name, WASM_PROBE.len });

    const module = try frontend.parseFn(a, WASM_PROBE);
    std.debug.print("[PARSE] linear memory = {d} bytes ({d} pages), funcs = {d}\n", .{
        module.memory_bytes, module.memory_bytes / 65536, module.funcs.len,
    });
    const f = module.funcs[0];
    std.debug.print("[PARSE] func0: params = {d}, extra locals = {d}, insts = {d}\n", .{
        f.num_params, f.num_extra_locals, f.insts.len,
    });
    std.debug.print("[PARSE] recovered universal IR:\n", .{});
    for (f.insts, 0..) |inst, i| {
        std.debug.print("  {d:>2}: {s}", .{ i, opName(inst.op) });
        switch (inst.op) {
            .const_i32, .local_get, .local_set, .br_if => std.debug.print(" {d}", .{inst.imm}),
            .load_i32 => std.debug.print(" off={d} align={d}", .{ inst.imm, inst.align_log2 }),
            else => {},
        }
        std.debug.print("\n", .{});
    }

    // Substrate-agnostic analysis (knows nothing about Wasm).
    const ba = try ir.analyze(a, module, 0);
    std.debug.print("\n[ANALYZE] guarded memory access recovered:\n", .{});
    std.debug.print("  load path-guard : {s}\n", .{ba.guard});
    std.debug.print("  load address    : {s}\n", .{ba.addr});
    std.debug.print("  access size     : {d} bytes, linear-mem model = (Array (_ BitVec 32) (_ BitVec 8))\n", .{ba.access_bytes});

    // Show the actual SMT the linear memory model lowers to.
    const q_sens = try ir.smtMemorySensitivity(a, ba);
    std.debug.print("\n[SMT] memory-sensitivity query handed to libz3:\n--------\n{s}--------\n", .{q_sens});

    const q_safe = try ir.smtBoundsSafety(a, ba, true);
    const q_unsafe = try ir.smtBoundsSafety(a, ba, false);

    std.debug.print("\n[Z3] on-demand Tier-2 verification (real libz3):\n", .{});
    const v_sens = runZ3(a, q_sens);
    const v_safe = runZ3(a, q_safe);
    const v_unsafe = runZ3(a, q_unsafe);

    report("memory sensitivity (array theory wired, path reachable)", v_sens, .sat);
    report("bounds safety WITH the bytecode's guard", v_safe, .unsat);
    report("bounds safety WITHOUT the guard (control)", v_unsafe, .sat);

    const ok = v_sens == .sat and v_safe == .unsat and v_unsafe == .sat;
    std.debug.print("\n[RESULT] {s}: Z3 ingested the Wasm linear-memory model and the guard's", .{if (ok) "PASS" else "FAIL"});
    std.debug.print(" sufficiency is proven (UNSAT) while its removal yields a counterexample (SAT).\n", .{});
}

fn report(label: []const u8, got: Verdict, expect: Verdict) void {
    const mark = if (got == expect) "OK " else "!! ";
    std.debug.print("  [{s}] {s:<52} -> {s} (expected {s})\n", .{ mark, label, word(got), word(expect) });
}
