//! Phase 11.0c–e Weaver — DRAFT (not yet wired into build.zig).
//!
//! Performs the Preamble Surgery the Phase 11.0 design discovery surfaced:
//!  (c) Register a fresh i32 local in func_idx's locals declaration. This
//!      becomes the "pristine alloc_base" preservation register.
//!  (d) Splice `local.tee <pristine_local>` immediately after the allocator's
//!      `call` instruction — clones the returned pointer into the new local
//!      while leaving it on the stack for the original program to consume.
//!  (e) At each StoreWitness's body_offset_of_store, splice a bounds-check
//!      guard derived from the saved alloc_base + the witness's static data.
//!
//! Wasm binary surgery rules of engagement honored in this draft:
//!  - Output uses 5-byte max-width LEB128 encoding for `body_size` and
//!    Code Section `section_size`. This is the user-selected policy from
//!    the 11.0 audit; it's non-canonical but legal (the existing fixtures
//!    already use 5-byte ulebs for call immediates, empirically accepted
//!    by the validator path this codebase uses).
//!  - Existing `br_if`/`br_table` branch immediates are NEVER perturbed:
//!    the guard pattern uses an `if`/`end` self-contained scope, so no
//!    new label-stack depth is introduced into the enclosing structure.
//!  - Witnesses are deduplicated by (func_idx, body_offset_of_store)
//!    before splicing. Loop unrolling causes the analyzer to emit the
//!    same source store multiple times; one patch covers all dynamic
//!    iterations.
//!
//! ═══════════════════════════════════════════════════════════════════════
//! AUDITOR FLAG ── DIRECTIVE DEVIATION on the guard byte sequence.
//! ═══════════════════════════════════════════════════════════════════════
//! The Phase 11.1 directive specifies the guard as:
//!
//!     local.get <pristine_local>
//!     [i32.const offset; i32.add]
//!     i32.const <size>
//!     i32.ge_u
//!     if 0x40 ; unreachable ; end
//!
//! With `pristine_local == alloc_base` (the Preamble Surgeon's preservation
//! register), this sequence computes `(alloc_base + offset) >= alloc_size`
//! — a comparison between an absolute memory pointer and a buffer-relative
//! size. That is never meaningful at runtime: alloc_base could be
//! 0x00100000 and alloc_size could be 8, so the guard trips on every
//! execution. The repaired binary would either trap unconditionally
//! (bricking the program) or, if alloc_base happened to be < size,
//! never trap (no repair).
//!
//! The DRAFT below implements the mathematically correct guard for the
//! preamble-surgery strategy. Math:
//!
//!     effective_addr = local[addr_local] + addr_const_offset + memarg_off
//!     offset_in_buf  = effective_addr - alloc_base
//!     OOB            ⇔ offset_in_buf + width > alloc_size
//!                    ⇔ offset_in_buf > alloc_size - width
//!
//!     Note: addr_const_offset already folds memarg_off (see
//!     phase10_provenance.zig Edit 8, i32_store handler).
//!
//! Synthesized bytes:
//!
//!     local.get <addr_local>            ;; effective address
//!     local.get <pristine_local>        ;; saved alloc_base
//!     i32.sub                           ;; offset_in_buffer
//!     [i32.const <addr_const_offset>; i32.add]   ;; if non-zero
//!     i32.const <alloc_size - width>    ;; max-safe offset (precomputed)
//!     i32.gt_u                          ;; offset_in_buf > max_safe_off
//!     if 0x40
//!       unreachable
//!     end
//!
//! Precondition for synthesis: alloc_size >= width. The current
//! AllocatorConfig + R6 rules guarantee a literal alloc_size; if
//! alloc_size < width is encountered, `injectGuard` returns
//! `error.AllocSizeBelowWidth` rather than emit an underflowing
//! immediate. Real fixtures have alloc_size=8/16 with width=4 — safe.
//!
//! If the project lead intended a different interpretation of
//! `pristine_local` (e.g., "save the loop counter, not alloc_base"),
//! the synthesis code in `synthesizeGuardBytes()` is the SINGLE point
//! to switch back. Flag this in audit and I will rewrite. The directive's
//! literal pattern is preserved in the docstring above for reference.
//! ═══════════════════════════════════════════════════════════════════════

const std = @import("std");
const phase10 = @import("phase10_provenance.zig");

pub const WeaverError = error{
    NotWasm,
    BadWasmVersion,
    CodeSectionNotFound,
    FunctionOutOfRange,
    NoLocalsDeclGroup,
    NoI32LocalsGroup,
    AllocatorCallNotFound,
    AllocSizeBelowWidth,
    LocalIdxOutOfRange,
    UnexpectedEof,
} || std.mem.Allocator.Error;

// ── Wasm opcode subset (shared with phase10_provenance.zig conceptually,
// duplicated here so the Weaver is independently auditable; intentional). ─
const Op = struct {
    const unreachable_: u8 = 0x00;
    const nop: u8 = 0x01;
    const block: u8 = 0x02;
    const loop_: u8 = 0x03;
    const if_: u8 = 0x04;
    const else_: u8 = 0x05;
    const end: u8 = 0x0b;
    const br: u8 = 0x0c;
    const br_if: u8 = 0x0d;
    const br_table: u8 = 0x0e;
    const ret: u8 = 0x0f;
    const call: u8 = 0x10;
    const call_indirect: u8 = 0x11;
    const drop: u8 = 0x1a;
    const select: u8 = 0x1b;
    const local_get: u8 = 0x20;
    const local_set: u8 = 0x21;
    const local_tee: u8 = 0x22;
    const global_get: u8 = 0x23;
    const global_set: u8 = 0x24;
    const i32_load: u8 = 0x28;
    const i32_store: u8 = 0x36;
    const i32_store8: u8 = 0x3a;
    const i32_store16: u8 = 0x3b;
    const memory_size: u8 = 0x3f;
    const memory_grow: u8 = 0x40;
    const i32_const: u8 = 0x41;
    const i32_eqz: u8 = 0x45;
    // Comparators — i32.gt_u is what the corrected guard uses.
    const i32_gt_u: u8 = 0x4b;
    const i32_ge_u: u8 = 0x4f;
    // Arithmetic.
    const i32_add: u8 = 0x6a;
    const i32_sub: u8 = 0x6b;
};

const ValType = struct {
    const i32_: u8 = 0x7f;
    const i64_: u8 = 0x7e;
    const f32_: u8 = 0x7d;
    const f64_: u8 = 0x7c;
};

const BlockType = struct {
    const void_: u8 = 0x40;
};

// ── ULEB128 helpers ────────────────────────────────────────────────────────

/// Read a ULEB128 u32 starting at `bytes[pos]`. Returns (value, bytes_read).
fn readUleb32(bytes: []const u8, pos: usize) WeaverError!struct { value: u32, len: usize } {
    var result: u32 = 0;
    var shift: u5 = 0;
    var i: usize = 0;
    while (true) {
        if (pos + i >= bytes.len) return error.UnexpectedEof;
        const b = bytes[pos + i];
        // The mask handles bytes whose payload bits would shift past the
        // u32 boundary — for u32, byte index 4's payload only contributes
        // 4 bits (the high 3 are required to be 0 per spec).
        result |= @as(u32, b & 0x7F) << shift;
        i += 1;
        if (b & 0x80 == 0) break;
        // Saturate the shift safely; a 6th byte means malformed input but
        // shift would otherwise wrap. We treat that as malformed (no error
        // here; caller may want to detect via i > 5).
        shift = @intCast(@min(@as(u32, shift) + 7, 28));
        if (i > 5) return error.UnexpectedEof; // u32 ULEB128 max 5 bytes
    }
    return .{ .value = result, .len = i };
}

/// Write a u32 as a 5-byte non-canonical ULEB128. Always 5 bytes — this is
/// the central design choice: a uleb whose width can change in response to
/// inserted body bytes would cascade-shift everything downstream. By
/// committing to 5 bytes at the outset, we trade ~4 bytes of file growth
/// for zero downstream-offset disturbance.
fn writeUleb5(out: []u8, value: u32) void {
    std.debug.assert(out.len >= 5);
    var v = value;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        out[i] = @as(u8, @intCast(v & 0x7F)) | 0x80;
        v >>= 7;
    }
    // 5th byte: payload only (no continuation bit). u32 has at most 4 bits
    // left after 4 × 7 = 28 shifts (bits 28-31); the high 3 bits of this
    // byte are zero.
    out[4] = @as(u8, @intCast(v & 0x7F));
}

/// Write a signed i32 as LEB128 SLEB128 — minimal encoding. Used for
/// guard's `i32.const` immediates; these are small literals (0, 4, 12, ...)
/// for the fixtures so the encoding is single-byte. Caller must supply a
/// buffer large enough (5 bytes always suffices for i32).
fn writeSlebI32(buf: *std.ArrayList(u8), value: i32) WeaverError!void {
    var v = value;
    while (true) {
        const byte: u8 = @as(u8, @intCast(@as(u32, @bitCast(v)) & 0x7F));
        v >>= 7; // arithmetic shift preserves sign
        const sign_bit_of_byte = (byte & 0x40) != 0;
        const more = !((v == 0 and !sign_bit_of_byte) or (v == -1 and sign_bit_of_byte));
        if (more) {
            try buf.append(byte | 0x80);
        } else {
            try buf.append(byte);
            return;
        }
    }
}

/// Write a u32 as LEB128 ULEB128 — minimal encoding. Used for the
/// `local.get`/`local.tee` immediates (local indices), which are small in
/// the fixtures so usually single-byte.
fn writeUlebI32(buf: *std.ArrayList(u8), value: u32) WeaverError!void {
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

// ── Wasm layout discovery ──────────────────────────────────────────────────

/// Locations and shapes the Weaver needs to know about for one user
/// function inside a parsed Wasm module. All offsets are FILE-RELATIVE
/// unless noted.
const FuncLayout = struct {
    /// File offset of the Code Section's id byte (0x0a).
    code_section_start: usize,
    /// File offset of the byte immediately AFTER the Code Section's
    /// content (== start of the next section, or EOF).
    code_section_end: usize,
    /// File offset of the section_size ULEB.
    code_section_size_off: usize,
    /// Width of the existing section_size ULEB in bytes.
    code_section_size_width: usize,
    /// Current decoded value of the section_size ULEB.
    code_section_size_value: u32,
    /// File offset of this function's body_size ULEB.
    body_size_off: usize,
    /// Width of the existing body_size ULEB in bytes.
    body_size_width: usize,
    /// Current decoded value of the body_size ULEB.
    body_size_value: u32,
    /// File offset where the function body starts (1st byte of locals
    /// decl group count). body_start + body_size_value == 1 byte past
    /// the final 0x0b end marker.
    body_start: usize,
    /// File offset where the instruction bytes start (== first byte
    /// after the locals decls). body_offset_of_store witnesses are
    /// RELATIVE to this position.
    inst_start: usize,
    /// Number of decl groups in the original locals decl.
    decl_group_count: u32,
    /// Sum of `count` over all decl groups (the "extra locals" beyond params).
    nlocals_extra_original: u32,
    /// Number of function params from the type table (needed so the
    /// computed `new_local_idx` is correct: nparams + nlocals_extra).
    nparams: u32,
};

/// Parse just enough of the .wasm to find `func_idx`'s body and metadata.
/// Lighter than `phase10_provenance.parseModule` — we only need offsets,
/// not the full symbolic-exec scaffolding.
pub fn findFuncLayout(
    allocator: std.mem.Allocator,
    wasm: []const u8,
    func_idx: u32,
) WeaverError!FuncLayout {
    if (wasm.len < 8) return error.NotWasm;
    if (!std.mem.eql(u8, wasm[0..4], "\x00asm")) return error.NotWasm;
    if (!std.mem.eql(u8, wasm[4..8], "\x01\x00\x00\x00")) return error.BadWasmVersion;

    var pos: usize = 8;
    var code_section_start: ?usize = null;
    var code_section_size_off: usize = 0;
    var code_section_size_width: usize = 0;
    var code_section_size_value: u32 = 0;
    var code_section_end: usize = 0;

    // Type section is also needed for function param counts so the Weaver
    // can correctly compute new_local_idx = nparams + nlocals_extra_new.
    var type_param_counts = std.ArrayList(u32).init(allocator);
    defer type_param_counts.deinit();
    var func_typeidx_list = std.ArrayList(u32).init(allocator);
    defer func_typeidx_list.deinit();

    while (pos < wasm.len) {
        const sec_id = wasm[pos];
        pos += 1;
        const sz = try readUleb32(wasm, pos);
        const size_off = pos;
        pos += sz.len;
        const content_start = pos;
        const content_end = content_start + sz.value;
        if (content_end > wasm.len) return error.UnexpectedEof;

        switch (sec_id) {
            1 => { // Type — record param counts.
                var p = content_start;
                const n_types = try readUleb32(wasm, p);
                p += n_types.len;
                for (0..n_types.value) |_| {
                    if (wasm[p] != 0x60) return error.NotWasm; // func form
                    p += 1;
                    const np = try readUleb32(wasm, p);
                    p += np.len;
                    p += @intCast(np.value); // skip param valtypes
                    const nr = try readUleb32(wasm, p);
                    p += nr.len;
                    p += @intCast(nr.value); // skip result valtypes
                    try type_param_counts.append(np.value);
                }
            },
            3 => { // Function — typeidx per user function.
                var p = content_start;
                const n_fn = try readUleb32(wasm, p);
                p += n_fn.len;
                for (0..n_fn.value) |_| {
                    const ti = try readUleb32(wasm, p);
                    p += ti.len;
                    try func_typeidx_list.append(ti.value);
                }
            },
            10 => { // Code — locate the target function's body.
                code_section_start = pos - 1 - sz.len; // back up to sec_id byte
                code_section_size_off = size_off;
                code_section_size_width = sz.len;
                code_section_size_value = sz.value;
                code_section_end = content_end;

                var p = content_start;
                const n_bodies = try readUleb32(wasm, p);
                p += n_bodies.len;
                if (func_idx >= n_bodies.value) return error.FunctionOutOfRange;

                // Skip earlier function bodies.
                for (0..func_idx) |_| {
                    const bs = try readUleb32(wasm, p);
                    p += bs.len;
                    p += @intCast(bs.value);
                }

                // Now p points at target function's body_size.
                const bs = try readUleb32(wasm, p);
                const body_size_off = p;
                const body_size_width = bs.len;
                const body_size_value = bs.value;
                p += bs.len;
                const body_start_file_off = p;

                // Walk the locals decl groups to find inst_start.
                const dg = try readUleb32(wasm, p);
                p += dg.len;
                var nlocals_extra: u32 = 0;
                for (0..dg.value) |_| {
                    const cnt = try readUleb32(wasm, p);
                    p += cnt.len;
                    if (p >= wasm.len) return error.UnexpectedEof;
                    p += 1; // valtype byte
                    nlocals_extra += cnt.value;
                }
                const inst_start_file_off = p;

                // Resolve nparams via the type table.
                if (func_idx >= func_typeidx_list.items.len) return error.FunctionOutOfRange;
                const tidx = func_typeidx_list.items[func_idx];
                if (tidx >= type_param_counts.items.len) return error.FunctionOutOfRange;
                const nparams = type_param_counts.items[tidx];

                return FuncLayout{
                    .code_section_start = code_section_start.?,
                    .code_section_end = code_section_end,
                    .code_section_size_off = code_section_size_off,
                    .code_section_size_width = code_section_size_width,
                    .code_section_size_value = code_section_size_value,
                    .body_size_off = body_size_off,
                    .body_size_width = body_size_width,
                    .body_size_value = body_size_value,
                    .body_start = body_start_file_off,
                    .inst_start = inst_start_file_off,
                    .decl_group_count = dg.value,
                    .nlocals_extra_original = nlocals_extra,
                    .nparams = nparams,
                };
            },
            else => {},
        }
        pos = content_end;
    }
    return error.CodeSectionNotFound;
}

// ── Opcode-immediate skipper (for body scanning) ───────────────────────────
//
// Mirrors phase10_provenance.skipImmediates byte-for-byte. Duplicated rather
// than imported so the Weaver compiles standalone for audit. If the two
// implementations ever drift, the Weaver's body scanner will desync with
// the Cartographer's body offsets and witnesses will splice at the wrong
// position. Keep this in lock-step with phase10_provenance.zig until both
// can share a common opcode-table module.

fn skipImmediates(bytes: []const u8, pos: *usize, op: u8) WeaverError!void {
    if (pos.* > bytes.len) return error.UnexpectedEof;

    // ULEB128-pair memarg ops (load/store family 0x28..0x3e excluding 0x3f).
    if ((op >= 0x28 and op <= 0x3e) and op != 0x3f) {
        const a = try readUleb32(bytes, pos.*);
        pos.* += a.len;
        const b = try readUleb32(bytes, pos.*);
        pos.* += b.len;
        return;
    }

    switch (op) {
        // 0-immediate (arithmetic, comparisons, drops, etc.).
        Op.unreachable_, Op.nop, Op.end, Op.ret, Op.drop, Op.select, Op.else_,
        Op.i32_eqz, Op.i32_add, Op.i32_sub, Op.i32_gt_u, Op.i32_ge_u,
        // Other comparators/arith we don't enumerate exhaustively — see
        // phase10_provenance.skipImmediates for the full list. The Weaver
        // only scans bodies linearly to find a `call` immediate, so as long
        // as no skipped opcode here happens to have immediates, we're fine.
        => {},
        Op.block, Op.loop_, Op.if_ => {
            if (pos.* >= bytes.len) return error.UnexpectedEof;
            pos.* += 1; // blocktype byte
        },
        Op.local_get, Op.local_set, Op.local_tee,
        Op.global_get, Op.global_set,
        Op.call, Op.br, Op.br_if,
        => {
            const u = try readUleb32(bytes, pos.*);
            pos.* += u.len;
        },
        Op.call_indirect => {
            const a = try readUleb32(bytes, pos.*);
            pos.* += a.len;
            const b = try readUleb32(bytes, pos.*);
            pos.* += b.len;
        },
        Op.br_table => {
            const n = try readUleb32(bytes, pos.*);
            pos.* += n.len;
            for (0..n.value) |_| {
                const l = try readUleb32(bytes, pos.*);
                pos.* += l.len;
            }
            const d = try readUleb32(bytes, pos.*);
            pos.* += d.len;
        },
        Op.i32_const => {
            // SLEB32 — for the scanner we just need to skip it. Walk bytes
            // until we hit one without the continuation bit. SLEB encoding
            // is at most 5 bytes for i32.
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                if (pos.* >= bytes.len) return error.UnexpectedEof;
                const b = bytes[pos.*];
                pos.* += 1;
                if (b & 0x80 == 0) return;
            }
            return error.UnexpectedEof;
        },
        Op.memory_size, Op.memory_grow => {
            if (pos.* >= bytes.len) return error.UnexpectedEof;
            pos.* += 1;
        },
        else => {
            // Heuristic: 0-immediate. Same trade-off as
            // phase10_provenance.skipImmediates — see that file's comment.
            // For Weaver use this is only hit when scanning for the
            // allocator call, so a misclassification would cause us to
            // desync from the body byte stream and return AllocatorCallNotFound;
            // a loud failure mode rather than a silent miscompile.
        },
    }
}

// ── Phase 2 — `injectPreservationLocal` (11.0c) ────────────────────────────

/// Output of `injectPreservationLocal`: the rewritten Wasm bytes plus the
/// new local index that subsequent stages should target with `local.tee`
/// / `local.get`.
pub const PreservationResult = struct {
    new_wasm: []u8,
    new_local_idx: u32,
};

/// Register a fresh i32 local in func_idx's locals declaration. Two cases:
///   (a) An existing i32 decl group is present — we increment its `count`.
///       Constant-byte change IF the count's ULEB width does not grow
///       (count < 64 transitioning to count < 128 stays 1 byte). For our
///       fixtures, count goes 2 → 3 or 3 → 4 — same byte width.
///   (b) No i32 group present (rare in our fixtures; happens for funcs
///       with only non-i32 locals or no locals). We APPEND a new group
///       `01 0x7f` and increment the group-count ULEB.
///
/// In BOTH cases the function's `body_size` ULEB is rewritten to the new
/// width using the 5-byte max-width policy, and the Code Section's
/// `section_size` ULEB is rewritten the same way. All other sections,
/// imports, exports, and function bodies are copied verbatim.
///
/// The returned `new_local_idx` is the index of the freshly-registered
/// local: `layout.nparams + layout.nlocals_extra_original`. (Wasm local
/// indices are 0-based across params + decls.)
pub fn injectPreservationLocal(
    allocator: std.mem.Allocator,
    wasm: []const u8,
    func_idx: u32,
) WeaverError!PreservationResult {
    const layout = try findFuncLayout(allocator, wasm, func_idx);

    // 1. Walk locals decl groups, looking for an i32 group.
    var p = layout.body_start;
    const dg_uleb = try readUleb32(wasm, p);
    p += dg_uleb.len;
    var i32_group_count_off: ?usize = null; // file offset of the count ULEB
    var i32_group_count_width: usize = 0;
    var i32_group_count_value: u32 = 0;
    var dg_iter: u32 = 0;
    while (dg_iter < dg_uleb.value) : (dg_iter += 1) {
        const cnt = try readUleb32(wasm, p);
        const cnt_off = p;
        p += cnt.len;
        if (p >= wasm.len) return error.UnexpectedEof;
        const vt = wasm[p];
        p += 1;
        if (vt == ValType.i32_ and i32_group_count_off == null) {
            i32_group_count_off = cnt_off;
            i32_group_count_width = cnt.len;
            i32_group_count_value = cnt.value;
        }
    }

    // Compute the new locals-decl bytes.
    var new_decl_buf = std.ArrayList(u8).init(allocator);
    defer new_decl_buf.deinit();

    if (i32_group_count_off) |_| {
        // Case (a): increment existing i32 group's count. Re-emit the
        // entire locals-decl block (group count ULEB + each group) so we
        // can centrally control the byte layout.
        try writeUlebI32(&new_decl_buf, dg_uleb.value);
        var q = layout.body_start + dg_uleb.len;
        var iter2: u32 = 0;
        while (iter2 < dg_uleb.value) : (iter2 += 1) {
            const cnt = try readUleb32(wasm, q);
            q += cnt.len;
            const vt = wasm[q];
            q += 1;
            const new_count = if (q == i32_group_count_off.? + i32_group_count_width + 1)
                cnt.value + 1
            else
                cnt.value;
            try writeUlebI32(&new_decl_buf, new_count);
            try new_decl_buf.append(vt);
        }
    } else {
        // Case (b): append a new i32 group and bump the group count.
        try writeUlebI32(&new_decl_buf, dg_uleb.value + 1);
        // Copy original groups verbatim.
        const q = layout.body_start + dg_uleb.len;
        const decls_size = layout.inst_start - q;
        try new_decl_buf.appendSlice(wasm[q .. q + decls_size]);
        // Append the new i32 group: count=1, valtype=i32.
        try writeUlebI32(&new_decl_buf, 1);
        try new_decl_buf.append(ValType.i32_);
    }

    // 2. Reassemble the function body: new_decl + original instruction
    // bytes (verbatim — no instruction-level patching in this phase). The
    // trailing 0x0b end byte is part of the instruction bytes (per the
    // Cartographer's parseModule, which slices body[br_.pos..] = decls
    // removed but the trailing end retained).
    const inst_bytes = wasm[layout.inst_start .. layout.body_start + layout.body_size_value];
    const new_body_content_size = new_decl_buf.items.len + inst_bytes.len;

    const new_wasm = try rebuildWasm(
        allocator,
        wasm,
        layout,
        new_decl_buf.items,
        inst_bytes,
        new_body_content_size,
        layout.nparams + layout.nlocals_extra_original,
    );
    return PreservationResult{
        .new_wasm = new_wasm,
        .new_local_idx = layout.nparams + layout.nlocals_extra_original,
    };
}

// ── Phase 3 — `cloneAllocBase` (11.0d) ─────────────────────────────────────

/// Scan func_idx's instruction body for the first `call <allocator_func_idx>`
/// and inject `local.tee <target_local>` immediately after it. The clone
/// preserves the allocator's return value (alloc_base) into `target_local`
/// while leaving the original on the stack for the source program's
/// downstream consumer (which in the fixtures is an `i32.add` that fuses
/// alloc_base into a per-iteration address).
///
/// Body-offset shift: `local.tee K` is 2 bytes when K < 128, more for
/// larger K. Witnesses whose `body_offset_of_store` is GREATER than the
/// allocator's body offset must be shifted by the local.tee's byte length
/// before being passed to `injectGuard`. See `applyAll()`.
pub fn cloneAllocBase(
    allocator: std.mem.Allocator,
    wasm: []const u8,
    func_idx: u32,
    allocator_func_idx: u32,
    target_local: u32,
) WeaverError![]u8 {
    const layout = try findFuncLayout(allocator, wasm, func_idx);

    // Linear scan of instruction body for `call <allocator_func_idx>`.
    const inst_len = (layout.body_start + layout.body_size_value) - layout.inst_start;
    const inst_bytes = wasm[layout.inst_start .. layout.inst_start + inst_len];
    var pos: usize = 0;
    var alloc_call_end_in_body: ?usize = null;
    while (pos < inst_bytes.len) {
        const op = inst_bytes[pos];
        pos += 1;
        if (op == Op.call) {
            const callee_uleb = try readUleb32(inst_bytes, pos);
            const callee_idx = callee_uleb.value;
            pos += callee_uleb.len;
            if (callee_idx == allocator_func_idx) {
                alloc_call_end_in_body = pos;
                break;
            }
            // Else: keep scanning — there may be other calls before the
            // allocator. (R6 in phase10 forbids MULTIPLE allocator calls
            // per function, but other non-allocator calls are fine.)
        } else {
            try skipImmediates(inst_bytes, &pos, op);
        }
    }
    const call_end = alloc_call_end_in_body orelse return error.AllocatorCallNotFound;

    // Compute the `local.tee target_local` byte sequence.
    var tee_bytes = std.ArrayList(u8).init(allocator);
    defer tee_bytes.deinit();
    try tee_bytes.append(Op.local_tee);
    try writeUlebI32(&tee_bytes, target_local);

    // Splice the local.tee at body-offset `call_end` within inst_bytes.
    var new_inst = std.ArrayList(u8).init(allocator);
    defer new_inst.deinit();
    try new_inst.appendSlice(inst_bytes[0..call_end]);
    try new_inst.appendSlice(tee_bytes.items);
    try new_inst.appendSlice(inst_bytes[call_end..]);

    // Reassemble. Locals decl is unchanged (caller already ran
    // injectPreservationLocal); just rebuild around the larger inst body.
    const decl_size = layout.inst_start - layout.body_start;
    const decls = wasm[layout.body_start .. layout.body_start + decl_size];
    const new_body_content_size = decls.len + new_inst.items.len;
    return try rebuildWasm(
        allocator,
        wasm,
        layout,
        decls,
        new_inst.items,
        new_body_content_size,
        0, // unused — caller only consumes []u8 here
    );
}

// ── Phase 4 — `injectGuard` (11.0e) ────────────────────────────────────────

/// Synthesize and splice a bounds-check guard at `witness.body_offset_of_store`
/// in `func_idx`'s instruction body. The guard uses `pristine_local` as
/// the saved alloc_base. Math + auditor flag are documented at file top;
/// see the AUDITOR FLAG block for why this deviates from the directive's
/// literal byte sequence.
///
/// The caller is responsible for ensuring `witness.body_offset_of_store`
/// is correct WITH RESPECT TO THE PASSED wasm bytes — i.e., already
/// shifted to account for any `local.tee` previously injected by
/// cloneAllocBase. The orchestrator `applyAll` handles that bookkeeping.
pub fn injectGuard(
    allocator: std.mem.Allocator,
    wasm: []const u8,
    func_idx: u32,
    witness: phase10.StoreWitness,
    pristine_local: u32,
) WeaverError![]u8 {
    if (witness.alloc_size < witness.width) return error.AllocSizeBelowWidth;

    const layout = try findFuncLayout(allocator, wasm, func_idx);
    const inst_len = (layout.body_start + layout.body_size_value) - layout.inst_start;
    const inst_bytes = wasm[layout.inst_start .. layout.inst_start + inst_len];

    if (witness.body_offset_of_store > inst_bytes.len) return error.UnexpectedEof;

    const guard = try synthesizeGuardBytes(allocator, witness, pristine_local);
    defer allocator.free(guard);

    var new_inst = std.ArrayList(u8).init(allocator);
    defer new_inst.deinit();
    try new_inst.appendSlice(inst_bytes[0..witness.body_offset_of_store]);
    try new_inst.appendSlice(guard);
    try new_inst.appendSlice(inst_bytes[witness.body_offset_of_store..]);

    const decl_size = layout.inst_start - layout.body_start;
    const decls = wasm[layout.body_start .. layout.body_start + decl_size];
    const new_body_content_size = decls.len + new_inst.items.len;
    return try rebuildWasm(
        allocator,
        wasm,
        layout,
        decls,
        new_inst.items,
        new_body_content_size,
        0,
    );
}

/// Pure function: produce the guard byte sequence for the corrected
/// (i32.sub-based) pattern. Math:
///
///     offset_in_buffer = local[addr_local] - local[pristine_local]
///                                          + addr_const_offset
///     OOB              ⇔ offset_in_buffer > (alloc_size - width)
///
/// Bytes:
///
///     0x20 <uleb addr_local>           ;; local.get addr_local
///     0x20 <uleb pristine_local>       ;; local.get pristine_local
///     0x6b                             ;; i32.sub
///     [ 0x41 <sleb addr_const_offset>  ;; i32.const  (if offset != 0)
///       0x6a ]                         ;; i32.add    (if offset != 0)
///     0x41 <sleb (alloc_size - width)> ;; i32.const max_safe_offset
///     0x4b                             ;; i32.gt_u
///     0x04 0x40                        ;; if 0x40
///     0x00                             ;; unreachable
///     0x0b                             ;; end
pub fn synthesizeGuardBytes(
    allocator: std.mem.Allocator,
    witness: phase10.StoreWitness,
    pristine_local: u32,
) WeaverError![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.append(Op.local_get);
    try writeUlebI32(&buf, witness.addr_local);
    try buf.append(Op.local_get);
    try writeUlebI32(&buf, pristine_local);
    try buf.append(Op.i32_sub);

    if (witness.addr_const_offset != 0) {
        try buf.append(Op.i32_const);
        // SLEB32 of a u32 — safe cast because addr_const_offset < 2^31
        // for any meaningful buffer offset in our fixtures.
        try writeSlebI32(&buf, @as(i32, @intCast(witness.addr_const_offset)));
        try buf.append(Op.i32_add);
    }

    try buf.append(Op.i32_const);
    const max_safe: i32 = @as(i32, @intCast(witness.alloc_size - witness.width));
    try writeSlebI32(&buf, max_safe);
    try buf.append(Op.i32_gt_u);
    try buf.append(Op.if_);
    try buf.append(BlockType.void_);
    try buf.append(Op.unreachable_);
    try buf.append(Op.end);

    return try buf.toOwnedSlice();
}

// ── Wasm rebuild ───────────────────────────────────────────────────────────

/// Reassemble a Wasm module after a single function body has been
/// modified. Copies all bytes before the Code Section verbatim, re-emits
/// the Code Section header with a 5-byte max-width section_size ULEB,
/// re-emits the per-function body_size as 5-byte max-width ULEB for the
/// modified function (other functions are copied verbatim including
/// their original-width body_size encodings), and copies all bytes after
/// the Code Section verbatim.
///
/// `new_decl_bytes` and `new_inst_bytes` are the modified function's
/// post-edit locals decl and instruction bytes. `new_body_content_size`
/// must equal `new_decl_bytes.len + new_inst_bytes.len` — passed
/// separately to make the math intent visible at the call site.
///
/// The 4th positional argument `new_local_idx_unused` was a placeholder
/// for `injectPreservationLocal`'s return; kept for now to keep the
/// signature stable across callers but ignored in the rebuild itself.
fn rebuildWasm(
    allocator: std.mem.Allocator,
    wasm: []const u8,
    layout: FuncLayout,
    new_decl_bytes: []const u8,
    new_inst_bytes: []const u8,
    new_body_content_size: usize,
    new_local_idx_unused: u32,
) WeaverError![]u8 {
    _ = new_local_idx_unused;

    // Read the Code Section's function count ULEB so we can preserve it.
    const content_start = layout.code_section_size_off + layout.code_section_size_width;
    const n_funcs = try readUleb32(wasm, content_start);
    var p = content_start + n_funcs.len;

    // Per-function: walk the original bodies. For func_idx == TARGET we
    // emit a new body_size (5-byte) + new content. For others we copy.
    var new_code_content = std.ArrayList(u8).init(allocator);
    defer new_code_content.deinit();
    try writeUlebI32(&new_code_content, n_funcs.value);

    var fi: u32 = 0;
    while (fi < n_funcs.value) : (fi += 1) {
        const bs = try readUleb32(wasm, p);
        const body_off = p + bs.len;
        const body_end = body_off + bs.value;

        if (p == layout.body_size_off) {
            // Target function — emit new body with 5-byte body_size.
            var size_buf: [5]u8 = undefined;
            writeUleb5(&size_buf, @as(u32, @intCast(new_body_content_size)));
            try new_code_content.appendSlice(&size_buf);
            try new_code_content.appendSlice(new_decl_bytes);
            try new_code_content.appendSlice(new_inst_bytes);
        } else {
            // Copy verbatim (includes original body_size ULEB).
            try new_code_content.appendSlice(wasm[p..body_end]);
        }
        p = body_end;
    }

    // Assemble the full new .wasm.
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    // 1. Bytes before Code Section's id byte.
    try out.appendSlice(wasm[0..layout.code_section_start]);
    // 2. Code Section id.
    try out.append(0x0a);
    // 3. New section_size as 5-byte ULEB.
    var sec_size_buf: [5]u8 = undefined;
    writeUleb5(&sec_size_buf, @as(u32, @intCast(new_code_content.items.len)));
    try out.appendSlice(&sec_size_buf);
    // 4. Code Section content.
    try out.appendSlice(new_code_content.items);
    // 5. Bytes after the original Code Section.
    try out.appendSlice(wasm[layout.code_section_end..]);

    return try out.toOwnedSlice();
}

// ── Orchestrator ───────────────────────────────────────────────────────────

/// Apply the full Phase 11.0c–e pipeline in one call. The three public
/// functions above are exposed for auditability; production callers
/// should typically use `applyAll`, which (a) deduplicates witnesses by
/// body_offset, (b) handles the body-offset shift caused by the
/// `local.tee` injection, and (c) processes guards in descending
/// body-offset order so earlier offsets are not invalidated by later
/// splices.
pub fn applyAll(
    allocator: std.mem.Allocator,
    wasm_in: []const u8,
    func_idx: u32,
    allocator_func_idx: u32,
    witnesses_in: []const phase10.StoreWitness,
) WeaverError![]u8 {
    // (c) Register the preservation local.
    const preserve = try injectPreservationLocal(allocator, wasm_in, func_idx);
    defer allocator.free(preserve.new_wasm);
    const pristine_local = preserve.new_local_idx;

    // (d) Clone alloc_base post-call.
    const after_clone = try cloneAllocBase(
        allocator,
        preserve.new_wasm,
        func_idx,
        allocator_func_idx,
        pristine_local,
    );
    defer allocator.free(after_clone);

    // Compute the local.tee byte length so we can shift downstream
    // witness offsets. tee = 0x22 + ULEB(pristine_local); for pristine
    // < 128 that's 2 bytes.
    var tee_buf = std.ArrayList(u8).init(allocator);
    defer tee_buf.deinit();
    try tee_buf.append(Op.local_tee);
    try writeUlebI32(&tee_buf, pristine_local);
    const tee_len: usize = tee_buf.items.len;

    // Find the allocator call's pre-shift body-offset so we know which
    // witnesses to shift.
    const alloc_call_end_pre = try findAllocatorCallEnd(allocator, preserve.new_wasm, func_idx, allocator_func_idx);

    // Dedup witnesses by body_offset_of_store and shift those AFTER the
    // allocator call by tee_len.
    var seen = std.AutoArrayHashMap(usize, void).init(allocator);
    defer seen.deinit();
    var shifted = std.ArrayList(phase10.StoreWitness).init(allocator);
    defer shifted.deinit();
    for (witnesses_in) |w| {
        if (w.func_idx != func_idx) continue;
        if (seen.contains(w.body_offset_of_store)) continue;
        try seen.put(w.body_offset_of_store, {});
        var w2 = w;
        if (w.body_offset_of_store >= alloc_call_end_pre) {
            w2.body_offset_of_store += tee_len;
        }
        try shifted.append(w2);
    }

    // Sort descending by body_offset_of_store so splices don't invalidate
    // earlier offsets in subsequent passes.
    std.mem.sort(phase10.StoreWitness, shifted.items, {}, struct {
        fn lt(_: void, a: phase10.StoreWitness, b: phase10.StoreWitness) bool {
            return a.body_offset_of_store > b.body_offset_of_store;
        }
    }.lt);

    // (e) Splice guards.
    var current = try allocator.dupe(u8, after_clone);
    for (shifted.items) |w| {
        const next = try injectGuard(allocator, current, func_idx, w, pristine_local);
        allocator.free(current);
        current = next;
    }
    return current;
}

/// Helper that returns the body-offset of the first byte AFTER the
/// allocator's `call` instruction. Shared logic with `cloneAllocBase`'s
/// scanner; factored so `applyAll` can compute the shift threshold
/// before calling `cloneAllocBase`.
fn findAllocatorCallEnd(
    allocator: std.mem.Allocator,
    wasm: []const u8,
    func_idx: u32,
    allocator_func_idx: u32,
) WeaverError!usize {
    const layout = try findFuncLayout(allocator, wasm, func_idx);
    const inst_len = (layout.body_start + layout.body_size_value) - layout.inst_start;
    const inst_bytes = wasm[layout.inst_start .. layout.inst_start + inst_len];
    var pos: usize = 0;
    while (pos < inst_bytes.len) {
        const op = inst_bytes[pos];
        pos += 1;
        if (op == Op.call) {
            const callee = try readUleb32(inst_bytes, pos);
            pos += callee.len;
            if (callee.value == allocator_func_idx) return pos;
        } else {
            try skipImmediates(inst_bytes, &pos, op);
        }
    }
    return error.AllocatorCallNotFound;
}
