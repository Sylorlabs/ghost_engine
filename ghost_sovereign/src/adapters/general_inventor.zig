const std = @import("std");
const engine = @import("invention_engine.zig");
const u64_mixer = @import("domain_u64_mixer.zig");
const sort_net = @import("domain_sort_net.zig");
const boolean = @import("domain_boolean.zig");

// --- GENERAL INVENTOR ---
//
// Single binary that instantiates the same generic invention engine for
// multiple domains. The engine code (search, gate, reachability, verdict)
// is identical across domains; only the Spec module changes.
//
// Usage:
//   ./general_inventor --domain=u64_mixer --iters=8000 --seed=ABCDEF0123456789
//   ./general_inventor --domain=sort_net  --iters=50000 --seed=CAFEBABE12345678
//   ./general_inventor --domain=boolean   --iters=20000 --seed=BEEFFACE12345678
//
// All three domain modules satisfy the same Spec contract — see
// invention_engine.zig for the contract documentation.

fn runDomain(comptime Spec: type, allocator: std.mem.Allocator, iters: usize, seed: u64, t_start: f64, csv_path: []const u8) !void {
    const Eng = engine.Engine(Spec);
    var e = Eng.init(seed);
    const stdout = std.io.getStdOut().writer();

    try stdout.print("=== GENERAL INVENTOR | domain={s} | iters={d} | seed=0x{X} ===\n\n", .{ Spec.DOMAIN_NAME, iters, seed });

    e.seedPool(Eng.PoolSize);
    try stdout.print("Seeded pool with {d} random programs.\n", .{e.count});
    try stdout.print("Searching ({d} iterations)...\n\n", .{iters});

    const sr = try e.search(iters, t_start, stdout);

    try stdout.print("\nSearch finished. Accepted {d} / {d} mutations ({d:.1}%).\n", .{
        sr.accepted, sr.iterations, 100.0 * @as(f64, @floatFromInt(sr.accepted)) / @as(f64, @floatFromInt(sr.iterations)),
    });
    try stdout.print("\nFinal program:\n", .{});
    try Spec.printProgram(sr.best_program, stdout);

    // Persist champion
    if (std.fs.path.dirname(csv_path)) |dir| if (dir.len != 0) try std.fs.cwd().makePath(dir);
    var f = try std.fs.cwd().createFile(csv_path, .{ .truncate = true });
    defer f.close();
    try Spec.programToCsv(sr.best_program, f.writer());
    try stdout.print("\nChampion persisted: {s}\n", .{csv_path});

    // Grade
    const g = try Eng.grade(sr.best_program, allocator);
    try stdout.print("\n=== VERDICT ({s}) ===\n", .{Spec.DOMAIN_NAME});
    try stdout.print("Quality passes gate: {s}\n", .{if (Spec.qualityPasses(g.quality)) "PASS" else "FAIL"});
    try stdout.print("Verdict: {s}\n", .{g.verdict.label()});

    // CSV grade row
    var gf = try std.fs.cwd().createFile("results/general_inventor_grade.csv", .{ .truncate = true });
    defer gf.close();
    try gf.writer().writeAll("domain,verdict,quality_passes\n");
    try gf.writer().print("{s},{s},{d}\n", .{ Spec.DOMAIN_NAME, g.verdict.label(), @intFromBool(Spec.qualityPasses(g.quality)) });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var domain: []const u8 = "u64_mixer";
    var iters: usize = 8000;
    var seed: u64 = 0xC0FFEEBABEF00D12;
    var csv_path: []const u8 = "results/general_inventor_champion.csv";
    var t_start: f64 = 8.0;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--domain=")) domain = arg["--domain=".len..]
        else if (std.mem.startsWith(u8, arg, "--iters=")) iters = try std.fmt.parseInt(usize, arg["--iters=".len..], 10)
        else if (std.mem.startsWith(u8, arg, "--seed=")) seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16)
        else if (std.mem.startsWith(u8, arg, "--csv=")) csv_path = arg["--csv=".len..]
        else if (std.mem.startsWith(u8, arg, "--t-start=")) t_start = try std.fmt.parseFloat(f64, arg["--t-start=".len..]);
    }

    try std.fs.cwd().makePath("results");

    if (std.mem.eql(u8, domain, "u64_mixer")) {
        try runDomain(u64_mixer, allocator, iters, seed, t_start, csv_path);
    } else if (std.mem.eql(u8, domain, "sort_net")) {
        try runDomain(sort_net, allocator, iters, seed, 50.0, csv_path);
    } else if (std.mem.eql(u8, domain, "boolean")) {
        try runDomain(boolean, allocator, iters, seed, 20.0, csv_path);
    } else {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("unknown domain '{s}'. valid: u64_mixer, sort_net, boolean\n", .{domain});
        return error.UnknownDomain;
    }
}
