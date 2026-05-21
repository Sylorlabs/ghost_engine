const std = @import("std");
const meta = @import("domain_meta_engine_sort.zig");

// Baseline: hand-written reference meta-program that performs simple
// hill-climb SA. Used to validate whether outer-search-discovered
// meta-programs are competitive with or exceed a known-good engine at
// the same inner-step budget.
//
// Also runs a "null" meta-program (just INIT+EVAL+ACCEPT — no
// mutation loop) as a floor.

fn buildHillClimb() meta.MetaProgram {
    // [0] INIT_CUR        — random init
    // [1] EVAL_CUR        — evaluate init
    // [2] ACCEPT_IF_BETTER — initialise best
    // [3] MUTATE_BEST_TO_CUR — explore from best
    // [4] EVAL_CUR
    // [5] ACCEPT_IF_BETTER
    // Steps 3-5 repeat every step after step 0.
    var p = meta.MetaProgram{ .instructions = undefined, .used = 0 };
    const ins = [_]meta.MetaInstr{
        .{ .op = .MUTATE_BEST_TO_CUR, .dst = 0, .src1 = 0, .src2 = 0 },
        .{ .op = .EVAL_CUR, .dst = 0, .src1 = 0, .src2 = 0 },
        .{ .op = .ACCEPT_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 },
    };
    for (ins, 0..) |x, i| {
        p.instructions[i] = x;
        p.used += 1;
    }
    return p;
}

fn buildNull() meta.MetaProgram {
    // Just one EVAL_CUR per step — the initial program never mutates.
    var p = meta.MetaProgram{ .instructions = undefined, .used = 0 };
    p.instructions[0] = .{ .op = .EVAL_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
    p.instructions[1] = .{ .op = .ACCEPT_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 };
    p.used = 2;
    return p;
}

fn buildRandomRestart() meta.MetaProgram {
    // INIT every step — pure random search.
    var p = meta.MetaProgram{ .instructions = undefined, .used = 0 };
    p.instructions[0] = .{ .op = .INIT_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
    p.instructions[1] = .{ .op = .EVAL_CUR, .dst = 0, .src1 = 0, .src2 = 0 };
    p.instructions[2] = .{ .op = .ACCEPT_IF_BETTER, .dst = 0, .src1 = 0, .src2 = 0 };
    p.used = 3;
    return p;
}

fn smix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn evalAcross(m: meta.MetaProgram, inner_steps: u32, eval_seeds: u32, root: u64) struct { mean: f64, min: f64, max: f64 } {
    var total: f64 = 0;
    var mn: f64 = std.math.inf(f64);
    var mx: f64 = -std.math.inf(f64);
    var s: u32 = 0;
    var seed: u64 = root;
    while (s < eval_seeds) : (s += 1) {
        seed = smix(seed +% 0x9E37_79B1 +% s);
        var q = meta.run(m, inner_steps, seed);
        if (std.math.isInf(q) or std.math.isNan(q)) q = 0.0;
        total += q;
        if (q < mn) mn = q;
        if (q > mx) mx = q;
    }
    return .{ .mean = total / @as(f64, @floatFromInt(eval_seeds)), .min = mn, .max = mx };
}

fn loadMetaFromCsv(alloc: std.mem.Allocator, path: []const u8) !meta.MetaProgram {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(alloc, 1 << 20);
    defer alloc.free(contents);

    var p = meta.MetaProgram{ .instructions = undefined, .used = 0 };
    var lines = std.mem.tokenizeAny(u8, contents, "\n\r");
    var first = true;
    while (lines.next()) |line| {
        if (first) { first = false; continue; } // header
        var fields = std.mem.tokenizeAny(u8, line, ",");
        _ = fields.next() orelse continue; // idx
        const op_id_s = fields.next() orelse continue;
        _ = fields.next() orelse continue; // op_name
        const dst_s = fields.next() orelse continue;
        const src1_s = fields.next() orelse continue;
        const src2_s = fields.next() orelse continue;
        const op_id = try std.fmt.parseInt(u4, op_id_s, 10);
        const dst = try std.fmt.parseInt(u2, dst_s, 10);
        const src1 = try std.fmt.parseInt(u2, src1_s, 10);
        const src2 = try std.fmt.parseInt(u2, src2_s, 10);
        p.instructions[p.used] = .{
            .op = @enumFromInt(op_id), .dst = dst, .src1 = src1, .src2 = src2,
        };
        p.used += 1;
        if (p.used >= meta.MaxMetaLen) break;
    }
    return p;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var inner_steps: u32 = 400;
    var eval_seeds: u32 = 10;
    const root: u64 = 0xCAFE_F00D_DEAD_BABE;
    var load_csv: ?[]const u8 = null;
    var load_label: []const u8 = "loaded";
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "--inner-steps=")) {
            inner_steps = std.fmt.parseInt(u32, a["--inner-steps=".len..], 10) catch inner_steps;
        } else if (std.mem.startsWith(u8, a, "--eval-seeds=")) {
            eval_seeds = std.fmt.parseInt(u32, a["--eval-seeds=".len..], 10) catch eval_seeds;
        } else if (std.mem.startsWith(u8, a, "--load=")) {
            load_csv = a["--load=".len..];
        } else if (std.mem.startsWith(u8, a, "--label=")) {
            load_label = a["--label=".len..];
        }
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("baseline reference engines: inner_steps={d} eval_seeds={d}\n", .{ inner_steps, eval_seeds });

    const cases = [_]struct { name: []const u8, prog: meta.MetaProgram }{
        .{ .name = "null (eval-only)", .prog = buildNull() },
        .{ .name = "random-restart", .prog = buildRandomRestart() },
        .{ .name = "hill-climb (canonical)", .prog = buildHillClimb() },
    };

    for (cases) |c| {
        const r = evalAcross(c.prog, inner_steps, eval_seeds, root);
        try stdout.print(
            "  {s:<25} mean={d:.4} min={d:.4} max={d:.4} (n={d}, len={d})\n",
            .{ c.name, r.mean, r.min, r.max, eval_seeds, c.prog.used },
        );
    }

    if (load_csv) |path| {
        const loaded = try loadMetaFromCsv(alloc, path);
        const r = evalAcross(loaded, inner_steps, eval_seeds, root);
        try stdout.print(
            "  {s:<25} mean={d:.4} min={d:.4} max={d:.4} (n={d}, len={d})  [{s}]\n",
            .{ load_label, r.mean, r.min, r.max, eval_seeds, loaded.used, path },
        );
    }
}
