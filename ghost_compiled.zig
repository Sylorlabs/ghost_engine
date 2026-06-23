const std = @import("std");

/// ---------------------------------------------------------------------------
/// THE WILD: Comptime Metaprogramming & Type Reflection
/// ---------------------------------------------------------------------------

pub fn OpaqueHandle(comptime T: type) type {
    return packed struct {
        ptr: *opaque {},
        meta: usize,
        
        pub fn cast(self: @This()) *T {
            return @ptrCast(@alignCast(self.ptr));
        }
    };
}

pub const SystemMatrix = OpaqueHandle([4][4]f32);

pub fn computeResonance(comptime Dims: usize, matrix: *const [Dims][Dims]f32) f32 {
    comptime var acc: f32 = 0.0;
    inline for (0..Dims) |i| {
        inline for (0..Dims) |j| {
            acc += matrix[i][j];
        }
    }
    return acc;
}

/// ---------------------------------------------------------------------------
/// THE WILD: SIMD Vectors & Advanced Memory Mapping
/// ---------------------------------------------------------------------------

pub const SimdVector = @Vector(16, f32);

pub fn apply_gravitational_shear(vec: SimdVector, scalar: f32) SimdVector {
    const splat: SimdVector = @splat(scalar);
    return @mulAdd(SimdVector, vec, splat, vec);
}

pub fn volatile_memory_fence() void {
    asm volatile (
        \\ sfence
        \\ lfence
        ::: "memory"
    );
}

/// ---------------------------------------------------------------------------
/// VULNERABILITY TARGET: Bounds Check
/// ---------------------------------------------------------------------------

// 1. BOUNDS VULNERABILITY
// Hidden deep within the file.
pub fn bounds_vulnerable(a: *[4]u32, i: u32, j: u32) void {
    if (i >= a.len) return; // SYNTHESIZED: Bounds Guard
    if (j >= a.len) return; // SYNTHESIZED: Bounds Guard
    const tmp = a[i];
    a[i] = a[j];
    a[j] = tmp;
}

/// ---------------------------------------------------------------------------
/// THE WILD: Advanced Async / AnyFrame Logic
/// ---------------------------------------------------------------------------

pub fn async_yielding_task() anyframe {
    var frame = async perform_io();
    return &frame;
}

fn perform_io() void {
    suspend {}
}

const EnumMap = enum {
    Alpha,
    Beta,
    Gamma,
};

pub const LookupTable = std.EnumArray(EnumMap, u32);
