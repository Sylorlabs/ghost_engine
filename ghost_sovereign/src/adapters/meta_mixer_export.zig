const std = @import("std");
const tier0 = @import("domain_meta_engine.zig");
const mixer = @import("domain_u64_mixer.zig");

fn loadMetaProgramCsv(allocator: std.mem.Allocator, path: []const u8) !tier0.MetaProgram {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(contents);

    var p = tier0.MetaProgram{ .instructions = undefined, .used = 0 };
    var lines = std.mem.tokenizeAny(u8, contents, "\n\r");
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        }
        var fields = std.mem.tokenizeAny(u8, line, ",");
        _ = fields.next() orelse continue;
        const op_id_s = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const dst_s = fields.next() orelse continue;
        const src1_s = fields.next() orelse continue;
        const src2_s = fields.next() orelse continue;
        if (p.used >= tier0.MaxMetaLen) break;
        p.instructions[p.used] = .{
            .op = @enumFromInt(try std.fmt.parseInt(u8, op_id_s, 10)),
            .dst = @intCast(try std.fmt.parseInt(u8, dst_s, 10)),
            .src1 = @intCast(try std.fmt.parseInt(u8, src1_s, 10)),
            .src2 = @intCast(try std.fmt.parseInt(u8, src2_s, 10)),
        };
        p.used += 1;
    }
    if (p.used == 0) return error.EmptyMetaProgram;
    return p;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var meta_path: []const u8 = "";
    var out_path: []const u8 = "";
    var seed: u64 = 0xC0FF_EE00_DEAD_BEEF;
    var steps: u32 = 150;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--meta=")) {
            meta_path = arg["--meta=".len..];
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            out_path = arg["--out=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--steps=")) {
            steps = try std.fmt.parseInt(u32, arg["--steps=".len..], 10);
        }
    }

    if (meta_path.len == 0 or out_path.len == 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("usage: meta_mixer_export --meta=PATH --out=PATH [--seed=hex] [--steps=N]\n");
        return error.MissingArg;
    }

    const meta = try loadMetaProgramCsv(allocator, meta_path);
    const r = tier0.runReturningChampion(meta, steps, seed);

    var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer file.close();
    try mixer.programToCsv(r.program_best, file.writer());

    const stdout = std.io.getStdOut().writer();
    try stdout.print("exported_mixer={s} q_best={d:.6} meta={s} seed=0x{X} steps={d}\n", .{
        out_path, r.q_best, meta_path, seed, steps,
    });
}
