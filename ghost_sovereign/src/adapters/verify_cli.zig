const std = @import("std");
const verify = @import("smt_verify.zig");

// Read a champion CSV and run the real-Z3 verifier. Replaces the
// hardcoded SMT_VERIFIED_FOUNDATIONAL_TRUTH string in invent_cli with
// an actual solver invocation.
//
// Usage:
//   verify_cli --domain=sort  --csv=PATH [--lib=PATH1,PATH2,...]
//   verify_cli --domain=mixer --csv=PATH [--bits=8] [--lib=PATH1,PATH2,...]
//
// Sort-net CSV format: idx,kind,i,j,size
// Mixer    CSV format: idx,op_id,op_name,dst,src1,src2,imm_hex,used_len
//
// --lib lists prior-generation champions to inline at CALL_LIB sites
// (matches runtime chain_extras). Order in the list IS the chain order.

fn parseSortCsv(allocator: std.mem.Allocator, path: []const u8) ![]verify.SortNode {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(contents);

    var list = std.ArrayList(verify.SortNode).init(allocator);
    errdefer list.deinit();
    var lines = std.mem.tokenizeAny(u8, contents, "\n\r");
    var first = true;
    while (lines.next()) |line| {
        if (first) { first = false; continue; }
        var fields = std.mem.tokenizeAny(u8, line, ",");
        _ = fields.next() orelse continue; // idx
        const kind_s = fields.next() orelse continue;
        const i_s = fields.next() orelse continue;
        const j_s = fields.next() orelse continue;
        const kind = try std.fmt.parseInt(u8, kind_s, 10);
        const i = try std.fmt.parseInt(u8, i_s, 10);
        const j = try std.fmt.parseInt(u8, j_s, 10);
        try list.append(.{ .i = i, .j = j, .kind = kind });
    }
    return list.toOwnedSlice();
}

fn parseMixerCsv(allocator: std.mem.Allocator, path: []const u8) ![]verify.MixerInstr {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(contents);

    var list = std.ArrayList(verify.MixerInstr).init(allocator);
    errdefer list.deinit();
    var lines = std.mem.tokenizeAny(u8, contents, "\n\r");
    var first = true;
    while (lines.next()) |line| {
        if (first) { first = false; continue; }
        var fields = std.mem.tokenizeAny(u8, line, ",");
        _ = fields.next() orelse continue; // idx
        const op_id_s = fields.next() orelse continue;
        _ = fields.next() orelse continue; // op_name
        const dst_s = fields.next() orelse continue;
        const src1_s = fields.next() orelse continue;
        const src2_s = fields.next() orelse continue;
        const imm_s = fields.next() orelse continue;
        const op_id = try std.fmt.parseInt(u8, op_id_s, 10);
        const dst = try std.fmt.parseInt(u8, dst_s, 10);
        const src1 = try std.fmt.parseInt(u8, src1_s, 10);
        const src2 = try std.fmt.parseInt(u8, src2_s, 10);
        const imm_hex = if (std.mem.startsWith(u8, imm_s, "0x") or std.mem.startsWith(u8, imm_s, "0X"))
            imm_s[2..]
        else
            imm_s;
        const imm = try std.fmt.parseInt(u64, imm_hex, 16);
        try list.append(.{
            .op = @enumFromInt(op_id),
            .dst = dst, .src1 = src1, .src2 = src2,
            .imm = imm,
        });
    }
    return list.toOwnedSlice();
}

const Domain = enum { sort, mixer };

// --lib=p1,p2,p3 — load each CSV as an extras entry. Returns null if
// the arg is empty.
fn loadSortLib(allocator: std.mem.Allocator, lib_arg: []const u8, log: anytype) !?verify.SortLib {
    if (lib_arg.len == 0) return null;
    var list = std.ArrayList([]const verify.SortNode).init(allocator);
    errdefer list.deinit();
    var parts = std.mem.tokenizeAny(u8, lib_arg, ",");
    while (parts.next()) |p| {
        const nodes = try parseSortCsv(allocator, p);
        try log.print("  lib[{d}] = {s}  ({d} nodes)\n", .{ list.items.len, p, nodes.len });
        try list.append(nodes);
    }
    return verify.SortLib{ .extras = try list.toOwnedSlice() };
}

fn freeSortLib(allocator: std.mem.Allocator, lib_opt: ?verify.SortLib) void {
    if (lib_opt) |lb| {
        for (lb.extras) |e| allocator.free(e);
        allocator.free(lb.extras);
    }
}

fn loadMixerLib(allocator: std.mem.Allocator, lib_arg: []const u8, log: anytype) !?verify.MixerLib {
    if (lib_arg.len == 0) return null;
    var list = std.ArrayList([]const verify.MixerInstr).init(allocator);
    errdefer list.deinit();
    var parts = std.mem.tokenizeAny(u8, lib_arg, ",");
    while (parts.next()) |p| {
        const ins = try parseMixerCsv(allocator, p);
        try log.print("  lib[{d}] = {s}  ({d} instrs)\n", .{ list.items.len, p, ins.len });
        try list.append(ins);
    }
    return verify.MixerLib{ .extras = try list.toOwnedSlice() };
}

fn freeMixerLib(allocator: std.mem.Allocator, lib_opt: ?verify.MixerLib) void {
    if (lib_opt) |lb| {
        for (lb.extras) |e| allocator.free(e);
        allocator.free(lb.extras);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var domain: Domain = .sort;
    var csv_path: []const u8 = "";
    var lib_arg: []const u8 = "";
    var bits: u8 = 8;
    var timeout_ms: u32 = 30_000;
    var dump_smt: bool = false;

    for (args) |a| {
        if (std.mem.startsWith(u8, a, "--domain=")) {
            const v = a["--domain=".len..];
            if (std.mem.eql(u8, v, "sort")) domain = .sort
            else if (std.mem.eql(u8, v, "mixer")) domain = .mixer;
        } else if (std.mem.startsWith(u8, a, "--csv=")) {
            csv_path = a["--csv=".len..];
        } else if (std.mem.startsWith(u8, a, "--lib=")) {
            lib_arg = a["--lib=".len..];
        } else if (std.mem.startsWith(u8, a, "--bits=")) {
            bits = std.fmt.parseInt(u8, a["--bits=".len..], 10) catch bits;
        } else if (std.mem.startsWith(u8, a, "--timeout-ms=")) {
            timeout_ms = std.fmt.parseInt(u32, a["--timeout-ms=".len..], 10) catch timeout_ms;
        } else if (std.mem.eql(u8, a, "--dump-smt")) {
            dump_smt = true;
        }
    }
    if (csv_path.len == 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("usage: verify_cli --domain=sort|mixer --csv=PATH [--lib=P1,P2,...] [--bits=N] [--timeout-ms=N] [--dump-smt]\n");
        return error.MissingArg;
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("verify_cli  domain={s}  csv={s}  bits={d}  timeout_ms={d}\n", .{
        switch (domain) { .sort => "sort", .mixer => "mixer" },
        csv_path, bits, timeout_ms,
    });

    const smt = switch (domain) {
        .sort => blk: {
            const comps = try parseSortCsv(alloc, csv_path);
            defer alloc.free(comps);
            try stdout.print("loaded {d} sort nodes\n", .{comps.len});
            const lib_opt = try loadSortLib(alloc, lib_arg, stdout);
            defer freeSortLib(alloc, lib_opt);
            break :blk try verify.emitSortNetCorrectness(alloc, 8, comps, lib_opt);
        },
        .mixer => blk: {
            const ins = try parseMixerCsv(alloc, csv_path);
            defer alloc.free(ins);
            try stdout.print("loaded {d} instructions\n", .{ins.len});
            const lib_opt = try loadMixerLib(alloc, lib_arg, stdout);
            defer freeMixerLib(alloc, lib_opt);
            break :blk try verify.emitMixerBijection(alloc, ins, bits, lib_opt);
        },
    };
    defer alloc.free(smt);

    if (dump_smt) {
        try stdout.writeAll("\n--- SMT-LIB2 ---\n");
        try stdout.writeAll(smt);
        try stdout.writeAll("\n--- end SMT ---\n");
    }

    const result = try verify.runSmtLib(alloc, smt, timeout_ms);

    try stdout.print("\nverdict: {s}\n", .{switch (result.verdict) {
        .verified => "VERIFIED (UNSAT — property holds)",
        .counter_example => "COUNTER-EXAMPLE (SAT — property fails)",
        .unknown => "UNKNOWN (solver gave up)",
        .error_smt => "ERROR (bad SMT or runtime error)",
    }});
    try stdout.print("elapsed: {d} ms\n", .{result.elapsed_ms});
    if (result.verdict == .counter_example or result.verdict == .error_smt) {
        try stdout.print("detail:\n{s}\n", .{result.detail});
    }
}
