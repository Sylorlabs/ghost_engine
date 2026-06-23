//! ghost_medic_ingest — ingest pytest failures as diagnostic runes. De-VSA'd: a diagnostic is a STRUCTURED
//! record (error|file|env), content-addressed by an exact id and ranked `emerging` on the triad ladder, persisted
//! to a plain shard file. No HyperVector, no vsa.bind, no GPU meaning-matrix — the prior version bound
//! (error⊗file⊗env) into a 4096-bit rune purely to store it; the structured record carries the same information,
//! readable. (Similarity matching, when needed, is feature_sim.zig — but the ingest path only stores + ranks.)
const std = @import("std");
const core = @import("ghost_core");
const RuneRank = core.triad.RuneRank;

const SHARD = ".ghost/medic/diagnostics.tsv";

fn idOf(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0xD1A6, s); // exact content id (was an FNV→HyperVector encode)
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("Usage: ghost_medic_ingest <pytest-log-path>\n", .{});
        std.process.exit(2);
    }

    const content = std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024 * 100) catch |err| {
        std.debug.print("ghost_medic_ingest: could not read '{s}': {any}\n", .{ args[1], err });
        std.process.exit(1);
    };
    defer allocator.free(content);

    // load existing diagnostic ids to dedup (exact content addressing — no fuzzy collision)
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    if (std.fs.cwd().readFileAlloc(allocator, SHARD, 1 << 24)) |prev| {
        defer allocator.free(prev);
        var pl = std.mem.splitScalar(u8, prev, '\n');
        while (pl.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.splitScalar(u8, line, '\t');
            _ = f.next(); // rank
            if (f.next()) |idhex| seen.put(std.fmt.parseInt(u64, idhex, 16) catch continue, {}) catch {};
        }
    } else |_| {}

    std.fs.cwd().makePath(".ghost/medic") catch {};
    var file = try std.fs.cwd().createFile(SHARD, .{ .truncate = false, .read = true });
    defer file.close();
    try file.seekFromEnd(0);
    if (try file.getPos() == 0) try file.writer().print("# ghost medic diagnostics — structured runes (no VSA)\n", .{});
    const w = file.writer();

    var last_file: []const u8 = "unknown";
    var lines = std.mem.splitScalar(u8, content, '\n');
    var error_count: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, ": in ")) |idx| {
            last_file = std.mem.trim(u8, line[0..idx], " \t\r");
        } else if (std.mem.startsWith(u8, line, "E   ")) {
            const err_msg = std.mem.trim(u8, line[4..], " \t\r");
            const payload = try std.fmt.allocPrint(allocator, "error: {s} | file: {s} | env: pytest", .{ err_msg, last_file });
            defer allocator.free(payload);
            const id = idOf(payload);
            if (seen.contains(id)) continue;
            seen.put(id, {}) catch {};
            try w.print("{s}\t{X:0>16}\t{s}\n", .{ RuneRank.emerging.label(), id, payload });
            error_count += 1;
            std.debug.print("Ingested diagnostic rune [{s}] -> {s}\n", .{ RuneRank.emerging.label(), payload });
        }
    }
    std.debug.print("Ingestion complete. {d} diagnostics stored as structured runes in {s}.\n", .{ error_count, SHARD });
}
