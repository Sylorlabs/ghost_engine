//! ghost_medic_solve — self-heal loop, de-VSA'd. Loads the structured diagnostic runes (emerging), proposes a
//! repair, runs it, verifies by the test command, and promotes the diagnostic to `verified` or demotes to
//! `noise` — rewriting the shard. No HyperVector, no vsa.bind, no GPU, no effector rune-decode: the prior version
//! bound (diagnostic ⊗ fix) into a candidate rune and had the effector decode it back to a command; the command
//! was hardcoded anyway, so we run it directly. generate→verify→keep on structured runes.
const std = @import("std");
const core = @import("ghost_core");
const RuneRank = core.triad.RuneRank;

const SHARD = ".ghost/medic/diagnostics.tsv";
const FIX_CMD = "pip install --break-system-packages jinja2"; // the proposed repair (was bound into a rune)

const Diag = struct { rank: []const u8, id: []const u8, payload: []const u8 };

fn runShell(allocator: std.mem.Allocator, cmd: []const u8) !u8 {
    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |c| c,
        else => 1,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("Usage: ghost_medic_solve <test-command...>\n", .{});
        std.process.exit(2);
    }
    const test_command = args[1..];

    const content = std.fs.cwd().readFileAlloc(allocator, SHARD, 1 << 24) catch {
        std.debug.print("[MEDIC] no diagnostics shard ({s}); nothing to solve. Run ghost_medic_ingest first.\n", .{SHARD});
        return;
    };
    defer allocator.free(content);

    // parse diagnostics (structured records — no hypervector decode)
    var diags = std.ArrayList(Diag).init(allocator);
    defer diags.deinit();
    var lines = std.mem.splitScalar(u8, content, '\n');
    var target: ?usize = null;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const rank = f.next() orelse continue;
        const id = f.next() orelse continue;
        const payload = f.next() orelse continue;
        if (target == null and std.mem.eql(u8, rank, RuneRank.emerging.label())) target = diags.items.len;
        try diags.append(.{ .rank = rank, .id = id, .payload = payload });
    }

    std.debug.print("[MEDIC] Scanning {d} diagnostic runes for emerging causal links...\n", .{diags.items.len});
    const ti = target orelse {
        std.debug.print("[MEDIC] No emerging diagnostics. System is healthy.\n", .{});
        return;
    };
    std.debug.print("[MEDIC] Emerging diagnostic: {s}\n", .{diags.items[ti].payload});
    std.debug.print("[MEDIC] Proposing repair: '{s}'\n", .{FIX_CMD});
    _ = runShell(allocator, FIX_CMD) catch 1;

    var joined = std.ArrayList(u8).init(allocator);
    defer joined.deinit();
    for (test_command, 0..) |arg, i| {
        if (i > 0) try joined.append(' ');
        try joined.appendSlice(arg);
    }
    std.debug.print("[MEDIC] Verifying fix: executing '{s}'\n", .{joined.items});
    const code = runShell(allocator, joined.items) catch 1;

    var new_rank: []const u8 = undefined;
    if (code == 0) {
        new_rank = RuneRank.verified.label();
        std.debug.print("[MEDIC] SUCCESS — promoting diagnostic to {s}.\n", .{new_rank});
    } else {
        new_rank = RuneRank.noise.label();
        std.debug.print("[MEDIC] FAILURE (exit {d}) — demoting to {s}.\n", .{ code, new_rank });
    }

    // rewrite the shard with the updated rank (verify→keep, persisted)
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try out.appendSlice("# ghost medic diagnostics — structured runes (no VSA)\n");
    for (diags.items, 0..) |d, i| {
        const r = if (i == ti) new_rank else d.rank;
        try out.writer().print("{s}\t{s}\t{s}\n", .{ r, d.id, d.payload });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = SHARD, .data = out.items });
}
