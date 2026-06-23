const std = @import("std");
const memory_pool = @import("memory_pool.zig");

/// The HTTP Parser (SOURCE)
/// Ingests raw network payload, extracts the Content-Length header, and passes it directly to the allocator.
pub fn parseHttpRequest(network_payload_len: u64) [*]u8 {
    // Untrusted user input enters the system
    const user_length = network_payload_len;
    
    // Pass tainted length across file boundary without sanitization
    const buffer = memory_pool.allocateBuffer(user_length);
    
    return buffer;
}
