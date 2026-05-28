//! Phase 10 acceptance harness.
//!
//! Runs the Provenance Tracker against three fixtures and asserts the
//! three-row table from Spec v3 §Phase 3.
//!
//!   ┌───────────────────┬─────────────────────────┬─────────────────────────┐
//!   │ Binary            │ Expected analyzer state │ Expected Z3 result      │
//!   ├───────────────────┼─────────────────────────┼─────────────────────────┤
//!   │ A (vulnerable)    │ analyzes successfully   │ SAT  (overflow witness) │
//!   │ B (safe-by-guard) │ analyzes successfully   │ UNSAT                   │
//!   │ C (xor-aliased)   │ UNANALYZABLE            │ (no Z3 query emitted)   │
//!   └───────────────────┴─────────────────────────┴─────────────────────────┘
//!
//! Exit code: 0 iff all three rows match; 1 otherwise.

const std = @import("std");
const prov = @import("phase10_provenance.zig");

const BIN_A = @embedFile("bin_a_vulnerable.wasm");
const BIN_B = @embedFile("bin_b_safe.wasm");
const BIN_C = @embedFile("bin_c_unanalyzable.wasm");
// Phase 9.1 fixture — same bytes the frozen baseline embeds. Passing it
// through the Phase 10 analyzer proves the substrate boundary: wprobe.wasm
// has no env.dummy_alloc import, so R2 must fire MissingAllocatorContract
// rather than silently mis-analyzing a Phase 9.1 binary as Phase 10 input.
const BIN_D_PHASE9 = @embedFile("wprobe.wasm");
// Phase 10.2b — multi-argument allocator fixture. Imports pool_alloc(alignment,
// size) where size is at arg index 1. Proves size_arg_index routing works: the
// engine skips alignment (index 0) and extracts the i32.const 16 size literal.
const BIN_F_POOL = @embedFile("bin_f_aligned_alloc.wasm");

// Phase 10.2 — pluggable allocator. The harness chooses the contract; the
// analyzer no longer hard-codes any allocator name. Swap `ALLOC_CFG` to
// `{ .name = "malloc", .kind = .export_, .size_arg_index = 0 }` to point
// the engine at a wasm module that exports its own allocator. Keep one
// AllocatorConfig per fixture if their conventions differ.
const ALLOC_CFG = prov.AllocatorConfig{
    .name = "dummy_alloc",
    .kind = .import_,
    .module = "env",
    .size_arg_index = 0,
};
// Negative control for row E (5th row): a deliberately-wrong config. The
// analyzer should return UNANALYZABLE/MissingAllocatorContract for ANY
// fixture, regardless of its bytecode, because no such import exists.
const ALLOC_CFG_WRONG = prov.AllocatorConfig{
    .name = "nonexistent_alloc",
    .kind = .import_,
    .module = "env",
    .size_arg_index = 0,
};
// Row F config — multi-argument allocator. pool_alloc(alignment, size) where
// size lives at arg index 1. The engine must skip args[0] (alignment=8) and
// parse args[1] (size=16) to emit the correct 16-byte bounds obligation.
const ALLOC_CFG_POOL = prov.AllocatorConfig{
    .name = "pool_alloc",
    .kind = .import_,
    .module = "env",
    .size_arg_index = 1,
};

const Expected = struct {
    label: []const u8,
    bytes: []const u8,
    cfg: prov.AllocatorConfig,
    expect_analyzes: bool,
    expect_z3: ?prov.Verdict, // null iff expect_analyzes == false
    expect_reason_contains: ?[]const u8 = null, // optional substring check on UNANALYZABLE reason
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    std.debug.print("=== GHOST ENGINE: Phase 10 — Provenance Tracker ===\n\n", .{});
    std.debug.print(
        "Spec v3 acceptance: three fixtures × {{analyzer state, Z3 verdict}}.\n" ++
            "Allocator contract: env.dummy_alloc recognized by import name (R2).\n" ++
            "Loop unroll bound: k = 3 (R5). Single-allocation per function (R6).\n\n",
        .{},
    );

    const cases = [_]Expected{
        .{ .label = "A (vulnerable)    ", .bytes = BIN_A, .cfg = ALLOC_CFG, .expect_analyzes = true, .expect_z3 = .sat },
        .{ .label = "B (safe-by-guard) ", .bytes = BIN_B, .cfg = ALLOC_CFG, .expect_analyzes = true, .expect_z3 = .unsat },
        .{ .label = "C (xor-aliased)   ", .bytes = BIN_C, .cfg = ALLOC_CFG, .expect_analyzes = false, .expect_z3 = null, .expect_reason_contains = "tainted-provenance" },
        // Phase 10.1 — substrate-boundary control. Phase 9.1's wprobe.wasm has
        // no env.dummy_alloc import; R2 (named-allocator contract) must REFUSE.
        .{ .label = "D (phase9 wprobe) ", .bytes = BIN_D_PHASE9, .cfg = ALLOC_CFG, .expect_analyzes = false, .expect_z3 = null, .expect_reason_contains = "MissingAllocatorContract" },
        // Phase 10.2 — config-layer control. Binary A with a wrong allocator
        // name. Proves R2's import scan is driven by the config, not a hard-
        // coded literal — any change would silently fold this row into row A's
        // pass without surfacing the regression.
        .{ .label = "E (wrong cfg on A)", .bytes = BIN_A, .cfg = ALLOC_CFG_WRONG, .expect_analyzes = false, .expect_z3 = null, .expect_reason_contains = "MissingAllocatorContract" },
        // Phase 10.2b — multi-argument allocator. pool_alloc(alignment=8, size=16)
        // where size is at arg index 1. The engine must extract the i32.const 16
        // literal from args[1], model a 16-byte buffer, and return SAT when the
        // loop store at offset seed*4+8 (iter 3, seed>=2) escapes the buffer.
        .{ .label = "F (pool_alloc/2arg) ", .bytes = BIN_F_POOL, .cfg = ALLOC_CFG_POOL, .expect_analyzes = true, .expect_z3 = .sat },
    };

    var all_pass = true;
    for (cases) |cs| {
        std.debug.print("--- {s} ---\n", .{cs.label});
        std.debug.print("  bytes      = {d}\n", .{cs.bytes.len});

        std.debug.print("  cfg        = {s} '{s}' (module={s}, size_arg={d})\n", .{
            switch (cs.cfg.kind) {
                .import_ => "import",
                .export_ => "export",
            },
            cs.cfg.name,
            cs.cfg.module orelse "<any>",
            cs.cfg.size_arg_index,
        });
        const result = prov.analyze(a, cs.bytes, cs.cfg) catch |e| {
            std.debug.print("  PARSE ERR  = {s}\n", .{@errorName(e)});
            all_pass = false;
            continue;
        };

        std.debug.print("  state      = {s}\n", .{@tagName(result.state)});
        std.debug.print("  loop k     = {d}\n", .{result.unroll_k});
        std.debug.print("  store sites= {d}\n", .{result.store_sites});

        if (result.state == .unanalyzable) {
            const reason = result.reason orelse "(none)";
            std.debug.print("  reason     = {s}\n", .{reason});
            const state_ok = !cs.expect_analyzes;
            mark("analyzer state matches", state_ok);
            if (!state_ok) all_pass = false;
            if (cs.expect_z3 != null) {
                std.debug.print("  !! expected a Z3 verdict but analyzer refused\n", .{});
                all_pass = false;
            } else {
                mark("no Z3 query emitted (as required)", true);
            }
            if (cs.expect_reason_contains) |needle| {
                const reason_ok = std.mem.indexOf(u8, reason, needle) != null;
                mark("reason cites expected R-rule", reason_ok);
                if (!reason_ok) {
                    std.debug.print("  !! expected reason to contain \"{s}\"\n", .{needle});
                    all_pass = false;
                }
            }
            std.debug.print("\n", .{});
            continue;
        }

        const smt = result.smt orelse "";
        std.debug.print("  SMT query  ({d} bytes):\n", .{smt.len});
        printIndented(smt, "    ");

        const verdict = prov.runZ3(a, smt);
        std.debug.print("  Z3 verdict = {s}\n", .{prov.verdictWord(verdict)});

        const state_ok = cs.expect_analyzes;
        const verdict_ok = if (cs.expect_z3) |ev| verdict == ev else false;
        mark("analyzer state matches", state_ok);
        mark("Z3 verdict matches", verdict_ok);
        if (!state_ok or !verdict_ok) all_pass = false;
        std.debug.print("\n", .{});
    }

    std.debug.print("=== {s}: Phase 10 acceptance test ===\n", .{if (all_pass) "PASS" else "FAIL"});
    if (!all_pass) std.process.exit(1);
}

fn mark(label: []const u8, ok: bool) void {
    const tag = if (ok) "OK " else "!! ";
    std.debug.print("  [{s}] {s}\n", .{ tag, label });
}

fn printIndented(s: []const u8, indent: []const u8) void {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| std.debug.print("{s}{s}\n", .{ indent, line });
}
