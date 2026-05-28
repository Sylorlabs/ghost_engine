//! Phase 10 — Provenance Tracker (Spec v3 implementation, honest scope).
//!
//! HONEST DESCRIPTION (read before believing any hype):
//!
//! This is a symbolic executor over a tiny subset of Wasm with one new typed
//! signal added to the abstract stack: a `Provenance` tag that records, per
//! value, whether it descends from an allocator (`dummy_alloc`) result and how.
//! Stores whose address provenance is `alloc{size}` get a bounds obligation
//! emitted to Z3 (`offset + access_bytes <= size`). Stores whose address
//! provenance is `tainted` (e.g. xor-derived) or `none` (untraceable) cause the
//! analyzer to REFUSE: it returns UNANALYZABLE and emits no Z3 query for that
//! site. Z3 remains the sole soundness authority on the queries the analyzer
//! does emit.
//!
//! What this DOES NOT do, by design (Out of Scope):
//!   - Symbolic allocation sizes (alloc arg MUST be an i32.const literal).
//!   - Multiple allocations per function (UNANALYZABLE on second dummy_alloc).
//!   - Loop unroll k > 3 (path explosion; soundness limited to first 3 iters).
//!   - Recovery of dummy_alloc's body (it's an import; there is no body).
//!   - Cross-function call inlining; non-dummy calls produce `none` provenance.
//!
//! Spec v3 rule mapping (search for the R-tag):
//!   R1: Stack carries `Value{ smt, prov }`, not bare strings.
//!   R2: Allocator recognized by IMPORT name `env.dummy_alloc`. We deviated
//!       from the spec's "exported" wording because imports give the
//!       "body never analyzed" contract for free — there IS no body.
//!   R3: Per-opcode propagation rules; see `step()`.
//!   R4: Store hook in `step()` emits SMT obligation OR raises UNANALYZABLE.
//!   R5: Loop unrolling at k=3 in `runLoop()`.
//!   R6: Second dummy_alloc call raises UNANALYZABLE.

const std = @import("std");

const c = @cImport({
    @cInclude("z3.h");
});

pub const Verdict = enum { sat, unsat, unknown, err };

pub const AnalyzerState = enum { analyzes, unanalyzable };

pub const AnalysisResult = struct {
    state: AnalyzerState,
    /// When state == analyzes: the SMT obligation for the store that overflows
    /// (or the strongest single obligation across all unrolled iterations). The
    /// harness sends this to Z3; SAT means an overflow witness exists, UNSAT
    /// means none does.
    smt: ?[]const u8 = null,
    /// When state == unanalyzable: human-readable reason.
    reason: ?[]const u8 = null,
    /// For logging: how many store sites the analyzer emitted obligations for.
    store_sites: usize = 0,
    /// Loop unroll bound actually applied (3 if a loop was present, 0 otherwise).
    unroll_k: usize = 0,
};

// ── Minimal Wasm reader (LEB128) ───────────────────────────────────────────
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
        if (shift < 64 and (b & 0x40) != 0) result |= @as(i64, -1) << @intCast(shift);
        return result;
    }
    fn eof(self: *Reader) bool {
        return self.pos >= self.bytes.len;
    }
};

// ── Wasm opcodes Phase 10 understands ──────────────────────────────────────
const Op = struct {
    const block = 0x02;
    const loop_ = 0x03;
    const br = 0x0c;
    const br_if = 0x0d;
    const end = 0x0b;
    const ret = 0x0f;
    const call = 0x10;
    const drop = 0x1a;
    const local_get = 0x20;
    const local_set = 0x21;
    const local_tee = 0x22;
    const i32_load = 0x28;
    const i32_store = 0x36;
    const i32_store8 = 0x3a;
    const i32_store16 = 0x3b;
    const i32_const = 0x41;
    const i32_eq = 0x46;
    const i32_ne = 0x47;
    const i32_lt_s = 0x48;
    const i32_lt_u = 0x49;
    const i32_gt_s = 0x4a;
    const i32_gt_u = 0x4b;
    const i32_le_s = 0x4c;
    const i32_le_u = 0x4d;
    const i32_ge_s = 0x4e;
    const i32_ge_u = 0x4f;
    const i32_add = 0x6a;
    const i32_sub = 0x6b;
    const i32_mul = 0x6c;
    const i32_and = 0x71;
    const i32_or = 0x72;
    const i32_xor = 0x73;
    const i32_shl = 0x74;
    const i32_shr_s = 0x75;
    const i32_shr_u = 0x76;
};

// ── Provenance tag — Spec v3 R1 ────────────────────────────────────────────
const Provenance = union(enum) {
    none,
    alloc: struct { id: u32, size: u32 },
    tainted,
};

const Value = struct {
    smt: []const u8, // SMT bv32 expression for this value
    prov: Provenance,
};

// ── Parsed module: just what we need for analysis ──────────────────────────
const Signature = struct { nparams: u32, nresults: u32 };
const Import = struct { module: []const u8, name: []const u8, kind: u8, typeidx: u32 };
const Export = struct { name: []const u8, kind: u8, idx: u32 };
const FuncBody = struct {
    /// global function index (imports + user)
    global_idx: u32,
    /// signature copied from the type table for convenience
    sig: Signature,
    /// number of locals (params + declared)
    nlocals: usize,
    /// body bytes (between local-decls and the closing 0x0b)
    body: []const u8,
};

const ParsedModule = struct {
    memory_bytes: u64,
    num_imports: u32,
    /// One Signature per GLOBAL function index (imports first, then user funcs).
    /// signatures.len == num_imports + funcs.len.
    signatures: []Signature,
    imports: []Import,
    exports: []Export,
    funcs: []FuncBody,
};

/// AllocatorConfig — Phase 10.2 pluggable allocator contract (replaces the
/// previously-hardcoded `env.dummy_alloc` literal). The analyzer consults this
/// before running R2 / R3(e). Examples:
///   .{ .name = "dummy_alloc", .kind = .import_, .module = "env", .size_arg_index = 0 }
///   .{ .name = "malloc",      .kind = .export_, .size_arg_index = 0 }
///   .{ .name = "__wbindgen_malloc", .kind = .export_, .size_arg_index = 0 }
///   .{ .name = "aligned_alloc", .kind = .export_, .size_arg_index = 1 }  // align,size
pub const AllocatorKind = enum { import_, export_ };
pub const AllocatorConfig = struct {
    name: []const u8,
    kind: AllocatorKind,
    /// Optional import-module filter; ignored for exports. If null on an
    /// import config, ANY module is accepted (matches purely by name).
    module: ?[]const u8 = null,
    /// Which parameter index (0-based, left-to-right in the function
    /// signature) carries the allocation size. The analyzer requires this
    /// argument at the call site to be an `i32.const` literal.
    size_arg_index: u32 = 0,
};

fn resolveAllocator(m: ParsedModule, cfg: AllocatorConfig) ?u32 {
    switch (cfg.kind) {
        .import_ => {
            for (m.imports, 0..) |imp, i| {
                if (imp.kind != 0) continue; // 0 = function import
                if (cfg.module) |needed| {
                    if (!std.mem.eql(u8, imp.module, needed)) continue;
                }
                if (std.mem.eql(u8, imp.name, cfg.name)) return @intCast(i);
            }
        },
        .export_ => {
            for (m.exports) |exp| {
                if (exp.kind != 0) continue; // 0 = function export
                if (std.mem.eql(u8, exp.name, cfg.name)) return exp.idx;
            }
        },
    }
    return null;
}

fn parseModule(allocator: std.mem.Allocator, bytes: []const u8) !ParsedModule {
    var r = Reader{ .bytes = bytes };
    if (!std.mem.eql(u8, try r.slice(4), "\x00asm")) return error.NotWasm;
    if (!std.mem.eql(u8, try r.slice(4), "\x01\x00\x00\x00")) return error.BadWasmVersion;

    var types_arr = std.ArrayList(Signature).init(allocator);
    var imports = std.ArrayList(Import).init(allocator);
    var func_typeidx = std.ArrayList(u32).init(allocator);
    var exports = std.ArrayList(Export).init(allocator);
    var memory_bytes: u64 = 0;
    var pending_bodies = std.ArrayList(struct { nlocals_extra: usize, body: []const u8 }).init(allocator);

    while (!r.eof()) {
        const id = try r.byte();
        const size = try r.uleb();
        const content = try r.slice(@intCast(size));
        var sr = Reader{ .bytes = content };

        switch (id) {
            1 => { // Type — Phase 10.2: retain (nparams, nresults) per type.
                const n = try sr.uleb();
                for (0..n) |_| {
                    const form = try sr.byte();
                    if (form != 0x60) return error.BadFuncType;
                    const np = try sr.uleb();
                    _ = try sr.slice(@intCast(np)); // param valtypes (i32/i64/f32/f64)
                    const nr = try sr.uleb();
                    _ = try sr.slice(@intCast(nr)); // result valtypes
                    try types_arr.append(.{ .nparams = @intCast(np), .nresults = @intCast(nr) });
                }
            },
            2 => { // Import — keep all; allocator resolution happens via AllocatorConfig.
                const n = try sr.uleb();
                for (0..n) |_| {
                    const ml = try sr.uleb();
                    const mod = try sr.slice(@intCast(ml));
                    const nl = try sr.uleb();
                    const nm = try sr.slice(@intCast(nl));
                    const kind = try sr.byte();
                    var typeidx: u32 = 0;
                    if (kind == 0) typeidx = @intCast(try sr.uleb()) // func import
                    else if (kind == 1) {
                        _ = try sr.byte(); // elemtype
                        const flags = try sr.byte();
                        _ = try sr.uleb();
                        if (flags & 1 != 0) _ = try sr.uleb();
                    } else if (kind == 2) {
                        const flags = try sr.byte();
                        _ = try sr.uleb();
                        if (flags & 1 != 0) _ = try sr.uleb();
                    } else if (kind == 3) {
                        _ = try sr.byte();
                        _ = try sr.byte();
                    }
                    try imports.append(.{ .module = mod, .name = nm, .kind = kind, .typeidx = typeidx });
                }
            },
            3 => { // Function — typeidx per user function.
                const n = try sr.uleb();
                for (0..n) |_| try func_typeidx.append(@intCast(try sr.uleb()));
            },
            5 => { // Memory
                const n = try sr.uleb();
                if (n >= 1) {
                    const flags = try sr.byte();
                    const min = try sr.uleb();
                    if (flags & 0x01 != 0) _ = try sr.uleb();
                    memory_bytes = min * 65536;
                }
            },
            7 => { // Export — Phase 10.2: needed for export-kind allocator configs.
                const n = try sr.uleb();
                for (0..n) |_| {
                    const nl = try sr.uleb();
                    const nm = try sr.slice(@intCast(nl));
                    const kind = try sr.byte();
                    const idx: u32 = @intCast(try sr.uleb());
                    try exports.append(.{ .name = nm, .kind = kind, .idx = idx });
                }
            },
            10 => { // Code — store body + extra-locals; nparams comes from sig later.
                const n = try sr.uleb();
                for (0..n) |_| {
                    const bsize = try sr.uleb();
                    const body = try sr.slice(@intCast(bsize));
                    var br_ = Reader{ .bytes = body };
                    const decl_groups = try br_.uleb();
                    var extra_locals: usize = 0;
                    for (0..decl_groups) |_| {
                        const cnt = try br_.uleb();
                        _ = try br_.byte();
                        extra_locals += @intCast(cnt);
                    }
                    const inst_bytes = body[br_.pos..];
                    try pending_bodies.append(.{ .nlocals_extra = extra_locals, .body = inst_bytes });
                }
            },
            else => {}, // Global/Element/Data/Start/Custom — not needed yet.
        }
    }

    // Build the unified global signature table: imports first, then user funcs.
    var signatures = try allocator.alloc(Signature, imports.items.len + func_typeidx.items.len);
    for (imports.items, 0..) |imp, i| {
        if (imp.kind != 0) {
            // Non-function imports have no signature; mark as 0/0 (never called).
            signatures[i] = .{ .nparams = 0, .nresults = 0 };
            continue;
        }
        if (imp.typeidx >= types_arr.items.len) return error.BadImportTypeRef;
        signatures[i] = types_arr.items[imp.typeidx];
    }
    var funcs = try allocator.alloc(FuncBody, func_typeidx.items.len);
    if (func_typeidx.items.len != pending_bodies.items.len) return error.FuncBodyCountMismatch;
    for (func_typeidx.items, 0..) |tidx, i| {
        if (tidx >= types_arr.items.len) return error.BadFuncTypeRef;
        const sig = types_arr.items[tidx];
        const gidx: u32 = @intCast(imports.items.len + i);
        signatures[gidx] = sig;
        funcs[i] = .{
            .global_idx = gidx,
            .sig = sig,
            .nlocals = sig.nparams + pending_bodies.items[i].nlocals_extra,
            .body = pending_bodies.items[i].body,
        };
    }

    return ParsedModule{
        .memory_bytes = memory_bytes,
        .num_imports = @intCast(imports.items.len),
        .signatures = signatures,
        .imports = try imports.toOwnedSlice(),
        .exports = try exports.toOwnedSlice(),
        .funcs = funcs,
    };
}

// ── Symbolic-execution state ───────────────────────────────────────────────
const Stack = std.ArrayList(Value);

const Analyzer = struct {
    allocator: std.mem.Allocator,
    /// SMT obligations accumulated, one per analyzed store site.
    obligations: std.ArrayList([]const u8),
    /// Locals are nullable to detect read-uninit.
    locals: []?Value,
    /// Number of alloc calls seen — R6 enforces <=1.
    alloc_count: u32 = 0,
    /// Symbolic constants the harness will declare (e.g. alloc base, seed).
    declarations: std.ArrayList([]const u8),
    /// Set when an UNANALYZABLE condition fires.
    unanalyzable: ?[]const u8 = null,
    /// Track stores emitted (for logging).
    store_sites: usize = 0,
    /// Whether at least one loop was unrolled (for logging).
    saw_loop: bool = false,
    // Phase 10.2 ── plumbed through for type-table-driven call dispatch.
    /// Per global function index: (nparams, nresults).
    signatures: []const Signature,
    /// Resolved allocator function index (null = no allocator in module).
    allocator_func_idx: ?u32,
    /// Which arg position the allocator's `size` lives at (from AllocatorConfig).
    allocator_size_arg_index: u32 = 0,

    fn pop(self: *Analyzer, stack: *Stack) !Value {
        _ = self;
        return stack.pop() orelse error.StackUnderflow;
    }

    fn freshAllocBase(self: *Analyzer, id: u32) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "alloc_base_{d}", .{id});
        const decl = try std.fmt.allocPrint(self.allocator, "(declare-const {s} (_ BitVec 32))", .{name});
        try self.declarations.append(decl);
        return name;
    }

    fn freshOpaque(self: *Analyzer, label: []const u8) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ label, self.declarations.items.len });
        const decl = try std.fmt.allocPrint(self.allocator, "(declare-const {s} (_ BitVec 32))", .{name});
        try self.declarations.append(decl);
        return name;
    }
};

// ── Per-opcode propagation (Spec v3 R3) ────────────────────────────────────
fn provBinary(op: u8, a: Provenance, b: Provenance) Provenance {
    // R3(c): xor / div / rem / rotl / rotr taint any non-none operand.
    if (op == Op.i32_xor) {
        const a_non = !std.meta.eql(a, Provenance{ .none = {} });
        const b_non = !std.meta.eql(b, Provenance{ .none = {} });
        if (a_non or b_non) return .tainted;
        return .none;
    }
    // R3(b): add/sub/mul/or/and/shl/shr_* — one alloc + one none inherits alloc.
    const a_alloc = a == .alloc;
    const b_alloc = b == .alloc;
    const a_taint = a == .tainted;
    const b_taint = b == .tainted;
    if (a_taint or b_taint) return .tainted;
    if (a_alloc and b_alloc) return .tainted; // two allocs in arithmetic = ambiguous
    if (a_alloc) return a;
    if (b_alloc) return b;
    return .none;
}

// ── Symbolic exec of a flat instruction block (no loop back-edges). ────────
/// Returns the SMT bool expression for "did the block fall through" path
/// guard (accumulated negations of br_if conditions), and updates `locals`
/// + `obligations`. A `br` / `br_if 1+` ends the block early.
fn execBlock(
    self: *Analyzer,
    body: []const u8,
    locals: []?Value,
    allocator_func_idx: ?u32,
    enclosing_guard: ?[]const u8,
    in_loop: bool,
) !void {
    var r = Reader{ .bytes = body };
    var stack = Stack.init(self.allocator);
    defer stack.deinit();
    var guard: ?[]const u8 = enclosing_guard;

    while (!r.eof()) {
        if (self.unanalyzable != null) return;
        const op = try r.byte();
        switch (op) {
            Op.i32_const => {
                const v = try r.sleb();
                const s = try std.fmt.allocPrint(self.allocator, "(_ bv{d} 32)", .{@as(u32, @truncate(@as(u64, @bitCast(v))))});
                try stack.append(.{ .smt = s, .prov = .none });
            },
            Op.local_get => {
                const idx = try r.uleb();
                if (idx >= locals.len) return error.LocalOOB;
                const v = locals[idx] orelse {
                    // Read of uninit local — treat as opaque param.
                    const sym = try self.freshOpaque("l");
                    const v2 = Value{ .smt = sym, .prov = .none };
                    locals[idx] = v2;
                    try stack.append(v2);
                    continue;
                };
                try stack.append(v);
            },
            Op.local_set => {
                const idx = try r.uleb();
                if (idx >= locals.len) return error.LocalOOB;
                locals[idx] = try self.pop(&stack);
            },
            Op.local_tee => {
                const idx = try r.uleb();
                if (idx >= locals.len) return error.LocalOOB;
                const v = try self.pop(&stack);
                locals[idx] = v;
                try stack.append(v);
            },
            Op.drop => _ = try self.pop(&stack),
            Op.i32_add, Op.i32_sub, Op.i32_mul, Op.i32_and, Op.i32_or, Op.i32_xor, Op.i32_shl, Op.i32_shr_s, Op.i32_shr_u => {
                const b = try self.pop(&stack);
                const a = try self.pop(&stack);
                const smt_op = switch (op) {
                    Op.i32_add => "bvadd",
                    Op.i32_sub => "bvsub",
                    Op.i32_mul => "bvmul",
                    Op.i32_and => "bvand",
                    Op.i32_or => "bvor",
                    Op.i32_xor => "bvxor",
                    Op.i32_shl => "bvshl",
                    Op.i32_shr_s => "bvashr",
                    Op.i32_shr_u => "bvlshr",
                    else => unreachable,
                };
                const s = try std.fmt.allocPrint(self.allocator, "({s} {s} {s})", .{ smt_op, a.smt, b.smt });
                try stack.append(.{ .smt = s, .prov = provBinary(op, a.prov, b.prov) });
            },
            Op.i32_eq, Op.i32_ne, Op.i32_lt_s, Op.i32_lt_u, Op.i32_gt_s, Op.i32_gt_u, Op.i32_le_s, Op.i32_le_u, Op.i32_ge_s, Op.i32_ge_u => {
                const b = try self.pop(&stack);
                const a = try self.pop(&stack);
                const cmp = switch (op) {
                    Op.i32_eq => "=",
                    Op.i32_ne => "distinct",
                    Op.i32_lt_s => "bvslt",
                    Op.i32_lt_u => "bvult",
                    Op.i32_gt_s => "bvsgt",
                    Op.i32_gt_u => "bvugt",
                    Op.i32_le_s => "bvsle",
                    Op.i32_le_u => "bvule",
                    Op.i32_ge_s => "bvsge",
                    Op.i32_ge_u => "bvuge",
                    else => unreachable,
                };
                // Comparison result is a Bool we coerce to bv32 {0,1}.
                const s = try std.fmt.allocPrint(self.allocator, "(ite ({s} {s} {s}) (_ bv1 32) (_ bv0 32))", .{ cmp, a.smt, b.smt });
                try stack.append(.{ .smt = s, .prov = .none });
            },
            Op.call => {
                const idx = try r.uleb();
                // Phase 10.2 — type-table-driven dispatch (Blocker #2 fix).
                if (idx >= self.signatures.len) {
                    self.unanalyzable = "call index out of range of signature table";
                    return;
                }
                const sig = self.signatures[idx];

                // Pop exactly `nparams` values. Wasm pushes args left-to-right,
                // so the topmost stack entry is the LAST (rightmost) param.
                // We reverse after popping so args[0] == first param.
                var args = try self.allocator.alloc(Value, sig.nparams);
                var i: usize = sig.nparams;
                while (i > 0) : (i -= 1) {
                    args[i - 1] = try self.pop(&stack);
                }

                // R2 / R3(e) / R6 — allocator dispatch via AllocatorConfig.
                if (allocator_func_idx) |afi| {
                    if (idx == afi) {
                        if (self.allocator_size_arg_index >= sig.nparams) {
                            self.unanalyzable = "AllocatorConfig.size_arg_index out of range for this allocator's signature";
                            return;
                        }
                        const size_arg = args[self.allocator_size_arg_index];
                        const size = parseLiteralBv32(size_arg.smt) orelse {
                            self.unanalyzable = "allocator size argument is not an i32.const literal";
                            return;
                        };
                        if (self.alloc_count >= 1) {
                            self.unanalyzable = "multiple allocator calls in one function (R6)";
                            return;
                        }
                        const id = self.alloc_count;
                        self.alloc_count += 1;
                        const base_sym = try self.freshAllocBase(id);
                        // Push the allocator's nresults — typically 1 (the buf
                        // pointer). The first result is alloc-provenanced; any
                        // additional results are pushed as opaque `none`.
                        if (sig.nresults >= 1) {
                            try stack.append(.{ .smt = base_sym, .prov = .{ .alloc = .{ .id = id, .size = size } } });
                            var k: u32 = 1;
                            while (k < sig.nresults) : (k += 1) {
                                const extra = try self.freshOpaque("alloc_extra_ret");
                                try stack.append(.{ .smt = extra, .prov = .none });
                            }
                        }
                        continue;
                    }
                }
                // R3(f) — non-allocator call: push exactly `nresults` opaques.
                var k: u32 = 0;
                while (k < sig.nresults) : (k += 1) {
                    const sym = try self.freshOpaque("call_ret");
                    try stack.append(.{ .smt = sym, .prov = .none });
                }
            },
            Op.i32_load => {
                _ = try r.uleb(); // align
                _ = try r.uleb(); // offset
                _ = try self.pop(&stack); // addr (ignored for spike; loads not the focus)
                const sym = try self.freshOpaque("loaded");
                try stack.append(.{ .smt = sym, .prov = .none });
            },
            Op.i32_store, Op.i32_store8, Op.i32_store16 => {
                _ = try r.uleb(); // align
                const off = try r.uleb();
                _ = try self.pop(&stack); // stored value
                const addr = try self.pop(&stack);
                const width: u32 = switch (op) {
                    Op.i32_store => 4,
                    Op.i32_store8 => 1,
                    Op.i32_store16 => 2,
                    else => unreachable,
                };
                // R4: dispatch on provenance.
                switch (addr.prov) {
                    .none => {
                        self.unanalyzable = "store with untraceable provenance";
                        return;
                    },
                    .tainted => {
                        self.unanalyzable = "store with tainted-provenance address";
                        return;
                    },
                    .alloc => |al| {
                        // Effective byte address = addr.smt + memarg.offset.
                        // Offset within buffer = (effective - alloc_base).
                        // Obligation: offset + width <= size.
                        const eff = try std.fmt.allocPrint(
                            self.allocator,
                            "(bvadd {s} (_ bv{d} 32))",
                            .{ addr.smt, off },
                        );
                        const offset_in_buf = try std.fmt.allocPrint(
                            self.allocator,
                            "(bvsub {s} alloc_base_{d})",
                            .{ eff, al.id },
                        );
                        // Violation predicate: offset + width > size.
                        const viol = try std.fmt.allocPrint(
                            self.allocator,
                            "(bvugt (bvadd {s} (_ bv{d} 32)) (_ bv{d} 32))",
                            .{ offset_in_buf, width, al.size },
                        );
                        // Wrap in path guard if present.
                        const oblig = if (guard) |g|
                            try std.fmt.allocPrint(self.allocator, "(and {s} {s})", .{ g, viol })
                        else
                            viol;
                        try self.obligations.append(oblig);
                        self.store_sites += 1;
                    },
                }
            },
            Op.block => {
                _ = try r.byte(); // blocktype (assume void 0x40 for fixtures)
                // Recurse into the block. The block ends at matching 0x0b.
                const sub_body = try sliceBlock(body, r.pos);
                try execBlock(self, sub_body, locals, allocator_func_idx, guard, in_loop);
                r.pos += sub_body.len + 1; // +1 for the 0x0b end byte
            },
            Op.loop_ => {
                _ = try r.byte(); // blocktype
                const sub_body = try sliceBlock(body, r.pos);
                self.saw_loop = true;
                // R5: unroll the loop body up to k=3 times.
                try runLoop(self, sub_body, locals, allocator_func_idx, guard);
                r.pos += sub_body.len + 1;
            },
            Op.br => {
                _ = try r.uleb();
                // Unconditional branch out of any nesting — terminate this block.
                return;
            },
            Op.br_if => {
                const label = try r.uleb();
                const cond = try self.pop(&stack);
                _ = label;
                // For the spike: any br_if escapes the loop iteration. We
                // accumulate (cond == 0) as the fall-through guard.
                const neg = try std.fmt.allocPrint(
                    self.allocator,
                    "(= {s} (_ bv0 32))",
                    .{cond.smt},
                );
                guard = if (guard) |g|
                    try std.fmt.allocPrint(self.allocator, "(and {s} {s})", .{ g, neg })
                else
                    neg;
            },
            Op.end => return,
            Op.ret => return,
            else => {
                self.unanalyzable = "unsupported opcode";
                return;
            },
        }
    }
}

/// R5 — unroll a loop body at most `k=3` times, threading symbolic state.
fn runLoop(
    self: *Analyzer,
    body: []const u8,
    locals: []?Value,
    allocator_func_idx: ?u32,
    enclosing_guard: ?[]const u8,
) anyerror!void {
    const K: usize = 3;
    var iter: usize = 0;
    while (iter < K) : (iter += 1) {
        if (self.unanalyzable != null) return;
        try execBlock(self, body, locals, allocator_func_idx, enclosing_guard, true);
    }
}

/// Given a `block`/`loop` body starting at `body[start]`, return the slice up
/// to the matching `end` (0x0b) byte, NOT including that byte.
fn sliceBlock(body: []const u8, start: usize) ![]const u8 {
    var depth: usize = 1;
    var r = Reader{ .bytes = body[start..] };
    while (!r.eof()) {
        const op = try r.byte();
        switch (op) {
            Op.block, Op.loop_ => {
                _ = try r.byte(); // blocktype
                depth += 1;
            },
            Op.end => {
                depth -= 1;
                if (depth == 0) return body[start .. start + r.pos - 1];
            },
            Op.i32_const => _ = try r.sleb(),
            Op.local_get, Op.local_set, Op.local_tee, Op.call, Op.br, Op.br_if => _ = try r.uleb(),
            Op.i32_load, Op.i32_store, Op.i32_store8, Op.i32_store16 => {
                _ = try r.uleb();
                _ = try r.uleb();
            },
            else => {},
        }
    }
    return error.UnterminatedBlock;
}

/// Parse "(_ bvK 32)" back to K, or return null.
fn parseLiteralBv32(s: []const u8) ?u32 {
    const prefix = "(_ bv";
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    const rest = s[prefix.len..];
    var i: usize = 0;
    while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') i += 1;
    const num = rest[0..i];
    return std.fmt.parseInt(u32, num, 10) catch null;
}

// ── Public analyze entry point ─────────────────────────────────────────────
/// Phase 10.2: `cfg` replaces the previously-hardcoded allocator literal. The
/// analyzer resolves the configured allocator inside the parsed module and
/// refuses (UNANALYZABLE / MissingAllocatorContract) if it isn't found.
pub fn analyze(
    allocator: std.mem.Allocator,
    wasm_bytes: []const u8,
    cfg: AllocatorConfig,
) !AnalysisResult {
    const m = try parseModule(allocator, wasm_bytes);
    const allocator_func_idx = resolveAllocator(m, cfg);
    if (allocator_func_idx == null) {
        const kind_word = switch (cfg.kind) {
            .import_ => "import",
            .export_ => "export",
        };
        const reason = try std.fmt.allocPrint(
            allocator,
            "MissingAllocatorContract: no {s} named '{s}' found (module filter: {s})",
            .{ kind_word, cfg.name, cfg.module orelse "<any>" },
        );
        return AnalysisResult{ .state = .unanalyzable, .reason = reason };
    }
    if (m.funcs.len == 0) {
        return AnalysisResult{ .state = .unanalyzable, .reason = "no user functions to analyze" };
    }

    const f = m.funcs[0];
    const locals = try allocator.alloc(?Value, @max(f.nlocals, 8));
    for (locals) |*l| l.* = null;

    var analyzer = Analyzer{
        .allocator = allocator,
        .obligations = std.ArrayList([]const u8).init(allocator),
        .locals = locals,
        .declarations = std.ArrayList([]const u8).init(allocator),
        .signatures = m.signatures,
        .allocator_func_idx = allocator_func_idx,
        .allocator_size_arg_index = cfg.size_arg_index,
    };

    try execBlock(&analyzer, f.body, locals, allocator_func_idx, null, false);

    if (analyzer.unanalyzable) |reason| {
        return AnalysisResult{
            .state = .unanalyzable,
            .reason = reason,
            .store_sites = analyzer.store_sites,
            .unroll_k = if (analyzer.saw_loop) 3 else 0,
        };
    }

    if (analyzer.obligations.items.len == 0) {
        return AnalysisResult{
            .state = .unanalyzable,
            .reason = "no analyzable store sites found",
            .store_sites = 0,
        };
    }

    // Build a single SMT query: declare bases/opaques, assert disjunction of
    // per-site violations. SAT iff ANY store overflows on ANY iteration.
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();
    for (analyzer.declarations.items) |d| {
        try w.print("{s}\n", .{d});
    }
    if (analyzer.obligations.items.len == 1) {
        try w.print("(assert {s})\n", .{analyzer.obligations.items[0]});
    } else {
        try w.writeAll("(assert (or");
        for (analyzer.obligations.items) |o| try w.print(" {s}", .{o});
        try w.writeAll("))\n");
    }
    try w.writeAll("(check-sat)\n");

    return AnalysisResult{
        .state = .analyzes,
        .smt = try buf.toOwnedSlice(),
        .store_sites = analyzer.store_sites,
        .unroll_k = if (analyzer.saw_loop) 3 else 0,
    };
}

// ── Z3 driver ──────────────────────────────────────────────────────────────
fn z3SilentErrorHandler(_: c.Z3_context, _: c.Z3_error_code) callconv(.C) void {}

pub fn runZ3(allocator: std.mem.Allocator, smt_text: []const u8) Verdict {
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

pub fn verdictWord(v: Verdict) []const u8 {
    return switch (v) {
        .sat => "SAT",
        .unsat => "UNSAT",
        .unknown => "UNKNOWN",
        .err => "ERR",
    };
}
