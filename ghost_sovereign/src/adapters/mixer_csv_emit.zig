const std = @import("std");
const mixer = @import("domain_u64_mixer.zig");

fn parseByteCount(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidByteCount;
    const last = text[text.len - 1];
    const mult: u64 = switch (last) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (mult == 1) text else text[0 .. text.len - 1];
    return (try std.fmt.parseInt(u64, digits, 10)) * mult;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var program_path: []const u8 = "";
    var seed: u64 = 0x0123_4567_89AB_CDEF;
    var bytes: u64 = 64 * 1024 * 1024;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--program=")) {
            program_path = arg["--program=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
            bytes = try parseByteCount(arg["--bytes=".len..]);
        }
    }

    if (program_path.len == 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("usage: mixer_csv_emit --program=PATH [--seed=hex] [--bytes=N|NK|NM|NG]\n");
        return error.MissingArg;
    }

    const program = try mixer.programFromCsv(allocator, program_path);
    const stdout = std.io.getStdOut().writer();
    var state = seed;
    var emitted: u64 = 0;
    while (emitted < bytes) {
        state = program.execute(state);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, state, .little);
        const n = @min(@as(u64, 8), bytes - emitted);
        try stdout.writeAll(buf[0..@intCast(n)]);
        emitted += n;
    }
}
