const std = @import("std");

// ════════════════════════════════════════════════════════════════════════════
//  Ghost — LEAN structured/exact invention engine (post VSA/LLM/GPU removal)
// ════════════════════════════════════════════════════════════════════════════
// The VSA/LLM/GPU engine + agentic platform were removed in the invention-engine transition;
// they live on origin at branch `backup/vsa-llm-gpu-engine`, fully recoverable. What remains is
// the VSA-free structured engine: the rank ladder, the structured/exact lattices, the certified
// rune forge, the medic self-heal pair, and the standalone math/feature discovery tools.
// CPU-only, no GPU, no shaders, no Vulkan, no libc. `zig build` and `zig build test`.
// ════════════════════════════════════════════════════════════════════════════

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // build_options — only what the lean core (config.zig + ghost.zig) actually reads.
    const opts = b.addOptions();
    opts.addOption([]const u8, "ghost_version", "V33-structured");
    opts.addOption(bool, "test_mode", false);
    opts.addOption([]const u8, "project_root", b.pathFromRoot("."));
    opts.addOption([]const u8, "platform_subdir", b.fmt("{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
    }));

    // ghost_core — the lean VSA-free substrate (rank + config + sys + forge).
    const ghost_core = b.createModule(.{
        .root_source_file = b.path("src/ghost.zig"),
        .target = target,
        .optimize = optimize,
    });
    ghost_core.addOptions("build_options", opts);

    // Tools that link ghost_core (certified runes + the medic self-heal pair).
    const core_clis = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "ghost_rune_forge", .root = "src/invention/rune_forge.zig" },
        .{ .name = "ghost_medic_ingest", .root = "src/medic_ingest_cli.zig" },
        .{ .name = "ghost_medic_solve", .root = "src/medic_solve_cli.zig" },
    };
    for (core_clis) |c| {
        const exe = b.addExecutable(.{
            .name = c.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(c.root),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("ghost_core", ghost_core);
        b.installArtifact(exe);
    }

    // Standalone invention/discovery tools (pure std — generate→test→keep with sound verifiers).
    const discover_tools = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "ghost_discover_laws", .root = "src/invention/discover_laws.zig" },
        .{ .name = "ghost_feature_invent", .root = "src/invention/feature_invent.zig" },
        .{ .name = "ghost_invent_sensors", .root = "src/invention/invent_sensors.zig" },
        .{ .name = "ghost_invent_compound", .root = "src/invention/invent_compound.zig" },
        .{ .name = "ghost_labs_search", .root = "src/invention/labs_search.zig" },
        .{ .name = "ghost_labs_smart", .root = "src/invention/labs_smart.zig" },
        .{ .name = "ghost_labs_theory", .root = "src/invention/labs_theory.zig" },
        .{ .name = "ghost_labs_invent", .root = "src/invention/labs_invent.zig" },
        .{ .name = "ghost_grow_basis", .root = "src/invention/grow_basis.zig" },
        .{ .name = "ghost_self_extend", .root = "src/invention/self_extend.zig" },
        .{ .name = "ghost_sortnet", .root = "src/invention/sortnet.zig" },
        .{ .name = "ghost_sortnet_optimal", .root = "src/invention/sortnet_optimal.zig" },
        .{ .name = "ghost_certifier", .root = "src/invention/certifier.zig" },
        .{ .name = "ghost_closedform", .root = "src/invention/discover_closedform.zig" },
        .{ .name = "ghost_auto_discover", .root = "src/invention/auto_discover.zig" },
        .{ .name = "ghost_divisor_discover", .root = "src/invention/divisor_discover.zig" },
        .{ .name = "ghost_double_discover", .root = "src/invention/double_discover.zig" },
        .{ .name = "ghost_recur_discover", .root = "src/invention/recur_discover.zig" },
        .{ .name = "ghost_prove_divisor", .root = "src/invention/prove_divisor.zig" },
        .{ .name = "ghost_prove_search", .root = "src/invention/prove_search.zig" },
        .{ .name = "ghost_prove_export", .root = "src/invention/prove_export.zig" },
    };
    for (discover_tools) |c| {
        const exe = b.addExecutable(.{
            .name = c.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(c.root),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(exe);
    }

    // Tests — compile EVERY source file and run the assertion suites. The headline certified
    // results are asserted directly (Fermat in discover_laws; Gauss/Möbius/σ in divisor_discover),
    // so a regression in a certified identity fails CI.
    const test_step = b.step("test", "Run the structured-engine test suite");

    // Targets that import ghost_core.
    const core_tests = [_][]const u8{
        "src/invention/exact_lattice.zig",
        "src/invention/rune_forge.zig",
        "src/medic_ingest_cli.zig",
        "src/medic_solve_cli.zig",
    };
    for (core_tests) |root| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        }) });
        t.root_module.addImport("ghost_core", ghost_core);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Standalone targets (build_options for the few that reach config via rank; harmless elsewhere).
    const standalone_tests = [_][]const u8{
        "src/ghost.zig",
        "src/forge.zig",
        "src/invention/structured_lattice.zig",
        "src/invention/feature_sim.zig",
        "src/invention/discover_laws.zig",
        "src/invention/feature_invent.zig",
        "src/invention/invent_sensors.zig",
        "src/invention/invent_compound.zig",
        "src/invention/labs_search.zig",
        "src/invention/labs_smart.zig",
        "src/invention/labs_theory.zig",
        "src/invention/labs_invent.zig",
        "src/invention/grow_basis.zig",
        "src/invention/self_extend.zig",
        "src/invention/sortnet.zig",
        "src/invention/sortnet_optimal.zig",
        "src/invention/certifier.zig",
        "src/invention/discover_closedform.zig",
        "src/invention/auto_discover.zig",
        "src/invention/divisor_discover.zig",
        "src/invention/double_discover.zig",
        "src/invention/recur_discover.zig",
        "src/invention/prove_divisor.zig",
        "src/invention/prove_search.zig",
        "src/invention/prove_export.zig",
    };
    for (standalone_tests) |root| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        }) });
        t.root_module.addOptions("build_options", opts);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
