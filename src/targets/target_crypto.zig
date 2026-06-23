const std = @import("std");

// Unused noise structure
const CryptoContext = struct {
    entropy: u64,
    flags: u32,
};

// Noisy wrapper function
pub fn initContext(seed: u64) CryptoContext {
    return CryptoContext{
        .entropy = seed ^ 0xDEADBEEF,
        .flags = 1,
    };
}

/// The classic ChaCha20 quarter-round, injected with un-optimized syntax
/// and structural noise to test VSA cartographer pass-through.
pub fn quarterRound(a: u64, b: u64, c: u64, d: u64) [4]u64 {
    // Noise variables
    var noise_flag: u64 = 0;
    _ = noise_flag;

    var a_reg = a;
    var b_reg = b;
    var c_reg = c;
    var d_reg = d;

    // ARX Block 1
    a_reg +%= b_reg;
    d_reg ^= a_reg;
    d_reg = (d_reg << 16) | (d_reg >> (64 - 16));

    // Noise
    const dummy_math = a_reg & 0xFF;
    _ = dummy_math;

    // ARX Block 2
    c_reg +%= d_reg;
    b_reg ^= c_reg;
    b_reg = (b_reg << 12) | (b_reg >> (64 - 12));

    // More Noise
    noise_flag = 1;

    // ARX Block 3
    a_reg +%= b_reg;
    d_reg ^= a_reg;
    d_reg = (d_reg << 8) | (d_reg >> (64 - 8));

    // ARX Block 4
    c_reg +%= d_reg;
    b_reg ^= c_reg;
    b_reg = (b_reg << 7) | (b_reg >> (64 - 7));

    return [_]u64{ a_reg, b_reg, c_reg, d_reg };
}
