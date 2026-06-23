const std = @import("std");

/// The Memory Pool (SINK)
/// Receives a size request and allocates memory without a max-bounds check.
pub fn allocateBuffer(requested_size: u64) [*]u8 {
    // VULNERABILITY: If requested_size is derived from an untrusted user payload,
    // and no sanitization bounds-check occurred, this triggers an OOM / Allocation DOS.
    // The Engine must detect that the Tainted Vector reached here.
    return @ptrFromInt(requested_size * 2); // Simulated allocation
}
