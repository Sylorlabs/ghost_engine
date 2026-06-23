const std = @import("std");

// Pass-through code: Ghost Engine should ignore this completely.
pub fn unknown_inline_asm() void {
    asm volatile ("nop");
}

pub fn some_simd_math(vec: @Vector(4, f32)) @Vector(4, f32) {
    return vec * @as(@Vector(4, f32), @splat(2.0));
}

// 1. BOUNDS VULNERABILITY
// Z3 must catch this and synthesize localized bounds guards.
pub fn bounds_vulnerable(a: *[4]u32, i: u32, j: u32) void {
    const tmp = a[i];
    a[i] = a[j];
    a[j] = tmp;
}

// Pass-through middle layer
pub fn do_nothing() void {}

// 2. ZERO-DIV VULNERABILITY
// Z3 must catch this and synthesize a control guard preventing division by zero.
pub fn zero_div_vulnerable(a: u32, b: u32) u32 {
    return a / b;
}

// 3. UAF VULNERABILITY
// Z3 must track temporal states, see Deref after Free, and synthesize State Reset + Guard.
pub fn uaf_vulnerable() void {
    var ptr = alloc();
    free(ptr);
    deref(ptr);
}
