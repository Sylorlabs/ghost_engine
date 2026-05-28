const std = @import("std");
const builtin = @import("builtin");

fn addCoreOptions(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    test_mode: bool,
    corpus_scan_spv_path: []const u8,
    lattice_query_spv_path: []const u8,
) *std.Build.Step.Options {
    const arch = target.result.cpu.arch;
    const features = target.result.cpu.features;
    const is_x86_64 = arch == .x86_64;

    var core_options = b.addOptions();
    core_options.addOption([]const u8, "ghost_version", "V32");
    core_options.addOption([]const u8, "project_root", b.pathFromRoot("."));
    core_options.addOption([]const u8, "platform_subdir", b.fmt(
        "platforms/{s}/{s}",
        .{ @tagName(target.result.os.tag), @tagName(arch) },
    ));
    core_options.addOption(bool, "test_mode", test_mode);
    core_options.addOption(bool, "use_avx2", is_x86_64 and std.Target.x86.featureSetHas(features, .avx2));
    core_options.addOption(bool, "use_neon", arch == .aarch64 or arch == .arm);
    core_options.addOption([]const u8, "corpus_scan_spv_path", corpus_scan_spv_path);
    core_options.addOption([]const u8, "lattice_query_spv_path", lattice_query_spv_path);
    const generated_shader_dir = b.pathFromRoot(".zig-cache/ghost_shaders");
    core_options.addOption([]const u8, "gemma_rune_embed_spv_path", b.pathJoin(&.{ generated_shader_dir, "rune_embed.spv" }));
    core_options.addOption([]const u8, "gemma_matmul_q4k_spv_path", b.pathJoin(&.{ generated_shader_dir, "matmul_q4k.spv" }));
    core_options.addOption([]const u8, "gemma_matmul_q8_0_spv_path", b.pathJoin(&.{ generated_shader_dir, "matmul_q8_0.spv" }));
    core_options.addOption([]const u8, "gemma_rms_norm_spv_path", b.pathJoin(&.{ generated_shader_dir, "rms_norm.spv" }));
    core_options.addOption([]const u8, "gemma_swiglu_spv_path", b.pathJoin(&.{ generated_shader_dir, "swiglu.spv" }));
    core_options.addOption([]const u8, "gemma_attention_spv_path", b.pathJoin(&.{ generated_shader_dir, "ghost_attention.spv" }));
    core_options.addOption([]const u8, "gemma_rune_project_spv_path", b.pathJoin(&.{ generated_shader_dir, "rune_project.spv" }));
    return core_options;
}

pub fn build(b: *std.Build) void {
    // Linux/x86_64 is the primary Ghost target. The default build specializes
    // for the local CPU; pass -Dtarget/-Dcpu to produce portable artifacts.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .gnu,
            .cpu_model = .native,
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const dev_native_backend = b.option(
        bool,
        "dev-native-backend",
        "Opt into Zig native codegen for scalar Debug checks; full Ghost VSA builds need LLVM on Zig 0.14.1",
    ) orelse false;
    const release_lto = b.option(
        bool,
        "release-lto",
        "Enable LTO for ReleaseFast builds when LLVM is active",
    ) orelse true;
    const strip_release = b.option(
        bool,
        "strip-release",
        "Strip ReleaseFast artifacts",
    ) orelse (optimize == .ReleaseFast);
    const omit_release_frame_pointer = b.option(
        bool,
        "omit-release-frame-pointer",
        "Omit frame pointers for ReleaseFast artifacts",
    ) orelse (optimize == .ReleaseFast);
    const use_llvm: ?bool = if (dev_native_backend) false else null;
    const use_lto = optimize == .ReleaseFast and release_lto and use_llvm != false;
    const release_strip: ?bool = if (strip_release) true else null;
    const release_omit_frame_pointer: ?bool = if (omit_release_frame_pointer) true else null;
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose name contains this text");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const generated_shader_dir = b.pathFromRoot(".zig-cache/ghost_shaders");
    const corpus_scan_spv_path = b.pathJoin(&.{ generated_shader_dir, "corpus_scan.spv" });
    const mkdir_generated_shaders = b.addSystemCommand(&.{ "mkdir", "-p", generated_shader_dir });
    const compile_corpus_scan_shader = b.addSystemCommand(&.{
        "glslc",
        b.pathFromRoot("src/shaders/corpus_scan.comp"),
        "-o",
        corpus_scan_spv_path,
    });
    compile_corpus_scan_shader.step.dependOn(&mkdir_generated_shaders.step);
    const phase2_search_spv_path = b.pathJoin(&.{ generated_shader_dir, "phase2_search.spv" });
    const compile_phase2_search_shader = b.addSystemCommand(&.{
        "glslc",
        b.pathFromRoot("src/gpu/search.comp"),
        "-o",
        phase2_search_spv_path,
    });
    compile_phase2_search_shader.step.dependOn(&mkdir_generated_shaders.step);
    compile_corpus_scan_shader.step.dependOn(&compile_phase2_search_shader.step);
    const gemma_shader_names = [_][]const u8{
        "rune_embed",
        "matmul_q4k",
        "matmul_q8_0",
        "rms_norm",
        "swiglu",
        "ghost_attention",
        "rune_project",
    };
    for (gemma_shader_names) |name| {
        const compile_gemma_shader = b.addSystemCommand(&.{
            "glslc",
            b.pathFromRoot(b.fmt("src/shaders/{s}.comp", .{name})),
            "-o",
            b.pathJoin(&.{ generated_shader_dir, b.fmt("{s}.spv", .{name}) }),
        });
        compile_gemma_shader.step.dependOn(&mkdir_generated_shaders.step);
        compile_corpus_scan_shader.step.dependOn(&compile_gemma_shader.step);
    }

    const native_gip_parser_check = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "test",
        b.pathFromRoot("src/compiler/gip_parser.zig"),
        "-fno-llvm",
        "-fno-emit-bin",
        "--cache-dir",
        b.pathFromRoot(".zig-cache"),
    });
    const native_gip_parser_step = b.step(
        "check-native-gip-parser",
        "Compile-check the scalar GIP parser with Zig native codegen and no emitted binary",
    );
    native_gip_parser_step.dependOn(&native_gip_parser_check.step);

    const core_options = addCoreOptions(b, target, false, corpus_scan_spv_path, phase2_search_spv_path);

    // ── 1. External Dependencies (Vulkan headers only) ──
    // NOTE: We do NOT link against vulkan-1.dll at build time.
    // The DLL is loaded dynamically at runtime via LoadLibraryA.
    // If the DLL is missing (no GPU driver), the engine falls back to CPU mode.
    const vulkan_sdk = b.graph.env_map.get("VULKAN_SDK");

    // ── 2. Sovereign Core Module ──
    const ghost_core = b.createModule(.{
        .root_source_file = b.path("src/ghost.zig"),
    });
    ghost_core.addOptions("build_options", core_options);
    if (target.result.os.tag == .windows) {
        if (vulkan_sdk) |sdk| {
            ghost_core.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Include" }) });
        }
    } else if (target.result.os.tag == .linux) {
        ghost_core.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        ghost_core.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
    }

    const domain_inference_module = b.createModule(.{
        .root_source_file = b.path("src/domain/inference.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
        .strip = release_strip,
        .omit_frame_pointer = release_omit_frame_pointer,
    });
    const anchor_discovery_module = b.createModule(.{
        .root_source_file = b.path("src/analysis/anchors.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
        .strip = release_strip,
        .omit_frame_pointer = release_omit_frame_pointer,
    });
    anchor_discovery_module.addImport("domain_inference", domain_inference_module);
    const semantic_tensor_module = b.createModule(.{
        .root_source_file = b.path("src/semantics/tensor.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
        .strip = release_strip,
        .omit_frame_pointer = release_omit_frame_pointer,
    });
    semantic_tensor_module.addImport("domain_inference", domain_inference_module);
    const z3_bridge_module = b.createModule(.{
        .root_source_file = b.path("src/verification/z3_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
        .strip = release_strip,
        .omit_frame_pointer = release_omit_frame_pointer,
    });
    if (target.result.os.tag == .linux) {
        z3_bridge_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        z3_bridge_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
        z3_bridge_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
    }
    const proof_session_module = b.createModule(.{
        .root_source_file = b.path("src/core/proof_session.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
        .strip = release_strip,
        .omit_frame_pointer = release_omit_frame_pointer,
    });
    ghost_core.addImport("proof_session", proof_session_module);
    ghost_core.addImport("z3_bridge", z3_bridge_module);
    z3_bridge_module.addImport("anchor_discovery", anchor_discovery_module);
    z3_bridge_module.addImport("semantic_tensor", semantic_tensor_module);
    z3_bridge_module.addImport("proof_session", proof_session_module);

    // Helper: add Vulkan include path to any module that imports ghost_core
    // (needed because @cImport in vulkan_loader.zig resolves headers at the root_module level)
    const addVulkanIncludes = struct {
        fn add(mod: *std.Build.Module, os: std.Target.Os, sdk_opt: ?[]const u8, builder: *std.Build) void {
            if (os.tag == .windows) {
                if (sdk_opt) |sdk| {
                    mod.addIncludePath(.{ .cwd_relative = builder.pathJoin(&.{ sdk, "Include" }) });
                }
            } else if (os.tag == .linux) {
                mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
                mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
                mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
            }
        }
    }.add;

    const addGhostExecutable = struct {
        fn add(
            builder: *std.Build,
            exe_name: []const u8,
            root: []const u8,
            exe_target: std.Build.ResolvedTarget,
            exe_optimize: std.builtin.OptimizeMode,
            core_module: *std.Build.Module,
            options: *std.Build.Step.Options,
            os: std.Target.Os,
            sdk_opt: ?[]const u8,
            exe_use_llvm: ?bool,
            exe_use_lto: bool,
            exe_strip: ?bool,
            exe_omit_frame_pointer: ?bool,
            add_vulkan_includes: *const fn (*std.Build.Module, std.Target.Os, ?[]const u8, *std.Build) void,
            shader_step: *std.Build.Step.Run,
        ) *std.Build.Step.Compile {
            const exe = builder.addExecutable(.{
                .name = exe_name,
                .use_llvm = exe_use_llvm,
                .root_module = builder.createModule(.{
                    .root_source_file = builder.path(root),
                    .target = exe_target,
                    .optimize = exe_optimize,
                    .code_model = .small,
                    .strip = exe_strip,
                    .omit_frame_pointer = exe_omit_frame_pointer,
                }),
            });
            exe.want_lto = exe_use_lto;
            exe.root_module.addImport("ghost_core", core_module);
            exe.root_module.addOptions("build_options", options);
            exe.root_module.linkSystemLibrary("c", .{});
            if (os.tag == .linux) {
                exe.root_module.linkSystemLibrary("dl", .{});
            }
            add_vulkan_includes(exe.root_module, os, sdk_opt, builder);
            if (std.mem.eql(u8, exe_name, "ghost_sovereign") and os.tag == .windows) {
                exe.root_module.linkSystemLibrary("ws2_32", .{});
            }
            exe.step.dependOn(&shader_step.step);
            return exe;
        }
    }.add;

    const phase2_hypervector_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vsa/hypervector.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    phase2_hypervector_tests.want_lto = use_lto;
    const run_phase2_hypervector_tests = b.addRunArtifact(phase2_hypervector_tests);

    const phase2_vulkan_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/vulkan_init.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    phase2_vulkan_tests.want_lto = use_lto;
    phase2_vulkan_tests.step.dependOn(&compile_phase2_search_shader.step);
    phase2_vulkan_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        phase2_vulkan_tests.root_module.linkSystemLibrary("dl", .{});
    }
    addVulkanIncludes(phase2_vulkan_tests.root_module, target.result.os, vulkan_sdk, b);
    const run_phase2_vulkan_tests = b.addRunArtifact(phase2_vulkan_tests);

    const phase2_oracle_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/oracle/compiler_loop.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    phase2_oracle_tests.want_lto = use_lto;
    const run_phase2_oracle_tests = b.addRunArtifact(phase2_oracle_tests);

    const swe_harness_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_swe_harness.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    swe_harness_tests.want_lto = use_lto;
    const run_swe_harness_tests = b.addRunArtifact(swe_harness_tests);

    const phase3_ipc_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ipc/protocol.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    phase3_ipc_tests.want_lto = use_lto;
    const run_phase3_ipc_tests = b.addRunArtifact(phase3_ipc_tests);

    const phase3_wingman_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zenith/wingman.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    phase3_wingman_tests.want_lto = use_lto;
    const run_phase3_wingman_tests = b.addRunArtifact(phase3_wingman_tests);

    const zenith_bridge_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zenith/bridge.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    zenith_bridge_tests.want_lto = use_lto;
    const run_zenith_bridge_tests = b.addRunArtifact(zenith_bridge_tests);

    const lattice_view_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/lattice_view.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    lattice_view_tests.root_module.addImport("ghost_core", ghost_core);
    lattice_view_tests.want_lto = use_lto;
    const run_lattice_view_tests = b.addRunArtifact(lattice_view_tests);

    const phase4_auto_fix_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/oracle/auto_fix.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    phase4_auto_fix_tests.want_lto = use_lto;
    const run_phase4_auto_fix_tests = b.addRunArtifact(phase4_auto_fix_tests);

    const phase4_curiosity_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ghost/curiosity.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    phase4_curiosity_tests.want_lto = use_lto;
    const run_phase4_curiosity_tests = b.addRunArtifact(phase4_curiosity_tests);

    const phase5_hive_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/net/hive.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    phase5_hive_tests.want_lto = use_lto;
    const run_phase5_hive_tests = b.addRunArtifact(phase5_hive_tests);

    const phase6_recursive_boot_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ghost/recursive_boot.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    phase6_recursive_boot_tests.want_lto = use_lto;
    const run_phase6_recursive_boot_tests = b.addRunArtifact(phase6_recursive_boot_tests);

    const phase2_step = b.step("test-phase2-core", "Run Phase 2 VSA, Vulkan stage-gate, and Reality Oracle tests");
    phase2_step.dependOn(&run_phase2_hypervector_tests.step);
    phase2_step.dependOn(&run_phase2_vulkan_tests.step);
    phase2_step.dependOn(&run_phase2_oracle_tests.step);

    const swe_harness_step = b.step("test-swe-harness", "Run native SWE provisioning harness tests");
    swe_harness_step.dependOn(&run_swe_harness_tests.step);

    const phase3_step = b.step("test-phase3-integration", "Run Phase 3 IPC and Wingman integration tests");
    phase3_step.dependOn(&run_phase3_ipc_tests.step);
    phase3_step.dependOn(&run_phase3_wingman_tests.step);
    phase3_step.dependOn(&run_zenith_bridge_tests.step);
    phase3_step.dependOn(&run_lattice_view_tests.step);

    const phase456_step = b.step("test-phase456", "Run explicit Phase 4/5/6 oracle, curiosity, hive, and recursive boot tests");
    phase456_step.dependOn(&run_phase4_auto_fix_tests.step);
    phase456_step.dependOn(&run_phase4_curiosity_tests.step);
    phase456_step.dependOn(&run_phase5_hive_tests.step);
    phase456_step.dependOn(&run_phase6_recursive_boot_tests.step);

    // ── 3. Shader SPIR-V ──
    const shader_names = [_][]const u8{
        "resonance_query",
        "genesis_etch",
        "thermal_prune",
        "recursive_lookahead",
        "lattice_etch",
        "candidate_score",
        "neighborhood_score",
        "contradiction_filter",
        "semantic_hash",
        "rune_search",
    };
    for (shader_names) |name| {
        const spv_path = b.pathJoin(&.{ "src", "shaders", b.fmt("{s}.spv", .{name}) });
        _ = b.path(spv_path);
    }

    // Helper: configure an executable with ghost_core (no Vulkan link-time dependency)
    const ExeConfig = struct {
        name: []const u8,
        root: []const u8,
    };
    const monolith = addGhostExecutable(
        b,
        "ghost_sovereign",
        "src/main.zig",
        target,
        optimize,
        ghost_core,
        core_options,
        target.result.os,
        vulkan_sdk,
        use_llvm,
        use_lto,
        release_strip,
        release_omit_frame_pointer,
        addVulkanIncludes,
        compile_corpus_scan_shader,
    );
    monolith.root_module.addImport("domain_inference", domain_inference_module);
    monolith.root_module.addImport("anchor_discovery", anchor_discovery_module);
    monolith.root_module.addImport("semantic_tensor", semantic_tensor_module);
    monolith.root_module.addImport("z3_bridge", z3_bridge_module);
    monolith.root_module.linkSystemLibrary("z3", .{});
    b.installArtifact(monolith);

    const exes = [_]ExeConfig{
        .{ .name = "ohl_trainer", .root = "src/trainer.zig" },
        .{ .name = "probe_inference", .root = "src/probe_inference.zig" },
        .{ .name = "sigil_core", .root = "src/sigil_core.zig" },
        .{ .name = "ghost_code_intel", .root = "src/code_intel_cli.zig" },
        .{ .name = "ghost_corpus_ingest", .root = "src/corpus_ingest_cli.zig" },
        .{ .name = "ghost_invent", .root = "src/invent_cli.zig" },
        .{ .name = "ghost_medic_ingest", .root = "src/medic_ingest_cli.zig" },
        .{ .name = "ghost_medic_solve", .root = "src/medic_solve_cli.zig" },
        .{ .name = "ghost_patch_candidates", .root = "src/patch_candidates_cli.zig" },
        .{ .name = "ghost_panic_dump", .root = "src/panic_dump_cli.zig" },
        .{ .name = "ghost_task_intent", .root = "src/task_intent_cli.zig" },
        .{ .name = "ghost_task_operator", .root = "src/task_operator_cli.zig" },
        .{ .name = "ghost_intent_grounding", .root = "src/intent_grounding_cli.zig" },
        .{ .name = "ghost_knowledge_pack", .root = "src/knowledge_packs.zig" },
        .{ .name = "ghost_gip", .root = "src/gip_cli.zig" },
        .{ .name = "ghost_gemma", .root = "src/gemma_cli.zig" },
        .{ .name = "ghost_swe_harness", .root = "src/swe_harness_cli.zig" },
        .{ .name = "sigil", .root = "src/ui/sigil.zig" },
        .{ .name = "lattice_view", .root = "src/ui/lattice_view.zig" },
        .{ .name = "ghostd", .root = "src/daemon.zig" },
        .{ .name = "ghost_project_autopsy", .root = "src/project_autopsy_cli.zig" },
        .{ .name = "ghost_forge", .root = "src/forge_cli.zig" },
        .{ .name = "ghost_semantic_test", .root = "src/semantic_test_cli.zig" },
    };

    for (exes) |cfg| {
        const exe = addGhostExecutable(
            b,
            cfg.name,
            cfg.root,
            target,
            optimize,
            ghost_core,
            core_options,
            target.result.os,
            vulkan_sdk,
            use_llvm,
            use_lto,
            release_strip,
            release_omit_frame_pointer,
            addVulkanIncludes,
            compile_corpus_scan_shader,
        );
        if (std.mem.eql(u8, cfg.name, "ghostd") or std.mem.eql(u8, cfg.name, "ghost_gip") or std.mem.eql(u8, cfg.name, "ghost_invent") or std.mem.eql(u8, cfg.name, "ghost_gemma")) {
            exe.root_module.addImport("domain_inference", domain_inference_module);
            exe.root_module.addImport("anchor_discovery", anchor_discovery_module);
            exe.root_module.addImport("semantic_tensor", semantic_tensor_module);
            exe.root_module.addImport("z3_bridge", z3_bridge_module);
            exe.root_module.linkSystemLibrary("z3", .{});
        }
        const install_exe = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install_exe.step);
        if (std.mem.eql(u8, cfg.name, "ghost_gemma")) {
            const gemma_weights_cli_step = b.step("ghost-gemma-weights", "Build the explicit Ghost Gemma GGUF weight inventory CLI");
            gemma_weights_cli_step.dependOn(&install_exe.step);
        }
    }

    const zenith_bridge_lib = b.addLibrary(.{
        .name = "zenith_wingman_bridge",
        .linkage = .dynamic,
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zenith/bridge.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .code_model = .small,
            .strip = true,
            .omit_frame_pointer = true,
        }),
    });
    zenith_bridge_lib.want_lto = use_llvm != false;
    b.installArtifact(zenith_bridge_lib);

    // ── 8. Run Step ──
    const run_cmd = b.addRunArtifact(monolith);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ── Phase 5: two-stage geometric compiler demo ──
    // Deliberately DECOUPLED from the ghost_core module graph (mirrors the
    // verify_cli precedent): it only needs std + libz3, so it builds and runs
    // even when unrelated parts of the engine are mid-change. Run with:
    //   zig build verified-swap
    {
        const verified_swap = b.addExecutable(.{
            .name = "verified_swap",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/verified_swap.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        verified_swap.root_module.linkSystemLibrary("c", .{});
        verified_swap.root_module.linkSystemLibrary("z3", .{});
        verified_swap.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        verified_swap.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
        verified_swap.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        b.installArtifact(verified_swap);
        const run_verified_swap = b.addRunArtifact(verified_swap);
        const verified_swap_step = b.step("verified-swap", "Build+run the Phase 5 two-stage geometric compiler demo (validator + real Z3)");
        verified_swap_step.dependOn(&run_verified_swap.step);
    }

    {
        const test_uaf = b.addExecutable(.{
            .name = "test_uaf",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test_uaf.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_uaf.root_module.linkSystemLibrary("c", .{});
        test_uaf.root_module.linkSystemLibrary("z3", .{});
        test_uaf.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        test_uaf.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
        test_uaf.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        b.installArtifact(test_uaf);
        const run_test_uaf = b.addRunArtifact(test_uaf);
        const test_uaf_step = b.step("test-uaf", "Build+run the Phase 8 UAF crucible demo");
        test_uaf_step.dependOn(&run_test_uaf.step);
    }

    // ── Phase 6: autonomous guard placement (counterexample-guided repair) ──
    // Same decoupled std+libz3 wiring. Run with:  zig build autonomous-guard
    {
        const autonomous_guard = b.addExecutable(.{
            .name = "autonomous_guard",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/autonomous_guard.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        autonomous_guard.root_module.linkSystemLibrary("c", .{});
        autonomous_guard.root_module.linkSystemLibrary("z3", .{});
        autonomous_guard.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        autonomous_guard.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
        autonomous_guard.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        b.installArtifact(autonomous_guard);
        const run_autonomous_guard = b.addRunArtifact(autonomous_guard);
        const autonomous_guard_step = b.step("autonomous-guard", "Build+run the Phase 6 autonomous guard-placement repair loop (Z3 SAT -> inject guard -> UNSAT)");
        autonomous_guard_step.dependOn(&run_autonomous_guard.step);
    }

    // ── Phase 8: Leviathan stream — Skim (VSA dedup) + Expand (real libz3) ──
    // Same decoupled std+libz3 wiring. Run with:  zig build leviathan-stream
    {
        const leviathan = b.addExecutable(.{
            .name = "leviathan_stream",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/compiler/leviathan_stream.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        leviathan.root_module.linkSystemLibrary("c", .{});
        leviathan.root_module.linkSystemLibrary("z3", .{});
        leviathan.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        leviathan.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
        leviathan.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        b.installArtifact(leviathan);
        const run_leviathan = b.addRunArtifact(leviathan);
        const leviathan_step = b.step("leviathan-stream", "Build+run Phase 8 Skim-and-Expand: VSA dedup sieve + on-demand real-Z3 island verification");
        leviathan_step.dependOn(&run_leviathan.step);
    }

    // ── Phase 9.1 (FROZEN REGRESSION): Wasm spike → array-theory bounds proof ──
    // Frozen baseline. New analysis lives in Phase 10. This step exists ONLY
    // to keep the original single-load pipeline green as a regression check.
    // Run with:  zig build wasm-spike-phase9-regression
    {
        const wasm_spike = b.addExecutable(.{
            .name = "wasm_cartographer_phase9",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/compiler/wasm_cartographer_phase9.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        wasm_spike.root_module.linkSystemLibrary("c", .{});
        wasm_spike.root_module.linkSystemLibrary("z3", .{});
        wasm_spike.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        wasm_spike.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
        wasm_spike.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        b.installArtifact(wasm_spike);
        const run_wasm_spike = b.addRunArtifact(wasm_spike);
        const wasm_spike_step = b.step("wasm-spike-phase9-regression", "FROZEN BASELINE: Phase 9.1 single-load array-theory bounds proof. New work belongs in zig build phase10-provenance.");
        wasm_spike_step.dependOn(&run_wasm_spike.step);
    }

    // ── Phase 10: Provenance Tracker — typed-stack symbolic exec + R5 unroll ──
    // Three-fixture acceptance test (Spec v3): A vulnerable -> SAT, B safe -> UNSAT,
    // C xor-aliased -> UNANALYZABLE. Run with:  zig build phase10-provenance
    {
        const phase10 = b.addExecutable(.{
            .name = "phase10_provenance",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/compiler/phase10_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        phase10.root_module.linkSystemLibrary("c", .{});
        phase10.root_module.linkSystemLibrary("z3", .{});
        phase10.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        phase10.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
        phase10.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        b.installArtifact(phase10);
        const run_phase10 = b.addRunArtifact(phase10);
        const phase10_step = b.step("phase10-provenance", "Build+run Phase 10 acceptance: A=SAT, B=UNSAT, C=UNANALYZABLE with real Z3 (Spec v3)");
        phase10_step.dependOn(&run_phase10.step);
    }

    // ── Phase 2.0: V2 bootstrap — dynamic codebook + SyGuS axiom discovery + Z3 integration proof ──
    // Same decoupled std+libz3 wiring. Run with:  zig build v2-bootstrap
    {
        const v2_bootstrap = b.addExecutable(.{
            .name = "v2_bootstrap",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test_v2_bootstrap.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        v2_bootstrap.root_module.linkSystemLibrary("c", .{});
        v2_bootstrap.root_module.linkSystemLibrary("z3", .{});
        v2_bootstrap.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        v2_bootstrap.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
        v2_bootstrap.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        b.installArtifact(v2_bootstrap);
        const run_v2_bootstrap = b.addRunArtifact(v2_bootstrap);
        const v2_bootstrap_step = b.step("v2-bootstrap", "Build+run Phase 2.0: dynamic codebook + SyGuS axiom discovery + Z3 integration proof");
        v2_bootstrap_step.dependOn(&run_v2_bootstrap.step);
    }

    // ── Phase 2.1: V2 boundary — characterize depth-2 synthesis limits with unary grammar ──
    // std-only; no z3, no ghost_core. Run with:  zig build v2-boundary
    {
        const v2_boundary = b.addExecutable(.{
            .name = "v2_boundary",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test_v2_boundary.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(v2_boundary);
        const run_v2_boundary = b.addRunArtifact(v2_boundary);
        const v2_boundary_step = b.step("v2-boundary", "Build+run Phase 2.1: depth-2 boundary characterization with unary bvnot/bvneg grammar");
        v2_boundary_step.dependOn(&run_v2_boundary.step);
    }

    const bench_exe = addGhostExecutable(
        b,
        "ghost_bench_serious_workflows",
        "src/bench_serious_workflows.zig",
        target,
        optimize,
        ghost_core,
        core_options,
        target.result.os,
        vulkan_sdk,
        use_llvm,
        use_lto,
        release_strip,
        release_omit_frame_pointer,
        addVulkanIncludes,
        compile_corpus_scan_shader,
    );
    const compute_bench_exe = addGhostExecutable(
        b,
        "ghost_bench_compute_dominance",
        "src/bench_compute_dominance.zig",
        target,
        optimize,
        ghost_core,
        core_options,
        target.result.os,
        vulkan_sdk,
        use_llvm,
        use_lto,
        release_strip,
        release_omit_frame_pointer,
        addVulkanIncludes,
        compile_corpus_scan_shader,
    );
    const run_compute_bench = b.addRunArtifact(compute_bench_exe);
    run_compute_bench.step.dependOn(b.getInstallStep());
    const compute_bench_step = b.step("bench-compute-dominance", "Run local compute dominance benchmark scenarios");
    compute_bench_step.dependOn(&run_compute_bench.step);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench-serious-workflows", "Run the serious workflow benchmark suite");
    bench_step.dependOn(&run_compute_bench.step);
    bench_step.dependOn(&run_bench.step);

    const hygiene_cmd = b.addSystemCommand(&.{
        "git",
        "status",
        "--short",
        "--untracked-files=all",
    });
    hygiene_cmd.has_side_effects = true;
    const hygiene_step = b.step("repo-hygiene", "Print repository status after ignoring generated Ghost state");
    hygiene_step.dependOn(&hygiene_cmd.step);

    const artifact_autopsy_smoke_cmd = b.addSystemCommand(&.{
        "bash",
        "tools/smoke_artifact_autopsy.sh",
    });
    artifact_autopsy_smoke_cmd.setCwd(b.path("."));
    artifact_autopsy_smoke_cmd.has_side_effects = true;
    artifact_autopsy_smoke_cmd.step.dependOn(b.getInstallStep());
    const artifact_autopsy_smoke_step = b.step("smoke-artifact-autopsy", "Run artifact autopsy smoke fixtures");
    artifact_autopsy_smoke_step.dependOn(&artifact_autopsy_smoke_cmd.step);

    const gemma_weights_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gemma/weights.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    gemma_weights_tests.want_lto = use_lto;
    gemma_weights_tests.root_module.addOptions("build_options", core_options);
    gemma_weights_tests.root_module.linkSystemLibrary("c", .{});
    const run_gemma_weights_tests = b.addRunArtifact(gemma_weights_tests);
    const gemma_weights_step = b.step("test-gemma-weights", "Run GGUF parser and Gemma weight inventory tests");
    gemma_weights_step.dependOn(&run_gemma_weights_tests.step);

    const gemma_inference_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gemma_native_tests.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    gemma_inference_tests.want_lto = use_lto;
    gemma_inference_tests.root_module.addOptions("build_options", core_options);
    gemma_inference_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        gemma_inference_tests.root_module.linkSystemLibrary("dl", .{});
        gemma_inference_tests.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(gemma_inference_tests.root_module, target.result.os, vulkan_sdk, b);
    const run_gemma_inference_tests = b.addRunArtifact(gemma_inference_tests);

    const gemma_agent_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gemma_native_tests.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    gemma_agent_tests.want_lto = use_lto;
    gemma_agent_tests.root_module.addOptions("build_options", core_options);
    gemma_agent_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        gemma_agent_tests.root_module.linkSystemLibrary("dl", .{});
        gemma_agent_tests.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(gemma_agent_tests.root_module, target.result.os, vulkan_sdk, b);
    const run_gemma_agent_tests = b.addRunArtifact(gemma_agent_tests);
    
    // Add the agents test back to the native step
    const gemma_native_step = b.step("test-gemma-native", "Run Ghost-native Gemma rune, attention, inference, and agent-router tests");
    gemma_native_step.dependOn(&run_gemma_inference_tests.step);
    gemma_native_step.dependOn(&run_gemma_agent_tests.step);

    const text_generation_lab_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/text_generation_lab.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    text_generation_lab_tests.want_lto = use_lto;
    text_generation_lab_tests.step.dependOn(&compile_corpus_scan_shader.step);
    const text_generation_lab_options = addCoreOptions(b, target, true, corpus_scan_spv_path, phase2_search_spv_path);
    text_generation_lab_tests.root_module.addOptions("build_options", text_generation_lab_options);
    text_generation_lab_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        text_generation_lab_tests.root_module.linkSystemLibrary("dl", .{});
        text_generation_lab_tests.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(text_generation_lab_tests.root_module, target.result.os, vulkan_sdk, b);
    const run_text_generation_lab_tests = b.addRunArtifact(text_generation_lab_tests);
    const text_generation_lab_smoke_step = b.step("smoke-text-generation-lab", "Run experimental text generation lab tests and fixture corpus smoke");
    text_generation_lab_smoke_step.dependOn(&run_text_generation_lab_tests.step);

    // ── 9. Unit & Integration Tests ──
    const main_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/test_routing.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    main_tests.want_lto = use_lto;
    main_tests.step.dependOn(&compile_corpus_scan_shader.step);
    const test_core_options = addCoreOptions(b, target, true, corpus_scan_spv_path, phase2_search_spv_path);
    swe_harness_tests.root_module.addOptions("build_options", test_core_options);
    swe_harness_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        swe_harness_tests.root_module.linkSystemLibrary("dl", .{});
        swe_harness_tests.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(swe_harness_tests.root_module, target.result.os, vulkan_sdk, b);
    const ghost_core_test = b.createModule(.{
        .root_source_file = b.path("src/ghost.zig"),
    });
    ghost_core_test.addImport("proof_session", proof_session_module);
    ghost_core_test.addOptions("build_options", test_core_options);
    if (target.result.os.tag == .windows) {
        if (vulkan_sdk) |sdk| {
            ghost_core_test.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Include" }) });
        }
    } else if (target.result.os.tag == .linux) {
        ghost_core_test.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        ghost_core_test.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
    }
    main_tests.root_module.addOptions("build_options", test_core_options);
    main_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        main_tests.root_module.linkSystemLibrary("dl", .{});
        main_tests.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(main_tests.root_module, target.result.os, vulkan_sdk, b);

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_smoke_step = b.step("test-smoke", "Run src/test_smoke.zig tests");
    test_smoke_step.dependOn(&run_main_tests.step);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(phase2_step);
    test_step.dependOn(phase3_step);
    test_step.dependOn(phase456_step);
    test_step.dependOn(swe_harness_step);
    test_step.dependOn(gemma_native_step);
    run_text_generation_lab_tests.step.dependOn(&run_main_tests.step);

    const lifecycle_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_verifier_lifecycle.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    lifecycle_tests.want_lto = use_lto;
    lifecycle_tests.step.dependOn(&compile_corpus_scan_shader.step);
    lifecycle_tests.root_module.addOptions("build_options", test_core_options);
    lifecycle_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        lifecycle_tests.root_module.linkSystemLibrary("dl", .{});
        lifecycle_tests.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(lifecycle_tests.root_module, target.result.os, vulkan_sdk, b);
    const run_lifecycle_tests = b.addRunArtifact(lifecycle_tests);
    run_lifecycle_tests.step.dependOn(&run_text_generation_lab_tests.step);
    const test_lifecycle_step = b.step("test-lifecycle", "Run src/test_verifier_lifecycle.zig tests");
    test_lifecycle_step.dependOn(&run_lifecycle_tests.step);

    const gip_cli_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gip_cli.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    gip_cli_tests.want_lto = use_lto;
    gip_cli_tests.step.dependOn(&compile_corpus_scan_shader.step);
    gip_cli_tests.root_module.addImport("ghost_core", ghost_core_test);
    gip_cli_tests.root_module.addOptions("build_options", test_core_options);
    gip_cli_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        gip_cli_tests.root_module.linkSystemLibrary("dl", .{});
        gip_cli_tests.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(gip_cli_tests.root_module, target.result.os, vulkan_sdk, b);
    const run_gip_cli_tests = b.addRunArtifact(gip_cli_tests);
    run_gip_cli_tests.step.dependOn(&run_lifecycle_tests.step);
    const test_gip_cli_step = b.step("test-gip-cli", "Run src/gip_cli.zig tests");
    test_gip_cli_step.dependOn(&run_gip_cli_tests.step);

    const knowledge_pack_cli_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/knowledge_packs.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    knowledge_pack_cli_tests.want_lto = use_lto;
    knowledge_pack_cli_tests.step.dependOn(&compile_corpus_scan_shader.step);
    knowledge_pack_cli_tests.root_module.addOptions("build_options", test_core_options);
    knowledge_pack_cli_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        knowledge_pack_cli_tests.root_module.linkSystemLibrary("dl", .{});
        knowledge_pack_cli_tests.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(knowledge_pack_cli_tests.root_module, target.result.os, vulkan_sdk, b);
    const run_knowledge_pack_cli_tests = b.addRunArtifact(knowledge_pack_cli_tests);
    run_knowledge_pack_cli_tests.step.dependOn(&run_gip_cli_tests.step);
    const test_knowledge_packs_step = b.step("test-knowledge-packs", "Run src/knowledge_packs.zig tests");
    test_knowledge_packs_step.dependOn(&run_knowledge_pack_cli_tests.step);

    const project_autopsy_cli_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/project_autopsy_cli.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    project_autopsy_cli_tests.want_lto = use_lto;
    project_autopsy_cli_tests.step.dependOn(&compile_corpus_scan_shader.step);
    project_autopsy_cli_tests.root_module.addImport("ghost_core", ghost_core_test);
    project_autopsy_cli_tests.root_module.addOptions("build_options", test_core_options);
    project_autopsy_cli_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        project_autopsy_cli_tests.root_module.linkSystemLibrary("dl", .{});
        project_autopsy_cli_tests.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(project_autopsy_cli_tests.root_module, target.result.os, vulkan_sdk, b);
    const run_project_autopsy_cli_tests = b.addRunArtifact(project_autopsy_cli_tests);
    run_project_autopsy_cli_tests.step.dependOn(&run_knowledge_pack_cli_tests.step);
    const test_project_autopsy_step = b.step("test-project-autopsy-cli", "Run src/project_autopsy_cli.zig tests");
    test_project_autopsy_step.dependOn(&run_project_autopsy_cli_tests.step);

    const compute_dominance_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_compute_dominance.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    compute_dominance_tests.want_lto = use_lto;
    compute_dominance_tests.step.dependOn(&compile_corpus_scan_shader.step);
    compute_dominance_tests.root_module.addImport("ghost_core", ghost_core_test);
    compute_dominance_tests.root_module.addOptions("build_options", test_core_options);
    compute_dominance_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        compute_dominance_tests.root_module.linkSystemLibrary("dl", .{});
        compute_dominance_tests.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(compute_dominance_tests.root_module, target.result.os, vulkan_sdk, b);
    const run_compute_dominance_tests = b.addRunArtifact(compute_dominance_tests);
    run_compute_dominance_tests.step.dependOn(&run_project_autopsy_cli_tests.step);
    const test_compute_dominance_step = b.step("test-compute-dominance", "Run src/bench_compute_dominance.zig tests");
    test_compute_dominance_step.dependOn(&run_compute_dominance_tests.step);

    const crucible_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/the_crucible.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .filters = test_filters,
    });
    crucible_tests.want_lto = use_lto;
    crucible_tests.step.dependOn(&compile_corpus_scan_shader.step);
    crucible_tests.root_module.addImport("ghost_core", ghost_core_test);
    crucible_tests.root_module.addOptions("build_options", test_core_options);
    crucible_tests.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        crucible_tests.root_module.linkSystemLibrary("dl", .{});
        crucible_tests.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(crucible_tests.root_module, target.result.os, vulkan_sdk, b);
    const run_crucible_tests = b.addRunArtifact(crucible_tests);
    const test_crucible_step = b.step("test-crucible", "Run the adversarial Technical Axiom Matrix crucible");
    test_crucible_step.dependOn(&run_crucible_tests.step);
    // test_step.dependOn(&run_compute_dominance_tests.step);
    test_step.dependOn(&run_crucible_tests.step);

    // ── 10. Parity Test ──
    const parity_test = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_parity.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
        .test_runner = .{
            .path = b.path("src/parity_test_runner.zig"),
            .mode = .simple,
        },
    });
    parity_test.want_lto = use_lto;
    parity_test.step.dependOn(&compile_corpus_scan_shader.step);
    parity_test.root_module.addImport("ghost_core", ghost_core);
    parity_test.root_module.addOptions("build_options", core_options);
    parity_test.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        parity_test.root_module.addLibraryPath(.{ .cwd_relative = "/lib/x86_64-linux-gnu" });
        parity_test.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        parity_test.root_module.linkSystemLibrary("dl", .{});
        parity_test.root_module.linkSystemLibrary("vulkan", .{});
    }
    addVulkanIncludes(parity_test.root_module, target.result.os, vulkan_sdk, b);

    const run_parity_test = b.addRunArtifact(parity_test);
    run_parity_test.stdio = .inherit;
    run_parity_test.has_side_effects = true;
    const parity_step = b.step("test-parity", "Run Vulkan GPU <-> CPU Parity Tests");
    parity_step.dependOn(&run_parity_test.step);

    // ── 11. Release Packaging ──
    // Creates a clean distributable folder with the selected target layout.
    const release_step = b.step("release", "Build and package a distributable release");
    const release_core_options = addCoreOptions(b, target, false, corpus_scan_spv_path, phase2_search_spv_path);
    const release_proof_session_module = b.createModule(.{
        .root_source_file = b.path("src/core/proof_session.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .code_model = .small,
        .strip = true,
        .omit_frame_pointer = true,
    });
    const release_domain_inference_module = b.createModule(.{
        .root_source_file = b.path("src/domain/inference.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .code_model = .small,
        .strip = true,
        .omit_frame_pointer = true,
    });
    const release_anchor_discovery_module = b.createModule(.{
        .root_source_file = b.path("src/analysis/anchors.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .code_model = .small,
        .strip = true,
        .omit_frame_pointer = true,
    });
    release_anchor_discovery_module.addImport("domain_inference", release_domain_inference_module);
    const release_semantic_tensor_module = b.createModule(.{
        .root_source_file = b.path("src/semantics/tensor.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .code_model = .small,
        .strip = true,
        .omit_frame_pointer = true,
    });
    release_semantic_tensor_module.addImport("domain_inference", release_domain_inference_module);
    const release_z3_bridge_module = b.createModule(.{
        .root_source_file = b.path("src/verification/z3_bridge.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .code_model = .small,
        .strip = true,
        .omit_frame_pointer = true,
    });
    if (target.result.os.tag == .linux) {
        release_z3_bridge_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        release_z3_bridge_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
        release_z3_bridge_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
    }
    release_z3_bridge_module.addImport("anchor_discovery", release_anchor_discovery_module);
    release_z3_bridge_module.addImport("semantic_tensor", release_semantic_tensor_module);
    release_z3_bridge_module.addImport("proof_session", release_proof_session_module);
    const release_ghost_core = b.createModule(.{
        .root_source_file = b.path("src/ghost.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .code_model = .small,
        .strip = true,
        .omit_frame_pointer = true,
    });
    release_ghost_core.addImport("proof_session", release_proof_session_module);
    release_ghost_core.addImport("z3_bridge", release_z3_bridge_module);
    release_ghost_core.addOptions("build_options", release_core_options);
    if (target.result.os.tag == .windows) {
        if (vulkan_sdk) |sdk| {
            release_ghost_core.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Include" }) });
        }
    } else if (target.result.os.tag == .linux) {
        release_ghost_core.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        release_ghost_core.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
    }

    const release_exe = b.addExecutable(.{
        .name = "ghost_sovereign",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .code_model = .small,
            .strip = true,
            .omit_frame_pointer = true,
        }),
    });
    release_exe.want_lto = release_lto;
    release_exe.step.dependOn(&compile_corpus_scan_shader.step);
    release_exe.root_module.addImport("ghost_core", release_ghost_core);
    release_exe.root_module.addImport("domain_inference", release_domain_inference_module);
    release_exe.root_module.addImport("anchor_discovery", release_anchor_discovery_module);
    release_exe.root_module.addImport("semantic_tensor", release_semantic_tensor_module);
    release_exe.root_module.addImport("z3_bridge", release_z3_bridge_module);
    release_exe.root_module.addOptions("build_options", release_core_options);
    release_exe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        release_exe.root_module.linkSystemLibrary("dl", .{});
        release_exe.root_module.linkSystemLibrary("z3", .{});
    }
    addVulkanIncludes(release_exe.root_module, target.result.os, vulkan_sdk, b);
    if (target.result.os.tag == .windows) {
        release_exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    const release_install = b.addInstallArtifact(release_exe, .{
        .dest_dir = .{ .override = .{ .custom = "ghost_release" } },
    });
    release_step.dependOn(&release_install.step);

    // Release packaging no longer shells out to `cmd /c`.

    // ── 12. Unicode Resonance Probe ──
    const unicode_probe = b.addExecutable(.{
        .name = "unicode_probe",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode_test.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
    });
    unicode_probe.want_lto = use_lto;
    unicode_probe.step.dependOn(&compile_corpus_scan_shader.step);
    unicode_probe.root_module.addImport("ghost_core", ghost_core);
    unicode_probe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        unicode_probe.root_module.linkSystemLibrary("dl", .{});
    }
    const run_unicode_probe = b.addRunArtifact(unicode_probe);
    const unicode_step = b.step("probe-unicode", "Run Unicode Resonance Probe");
    unicode_step.dependOn(&run_unicode_probe.step);

    // ── 13. Tools: Seed Lattice & Generate Corpus ──
    const seed_exe = b.addExecutable(.{
        .name = "seed_lattice",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/seed_lattice.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
    });
    seed_exe.want_lto = use_lto;
    seed_exe.step.dependOn(&compile_corpus_scan_shader.step);
    seed_exe.root_module.addImport("ghost_core", ghost_core);
    seed_exe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        seed_exe.root_module.linkSystemLibrary("dl", .{});
    }
    const run_seed = b.addRunArtifact(seed_exe);
    const seed_step = b.step("seed", "Initialize the seeded platform state files (lattice, semantic monolith, tags)");
    seed_step.dependOn(&run_seed.step);

    const corpus_exe = b.addExecutable(.{
        .name = "gen_corpus",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_corpus.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
            .strip = release_strip,
            .omit_frame_pointer = release_omit_frame_pointer,
        }),
    });
    corpus_exe.want_lto = use_lto;
    corpus_exe.step.dependOn(&compile_corpus_scan_shader.step);
    corpus_exe.root_module.addImport("ghost_core", ghost_core);
    corpus_exe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        corpus_exe.root_module.linkSystemLibrary("dl", .{});
    }
    const run_corpus = b.addRunArtifact(corpus_exe);
    const corpus_step = b.step("corpus", "Generate the mixed_sovereign.txt test corpus");
    corpus_step.dependOn(&run_corpus.step);
}
