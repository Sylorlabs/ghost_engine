const std = @import("std");
const flame = @import("flame");
const void_eng = @import("void");

const TrialCount = 4;

const Mode = enum {
    ask_experts,
    debate_experts,
    audit_experts,
    omni_ingest_verdict,
    final_questions,
    total_audit,
};

fn modeFromName(name: []const u8) Mode {
    if (std.mem.eql(u8, name, "debate_experts")) return .debate_experts;
    if (std.mem.eql(u8, name, "audit_experts")) return .audit_experts;
    if (std.mem.eql(u8, name, "omni_ingest_verdict")) return .omni_ingest_verdict;
    if (std.mem.eql(u8, name, "final_questions")) return .final_questions;
    if (std.mem.eql(u8, name, "total_audit")) return .total_audit;
    return .ask_experts;
}

fn defaultPrompt(mode: Mode) []const u8 {
    return switch (mode) {
        .ask_experts => "Evaluate the current Ghost Sovereign invention result using measured reservoir signals only.",
        .debate_experts => "Compare the program synthesis result against the conceptless bitfield lineage without narrative claims.",
        .audit_experts => "Audit Ghost Sovereign for external credibility hazards and unsupported claims.",
        .omni_ingest_verdict => "Should the project route more local corpus runes through the reservoir before claiming understanding?",
        .final_questions => "What concrete measurements are still missing before any external invention claim?",
        .total_audit => "Run a compact measured audit of Ghost Sovereign's current reservoir response.",
    };
}

fn modeName(mode: Mode) []const u8 {
    return switch (mode) {
        .ask_experts => "ask_experts",
        .debate_experts => "debate_experts",
        .audit_experts => "audit_experts",
        .omni_ingest_verdict => "omni_ingest_verdict",
        .final_questions => "final_questions",
        .total_audit => "total_audit",
    };
}

fn pressure(state: *const flame.FlameState, law: flame.Law) u128 {
    const got = law.ca * state.chamber[law.a] + law.cb * state.chamber[law.b];
    return @abs(got - law.t);
}

fn triggerEdge(before: *const flame.FlameState, after: *const flame.FlameState) usize {
    var max_change: u128 = 0;
    var edge: usize = 0;
    for (flame.Laws, 0..) |law, i| {
        const p0 = pressure(before, law);
        const p1 = pressure(after, law);
        const change = if (p1 > p0) p1 - p0 else p0 - p1;
        if (change > max_change) {
            max_change = change;
            edge = i;
        }
    }
    return edge;
}

fn stateFingerprint(state: *const flame.FlameState) u64 {
    var h: u64 = state.kernel ^ 0xD1A6_A11D_51A7_E5A7;
    for (state.chamber, 0..) |value, idx| {
        const bits: u128 = @bitCast(value);
        h = flame.splitMix64(h ^ @as(u64, @truncate(bits)) ^ @as(u64, @intCast(idx * 131)));
        h = flame.splitMix64(h ^ @as(u64, @truncate(bits >> 64)));
    }
    return h;
}

fn runTrial(writer: anytype, prompt: []const u8, seed: u64, trial: usize) !i128 {
    var engine = void_eng.VoidEngine.init(seed);
    const before_state = engine.state;
    const closure_before = flame.closureError(&before_state);

    engine.ingestTextSequence(seed ^ 0xC011EC7ED, prompt, flame.SequenceLen);
    const closure_after = flame.closureError(&engine.state);
    const delta = @as(i128, @intCast(closure_after)) - @as(i128, @intCast(closure_before));
    const edge = triggerEdge(&before_state, &engine.state);
    const fingerprint = stateFingerprint(&engine.state);

    try writer.print(
        "trial={d} seed=0x{X} closure_before={d} closure_after={d} delta={d} trigger_edge={d} fingerprint=0x{X}\n",
        .{ trial, seed, closure_before, closure_after, delta, edge, fingerprint },
    );
    return delta;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    const exe_name = std.fs.path.basename(args.next() orelse "ask_experts");
    const mode = modeFromName(exe_name);

    var prompt = defaultPrompt(mode);
    var seed: u64 = 0xA5EED5_51A7E_2026;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--message=")) {
            prompt = arg["--message=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 16);
        }
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== GHOST SOVEREIGN MEASURED PROBE ===\n", .{});
    try stdout.print("mode={s}\n", .{modeName(mode)});
    try stdout.print("status=MEASURED_NON_LANGUAGE\n", .{});
    try stdout.print("prompt={s}\n", .{prompt});
    try stdout.print("trials={d}\n\n", .{TrialCount});

    var best_delta: i128 = std.math.maxInt(i128);
    var sum_delta: i128 = 0;
    for (0..TrialCount) |trial| {
        const trial_seed = flame.splitMix64(seed ^ @as(u64, @intCast(trial * 4099)));
        const delta = try runTrial(stdout, prompt, trial_seed, trial);
        best_delta = @min(best_delta, delta);
        sum_delta += delta;
    }

    const mean_delta = @divTrunc(sum_delta, TrialCount);
    try stdout.print("\nsummary_best_delta={d}\n", .{best_delta});
    try stdout.print("summary_mean_delta={d}\n", .{mean_delta});
    try stdout.print("verdict=probe_only_no_language_generation_no_external_authority\n", .{});
}
