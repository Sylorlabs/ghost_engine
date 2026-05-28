//! Phase 10 fixture H — I64 POISON PILL.
//!
//! Forces an i64 opcode (`i64.const` / `i64.add`) inside the function so the
//! engine must refuse with `I64TheoryUnsupported` rather than truncate to i32
//! and silently mis-model the arithmetic. The return type is `u64` so LLVM
//! cannot DCE the i64 work; the allocator import keeps R2 from firing first.

extern fn dummy_alloc(size: u32) [*]u8;
extern fn opaque_idx_seed() u32;

export fn f() u64 {
    const buf = dummy_alloc(8);
    _ = buf;
    const x: u64 = @as(u64, opaque_idx_seed());
    return x +% 0xCAFEBABE_DEADBEEF; // i64.add with i64.const → poison pill
}
