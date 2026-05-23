const std = @import("std");
const mixer = @import("domain_u64_mixer_mulfree.zig");

fn parseHexOrDecimal(text: []const u8) !u64 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return std.fmt.parseInt(u64, text[2..], 16);
    }
    return std.fmt.parseInt(u64, text, 16) catch std.fmt.parseInt(u64, text, 10);
}

fn parseByteCount(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidByteCount;
    var digits = text;
    var multiplier: u64 = 1;
    switch (text[text.len - 1]) {
        'k', 'K' => {
            digits = text[0 .. text.len - 1];
            multiplier = 1024;
        },
        'm', 'M' => {
            digits = text[0 .. text.len - 1];
            multiplier = 1024 * 1024;
        },
        'g', 'G' => {
            digits = text[0 .. text.len - 1];
            multiplier = 1024 * 1024 * 1024;
        },
        't', 'T' => {
            digits = text[0 .. text.len - 1];
            multiplier = 1024 * 1024 * 1024 * 1024;
        },
        else => {},
    }
    if (digits.len == 0) return error.InvalidByteCount;
    const base = try std.fmt.parseInt(u64, digits, 10);
    return std.math.mul(u64, base, multiplier) catch error.ByteCountOverflow;
}

fn writeRaw(writer: anytype, bytes: []const u8) !bool {
    writer.writeAll(bytes) catch |err| switch (err) {
        error.BrokenPipe => return false,
        else => return err,
    };
    return true;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\usage: practrand_emit_mulfree --program=champion.csv [options]
        \\
        \\Options:
        \\  --mode=mul_free|no_carry|unrestricted
        \\  --seed=HEX
        \\  --bytes=N[K|M|G]
        \\
        \\Writes raw little-endian u64 words to stdout. Diagnostics and usage go to stderr.
        \\The loaded CSV is validated against the selected mode before any stream is emitted.
        \\
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var mode: mixer.MulFreeMode = .mul_free;
    var program_path: ?[]const u8 = null;
    var state: u64 = 0x0123456789ABCDEF;
    var byte_limit: ?u64 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(std.io.getStdErr().writer());
            return;
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            mode = try mixer.parseMode(arg["--mode=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--program=")) {
            program_path = arg["--program=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            state = try parseHexOrDecimal(arg["--seed=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
            byte_limit = try parseByteCount(arg["--bytes=".len..]);
        } else {
            try std.io.getStdErr().writer().print("unknown argument: {s}\n", .{arg});
            try printUsage(std.io.getStdErr().writer());
            return error.InvalidArgument;
        }
    }

    const path = program_path orelse {
        try printUsage(std.io.getStdErr().writer());
        return error.MissingProgram;
    };
    const program = try mixer.programFromCsv(allocator, path);
    try mixer.validateMode(program, mode);

    const stdout = std.io.getStdOut().writer();
    var produced: u64 = 0;
    var buf: [32 * 1024]u8 = undefined;

    while (byte_limit == null or produced < byte_limit.?) {
        const target_bytes: usize = if (byte_limit) |limit|
            @intCast(@min(@as(u64, buf.len), limit - produced))
        else
            buf.len;

        var offset: usize = 0;
        while (offset < target_bytes) {
            state = program.execute(state);
            const take = @min(@as(usize, 8), target_bytes - offset);
            if (take == 8) {
                std.mem.writeInt(u64, buf[offset..][0..8], state, .little);
            } else {
                var word_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &word_bytes, state, .little);
                @memcpy(buf[offset..][0..take], word_bytes[0..take]);
            }
            offset += take;
        }

        if (!try writeRaw(stdout, buf[0..target_bytes])) return;
        produced += @as(u64, @intCast(target_bytes));
    }
}

test "byte-count parser accepts binary suffixes" {
    try std.testing.expectEqual(@as(u64, 64), try parseByteCount("64"));
    try std.testing.expectEqual(@as(u64, 1024), try parseByteCount("1K"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024), try parseByteCount("1M"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), try parseByteCount("1G"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024 * 1024), try parseByteCount("1T"));
}
