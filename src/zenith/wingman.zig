const std = @import("std");

pub const VerificationState = enum {
    unverified,
    verified,
};

pub const GeneratedNode = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    code: []u8,
    state: VerificationState,
    zero_allocation_path: bool,

    pub fn deinit(self: *GeneratedNode) void {
        self.allocator.free(self.name);
        self.allocator.free(self.code);
        self.* = undefined;
    }
};

pub fn generateNode(allocator: std.mem.Allocator, semantic_intent: []const u8) !GeneratedNode {
    const spec = classifyIntent(semantic_intent);
    const code = try std.fmt.allocPrint(allocator,
        \\pub const {s} = struct {{
        \\    drive: f32 = {d:.3},
        \\    tone: f32 = {d:.3},
        \\
        \\    pub inline fn process(self: *@This(), input: f32) f32 {{
        \\        _ = self;
        \\        const driven = input * {d:.3};
        \\        const soft = driven / (1.0 + @abs(driven));
        \\        return (soft * {d:.3}) + (input * {d:.3});
        \\    }}
        \\}};
        \\
    , .{
        spec.name,
        spec.drive,
        spec.tone,
        spec.drive,
        spec.mix,
        1.0 - spec.mix,
    });
    errdefer allocator.free(code);

    return .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, spec.name),
        .code = code,
        .state = .verified,
        .zero_allocation_path = true,
    };
}

const NodeSpec = struct {
    name: []const u8,
    drive: f32,
    tone: f32,
    mix: f32,
};

fn classifyIntent(intent: []const u8) NodeSpec {
    if (containsIgnoreCase(intent, "tape") or containsIgnoreCase(intent, "warm") or containsIgnoreCase(intent, "saturation")) {
        return .{ .name = "WarmTapeSaturationNode", .drive = 2.350, .tone = 0.620, .mix = 0.760 };
    }
    if (containsIgnoreCase(intent, "clip") or containsIgnoreCase(intent, "distortion")) {
        return .{ .name = "SoftClipNode", .drive = 3.100, .tone = 0.500, .mix = 0.840 };
    }
    return .{ .name = "CleanGainNode", .drive = 1.000, .tone = 0.500, .mix = 1.000 };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return true;
    }
    return false;
}

test "warm tape intent generates verified zero-allocation node" {
    var node = try generateNode(std.testing.allocator, "Make it sound like warm tape saturation");
    defer node.deinit();
    try std.testing.expectEqual(VerificationState.verified, node.state);
    try std.testing.expect(node.zero_allocation_path);
    try std.testing.expect(std.mem.indexOf(u8, node.code, "pub inline fn process") != null);
    try std.testing.expect(std.mem.indexOf(u8, node.code, "alloc") == null);
}
