const std = @import("std");

const MaxRows = 32;

const Kind = enum {
    meta,
    mm,
    mmm,
};

const Row = struct {
    op_id: u8,
    dst: u8,
    src1: u8,
    src2: u8,

    fn eq(a: Row, b: Row) bool {
        return a.op_id == b.op_id and a.dst == b.dst and a.src1 == b.src1 and a.src2 == b.src2;
    }
};

const Program = struct {
    rows: [MaxRows]Row = undefined,
    used: usize = 0,
};

fn parseKind(s: []const u8) !Kind {
    if (std.mem.eql(u8, s, "meta")) return .meta;
    if (std.mem.eql(u8, s, "mm")) return .mm;
    if (std.mem.eql(u8, s, "mmm")) return .mmm;
    return error.UnknownKind;
}

fn loadCsv(allocator: std.mem.Allocator, path: []const u8) !Program {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(contents);

    var p = Program{};
    var lines = std.mem.tokenizeAny(u8, contents, "\n\r");
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        }
        var fields = std.mem.tokenizeAny(u8, line, ",");
        _ = fields.next() orelse continue; // idx
        const op_id_s = fields.next() orelse continue;
        _ = fields.next() orelse continue; // op_name
        const dst_s = fields.next() orelse continue;
        const src1_s = fields.next() orelse continue;
        const src2_s = fields.next() orelse continue;
        if (p.used >= MaxRows) break;
        p.rows[p.used] = .{
            .op_id = try std.fmt.parseInt(u8, op_id_s, 10),
            .dst = try std.fmt.parseInt(u8, dst_s, 10),
            .src1 = try std.fmt.parseInt(u8, src1_s, 10),
            .src2 = try std.fmt.parseInt(u8, src2_s, 10),
        };
        p.used += 1;
    }
    return p;
}

fn editDistance(a: Program, b: Program) usize {
    var dp: [MaxRows + 1][MaxRows + 1]usize = undefined;
    var i: usize = 0;
    while (i <= a.used) : (i += 1) dp[i][0] = i;
    var j: usize = 0;
    while (j <= b.used) : (j += 1) dp[0][j] = j;

    i = 1;
    while (i <= a.used) : (i += 1) {
        j = 1;
        while (j <= b.used) : (j += 1) {
            const sub_cost: usize = if (a.rows[i - 1].eq(b.rows[j - 1])) 0 else 1;
            const del = dp[i - 1][j] + 1;
            const ins = dp[i][j - 1] + 1;
            const sub = dp[i - 1][j - 1] + sub_cost;
            dp[i][j] = @min(@min(del, ins), sub);
        }
    }
    return dp[a.used][b.used];
}

const Structure = struct {
    has_eval: bool = false,
    has_accept: bool = false,
    has_call: bool = false,
    first_eval: i32 = -1,
    first_accept: i32 = -1,
};

fn summarize(p: Program) Structure {
    var s = Structure{};
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        switch (p.rows[i].op_id) {
            4 => {
                s.has_eval = true;
                if (s.first_eval < 0) s.first_eval = @intCast(i);
            },
            5, 6 => {
                s.has_accept = true;
                if (s.first_accept < 0) s.first_accept = @intCast(i);
            },
            12 => s.has_call = true,
            else => {},
        }
    }
    return s;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var candidate_path: []const u8 = "";
    var against_paths: []const u8 = "";
    var kind: Kind = .meta;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--candidate=")) {
            candidate_path = arg["--candidate=".len..];
        } else if (std.mem.startsWith(u8, arg, "--against=")) {
            against_paths = arg["--against=".len..];
        } else if (std.mem.startsWith(u8, arg, "--kind=")) {
            kind = try parseKind(arg["--kind=".len..]);
        }
    }

    if (candidate_path.len == 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("usage: lineage_audit --kind=meta|mm|mmm --candidate=PATH [--against=p1,p2,...]\n");
        return error.MissingArg;
    }

    const stdout = std.io.getStdOut().writer();
    const candidate = try loadCsv(allocator, candidate_path);
    const s = summarize(candidate);

    try stdout.print("=== LINEAGE AUDIT ===\n", .{});
    try stdout.print("kind={s} candidate={s} used={d}\n", .{ @tagName(kind), candidate_path, candidate.used });
    try stdout.print("has_eval={} has_accept={} has_call={} first_eval={d} first_accept={d} eval_before_accept={}\n", .{
        s.has_eval,
        s.has_accept,
        s.has_call,
        s.first_eval,
        s.first_accept,
        s.first_eval >= 0 and s.first_accept >= 0 and s.first_eval < s.first_accept,
    });

    if (against_paths.len == 0) {
        try stdout.writeAll("against_count=0 lineage_verdict=NOT_CHECKED\n");
        return;
    }

    var parts = std.mem.tokenizeAny(u8, against_paths, ",");
    var count: usize = 0;
    var exact_copy = false;
    var nearest_path: []const u8 = "";
    var nearest_dist: usize = std.math.maxInt(usize);
    var nearest_norm: f64 = 0;

    while (parts.next()) |path| {
        const other = try loadCsv(allocator, path);
        const dist = editDistance(candidate, other);
        const denom = @max(candidate.used, other.used);
        const norm = if (denom == 0) 0 else @as(f64, @floatFromInt(dist)) / @as(f64, @floatFromInt(denom));
        if (dist == 0) exact_copy = true;
        if (dist < nearest_dist) {
            nearest_dist = dist;
            nearest_norm = norm;
            nearest_path = path;
        }
        count += 1;
    }

    try stdout.print("against_count={d} exact_copy={} nearest_edit_distance={d} nearest_normalized={d:.4} nearest={s}\n", .{
        count, exact_copy, nearest_dist, nearest_norm, nearest_path,
    });
    if (exact_copy) {
        try stdout.writeAll("lineage_verdict=COPY\n");
    } else if (nearest_norm < 0.25) {
        try stdout.writeAll("lineage_verdict=NEAR_COPY_STRUCTURAL\n");
    } else {
        try stdout.writeAll("lineage_verdict=NON_COPY_STRUCTURAL\n");
    }
}
