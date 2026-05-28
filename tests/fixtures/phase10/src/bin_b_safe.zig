//! Phase 10 fixture B — SAFE BY GUARD.
//!
//! Identical to A except each store is guarded by an explicit `idx*4 + 4 <= 8`
//! bounds check. At i=2 the guard 12 <= 8 is false, so the third store does not
//! execute. Expected analyzer result: UNSAT (no path overflows).

extern fn dummy_alloc(size: u32) [*]u8;
extern fn opaque_idx_seed() u32;

export fn f() void {
    const base = dummy_alloc(8);
    const seed = opaque_idx_seed();
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const idx = i +% seed;
        if (idx * 4 + 4 <= 8) {
            const p: *u32 = @ptrCast(@alignCast(base + idx * 4));
            p.* = i;
        }
    }
}
