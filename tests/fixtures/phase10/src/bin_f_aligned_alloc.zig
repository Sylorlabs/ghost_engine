//! Phase 10 fixture F — VULNERABLE, multi-argument allocator.
//!
//! This fixture proves that `AllocatorConfig.size_arg_index = 1` works: the
//! engine skips the alignment argument (index 0) and extracts size (index 1).
//!
//! The allocator is `env.pool_alloc(alignment: u32, size: u32) -> [*]u8` —
//! a two-argument allocator where size lives at arg index 1.
//! Called as `pool_alloc(8, 16)`, giving a 16-byte buffer. The loop stores
//! 4 bytes per iteration at offset `idx*4` where `idx = i + seed`. With
//! seed >= 2 and i=2 (3rd k=3 unroll): offset = 4*4 = 16 → 16+4 > 16.
//!
//! Note: "aligned_alloc" is a known libc symbol — LLVM applies aliasing-based
//! DCE to it even in freestanding mode. We use `pool_alloc` to get the same
//! (alignment, size) calling convention without triggering that optimization.
//!
//! Expected analyzer result: SAT (Z3 finds seed=2, i=2 overflows).

extern fn pool_alloc(pool_alignment: u32, size: u32) [*]u8;
extern fn opaque_idx_seed() u32;

export fn f() void {
    const base = pool_alloc(8, 16); // pool_alignment=8, size=16; size_arg_index=1
    const seed = opaque_idx_seed();
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const idx = i +% seed;
        const p: *u32 = @ptrCast(@alignCast(base + idx * 4));
        p.* = i;
    }
}
