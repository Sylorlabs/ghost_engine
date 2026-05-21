const std = @import("std");
const engine = @import("invention_engine.zig");

// --- DOMAIN: 4-input boolean function synthesis ---
//
// Target: PARITY-4 (output = a XOR b XOR c XOR d). Truth table = 0x6996.
//
// Program = sequence of gates, each gate computes (op, src1, src2) → value.
// Inputs 0..3 are the four boolean variables a,b,c,d. Subsequent slots
// (4..MaxGates+3) reference previous gate outputs. Output = value of last
// gate.
//
// Ops: AND, OR, XOR, NAND, NOR, NOT (NOT is unary; src2 ignored).
//
// Quality = Hamming similarity of candidate truth table (16 bits) to
// target truth table (16 bits). Exact match = 16/16.
//
// Library = canonical parity-4 implementations (tree and cascade).
//
// Divergence axis = STRUCTURAL. Every correct circuit computes the same
// truth table (the target), so functional similarity cannot be the
// divergence axis. Same logic as sorting networks.

pub const DOMAIN_NAME: []const u8 = "boolean-parity4";

const NumInputs: usize = 4;
const MaxGates: usize = 12;
const NumInputSlots: usize = NumInputs;
const TargetTruthTable: u16 = 0x6996; // PARITY-4 truth table

const Op = enum(u3) {
    AND = 0, OR = 1, XOR = 2, NAND = 3, NOR = 4, NOT = 5,
};

const Gate = struct {
    op: Op,
    src1: u4, // index into [inputs 0..3, gates 4..15]
    src2: u4,
    fn eq(a: Gate, b: Gate) bool { return a.op == b.op and a.src1 == b.src1 and a.src2 == b.src2; }
};

pub const Program = struct {
    gates: [MaxGates]Gate,
    used: u8,

    pub fn evaluate(self: Program, inputs: u4) u1 {
        var values = [_]u1{0} ** (NumInputs + MaxGates);
        values[0] = @intCast((inputs >> 0) & 1);
        values[1] = @intCast((inputs >> 1) & 1);
        values[2] = @intCast((inputs >> 2) & 1);
        values[3] = @intCast((inputs >> 3) & 1);
        var i: usize = 0;
        while (i < self.used) : (i += 1) {
            const g = self.gates[i];
            const s1 = @min(@as(usize, g.src1), NumInputs + i - 1);
            const s2 = @min(@as(usize, g.src2), NumInputs + i - 1);
            const a = values[s1];
            const b = values[s2];
            const r: u1 = switch (g.op) {
                .AND => a & b,
                .OR => a | b,
                .XOR => a ^ b,
                .NAND => ~(a & b),
                .NOR => ~(a | b),
                .NOT => ~a,
            };
            values[NumInputs + i] = r;
        }
        if (self.used == 0) return 0;
        return values[NumInputs + self.used - 1];
    }

    pub fn truthTable(self: Program) u16 {
        var tt: u16 = 0;
        var inputs: u4 = 0;
        while (true) {
            const out: u16 = self.evaluate(inputs);
            tt |= (out << inputs);
            if (inputs == 15) break;
            inputs += 1;
        }
        return tt;
    }
};

pub const Quality = struct {
    matches: u8,             // out of 16
    correctness: f64,        // matches / 16
    size: u8,
    truth_table: u16,
    composite: f64,
};

pub fn evaluateQuality(p: Program) Quality {
    const tt = p.truthTable();
    const diff = tt ^ TargetTruthTable;
    const wrong: u8 = @popCount(diff);
    const matches: u8 = 16 - wrong;
    const correctness = @as(f64, @floatFromInt(matches)) / 16.0;
    const composite = 100.0 * correctness - @as(f64, @floatFromInt(p.used)) * 0.5;
    return .{ .matches = matches, .correctness = correctness, .size = p.used, .truth_table = tt, .composite = composite };
}

pub fn qualityScalar(q: Quality) f64 { return q.composite; }
pub fn qualityPasses(q: Quality) bool { return q.matches == 16; }
pub fn isFinite(q: Quality) bool { return std.math.isFinite(q.composite); }

// --- Library: canonical parity-4 circuits ---
fn libTree() Program {
    // g0 = a XOR b;  g1 = c XOR d;  g2 = g0 XOR g1
    var p = Program{ .gates = undefined, .used = 3 };
    p.gates[0] = .{ .op = .XOR, .src1 = 0, .src2 = 1 };
    p.gates[1] = .{ .op = .XOR, .src1 = 2, .src2 = 3 };
    p.gates[2] = .{ .op = .XOR, .src1 = 4, .src2 = 5 };
    return p;
}

fn libCascade() Program {
    // g0 = a XOR b;  g1 = g0 XOR c;  g2 = g1 XOR d
    var p = Program{ .gates = undefined, .used = 3 };
    p.gates[0] = .{ .op = .XOR, .src1 = 0, .src2 = 1 };
    p.gates[1] = .{ .op = .XOR, .src1 = 4, .src2 = 2 };
    p.gates[2] = .{ .op = .XOR, .src1 = 5, .src2 = 3 };
    return p;
}

fn libAltTree() Program {
    // g0 = a XOR c;  g1 = b XOR d;  g2 = g0 XOR g1
    var p = Program{ .gates = undefined, .used = 3 };
    p.gates[0] = .{ .op = .XOR, .src1 = 0, .src2 = 2 };
    p.gates[1] = .{ .op = .XOR, .src1 = 1, .src2 = 3 };
    p.gates[2] = .{ .op = .XOR, .src1 = 4, .src2 = 5 };
    return p;
}

const LibEntry = struct { name: []const u8, program: Program };
fn libraryRaw() [3]LibEntry {
    return .{
        .{ .name = "Tree", .program = libTree() },
        .{ .name = "Cascade", .program = libCascade() },
        .{ .name = "AltTree", .program = libAltTree() },
    };
}

// Filter to entries that match target (self-test of library).
fn library(allocator: std.mem.Allocator) ![]LibEntry {
    const raw = libraryRaw();
    var list = std.ArrayList(LibEntry).init(allocator);
    for (raw) |entry| {
        if (entry.program.truthTable() == TargetTruthTable) try list.append(entry);
    }
    return try list.toOwnedSlice();
}

// --- Distance ---
pub const DistanceResult = struct {
    closest_name: []const u8,
    min_edit: usize,
    norm_edit: f64,
    matches: u8,
};

fn gateEditDist(a: []const Gate, b: []const Gate, allocator: std.mem.Allocator) !usize {
    const la = a.len; const lb = b.len;
    const cols = lb + 1;
    const dp = try allocator.alloc(usize, (la + 1) * cols);
    defer allocator.free(dp);
    var i: usize = 0;
    while (i <= la) : (i += 1) dp[i * cols + 0] = i;
    var j: usize = 0;
    while (j <= lb) : (j += 1) dp[0 * cols + j] = j;
    i = 1;
    while (i <= la) : (i += 1) {
        var jj: usize = 1;
        while (jj <= lb) : (jj += 1) {
            const sub: usize = if (a[i - 1].eq(b[jj - 1])) 0 else 1;
            const v_sub = dp[(i - 1) * cols + (jj - 1)] + sub;
            const v_del = dp[(i - 1) * cols + jj] + 1;
            const v_ins = dp[i * cols + (jj - 1)] + 1;
            var best = v_sub;
            if (v_del < best) best = v_del;
            if (v_ins < best) best = v_ins;
            dp[i * cols + jj] = best;
        }
    }
    return dp[la * cols + lb];
}

pub fn distanceToLibrary(p: Program, allocator: std.mem.Allocator) !DistanceResult {
    const lib = try library(allocator);
    defer allocator.free(lib);
    var min_ed: usize = std.math.maxInt(usize);
    var min_name: []const u8 = "";
    for (lib) |entry| {
        const ed = try gateEditDist(p.gates[0..p.used], entry.program.gates[0..entry.program.used], allocator);
        if (ed < min_ed) { min_ed = ed; min_name = entry.name; }
    }
    const max_len = @max(p.used, 3);
    const matches: u8 = 16 - @popCount(p.truthTable() ^ TargetTruthTable);
    return .{
        .closest_name = min_name,
        .min_edit = min_ed,
        .norm_edit = @as(f64, @floatFromInt(min_ed)) / @as(f64, @floatFromInt(max_len)),
        .matches = matches,
    };
}

pub fn isEquivalent(d: DistanceResult) bool { return d.min_edit == 0; }
pub fn isTrivialVariant(d: DistanceResult) bool { return d.min_edit <= 1 and d.matches == 16; }
pub fn isRemix(d: DistanceResult) bool { return d.norm_edit <= 0.20; }

// --- Reachability via library-window structural search ---
pub const ReachabilityResult = struct {
    min_window_edit: usize,
    min_norm_edit: f64,
    best_depth: usize,
    reachable: bool,
};
const MaxDepth: usize = 3;
const ReachNormThreshold: f64 = 0.10;
const MaxConcatLen: usize = MaxGates * 4;

pub fn reachability(p: Program, allocator: std.mem.Allocator) !ReachabilityResult {
    const lib = try library(allocator);
    defer allocator.free(lib);
    var best: ReachabilityResult = .{ .min_window_edit = std.math.maxInt(usize), .min_norm_edit = 1.0, .best_depth = 0, .reachable = false };
    var depth: usize = 1;
    while (depth <= MaxDepth) : (depth += 1) {
        const total = std.math.pow(usize, lib.len, depth);
        var n: usize = 0;
        while (n < total) : (n += 1) {
            var path: [MaxDepth]usize = .{0} ** MaxDepth;
            var t = n; var i: usize = 0;
            while (i < depth) : (i += 1) { path[i] = t % lib.len; t /= lib.len; }
            var concat: [MaxConcatLen]Gate = undefined;
            var ci: usize = 0;
            i = 0;
            while (i < depth) : (i += 1) {
                const net = lib[path[i]].program;
                var k: usize = 0;
                while (k < net.used and ci < concat.len) : (k += 1) { concat[ci] = net.gates[k]; ci += 1; }
            }
            if (p.used > ci) continue;
            var start: usize = 0;
            while (start + p.used <= ci) : (start += 1) {
                const ed = try gateEditDist(p.gates[0..p.used], concat[start .. start + p.used], allocator);
                const norm = @as(f64, @floatFromInt(ed)) / @as(f64, @floatFromInt(p.used));
                if (ed < best.min_window_edit) {
                    best.min_window_edit = ed;
                    best.min_norm_edit = norm;
                    best.best_depth = depth;
                }
            }
        }
    }
    best.reachable = best.min_norm_edit <= ReachNormThreshold;
    return best;
}

pub fn isReachable(r: ReachabilityResult) bool { return r.reachable; }

// --- Mutation / crossover / random init ---
fn randomGate(rng: *u64, gate_idx: usize) Gate {
    rng.* = engine.smix(rng.*);
    const op_idx: u3 = @intCast(rng.* % 6);
    rng.* = engine.smix(rng.*);
    const max_ref: u64 = NumInputs + gate_idx; // up to but not including current gate
    const src1: u4 = @intCast(rng.* % max_ref);
    rng.* = engine.smix(rng.*);
    const src2: u4 = @intCast(rng.* % max_ref);
    return .{ .op = @enumFromInt(op_idx), .src1 = src1, .src2 = src2 };
}

pub fn randomProgram(rng: *u64) Program {
    rng.* = engine.smix(rng.*);
    const len: u8 = @intCast(3 + (rng.* % 6)); // 3..8 gates
    var p = Program{ .gates = undefined, .used = len };
    var i: usize = 0;
    while (i < len) : (i += 1) p.gates[i] = randomGate(rng, i);
    return p;
}

pub fn mutate(p: Program, rng: *u64) Program {
    var q = p;
    rng.* = engine.smix(rng.*);
    const mode = rng.* % 16;
    if (mode < 11) {
        // Point mutation: change a gate (preserve src refs to valid range)
        rng.* = engine.smix(rng.*);
        const idx: usize = rng.* % q.used;
        q.gates[idx] = randomGate(rng, idx);
    } else if (mode < 13 and q.used < MaxGates) {
        rng.* = engine.smix(rng.*);
        const idx: usize = rng.* % (q.used + 1);
        var i: usize = q.used;
        while (i > idx) : (i -= 1) q.gates[i] = q.gates[i - 1];
        q.gates[idx] = randomGate(rng, idx);
        q.used += 1;
    } else if (q.used > 3) {
        rng.* = engine.smix(rng.*);
        const idx: usize = rng.* % q.used;
        var i: usize = idx;
        while (i < q.used - 1) : (i += 1) q.gates[i] = q.gates[i + 1];
        q.used -= 1;
    } else {
        // Op tweak
        rng.* = engine.smix(rng.*);
        const idx: usize = rng.* % q.used;
        rng.* = engine.smix(rng.*);
        q.gates[idx].op = @enumFromInt(@as(u3, @intCast(rng.* % 6)));
    }
    return q;
}

pub fn crossover(a: Program, b: Program, rng: *u64) Program {
    rng.* = engine.smix(rng.*);
    const min_len = @min(a.used, b.used);
    if (min_len < 3) return a;
    const cut: usize = rng.* % min_len;
    var q = a;
    var i: usize = cut;
    while (i < b.used and i < MaxGates) : (i += 1) q.gates[i] = b.gates[i];
    q.used = b.used;
    return q;
}

fn opName(op: Op) []const u8 {
    return switch (op) {
        .AND => "AND", .OR => "OR", .XOR => "XOR",
        .NAND => "NAND", .NOR => "NOR", .NOT => "NOT",
    };
}

pub fn printProgram(p: Program, writer: anytype) !void {
    try writer.print("  target_truth_table = 0x{X:0>4} (PARITY-4)\n", .{TargetTruthTable});
    try writer.print("  actual_truth_table = 0x{X:0>4}\n", .{p.truthTable()});
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const g = p.gates[i];
        try writer.print("  [g{d}] = {s}(slot{d}, slot{d})\n", .{ i, opName(g.op), g.src1, g.src2 });
    }
}

pub fn programToCsv(p: Program, writer: anytype) !void {
    try writer.writeAll("idx,op_id,op_name,src1,src2,size,truth_table_hex\n");
    var i: usize = 0;
    while (i < p.used) : (i += 1) {
        const g = p.gates[i];
        try writer.print("{d},{d},{s},{d},{d},{d},0x{X:0>4}\n", .{
            i, @intFromEnum(g.op), opName(g.op), g.src1, g.src2, p.used, p.truthTable(),
        });
    }
}
