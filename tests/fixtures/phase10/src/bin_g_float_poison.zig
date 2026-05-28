//! Phase 10 fixture G — FLOAT POISON PILL.
//!
//! Forces the engine to encounter an f32 opcode (`f32.mul` or similar) inside
//! a function. The analyzer must refuse with reason `FloatTheoryUnsupported`
//! and emit zero Z3 queries — NOT silently lower the float to a junk SMT term.
//!
//! `dummy_alloc` is still imported so the allocator contract resolves (otherwise
//! the row would short-circuit on MissingAllocatorContract before ever reaching
//! the float opcode). We return the f32 to keep LLVM from DCE'ing the math.

extern fn dummy_alloc(size: u32) [*]u8;
extern fn opaque_idx_seed() u32;

export fn f() f32 {
    const buf = dummy_alloc(8);
    _ = buf;
    const x: f32 = @floatFromInt(opaque_idx_seed());
    return x * 2.0; // f32.mul → poison pill
}
