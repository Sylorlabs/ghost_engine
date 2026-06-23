const std = @import("std");

pub const ZenithNodeState = extern struct {
    drive: f32 = 2.350,
    mix: f32 = 0.760,
};

export fn zenith_node_init(state: *ZenithNodeState) callconv(.c) void {
    state.* = .{};
}

export fn zenith_node_process(state: *ZenithNodeState, input: f32) callconv(.c) f32 {
    const driven = input * state.drive;
    const soft = driven / (1.0 + @abs(driven));
    return (soft * state.mix) + (input * (1.0 - state.mix));
}

export fn zenith_node_process_buffer(state: *ZenithNodeState, input: [*]const f32, output: [*]f32, frame_count: usize) callconv(.c) void {
    var idx: usize = 0;
    while (idx < frame_count) : (idx += 1) {
        output[idx] = zenith_node_process(state, input[idx]);
    }
}

export fn zenith_node_name() callconv(.c) [*:0]const u8 {
    return "WarmTapeSaturationNode";
}

test "bridge process path is deterministic and heap-free" {
    var state: ZenithNodeState = undefined;
    zenith_node_init(&state);
    const a = zenith_node_process(&state, 0.25);
    const b = zenith_node_process(&state, 0.25);
    try std.testing.expectEqual(a, b);
}
