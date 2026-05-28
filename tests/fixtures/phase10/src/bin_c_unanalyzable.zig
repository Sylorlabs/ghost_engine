//! Phase 10 fixture C — UNANALYZABLE (negative control).
//!
//! Semantically identical to A — `mask` is fed from the host as 0, so
//! `(base ^ mask)` is value-equal to `base`. But Spec v3 R3(b) declares XOR on
//! an alloc-provenanced value to be provenance-breaking by policy; the analyzer
//! must REFUSE to emit a Z3 query for the store at all, returning
//! UNANALYZABLE. A "lucky" analyzer that confidently answers SAT or UNSAT on C
//! is broken regardless of what it does on A and B.

extern fn dummy_alloc(size: u32) [*]u8;
extern fn opaque_idx_seed() u32;
extern fn opaque_xor_mask() u32;

export fn f() void {
    const base = dummy_alloc(8);
    const seed = opaque_idx_seed();
    const mask = opaque_xor_mask();
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const idx = i +% seed;
        const tainted_addr = @intFromPtr(base + idx * 4) ^ mask;
        const p: *u32 = @ptrFromInt(tainted_addr);
        p.* = i;
    }
}
