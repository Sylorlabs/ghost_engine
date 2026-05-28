//! Phase 10 fixture A — VULNERABLE.
//!
//! 8-byte buffer, three 4-byte stores at offsets 0, 4, 8. The store at i=2
//! writes bytes 8..11, escaping the buffer by 4. Expected analyzer result:
//! SAT (the bounds proof finds a counterexample) with a model on i=2.
//!
//! Why the @noInline-via-extern dance: at -OReleaseSmall Zig will eagerly
//! unroll a `while (i < 3)` loop and constant-fold every store offset, so the
//! resulting .wasm contains three independent stores and no loop. That is
//! actually fine for Phase 10 acceptance — provenance + store-bounds are what
//! the spec tests, not loop-unrolling — but we use `opaque_idx_seed` to make
//! the store offsets stay symbolic in the IR rather than constant-folded into
//! literal addresses. The analyzer must still prove the overflow.
//!
//! `dummy_alloc` is declared `extern`, which makes it a wasm IMPORT. The
//! cartographer recognizes the allocator by import name rather than by export
//! scan; this is a faithful equivalent of Spec v3 R2 (named-allocator contract,
//! body never analyzed — imports never have a body to analyze) and lets us
//! avoid plumbing export-section parsing for the spike.

extern fn dummy_alloc(size: u32) [*]u8;
extern fn opaque_idx_seed() u32;

export fn f() void {
    const base = dummy_alloc(8);
    const seed = opaque_idx_seed();
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const idx = i +% seed;
        const p: *u32 = @ptrCast(@alignCast(base + idx * 4));
        p.* = i;
    }
}
