const std = @import("std");

const Variant = enum {
    discovered,
    splitmix,
    splitmix_counter,
};

const golden = 0x9E3779B97F4A7C15;
const split_k1 = 0xBF58476D1CE4E5B9;
const split_k2 = 0x94D049BB133111EB;

fn splitMixScramble(x: u64) u64 {
    var z = x;
    z = (z ^ (z >> 30)) *% split_k1;
    z = (z ^ (z >> 27)) *% split_k2;
    return z ^ (z >> 31);
}

fn splitMix64Ref(x: u64) u64 {
    return splitMixScramble(x +% golden);
}

fn discoveredRun2Mix(x: u64) u64 {
    var r0 = x;
    const r1 = r0 ^ (r0 >> 37);
    r0 = r1 +% 0x9EE408BD3A3337DD;
    var r6 = r0 *% 0x0D5886EBD935161F;
    r6 = r6 ^ (r6 >> 30);
    return r6 *% 0x125B26B8C3E6F5D1;
}

fn nextWord(variant: Variant, state: *u64) u64 {
    return switch (variant) {
        .discovered => blk: {
            state.* = discoveredRun2Mix(state.*);
            break :blk state.*;
        },
        .splitmix => blk: {
            state.* = splitMix64Ref(state.*);
            break :blk state.*;
        },
        .splitmix_counter => blk: {
            state.* +%= golden;
            break :blk splitMixScramble(state.*);
        },
    };
}

fn parseVariant(text: []const u8) !Variant {
    if (std.mem.eql(u8, text, "discovered") or std.mem.eql(u8, text, "discovered-run2")) return .discovered;
    if (std.mem.eql(u8, text, "splitmix") or std.mem.eql(u8, text, "splitmix-iterated")) return .splitmix;
    if (std.mem.eql(u8, text, "splitmix-counter")) return .splitmix_counter;
    return error.InvalidVariant;
}

fn parseHexOrDecimal(text: []const u8) !u64 {
    if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
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
        else => {},
    }
    if (digits.len == 0) return error.InvalidByteCount;

    const base = try std.fmt.parseInt(u64, digits, 10);
    return std.math.mul(u64, base, multiplier) catch error.ByteCountOverflow;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\usage: practrand_emit [--variant=discovered|splitmix|splitmix-counter] [--seed=<hex>] [--bytes=<n>[K|M|G]]
        \\
        \\Writes raw little-endian u64 words to stdout. Diagnostics and usage go to stderr.
        \\Default variant is discovered-run2; default output is unbounded until the reader closes the pipe.
        \\
    );
}

fn writeRaw(writer: anytype, bytes: []const u8) !bool {
    writer.writeAll(bytes) catch |err| switch (err) {
        error.BrokenPipe => return false,
        else => return err,
    };
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var variant: Variant = .discovered;
    var state: u64 = 0x0123456789ABCDEF;
    var byte_limit: ?u64 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(std.io.getStdErr().writer());
            return;
        } else if (std.mem.startsWith(u8, arg, "--variant=")) {
            variant = parseVariant(arg["--variant=".len..]) catch |err| {
                try std.io.getStdErr().writer().print("invalid variant: {s}\n", .{arg["--variant=".len..]});
                return err;
            };
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            state = parseHexOrDecimal(arg["--seed=".len..]) catch |err| {
                try std.io.getStdErr().writer().print("invalid seed: {s}\n", .{arg["--seed=".len..]});
                return err;
            };
        } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
            byte_limit = parseByteCount(arg["--bytes=".len..]) catch |err| {
                try std.io.getStdErr().writer().print("invalid byte count: {s}\n", .{arg["--bytes=".len..]});
                return err;
            };
        } else {
            try std.io.getStdErr().writer().print("unknown argument: {s}\n", .{arg});
            try printUsage(std.io.getStdErr().writer());
            return error.InvalidArgument;
        }
    }

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
            const word = nextWord(variant, &state);
            const take = @min(@as(usize, 8), target_bytes - offset);
            if (take == 8) {
                std.mem.writeInt(u64, buf[offset..][0..8], word, .little);
            } else {
                var word_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &word_bytes, word, .little);
                @memcpy(buf[offset..][0..take], word_bytes[0..take]);
            }
            offset += take;
        }

        if (!try writeRaw(stdout, buf[0..target_bytes])) return;
        produced += @as(u64, @intCast(target_bytes));
    }
}

test "discovered Run 2 stream is stable" {
    var state: u64 = 0x0123456789ABCDEF;
    try std.testing.expectEqual(@as(u64, 0xDFE838ACEED53BF0), nextWord(.discovered, &state));
    try std.testing.expectEqual(@as(u64, 0x60B0E14DAC746FF3), nextWord(.discovered, &state));
}

test "byte-count parser accepts binary suffixes" {
    try std.testing.expectEqual(@as(u64, 64), try parseByteCount("64"));
    try std.testing.expectEqual(@as(u64, 1024), try parseByteCount("1K"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024), try parseByteCount("1M"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), try parseByteCount("1G"));
}
