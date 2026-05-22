const std = @import("std");
const absolute = @import("absolute_final");

const ProbeMode = enum { trained, contextual };

const Pair = struct {
    label: []const u8,
    a: []const u8,
    b: []const u8,
};

fn signature(core: *absolute.AbsoluteCore, snapshot: []const u64, text: []const u8, mode: ProbeMode) u64 {
    @memcpy(core.field, snapshot);
    const report = switch (mode) {
        .trained => core.ingestSemanticTrained(text),
        .contextual => core.ingestContextualized(text),
    };
    return core.field[report.dominant_edge];
}

fn distance(core: *absolute.AbsoluteCore, snapshot: []const u64, a: []const u8, b: []const u8, mode: ProbeMode) u32 {
    const sa = signature(core, snapshot, a, mode);
    const sb = signature(core, snapshot, b, mode);
    return @popCount(sa ^ sb);
}

fn runPairs(
    writer: anytype,
    title: []const u8,
    core: *absolute.AbsoluteCore,
    snapshot: []const u64,
    mode: ProbeMode,
    pairs: []const Pair,
) !void {
    try writer.print("\n[{s}] mode={s}\n", .{ title, @tagName(mode) });
    try writer.writeAll("label,distance,a,b\n");
    for (pairs) |p| {
        try writer.print("{s},{d},\"{s}\",\"{s}\"\n", .{
            p.label,
            distance(core, snapshot, p.a, p.b, mode),
            p.a,
            p.b,
        });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var hv_path: []const u8 = absolute.AbsoluteCore.DefaultTrainedHvPath;
    var state_path: []const u8 = "state/semantic_structure_probe.bin";
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--hv=")) hv_path = arg["--hv=".len..]
        else if (std.mem.startsWith(u8, arg, "--state=")) state_path = arg["--state=".len..];
    }

    const stdout = std.io.getStdOut().writer();
    var core = try absolute.AbsoluteCore.initAt(state_path, 16 * 1024 * 1024);
    defer core.deinit();
    core.setTrainedHypervectorPath(hv_path);
    core.loadTrainedHypervectors();
    const info = core.trainedHypervectorInfo();
    try stdout.print("=== SEMANTIC STRUCTURE PROBE ===\n", .{});
    try stdout.print("hv_path={s} loaded={} mode={s} count={d} flags=0x{X} checksum_ok={}\n", .{
        info.path,
        info.loaded,
        @tagName(info.mode),
        info.count,
        info.flags,
        info.checksum_ok,
    });

    core.reset();
    const snapshot = try allocator.alloc(u64, core.field.len);
    defer allocator.free(snapshot);
    @memcpy(snapshot, core.field);

    const oov_pairs = [_]Pair{
        .{ .label = "oov_shared_light", .a = "starlight", .b = "light" },
        .{ .label = "oov_shared_light", .a = "sunlight", .b = "light" },
        .{ .label = "oov_shared_light", .a = "moonlight", .b = "light" },
        .{ .label = "oov_shared_river", .a = "riverbank", .b = "river" },
        .{ .label = "oov_control", .a = "starlight", .b = "granite" },
        .{ .label = "oov_control", .a = "riverbank", .b = "piano" },
    };
    const syntax_pairs = [_]Pair{
        .{ .label = "same_sentence", .a = "dog bites man", .b = "dog bites man" },
        .{ .label = "reversed_roles", .a = "dog bites man", .b = "man bites dog" },
        .{ .label = "near_role_swap", .a = "doctor treats patient", .b = "patient treats doctor" },
        .{ .label = "control", .a = "dog bites man", .b = "river flows downhill" },
    };
    const polysemy_pairs = [_]Pair{
        .{ .label = "bank_same_river", .a = "river bank overflowed", .b = "river shore overflowed" },
        .{ .label = "bank_same_money", .a = "money bank loaned cash", .b = "credit bank loaned cash" },
        .{ .label = "bank_cross_sense", .a = "river bank overflowed", .b = "money bank loaned cash" },
        .{ .label = "bank_word_only", .a = "bank", .b = "bank" },
    };

    try runPairs(stdout, "OOV_SUBWORD", &core, snapshot, .trained, &oov_pairs);
    try runPairs(stdout, "SYNTAX_ORDER", &core, snapshot, .trained, &syntax_pairs);
    try runPairs(stdout, "SYNTAX_ORDER", &core, snapshot, .contextual, &syntax_pairs);
    try runPairs(stdout, "POLYSEMY_CONTEXT", &core, snapshot, .contextual, &polysemy_pairs);
}
