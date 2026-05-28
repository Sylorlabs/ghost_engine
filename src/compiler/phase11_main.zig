//! Phase 11 — end-to-end CEGIS loop.
//!
//! Detect → Patch → Persist → Verify on bin_a_vulnerable.wasm.
//!
//!   1. Detect:  prov.analyze(BIN_A) → expect state=.analyzes, Z3=SAT,
//!               len(witnesses) >= 1.
//!   2. Patch:   weaver.applyAll(BIN_A, func_idx=0, alloc_func_idx, witnesses).
//!   3. Persist: write the resulting bytes to bin_a_repaired.wasm on disk.
//!   4. Verify:  re-read the file, run prov.analyze again, require
//!               state=.analyzes AND Z3=UNSAT for the combined query AND
//!               UNSAT for every per-witness query.
//!
//! Exit code 0 iff the full SAT→Patch→UNSAT sequence is observed.
//! Per-rule: NO "Patch Successful" gets printed unless step 4 truly
//! returned UNSAT against Z3 on bytes round-tripped through the disk.

const std = @import("std");
const prov = @import("phase10_provenance.zig");
const weaver = @import("phase11_weaver.zig");

const BIN_A = @embedFile("bin_a_vulnerable.wasm");

const ALLOC_CFG = prov.AllocatorConfig{
    .name = "dummy_alloc",
    .kind = .import_,
    .module = "env",
    .size_arg_index = 0,
};

const REPAIRED_PATH = "src/compiler/bin_a_repaired.wasm";

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    std.debug.print("=== GHOST ENGINE Phase 11 — CEGIS loop on bin_a_vulnerable.wasm ===\n\n", .{});

    // ────────────────────────────────────────────────────────────────────
    // Step 1: Detect.
    // ────────────────────────────────────────────────────────────────────
    std.debug.print("--- Step 1: DETECT (analyze original bytes) ---\n", .{});
    std.debug.print("  input bytes = {d}\n", .{BIN_A.len});

    const r1 = try prov.analyze(a, BIN_A, ALLOC_CFG);
    if (r1.state != .analyzes) {
        std.debug.print("  !! analyzer state = {s}, reason = {s}\n", .{
            @tagName(r1.state),
            r1.reason orelse "(none)",
        });
        return error.Step1NotAnalyzes;
    }
    std.debug.print("  analyzer state = {s}\n", .{@tagName(r1.state)});
    std.debug.print("  store sites    = {d}\n", .{r1.store_sites});
    std.debug.print("  witnesses      = {d}\n", .{r1.witnesses.len});

    if (r1.witnesses.len == 0) {
        std.debug.print("  !! expected at least one StoreWitness — Weaver has nothing to repair\n", .{});
        return error.Step1NoWitnesses;
    }

    const v1 = prov.runZ3(a, r1.smt orelse "");
    std.debug.print("  Z3 verdict     = {s}\n", .{prov.verdictWord(v1)});
    if (v1 != .sat) {
        std.debug.print("  !! expected SAT (vulnerable). Aborting before any patch.\n", .{});
        return error.Step1NotSat;
    }

    const alloc_idx = r1.allocator_func_idx orelse {
        std.debug.print("  !! analyzer did not return an allocator_func_idx\n", .{});
        return error.Step1NoAllocIdx;
    };
    std.debug.print("  allocator idx  = {d} (global func index)\n", .{alloc_idx});

    for (r1.witnesses, 0..) |w, i| {
        std.debug.print(
            "  witness[{d}]: func={d} body_off=0x{x} addr_local={d} const_off={d} width={d} size={d}\n",
            .{ i, w.func_idx, w.body_offset_of_store, w.addr_local, w.addr_const_offset, w.width, w.alloc_size },
        );
    }
    std.debug.print("\n", .{});

    // ────────────────────────────────────────────────────────────────────
    // Step 2: Patch.
    // ────────────────────────────────────────────────────────────────────
    std.debug.print("--- Step 2: PATCH (Weaver: preamble surgery + guard injection) ---\n", .{});
    const patched = try weaver.applyAll(a, BIN_A, 0, alloc_idx, r1.witnesses);
    std.debug.print("  input bytes    = {d}\n", .{BIN_A.len});
    std.debug.print("  patched bytes  = {d}  (Δ = {d})\n", .{ patched.len, @as(i64, @intCast(patched.len)) - @as(i64, @intCast(BIN_A.len)) });
    std.debug.print("\n", .{});

    // ────────────────────────────────────────────────────────────────────
    // Step 3: Persist.
    // ────────────────────────────────────────────────────────────────────
    std.debug.print("--- Step 3: PERSIST (write to disk) ---\n", .{});
    {
        const f = try std.fs.cwd().createFile(REPAIRED_PATH, .{ .truncate = true });
        defer f.close();
        try f.writeAll(patched);
    }
    std.debug.print("  wrote          = {s}\n", .{REPAIRED_PATH});
    std.debug.print("\n", .{});

    // ────────────────────────────────────────────────────────────────────
    // Step 4: Verify.
    //
    // Round-trip through the disk: read the freshly-written file back so
    // we're verifying against the BYTES THAT WERE PERSISTED, not against
    // an in-memory buffer that might differ from what got written.
    // ────────────────────────────────────────────────────────────────────
    std.debug.print("--- Step 4: VERIFY (re-analyze patched bytes) ---\n", .{});
    const f2 = try std.fs.cwd().openFile(REPAIRED_PATH, .{});
    defer f2.close();
    const stat = try f2.stat();
    const repaired_bytes = try a.alloc(u8, stat.size);
    const n_read = try f2.readAll(repaired_bytes);
    if (n_read != stat.size) return error.Step4ShortRead;
    std.debug.print("  read bytes     = {d}\n", .{repaired_bytes.len});

    const r2 = try prov.analyze(a, repaired_bytes, ALLOC_CFG);
    if (r2.state != .analyzes) {
        std.debug.print("  !! patched binary did not analyze: state={s} reason={s}\n", .{
            @tagName(r2.state),
            r2.reason orelse "(none)",
        });
        return error.Step4NotAnalyzes;
    }
    std.debug.print("  analyzer state = {s}\n", .{@tagName(r2.state)});
    std.debug.print("  store sites    = {d}\n", .{r2.store_sites});
    std.debug.print("  witnesses      = {d}\n", .{r2.witnesses.len});

    const v2 = prov.runZ3(a, r2.smt orelse "");
    std.debug.print("  Z3 verdict     = {s}  (combined)\n", .{prov.verdictWord(v2)});

    // Per-witness verdicts must ALSO all be UNSAT for the patch to be
    // considered sound — the combined verdict could in principle hide a
    // residual SAT under a disjunction collapse, although in practice
    // Z3 wouldn't do that. Belt and suspenders.
    var per_witness_any_sat = false;
    var per_witness_all_unsat = true;
    for (r2.per_witness_smts, 0..) |wsmt, wi| {
        const wv = prov.runZ3(a, wsmt);
        std.debug.print("    per-witness[{d}] = {s}\n", .{ wi, prov.verdictWord(wv) });
        if (wv == .sat) per_witness_any_sat = true;
        if (wv != .unsat) per_witness_all_unsat = false;
    }

    if (v2 != .unsat) {
        std.debug.print("  !! expected UNSAT after repair. Combined verdict = {s}\n", .{prov.verdictWord(v2)});
        return error.Step4CombinedNotUnsat;
    }
    if (per_witness_any_sat) {
        std.debug.print("  !! some per-witness query is still SAT after repair\n", .{});
        return error.Step4PerWitnessSat;
    }
    if (!per_witness_all_unsat) {
        std.debug.print("  !! some per-witness query is not UNSAT (got UNKNOWN/ERR)\n", .{});
        return error.Step4PerWitnessNotUnsat;
    }

    std.debug.print("\n=== CEGIS LOOP CLOSED: original=SAT → repaired=UNSAT ===\n", .{});
    std.debug.print("    bytes round-tripped through {s}\n", .{REPAIRED_PATH});
}
