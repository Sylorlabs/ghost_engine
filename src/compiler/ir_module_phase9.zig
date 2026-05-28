//! ⚠ FROZEN REGRESSION BASELINE — do not extend this file.
//! New analysis goes into `phase10_provenance.zig`, which carries a typed
//! stack with provenance tags, store-bounds R-rules, k=3 loop unrolling, and
//! a named-allocator contract — all of which subsume this file's straight-line
//! single-load array-theory pipeline. This file exists ONLY so that
//! `zig build wasm-spike-phase9-regression` keeps proving the original
//! Phase 9.1 path still works. See [[project-phase10-provenance]].
//!
//! Phase 9.1 — The substrate-agnostic IR abstraction.
//!
//! HONEST DESCRIPTION (read before believing any hype):
//!
//! The Cartographer/Z3 core must not know whether it is eating WebAssembly or
//! LLVM IR. This module is that boundary. A *frontend* (e.g. wasm_cartographer)
//! lowers its native bytecode into the small universal IR defined here; the
//! analysis (`analyze`) and SMT lowering (`smt*`) below operate ONLY on that
//! universal IR. To add LLVM later you implement one more `Frontend.parseFn`
//! that produces an `IrModule` — the analysis code does not change.
//!
//! This is a SPIKE. The IR covers exactly the opcodes the bounds-check probe
//! lowers to. It is not a complete IR and does not pretend to be. The linear
//! memory is modelled honestly as an SMT byte-array (theory of arrays); a load
//! is a select-concat, and the bounds proof must relate idx/len/memory-size
//! itself — none of which the load instruction carries (semantic erasure).

const std = @import("std");

pub const ValType = enum { i32, i64 };

/// Universal opcodes. A frontend maps its native instruction set onto these.
pub const IrOpcode = enum {
    const_i32,
    local_get,
    local_set,
    i_add,
    i_shl,
    i_lt_u,
    i_ge_u,
    load_i32,
    block_begin,
    block_end,
    br_if,
    ret,
};

pub const IrInst = struct {
    op: IrOpcode,
    /// const value, local index, branch label, or load offset depending on op.
    imm: u64 = 0,
    /// alignment (log2) for memory ops.
    align_log2: u32 = 0,
};

pub const IrFunction = struct {
    num_params: usize,
    /// locals declared beyond the parameters.
    num_extra_locals: usize,
    insts: []const IrInst,
};

pub const IrModule = struct {
    /// Where the IR came from — for honest logging only.
    substrate: []const u8,
    /// Linear memory size in bytes (0 if the module declares none).
    memory_bytes: u64,
    funcs: []const IrFunction,
};

/// The interface that makes the core substrate-agnostic. Wasm implements it
/// today; an LLVM frontend would provide the same signature.
pub const Frontend = struct {
    name: []const u8,
    parseFn: *const fn (std.mem.Allocator, []const u8) anyerror!IrModule,
};

/// Result of symbolically executing a function down to its (single, in this
/// spike) guarded memory access.
pub const BoundsAnalysis = struct {
    /// SMT Bool: the path condition under which the load actually executes.
    guard: []const u8,
    /// SMT bv32: the effective byte address of the load.
    addr: []const u8,
    /// bytes touched by the load (4 for i32.load).
    access_bytes: u32,
    /// linear memory size carried from the module.
    memory_bytes: u64,
    num_params: usize,
};

const Stack = std.ArrayList([]const u8);

fn pop(stack: *Stack) ![]const u8 {
    return stack.pop() orelse error.StackUnderflow;
}

/// Symbolically execute `func_idx` over the universal IR, recovering the
/// guarded memory access. This is the substrate-agnostic heart: it never
/// mentions Wasm or LLVM, only `IrInst`.
pub fn analyze(allocator: std.mem.Allocator, module: IrModule, func_idx: usize) !BoundsAnalysis {
    const f = module.funcs[func_idx];

    var stack = Stack.init(allocator);
    defer stack.deinit();

    const nlocals = f.num_params + f.num_extra_locals;
    const locals = try allocator.alloc(?[]const u8, nlocals);
    for (0..nlocals) |i| {
        locals[i] = if (i < f.num_params)
            try std.fmt.allocPrint(allocator, "l{d}", .{i})
        else
            null;
    }

    // Accumulated path condition for the fall-through (non-branching) path.
    var path_guard: ?[]const u8 = null;
    var found: ?BoundsAnalysis = null;

    for (f.insts) |inst| {
        switch (inst.op) {
            .const_i32 => {
                const t = try std.fmt.allocPrint(allocator, "#x{x:0>8}", .{@as(u32, @truncate(inst.imm))});
                try stack.append(t);
            },
            .local_get => {
                const v = locals[inst.imm] orelse return error.ReadUninitLocal;
                try stack.append(v);
            },
            .local_set => {
                locals[inst.imm] = try pop(&stack);
            },
            .i_add => {
                const b = try pop(&stack);
                const a = try pop(&stack);
                try stack.append(try std.fmt.allocPrint(allocator, "(bvadd {s} {s})", .{ a, b }));
            },
            .i_shl => {
                const b = try pop(&stack);
                const a = try pop(&stack);
                try stack.append(try std.fmt.allocPrint(allocator, "(bvshl {s} {s})", .{ a, b }));
            },
            .i_lt_u => {
                const b = try pop(&stack);
                const a = try pop(&stack);
                try stack.append(try std.fmt.allocPrint(allocator, "(bvult {s} {s})", .{ a, b }));
            },
            .i_ge_u => {
                const b = try pop(&stack);
                const a = try pop(&stack);
                try stack.append(try std.fmt.allocPrint(allocator, "(bvuge {s} {s})", .{ a, b }));
            },
            .br_if => {
                // The branch leaves the block; the load lives on the fall-through
                // path, guarded by the NEGATION of the branch condition.
                const cond = try pop(&stack);
                const neg = try std.fmt.allocPrint(allocator, "(not {s})", .{cond});
                path_guard = if (path_guard) |g|
                    try std.fmt.allocPrint(allocator, "(and {s} {s})", .{ g, neg })
                else
                    neg;
            },
            .load_i32 => {
                const base = try pop(&stack);
                const eff = if (inst.imm != 0)
                    try std.fmt.allocPrint(allocator, "(bvadd {s} #x{x:0>8})", .{ base, @as(u32, @truncate(inst.imm)) })
                else
                    base;
                found = .{
                    .guard = path_guard orelse "true",
                    .addr = eff,
                    .access_bytes = 4,
                    .memory_bytes = module.memory_bytes,
                    .num_params = f.num_params,
                };
                // The loaded value continues up the stack as a symbolic word.
                try stack.append("loaded_word");
            },
            .block_begin, .block_end, .ret => {},
        }
    }

    return found orelse error.NoMemoryAccess;
}

fn declareParams(w: anytype, n: usize) !void {
    for (0..n) |i| try w.print("(declare-const l{d} (_ BitVec 32))\n", .{i});
}

/// Query A — MEMORY SENSITIVITY (expect SAT): under the load's guard, the
/// loaded word genuinely depends on linear-memory contents at the computed
/// address. Proves the array-theory model is wired and the guarded path is
/// reachable (non-vacuity).
pub fn smtMemorySensitivity(allocator: std.mem.Allocator, a: BoundsAnalysis) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();
    try declareParams(w, a.num_params);
    try w.writeAll(
        \\(declare-const mem1 (Array (_ BitVec 32) (_ BitVec 8)))
        \\(declare-const mem2 (Array (_ BitVec 32) (_ BitVec 8)))
        \\
    );
    try w.print("(define-fun ADDR () (_ BitVec 32) {s})\n", .{a.addr});
    try w.writeAll(
        \\(define-fun LOADW ((m (Array (_ BitVec 32) (_ BitVec 8)))) (_ BitVec 32)
        \\  (concat (select m (bvadd ADDR #x00000003))
        \\          (select m (bvadd ADDR #x00000002))
        \\          (select m (bvadd ADDR #x00000001))
        \\          (select m ADDR)))
        \\
    );
    try w.print("(assert {s})\n", .{a.guard});
    try w.writeAll("(assert (distinct (LOADW mem1) (LOADW mem2)))\n(check-sat)\n");
    return buf.toOwnedSlice();
}

/// Query B — BOUNDS SAFETY (expect UNSAT with guard, SAT without): does the
/// load's guard keep the 4-byte access inside a `len`-element buffer that fits
/// in linear memory? Honest preconditions: the element count's byte size is
/// representable in 32 bits, and the buffer span does not wrap or exceed the
/// declared linear memory.
pub fn smtBoundsSafety(allocator: std.mem.Allocator, a: BoundsAnalysis, with_guard: bool) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();
    try declareParams(w, a.num_params);
    try w.print("(define-fun MEM () (_ BitVec 32) #x{x:0>8})\n", .{@as(u32, @truncate(a.memory_bytes))});
    try w.writeAll(
        \\(define-fun ELEM_BYTES () (_ BitVec 32) (bvshl l2 #x00000002))
        \\(define-fun BUF_END () (_ BitVec 32) (bvadd l0 ELEM_BYTES))
        \\
    );
    try w.print("(define-fun LAST () (_ BitVec 32) (bvadd {s} #x00000003))\n", .{a.addr});
    try w.writeAll(
        \\;; preconditions: element count fits, buffer within linear memory, no wrap
        \\(assert (bvule l2 #x20000000))
        \\(assert (bvule BUF_END MEM))
        \\(assert (bvuge BUF_END l0))
        \\
    );
    if (with_guard) {
        try w.print(";; the guard the bytecode actually enforces:\n(assert {s})\n", .{a.guard});
    } else {
        try w.writeAll(";; guard REMOVED -> expect a counterexample\n");
    }
    try w.writeAll(";; VIOLATION: the 4-byte load escapes the buffer\n(assert (bvuge LAST BUF_END))\n(check-sat)\n");
    return buf.toOwnedSlice();
}
