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

/// Phase 11.0a — per-store witness for the Weaver. Populated only for stores
/// whose address expression at execution time is `local.get K` or
/// `local.get K (+ i32.const M, i32.add)*`. Other shapes (shl, mul, call
/// results, opaques) do NOT emit a witness — analysis still proceeds (the
/// store contributes its obligation to the combined SMT query), but
/// `phase11_weaver` refuses to repair witnessless stores. This is the
/// "no guessing at Wasm-level expressions" rule that mirrors the existing
/// poison-pill philosophy.
pub const StoreWitness = struct {
    /// Index into ParsedModule.funcs (user-function index, NOT the global
    /// function index that prepends imports). Phase 10 analyzes only func[0];
    /// the field exists for symmetry with future multi-function support.
    func_idx: u32,
    /// Byte offset of the i32.store{,8,16} OPCODE within the function body
    /// (i.e. relative to FuncBody.body[0], not to the .wasm file start).
    /// The Weaver splices guard bytes immediately before this offset.
    body_offset_of_store: usize,
    /// Local index whose value carries the address (or its alloc-base).
    addr_local: u32,
    /// Literal byte offset added to `addr_local`'s value via i32.const+i32.add
    /// chains. Zero when the address is exactly `local.get K`.
    addr_const_offset: u32,
    /// Access width in bytes: 4/2/1 for i32.store / i32.store16 / i32.store8.
    /// The Weaver folds this into the guard so partial-overflow stores
    /// (`addr_const_offset + width > alloc_size`) still trap.
    width: u32,
    /// Allocation size in bytes recorded at the source allocator call. The
    /// guard compares (addr_local + addr_const_offset + width) against this.
    alloc_size: u32,
};

/// Block-termination signal — Phase 11.0b ("Defect 4" fix). `execBlock`
/// returns this so the `if`/`end` handler can decide whether the fall-through
/// guard should be tightened by `¬cond`. Without this signal the analyzer
/// would not learn that a post-guard `i32.store` is conditioned on the guard
/// being false, and a correctly repaired binary would re-analyze as SAT.
pub const BlockTermination = enum {
    /// Block reached its closing `end` (or fell off the end of the slice).
    fallthrough,
    /// Block hit `unreachable`. No path beyond this point in this block.
    trapped,
    /// Block hit `br N`, `br_table`, or `ret`. Control left the block.
    branched_out,
};

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
    /// Phase 11.0a — per-store witnesses for the Weaver. Length equals the
    /// number of stores whose address shape was Weaver-extractable, which may
    /// be LESS than `store_sites` if some stores have unanalyzable address
    /// expressions (shl, call-result-rooted, etc.).
    witnesses: []const StoreWitness = &[_]StoreWitness{},
    /// Phase 11.0a — per-witness self-contained Z3-ready SMT queries
    /// (declarations + single `(assert ...)` + `(check-sat)`). Same length and
    /// indexing as `witnesses`. The end-to-end Weaver harness runs Z3 on each
    /// individually so it knows WHICH store the SAT verdict justifies
    /// repairing — the combined `smt` field's disjunction cannot answer that.
    per_witness_smts: []const []const u8 = &[_][]const u8{},
    /// Phase 11.0 — the resolved allocator's GLOBAL function index
    /// (imports first, then user funcs) when state == .analyzes. Lets the
    /// downstream Wasm rewriter scan the body for the matching `call`
    /// without re-parsing the module. Null when state == .unanalyzable.
    allocator_func_idx: ?u32 = null,
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
// Phase 10.3 (MVP Vocabulary): expanded from the original ~30-opcode subset
// to cover the integer half of the Wasm MVP — control flow, globals, memory
// metadata, i32 sign-extensions, drop/select. Float and i64 opcodes are
// intentionally NOT listed here as named constants; instead they're routed
// through poison-pill range checks (see isFloatOpcode / isI64Opcode below)
// so that any one of dozens of opcodes triggers a clean UNANALYZABLE without
// us having to name each one.
const Op = struct {
    const unreachable_ = 0x00;
    const nop = 0x01;
    const block = 0x02;
    const loop_ = 0x03;
    const if_ = 0x04;
    const else_ = 0x05;
    const end = 0x0b;
    const br = 0x0c;
    const br_if = 0x0d;
    const br_table = 0x0e;
    const ret = 0x0f;
    const call = 0x10;
    const call_indirect = 0x11;
    const drop = 0x1a;
    const select = 0x1b;
    const local_get = 0x20;
    const local_set = 0x21;
    const local_tee = 0x22;
    const global_get = 0x23;
    const global_set = 0x24;
    const i32_load = 0x28;
    const memory_size = 0x3f;
    const memory_grow = 0x40;
    const i32_store = 0x36;
    const i32_store8 = 0x3a;
    const i32_store16 = 0x3b;
    const i32_const = 0x41;
    const i64_const = 0x42; // i64 poison pill (parser must still skip the SLEB)
    const f32_const = 0x43; // float poison pill (parser must still skip 4 bytes)
    const f64_const = 0x44; // float poison pill (parser must still skip 8 bytes)
    const i32_eqz = 0x45;
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
    const i32_div_s = 0x6d;
    const i32_div_u = 0x6e;
    const i32_rem_s = 0x6f;
    const i32_rem_u = 0x70;
    const i32_and = 0x71;
    const i32_or = 0x72;
    const i32_xor = 0x73;
    const i32_shl = 0x74;
    const i32_shr_s = 0x75;
    const i32_shr_u = 0x76;
    const i32_rotl = 0x77;
    const i32_rotr = 0x78;
    const i32_extend8_s = 0xc0;
    const i32_extend16_s = 0xc1;
};

/// Float opcodes — Phase 3 of the directive demands a Poison Pill rather than
/// SMT lowering (real-typed Z3 is exponential and seldom decisive). We map any
/// f32/f64 opcode (loads/stores/const/arith/cmp/conv) to UNANALYZABLE with
/// reason `FloatTheoryUnsupported`. The ranges below are the Wasm MVP layout.
fn isFloatOpcode(op: u8) bool {
    return op == 0x2a or op == 0x2b // f32.load, f64.load
        or op == 0x38 or op == 0x39 // f32.store, f64.store
        or op == 0x43 or op == 0x44 // f32.const, f64.const
        or (op >= 0x5b and op <= 0x66) // f32/f64 comparisons
        or (op >= 0x8b and op <= 0xa6) // f32/f64 unary + binary arith
        or op == 0xb2 or op == 0xb3 or op == 0xb4 or op == 0xb5 // i32 <-> f32/f64
        or op == 0xb6 or op == 0xb7 or op == 0xb8 or op == 0xb9 // i64 <-> f32/f64
        or op == 0xba or op == 0xbb // f32 <-> f64
        or op == 0xbc or op == 0xbd or op == 0xbe; // reinterpret (treat as float)
}

/// i64 opcodes — by symmetric argument: our SMT lowering is (_ BitVec 32)
/// throughout. Treating i64 ops as i32 would silently truncate. The honest
/// move is the same Poison Pill: any i64 opcode aborts with `I64TheoryUnsupported`.
/// This is a Phase 10.3 deviation from the directive's wording ("INTEGER ONLY")
/// in favor of soundness — see project memory.
fn isI64Opcode(op: u8) bool {
    return op == 0x29 // i64.load
        or (op >= 0x30 and op <= 0x35) // i64 load variants
        or op == 0x37 // i64.store
        or (op >= 0x3c and op <= 0x3e) // i64 store variants
        or op == 0x42 // i64.const
        or op == 0x50 // i64.eqz
        or (op >= 0x51 and op <= 0x5a) // i64 comparisons
        or (op >= 0x7c and op <= 0x8a) // i64 arith
        or op == 0xa7 // i32.wrap_i64
        or op == 0xac or op == 0xad // i64.extend_i32_s/u
        or (op >= 0xc2 and op <= 0xc4); // i64.extend8/16/32_s
}

// ── Provenance tag — Spec v3 R1 ────────────────────────────────────────────
const Provenance = union(enum) {
    none,
    alloc: struct { id: u32, size: u32 },
    tainted,
};

/// Wasm-level origin of a stack Value — Phase 11.0a.
///
/// This is ORTHOGONAL to `Provenance` (which tracks symbolic alloc-base
/// lineage for the SMT solver). `Origin` tracks the SYNTACTIC SHAPE of the
/// Wasm bytecode that produced the value, restricted to the narrow grammar
///
///     E ::= local.get K   |   E + i32.const M
///
/// that the Phase 11 Weaver can replay verbatim ahead of a store. Anything
/// outside this grammar (shifts, multiplies, call results, loads, opaques,
/// arithmetic with two non-const operands) collapses to `.unknown` — the
/// Weaver then refuses to synthesize a guard for that store. This is the
/// "do not guess at Wasm-level address expressions" rule the user selected.
const Origin = union(enum) {
    /// Origin not in the supported grammar. The Weaver will not repair stores
    /// whose address Value carries this origin.
    unknown,
    /// Pushed by `local.get K` (or `local.tee K`).
    local_get: u32,
    /// Pushed by `i32.const C`. Tracked because the i32.add propagator needs
    /// to recognize `local + const` and `const + local` shapes.
    const_: u32,
    /// Pushed by a `local.get K [i32.const M i32.add]+` chain. `off` is the
    /// accumulated constant — repeated `+ i32.const M2` folds into M + M2 at
    /// origin-propagation time, never at the SMT level.
    local_plus_const: struct { local: u32, off: u32 },
};

const Value = struct {
    smt: []const u8, // SMT bv32 expression for this value
    prov: Provenance,
    /// Phase 11.0a — Wasm-level origin for Weaver replay. `.unknown` is the
    /// safe default; only `local.get`, `local.tee`, `i32.const`, and a
    /// `local + const` shape of `i32.add` propagate anything else.
    wasm_origin: Origin = .unknown,
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

/// Phase 10.3 — global state. We record only mutability (the valtype is
/// always i32 in our analyzable subset; i64/float globals trigger the
/// poison pill at first use). The init expression is intentionally NOT
/// evaluated symbolically: each global starts as an opaque symbolic `none`-
/// provenance value on first read.
const Global = struct {
    valtype: u8, // 0x7f i32, 0x7e i64, 0x7d f32, 0x7c f64
    mut: bool,
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
    /// Phase 10.3: globals declared in Section 6 (plus imported globals from
    /// Section 2 prepended, since global indices in code refer to the unified
    /// import-then-defined namespace, same as functions).
    globals: []Global,
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
    var globals_list = std.ArrayList(Global).init(allocator);
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
                    } else if (kind == 3) { // imported global
                        const valtype = try sr.byte();
                        const mut = try sr.byte();
                        // Imported globals occupy the low end of the global
                        // index space; record so code-section global.get/set
                        // indices line up with our globals[] array.
                        try globals_list.append(.{ .valtype = valtype, .mut = mut != 0 });
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
            6 => { // Global — Phase 10.3. Each global = (valtype, mut, init-expr).
                // We skip the init-expr (terminated by 0x0b) without evaluating
                // it; at run-time we present each global as a fresh symbolic
                // opaque on first read. This is honest underapproximation: a
                // constant-init global is treated as a free i32 variable.
                const n = try sr.uleb();
                for (0..n) |_| {
                    const valtype = try sr.byte();
                    const mut = try sr.byte();
                    try globals_list.append(.{ .valtype = valtype, .mut = mut != 0 });
                    // Skip init expression: read opcodes until 0x0b. For our
                    // purposes init exprs are usually `i32.const N; end`.
                    while (true) {
                        const ib = try sr.byte();
                        if (ib == 0x0b) break;
                        if (ib == 0x41) { // i32.const sleb
                            _ = try sr.sleb();
                        } else if (ib == 0x42) { // i64.const sleb
                            _ = try sr.sleb();
                        } else if (ib == 0x43) { // f32.const 4 raw bytes
                            _ = try sr.slice(4);
                        } else if (ib == 0x44) { // f64.const 8 raw bytes
                            _ = try sr.slice(8);
                        } else if (ib == 0x23) { // global.get
                            _ = try sr.uleb();
                        }
                        // Other init opcodes (rare) — ignore; the 0x0b terminator
                        // will arrive.
                    }
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
        .globals = try globals_list.toOwnedSlice(),
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
    // Phase 10.3 ── global state. Each entry is lazily filled with a fresh
    // opaque on first read; metadata for type/mut comes from `globals_meta`.
    globals: []?Value,
    globals_meta: []const Global,
    // Phase 11.0a ── Weaver support.
    /// The OUTER function body. `execBlock` is called recursively with sub-
    /// slices for nested blocks; pointer arithmetic against this base gives
    /// the absolute body-offset of each i32.store opcode, which the Weaver
    /// needs to know exactly where to splice guard bytes.
    body_base: []const u8 = &[_]u8{},
    /// User-function index being analyzed. Phase 10 only analyzes funcs[0],
    /// so this is always 0; carried as a field so the witness records what
    /// it was rather than implicitly assuming.
    user_func_idx: u32 = 0,
    /// Per-store witnesses for the Weaver. Only stores with a Weaver-shaped
    /// address Value get an entry here; witnessless stores still contribute
    /// an obligation to `obligations`.
    witnesses: std.ArrayList(StoreWitness),
    /// Per-witness self-contained SMT obligation TEXT (without declarations,
    /// without the (assert) wrapper, without check-sat). `analyze()` wraps
    /// each into a full query at result-build time. Same indexing as
    /// `witnesses` — parallel arrays so we can route Z3 SAT verdicts back
    /// to the specific store that justified them.
    per_witness_obligations: std.ArrayList([]const u8),

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

// ── Phase 11.0a — Wasm origin propagation for i32.add ──────────────────────
/// Returns the origin of `a + b` when both are i32 values. Recognized shapes:
///   local + const                  → local_plus_const{local, off=const}
///   const + local                  → local_plus_const{local, off=const}
///   local_plus_const + const       → local_plus_const{local, off += const}
///   const + local_plus_const       → local_plus_const{local, off += const}
/// Every other combination is `.unknown`. Wrapping on `off` is treated as
/// catastrophic (we collapse to `.unknown` rather than mask) — a 32-bit
/// overflow on the constant accumulator means the source program is doing
/// something the Weaver should not be trusted to model.
fn addOrigin(a: Origin, b: Origin) Origin {
    switch (a) {
        .local_get => |la| switch (b) {
            .const_ => |cb| return .{ .local_plus_const = .{ .local = la, .off = cb } },
            else => return .unknown,
        },
        .const_ => |ca| switch (b) {
            .local_get => |lb| return .{ .local_plus_const = .{ .local = lb, .off = ca } },
            .local_plus_const => |bp| {
                const sum = @addWithOverflow(bp.off, ca);
                if (sum[1] != 0) return .unknown;
                return .{ .local_plus_const = .{ .local = bp.local, .off = sum[0] } };
            },
            else => return .unknown,
        },
        .local_plus_const => |ap| switch (b) {
            .const_ => |cb| {
                const sum = @addWithOverflow(ap.off, cb);
                if (sum[1] != 0) return .unknown;
                return .{ .local_plus_const = .{ .local = ap.local, .off = sum[0] } };
            },
            else => return .unknown,
        },
        .unknown => return .unknown,
    }
}

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
/// Symbolically executes a block body. Returns a `BlockTermination` that the
/// caller uses to decide whether downstream code in the enclosing block is
/// reachable from this branch — Phase 11.0b ("Defect 4" fix) needs this so
/// that `if (cond) unreachable end` patches actually tighten the fall-through
/// path guard by `¬cond`, otherwise the verification loop returns SAT on
/// correctly-repaired binaries.
fn execBlock(
    self: *Analyzer,
    body: []const u8,
    locals: []?Value,
    allocator_func_idx: ?u32,
    enclosing_guard: ?[]const u8,
    in_loop: bool,
) anyerror!BlockTermination {
    var r = Reader{ .bytes = body };
    var stack = Stack.init(self.allocator);
    defer stack.deinit();
    var guard: ?[]const u8 = enclosing_guard;
    // Phase 11.0a — base offset of `body` within the outer function body.
    // Used to record `body_offset_of_store` for the Weaver. Pointer
    // arithmetic is valid here because every recursive `execBlock` call is
    // handed a *sub-slice* of the outer function body (`sliceBlock` /
    // `sliceIf` return sub-slices into the same backing array).
    const body_base_off: usize = if (self.body_base.len == 0)
        0
    else
        @intFromPtr(body.ptr) - @intFromPtr(self.body_base.ptr);

    while (!r.eof()) {
        if (self.unanalyzable != null) return .trapped;
        // Capture opcode position BEFORE advancing the reader, so the
        // i32.store handler can record an absolute body offset even after
        // consuming the align/offset immediates.
        const op_start_in_body: usize = r.pos;
        const op = try r.byte();
        // Phase 10.3 ── Poison Pills. Float and i64 opcodes are intercepted
        // BEFORE the main switch so they fire even if the opcode would also
        // happen to be a future named case. Both reasons are deliberately
        // distinguishable for the harness's substring assertions.
        if (isFloatOpcode(op)) {
            self.unanalyzable = "FloatTheoryUnsupported: f32/f64 opcode encountered";
            return .trapped;
        }
        if (isI64Opcode(op)) {
            self.unanalyzable = "I64TheoryUnsupported: i64 opcode encountered (analyzer is i32-only)";
            return .trapped;
        }
        switch (op) {
            Op.nop => {},
            Op.unreachable_ => {
                // Wasm `unreachable` traps. From an analyzer's POV: any path
                // that hits it is dead. Terminate the block with `.trapped`
                // so the `if`/`end` handler upstream can conclude that the
                // then-arm does not fall through (Phase 11.0b).
                return .trapped;
            },
            Op.i32_const => {
                const v = try r.sleb();
                const truncated = @as(u32, @truncate(@as(u64, @bitCast(v))));
                const s = try std.fmt.allocPrint(self.allocator, "(_ bv{d} 32)", .{truncated});
                // Phase 11.0a — tag the origin so a later `i32.add` against
                // a `.local_get` operand can fold this constant into the
                // address expression's accumulated offset.
                try stack.append(.{ .smt = s, .prov = .none, .wasm_origin = .{ .const_ = truncated } });
            },
            Op.local_get => {
                const idx = try r.uleb();
                if (idx >= locals.len) return error.LocalOOB;
                // Phase 11.0a — origin is ALWAYS `.local_get(idx)` for the
                // value pushed here, REGARDLESS of how `locals[idx]` was
                // computed earlier. The Weaver replays `local.get idx` to
                // recover the address — what produced it the first time is
                // irrelevant for the bounds check.
                const v_in = locals[idx] orelse blk: {
                    // Read of uninit local — treat as opaque param.
                    const sym = try self.freshOpaque("l");
                    const v2 = Value{ .smt = sym, .prov = .none };
                    locals[idx] = v2;
                    break :blk v2;
                };
                try stack.append(.{
                    .smt = v_in.smt,
                    .prov = v_in.prov,
                    .wasm_origin = .{ .local_get = @intCast(idx) },
                });
            },
            Op.local_set => {
                const idx = try r.uleb();
                if (idx >= locals.len) return error.LocalOOB;
                // Strip origin on store: the local CELL has no origin; only
                // values freshly produced by a Wasm op do. On later
                // `local.get` we re-attach `.local_get` regardless.
                const v = try self.pop(&stack);
                locals[idx] = .{ .smt = v.smt, .prov = v.prov, .wasm_origin = .unknown };
            },
            Op.local_tee => {
                const idx = try r.uleb();
                if (idx >= locals.len) return error.LocalOOB;
                const v = try self.pop(&stack);
                // Local cell stripped of origin (same reasoning as local.set);
                // stack value re-tagged with `.local_get(idx)` so downstream
                // arithmetic against this stack item is Weaver-replayable.
                locals[idx] = .{ .smt = v.smt, .prov = v.prov, .wasm_origin = .unknown };
                try stack.append(.{
                    .smt = v.smt,
                    .prov = v.prov,
                    .wasm_origin = .{ .local_get = @intCast(idx) },
                });
            },
            Op.drop => _ = try self.pop(&stack),
            Op.select => {
                // select pops (cond, b, a) and pushes (cond != 0 ? a : b).
                const cond = try self.pop(&stack);
                const b = try self.pop(&stack);
                const a = try self.pop(&stack);
                const smt = try std.fmt.allocPrint(
                    self.allocator,
                    "(ite (distinct {s} (_ bv0 32)) {s} {s})",
                    .{ cond.smt, a.smt, b.smt },
                );
                // Provenance merge: if either arm has known alloc provenance
                // but they don't agree exactly, conservatively taint. This
                // mirrors the R3(c) rule: ambiguity = taint, never silent
                // promotion.
                const prov: Provenance = blk: {
                    if (a.prov == .tainted or b.prov == .tainted) break :blk .tainted;
                    if (std.meta.eql(a.prov, b.prov)) break :blk a.prov;
                    break :blk .tainted;
                };
                try stack.append(.{ .smt = smt, .prov = prov });
            },
            Op.global_get => {
                const idx = try r.uleb();
                if (idx >= self.globals.len) {
                    self.unanalyzable = "global.get index out of range";
                    return .trapped;
                }
                const meta = self.globals_meta[idx];
                if (meta.valtype != 0x7f) {
                    // Non-i32 global — caught here rather than at parse time so
                    // i32 modules with unused i64/float globals still analyze.
                    self.unanalyzable = "global.get on non-i32 global (analyzer is i32-only)";
                    return .trapped;
                }
                if (self.globals[idx] == null) {
                    const sym = try self.freshOpaque("global");
                    self.globals[idx] = .{ .smt = sym, .prov = .none };
                }
                try stack.append(self.globals[idx].?);
            },
            Op.global_set => {
                const idx = try r.uleb();
                if (idx >= self.globals.len) {
                    self.unanalyzable = "global.set index out of range";
                    return .trapped;
                }
                const meta = self.globals_meta[idx];
                if (meta.valtype != 0x7f) {
                    self.unanalyzable = "global.set on non-i32 global (analyzer is i32-only)";
                    return .trapped;
                }
                // Phase 11.0a — strip origin: globals are not Weaver-replayable
                // (no Wasm-level identifier that corresponds to "current value
                // of global K" in the same way `local.get K` corresponds to a
                // local's current value, in a fashion that's stable across the
                // guard insertion point). Treat as `.unknown`.
                const v = try self.pop(&stack);
                self.globals[idx] = .{ .smt = v.smt, .prov = v.prov, .wasm_origin = .unknown };
            },
            Op.memory_size => {
                _ = try r.byte(); // memidx reserved-0
                const sym = try self.freshOpaque("memsize");
                try stack.append(.{ .smt = sym, .prov = .none });
            },
            Op.memory_grow => {
                _ = try r.byte(); // memidx reserved-0
                _ = try self.pop(&stack); // delta pages
                const sym = try self.freshOpaque("memgrow_prev");
                try stack.append(.{ .smt = sym, .prov = .none });
            },
            Op.i32_extend8_s, Op.i32_extend16_s => {
                // Sign-extend the low 8/16 bits of a bv32 to a bv32. Provenance
                // is tainted because bit-twiddling defeats the linear pointer
                // model (R3(c)-equivalent).
                const v = try self.pop(&stack);
                const bits: u8 = if (op == Op.i32_extend8_s) 8 else 16;
                const smt = try std.fmt.allocPrint(
                    self.allocator,
                    "((_ sign_extend {d}) ((_ extract {d} 0) {s}))",
                    .{ 32 - bits, bits - 1, v.smt },
                );
                const prov: Provenance = if (v.prov == .none) .none else .tainted;
                try stack.append(.{ .smt = smt, .prov = prov });
            },
            Op.i32_eqz => {
                const a = try self.pop(&stack);
                const s = try std.fmt.allocPrint(
                    self.allocator,
                    "(ite (= {s} (_ bv0 32)) (_ bv1 32) (_ bv0 32))",
                    .{a.smt},
                );
                try stack.append(.{ .smt = s, .prov = .none });
            },
            Op.i32_div_s, Op.i32_div_u, Op.i32_rem_s, Op.i32_rem_u, Op.i32_rotl, Op.i32_rotr => {
                // Spec v3 R3(c): these tear up the linear pointer model.
                // Compute the SMT for completeness, but mark provenance tainted
                // so a downstream store with this address raises UNANALYZABLE.
                const b = try self.pop(&stack);
                const a = try self.pop(&stack);
                const smt_op = switch (op) {
                    Op.i32_div_s => "bvsdiv",
                    Op.i32_div_u => "bvudiv",
                    Op.i32_rem_s => "bvsrem",
                    Op.i32_rem_u => "bvurem",
                    // No native rotl/rotr in SMT-LIB BitVec; lower to shifts+or.
                    // For our purposes the result is opaque and tainted, so the
                    // exact lowering doesn't matter beyond well-formedness.
                    Op.i32_rotl => "bvshl",
                    Op.i32_rotr => "bvlshr",
                    else => unreachable,
                };
                const s = try std.fmt.allocPrint(self.allocator, "({s} {s} {s})", .{ smt_op, a.smt, b.smt });
                try stack.append(.{ .smt = s, .prov = .tainted });
            },
            Op.call_indirect => {
                // (typeidx, tableidx) — we have no way to resolve the actual
                // target function symbolically. Refuse rather than guess.
                _ = try r.uleb();
                _ = try r.uleb();
                self.unanalyzable = "call_indirect (target unresolvable symbolically)";
                return .trapped;
            },
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
                // Phase 11.0a — origin propagation. ONLY i32.add propagates
                // a Weaver-replayable origin, and only when one operand is a
                // local-rooted origin and the other is a constant. All other
                // arithmetic (sub/mul/shl/and/or/xor/shr) clobbers to
                // `.unknown` — the Weaver refuses to emit a guard for a
                // store whose address depends on multiplication or shifts,
                // matching the user-chosen "no guessing" policy.
                var out_origin: Origin = .unknown;
                if (op == Op.i32_add) {
                    out_origin = addOrigin(a.wasm_origin, b.wasm_origin);
                }
                try stack.append(.{
                    .smt = s,
                    .prov = provBinary(op, a.prov, b.prov),
                    .wasm_origin = out_origin,
                });
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
                    return .trapped;
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
                            return .trapped;
                        }
                        const size_arg = args[self.allocator_size_arg_index];
                        const size = parseLiteralBv32(size_arg.smt) orelse {
                            self.unanalyzable = "allocator size argument is not an i32.const literal";
                            return .trapped;
                        };
                        if (self.alloc_count >= 1) {
                            self.unanalyzable = "multiple allocator calls in one function (R6)";
                            return .trapped;
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
                        return .trapped;
                    },
                    .tainted => {
                        self.unanalyzable = "store with tainted-provenance address";
                        return .trapped;
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

                        // Phase 11.0a — emit per-store witness if the address
                        // Value's wasm_origin is in the supported grammar.
                        // The memarg `off` (the static immediate of i32.store)
                        // is folded into `addr_const_offset` here: the Weaver
                        // emits the guard BEFORE the store, where it must
                        // mirror the full effective address that the original
                        // i32.store would compute (`addr_local + addr_const + memarg_off`).
                        const witness_offset_opt: ?u32 = switch (addr.wasm_origin) {
                            .local_get => |k| blk: {
                                const sum = @addWithOverflow(@as(u32, 0), @as(u32, @intCast(off)));
                                if (sum[1] != 0) break :blk null;
                                _ = k;
                                break :blk sum[0];
                            },
                            .local_plus_const => |p| blk: {
                                const sum = @addWithOverflow(p.off, @as(u32, @intCast(off)));
                                if (sum[1] != 0) break :blk null;
                                break :blk sum[0];
                            },
                            else => null,
                        };
                        const witness_local_opt: ?u32 = switch (addr.wasm_origin) {
                            .local_get => |k| k,
                            .local_plus_const => |p| p.local,
                            else => null,
                        };
                        if (witness_offset_opt) |const_off| {
                            if (witness_local_opt) |lk| {
                                try self.witnesses.append(.{
                                    .func_idx = self.user_func_idx,
                                    .body_offset_of_store = body_base_off + op_start_in_body,
                                    .addr_local = lk,
                                    .addr_const_offset = const_off,
                                    .width = width,
                                    .alloc_size = al.size,
                                });
                                // Per-witness obligation = THIS store's
                                // violation predicate alone (no path-guard
                                // disjunction with other stores). Used to
                                // drive Z3 SAT/UNSAT per repair target.
                                try self.per_witness_obligations.append(oblig);
                            }
                        }
                        // If the address shape was unsupported (shifts,
                        // calls, opaques), we still ANALYZE — the obligation
                        // is in the combined disjunction so SAT detection is
                        // unaffected — but the Weaver will refuse to repair
                        // a SAT verdict that lacks a corresponding witness.
                    },
                }
            },
            Op.block => {
                _ = try r.byte(); // blocktype (assume void 0x40 for fixtures)
                // Recurse into the block. The block ends at matching 0x0b.
                // Termination is intentionally DISCARDED: a `block`'s closing
                // `end` is the target label for any internal `br 0`, so
                // fall-through past the block is always abstractly reached
                // (even when inner code unconditionally `br 0`s to the end).
                const sub_body = try sliceBlock(body, r.pos);
                _ = try execBlock(self, sub_body, locals, allocator_func_idx, guard, in_loop);
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
            Op.if_ => {
                // Wasm `if blocktype <then> [else <else>] end`. Phase 10.3
                // supports void blocktype (0x40) only; value-producing ifs
                // would need ite-merging of the trailing stack value across
                // arms, which is out of scope (see directive deviations note).
                const bt = try r.byte();
                if (bt != 0x40) {
                    self.unanalyzable = "ValueProducingBranchUnsupported: if/else with non-void blocktype";
                    return .trapped;
                }
                const cond = try self.pop(&stack);
                const slices = try sliceIf(body, r.pos);
                // Path-guards for the two arms.
                const then_g = try std.fmt.allocPrint(
                    self.allocator,
                    "(distinct {s} (_ bv0 32))",
                    .{cond.smt},
                );
                const new_then_guard = if (guard) |g|
                    try std.fmt.allocPrint(self.allocator, "(and {s} {s})", .{ g, then_g })
                else
                    then_g;
                const then_term = try execBlock(self, slices.then_body, locals, allocator_func_idx, new_then_guard, in_loop);
                // Phase 11.0b — fall-through narrowing depends on whether
                // the else-arm reaches the post-if point. With NO else-body
                // the implicit else is the fall-through itself (always
                // reaches), so `else_term` defaults to .fallthrough.
                var else_term: BlockTermination = .fallthrough;
                if (slices.else_body) |eb| {
                    if (self.unanalyzable != null) return .trapped;
                    const else_g = try std.fmt.allocPrint(
                        self.allocator,
                        "(= {s} (_ bv0 32))",
                        .{cond.smt},
                    );
                    const new_else_guard = if (guard) |g|
                        try std.fmt.allocPrint(self.allocator, "(and {s} {s})", .{ g, else_g })
                    else
                        else_g;
                    else_term = try execBlock(self, eb, locals, allocator_func_idx, new_else_guard, in_loop);
                }
                // r.pos points at the start of the then-body. Advance past
                // the matching `end` (+1 byte for the 0x0b terminator).
                r.pos = slices.end_offset + 1;

                // Phase 11.0b ── Defect 4 fix. Narrow the fall-through guard
                // based on which arms can reach the post-`end` instruction:
                //
                //   then=fall, else=fall   → guard unchanged (both reach)
                //   then=trap, else=fall   → guard ∧= (cond == 0)
                //   then=fall, else=trap   → guard ∧= (cond != 0)
                //   then=trap, else=trap   → post-if is unreachable; propagate .trapped
                //
                // Without this, an `if (idx >= size) unreachable end`
                // patched in by phase11_weaver doesn't narrow the path
                // guard of the subsequent i32.store, and re-analysis of the
                // repaired binary returns SAT against a verifiably-safe
                // program. With it, the repair loop closes soundly.
                const then_reaches = then_term == .fallthrough;
                const else_reaches = else_term == .fallthrough;
                if (!then_reaches and !else_reaches) {
                    // Both arms terminate (trap or branch out). The
                    // enclosing block's post-`end` code is dead.
                    return .trapped;
                }
                if (then_reaches and !else_reaches) {
                    // Only the then-arm reaches here, which means cond was
                    // nonzero. Conjoin (cond != 0) into the fall-through.
                    guard = if (guard) |g|
                        try std.fmt.allocPrint(self.allocator, "(and {s} {s})", .{ g, then_g })
                    else
                        then_g;
                } else if (!then_reaches and else_reaches) {
                    // Only the else-path (which includes the implicit
                    // no-else fall-through) reaches here → cond == 0.
                    const eq0 = try std.fmt.allocPrint(self.allocator, "(= {s} (_ bv0 32))", .{cond.smt});
                    guard = if (guard) |g|
                        try std.fmt.allocPrint(self.allocator, "(and {s} {s})", .{ g, eq0 })
                    else
                        eq0;
                }
                // else: both reach → no narrowing possible.
            },
            Op.br => {
                _ = try r.uleb();
                // Unconditional branch out of any nesting.
                return .branched_out;
            },
            Op.br_table => {
                // br_table: <n> <labels...> <default>. We consume all n+1 ULEBs
                // and the index off the stack, then treat the branch as
                // unconditional (any path here exits this block). The path
                // guard down-stream of br_table is the disjunction of every
                // taken-target — an over-approximation we tolerate because
                // br_table is rare in pointer-heavy code.
                const n = try r.uleb();
                var k: u64 = 0;
                while (k < n) : (k += 1) _ = try r.uleb();
                _ = try r.uleb(); // default label
                _ = try self.pop(&stack); // index
                return .branched_out;
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
            Op.end => return .fallthrough,
            Op.ret => return .branched_out,
            else => {
                self.unanalyzable = "unsupported opcode";
                return .trapped;
            },
        }
    }
    return .fallthrough;
}

/// R5 — unroll a loop body at most `k=3` times, threading symbolic state.
///
/// Per-iteration `BlockTermination` is intentionally discarded: a `loop`
/// header in Wasm names the loop-START label (not the post-loop label), so
/// `br 0` from inside iterates rather than escaping. Whether iteration N
/// fell through, trapped, or branched-out, the enclosing block's
/// post-`loop`/`end` code is independently reached via the loop's normal
/// exit semantics — that's modeled by the outer `Op.block`/function-body
/// fall-through, not by anything `runLoop` returns.
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
        _ = try execBlock(self, body, locals, allocator_func_idx, enclosing_guard, true);
    }
}

/// Skip past the immediate operands of an opcode in the byte stream. This is
/// the SINGLE source of truth for opcode immediate widths, used by both
/// `sliceBlock` (depth tracking for end-byte location) and `sliceIf` (finding
/// else/end at the right depth). If `execBlock` and these slicers disagree on
/// any opcode's immediate width, block boundaries desync and the analyzer
/// silently mis-parses real code.
fn skipImmediates(r: *Reader, op: u8) !void {
    // ULEB128-pair memarg ops (align, offset).
    if ((op >= 0x28 and op <= 0x3e) and op != 0x3f) {
        _ = try r.uleb();
        _ = try r.uleb();
        return;
    }
    switch (op) {
        // 0-immediate opcodes — the vast majority of arithmetic/comparisons.
        Op.unreachable_, Op.nop, Op.end, Op.ret, Op.drop, Op.select,
        Op.i32_eqz,
        Op.i32_eq, Op.i32_ne,
        Op.i32_lt_s, Op.i32_lt_u, Op.i32_gt_s, Op.i32_gt_u,
        Op.i32_le_s, Op.i32_le_u, Op.i32_ge_s, Op.i32_ge_u,
        Op.i32_add, Op.i32_sub, Op.i32_mul,
        Op.i32_div_s, Op.i32_div_u, Op.i32_rem_s, Op.i32_rem_u,
        Op.i32_and, Op.i32_or, Op.i32_xor,
        Op.i32_shl, Op.i32_shr_s, Op.i32_shr_u, Op.i32_rotl, Op.i32_rotr,
        Op.i32_extend8_s, Op.i32_extend16_s,
        Op.else_,
        => {},
        // Block-openers: 1-byte blocktype (we only support 0x40, but the
        // depth-tracker must skip it regardless).
        Op.block, Op.loop_, Op.if_ => _ = try r.byte(),
        // 1-ULEB128 opcodes.
        Op.local_get, Op.local_set, Op.local_tee, Op.global_get, Op.global_set,
        Op.call, Op.br, Op.br_if,
        => _ = try r.uleb(),
        Op.call_indirect => {
            _ = try r.uleb();
            _ = try r.uleb();
        },
        // br_table: <n labels...> <default>.
        Op.br_table => {
            const n = try r.uleb();
            var i: u64 = 0;
            while (i < n) : (i += 1) _ = try r.uleb();
            _ = try r.uleb();
        },
        // i32.const = SLEB128, i64.const = SLEB128 (poison-pill at exec).
        Op.i32_const, Op.i64_const => _ = try r.sleb(),
        // f32.const / f64.const carry raw IEEE bytes — variable-width below.
        Op.f32_const => _ = try r.slice(4),
        Op.f64_const => _ = try r.slice(8),
        // memory.size / memory.grow each carry a single reserved-0 byte.
        Op.memory_size, Op.memory_grow => _ = try r.byte(),
        else => {
            // Floats outside the const range (cmp/arith/conv) take 0 immediates;
            // i64 ops outside the load/store/const block likewise. Anything else
            // is an opcode we haven't classified — treat as 0-imm and trust that
            // execBlock will refuse it with UNANALYZABLE before it matters. If
            // this assumption is wrong, the depth-tracker will desync — but the
            // resulting block-mismatch error is itself loud failure, not silent.
        },
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
            Op.block, Op.loop_, Op.if_ => {
                _ = try r.byte(); // blocktype
                depth += 1;
            },
            Op.end => {
                depth -= 1;
                if (depth == 0) return body[start .. start + r.pos - 1];
            },
            else => try skipImmediates(&r, op),
        }
    }
    return error.UnterminatedBlock;
}

/// Phase 10.3 — split an `if [else] end` body. Given `body[start..]` is the
/// content immediately following the `if`'s blocktype byte, locate the
/// matching `else` (depth == 1) if present, and the matching `end` (depth==0).
/// Returns slices for the then-body, optional else-body, and the absolute
/// offset of the `end` byte inside `body`.
const IfSlices = struct {
    then_body: []const u8,
    else_body: ?[]const u8,
    /// Offset within `body` of the matching `end` byte itself.
    end_offset: usize,
};

fn sliceIf(body: []const u8, start: usize) !IfSlices {
    var depth: usize = 1;
    var r = Reader{ .bytes = body[start..] };
    var else_at: ?usize = null; // body-absolute offset of the else byte, if any
    while (!r.eof()) {
        const op_pos_in_body = start + r.pos;
        const op = try r.byte();
        switch (op) {
            Op.block, Op.loop_, Op.if_ => {
                _ = try r.byte();
                depth += 1;
            },
            Op.else_ => {
                if (depth == 1 and else_at == null) {
                    else_at = op_pos_in_body;
                }
            },
            Op.end => {
                depth -= 1;
                if (depth == 0) {
                    const end_off = op_pos_in_body;
                    const then_end = else_at orelse end_off;
                    const then_body = body[start..then_end];
                    const else_body: ?[]const u8 = if (else_at) |ea|
                        body[ea + 1 .. end_off]
                    else
                        null;
                    return .{ .then_body = then_body, .else_body = else_body, .end_offset = end_off };
                }
            },
            else => try skipImmediates(&r, op),
        }
    }
    return error.UnterminatedIf;
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

    const global_slots = try allocator.alloc(?Value, m.globals.len);
    for (global_slots) |*g| g.* = null;

    var analyzer = Analyzer{
        .allocator = allocator,
        .obligations = std.ArrayList([]const u8).init(allocator),
        .locals = locals,
        .declarations = std.ArrayList([]const u8).init(allocator),
        .signatures = m.signatures,
        .allocator_func_idx = allocator_func_idx,
        .allocator_size_arg_index = cfg.size_arg_index,
        .globals = global_slots,
        .globals_meta = m.globals,
        // Phase 11.0a — Weaver support.
        .body_base = f.body,
        .user_func_idx = 0,
        .witnesses = std.ArrayList(StoreWitness).init(allocator),
        .per_witness_obligations = std.ArrayList([]const u8).init(allocator),
    };

    _ = try execBlock(&analyzer, f.body, locals, allocator_func_idx, null, false);

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

    // Phase 11.0a — build a self-contained SMT query per witness. Each query
    // re-emits all declarations (alloc bases + opaques) so it can be sent to
    // Z3 standalone; the harness uses these to ROUTE a per-store verdict back
    // to the specific repair site, which the combined-disjunction query cannot.
    const witnesses_slice = try analyzer.witnesses.toOwnedSlice();
    var per_witness_smts = try allocator.alloc([]const u8, analyzer.per_witness_obligations.items.len);
    for (analyzer.per_witness_obligations.items, 0..) |oblig, i| {
        var qbuf = std.ArrayList(u8).init(allocator);
        const qw = qbuf.writer();
        for (analyzer.declarations.items) |d| {
            try qw.print("{s}\n", .{d});
        }
        try qw.print("(assert {s})\n(check-sat)\n", .{oblig});
        per_witness_smts[i] = try qbuf.toOwnedSlice();
    }

    return AnalysisResult{
        .state = .analyzes,
        .smt = try buf.toOwnedSlice(),
        .store_sites = analyzer.store_sites,
        .unroll_k = if (analyzer.saw_loop) 3 else 0,
        .witnesses = witnesses_slice,
        .per_witness_smts = per_witness_smts,
        .allocator_func_idx = allocator_func_idx,
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
