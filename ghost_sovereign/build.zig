const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const modules = makeGhostModules(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "ghost_core",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(exe.root_module, modules);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the Ghost Core probe");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/flame.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Ghost Core tests");
    test_step.dependOn(&run_tests.step);

    const sovereign_interface_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/sovereign_interface.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(sovereign_interface_tests.root_module, modules);
    const run_sovereign_interface_tests = b.addRunArtifact(sovereign_interface_tests);
    test_step.dependOn(&run_sovereign_interface_tests.step);

    const grammar_pulse_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/grammar_pulse.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(grammar_pulse_tests.root_module, modules);
    const run_grammar_pulse_tests = b.addRunArtifact(grammar_pulse_tests);
    test_step.dependOn(&run_grammar_pulse_tests.step);

    // Synthesis Executables
    const synthesis_files = [_][]const u8{
        "absolute_final_synthesis",   "absolute_proof_synthesis",        "absolute_synthesis",
        "decoder_synthesis",          "final_merge_synthesis",           "ghost_infinity_synthesis",
        "ghost_null_synthesis",       "ghost_zero_synthesis",            "grounded_singularity_synthesis",
        "hardware_mirror_synthesis",  "infinity_stress_test",            "ingestion_strategy_synthesis",
        "native_mirror_synthesis",    "null_manifesto_synthesis",        "primitive_resonance_synthesis",
        "probe_map",                  "reiteration_synthesis",           "simd_resonance_synthesis",
        "vsa_leap_synthesis",         "wiki_ingestion_synthesis",        "zero_scalar_proof",
        "zero_unit_synthesis",        "entangled_singularity_synthesis", "bridge_synthesis",
        "neologism_bridge_synthesis", "cli_overhaul_synthesis",          "wave2_synthesis",
        "truth_verdict_synthesis",    "wave3_synthesis",                 "semantic_overlap_synthesis",
    };

    for (synthesis_files) |name| {
        const synth_exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("src/synthesis/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        addGhostImports(synth_exe.root_module, modules);
        b.installArtifact(synth_exe);
    }

    // Main Engine Adapters
    const chat = b.addExecutable(.{
        .name = "chat",
        .root_source_file = b.path("src/adapters/chat.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(chat.root_module, modules);
    b.installArtifact(chat);
    const run_chat = b.addRunArtifact(chat);
    if (b.args) |args| run_chat.addArgs(args);
    const chat_step = b.step("chat", "Run the Ghost Chat Steering Wheel");
    chat_step.dependOn(&run_chat.step);

    const alien = b.addExecutable(.{
        .name = "ghost_alien_voice",
        .root_source_file = b.path("src/adapters/aetheric_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(alien.root_module, modules);
    b.installArtifact(alien);

    const void_adapter = b.addExecutable(.{
        .name = "ghost_invent_void",
        .root_source_file = b.path("src/adapters/void_cli_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(void_adapter.root_module, modules);
    b.installArtifact(void_adapter);

    const search = b.addExecutable(.{
        .name = "ghost_search",
        .root_source_file = b.path("src/adapters/search.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(search.root_module, modules);
    b.installArtifact(search);

    const infinity_exe = b.addExecutable(.{
        .name = "ghost_infinity",
        .root_source_file = b.path("src/adapters/infinity_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(infinity_exe.root_module, modules);
    b.installArtifact(infinity_exe);

    const null_exe = b.addExecutable(.{
        .name = "ghost_null",
        .root_source_file = b.path("src/adapters/ghost_null_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(null_exe.root_module, modules);
    b.installArtifact(null_exe);

    const absolute_proof_exe = b.addExecutable(.{
        .name = "ghost_absolute_proof",
        .root_source_file = b.path("src/adapters/ghost_absolute_proof_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(absolute_proof_exe.root_module, modules);
    b.installArtifact(absolute_proof_exe);

    const grounded_probe = b.addExecutable(.{
        .name = "ghost_grounded_probe",
        .root_source_file = b.path("src/adapters/ghost_grounded_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(grounded_probe.root_module, modules);
    b.installArtifact(grounded_probe);

    const zeroscalar_probe = b.addExecutable(.{
        .name = "ghost_zeroscalar_probe",
        .root_source_file = b.path("src/adapters/ghost_zeroscalar_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(zeroscalar_probe.root_module, modules);
    b.installArtifact(zeroscalar_probe);

    const final_probe = b.addExecutable(.{
        .name = "ghost_final_probe",
        .root_source_file = b.path("src/adapters/ghost_final_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(final_probe.root_module, modules);
    b.installArtifact(final_probe);

    const reproduce_baseline = b.addExecutable(.{
        .name = "reproduce_baseline",
        .root_source_file = b.path("src/reproduce_baseline.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(reproduce_baseline);

    const absolute_exe = b.addExecutable(.{
        .name = "ghost_absolute",
        .root_source_file = b.path("src/adapters/ghost_absolute_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(absolute_exe.root_module, modules);
    b.installArtifact(absolute_exe);

    const calibration_absolute = b.addExecutable(.{
        .name = "calibration_absolute",
        .root_source_file = b.path("src/adapters/calibration_absolute.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(calibration_absolute.root_module, modules);
    b.installArtifact(calibration_absolute);

    const throughput_bench = b.addExecutable(.{
        .name = "ghost_throughput_bench",
        .root_source_file = b.path("src/adapters/ghost_throughput_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(throughput_bench.root_module, modules);
    b.installArtifact(throughput_bench);

    const sovereign_interface = b.addExecutable(.{
        .name = "sovereign_interface",
        .root_source_file = b.path("src/adapters/sovereign_interface.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(sovereign_interface.root_module, modules);
    b.installArtifact(sovereign_interface);

    const grammar_pulse = b.addExecutable(.{
        .name = "grammar_pulse",
        .root_source_file = b.path("src/adapters/grammar_pulse.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(grammar_pulse.root_module, modules);
    b.installArtifact(grammar_pulse);

    const bridge_transceiver = b.addExecutable(.{
        .name = "bridge_transceiver",
        .root_source_file = b.path("src/adapters/bridge_transceiver.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(bridge_transceiver);

    const anchor_readout = b.addExecutable(.{
        .name = "anchor_readout",
        .root_source_file = b.path("src/adapters/anchor_readout.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(anchor_readout.root_module, modules);
    b.installArtifact(anchor_readout);

    const anchor_distribution = b.addExecutable(.{
        .name = "anchor_distribution",
        .root_source_file = b.path("src/adapters/anchor_distribution.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(anchor_distribution.root_module, modules);
    b.installArtifact(anchor_distribution);

    const persistence_check = b.addExecutable(.{
        .name = "persistence_check",
        .root_source_file = b.path("src/adapters/persistence_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(persistence_check.root_module, modules);
    b.installArtifact(persistence_check);

    const proper_consultation = b.addExecutable(.{
        .name = "proper_consultation",
        .root_source_file = b.path("src/adapters/proper_consultation.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(proper_consultation.root_module, modules);
    b.installArtifact(proper_consultation);

    const measured_probe_names = [_][]const u8{
        "ask_experts",
        "debate_experts",
        "audit_experts",
        "omni_ingest_verdict",
        "final_questions",
        "total_audit",
    };

    for (measured_probe_names) |name| {
        const measured_probe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path("src/adapters/measured_consultation_probe.zig"),
            .target = target,
            .optimize = optimize,
        });
        addGhostImports(measured_probe.root_module, modules);
        b.installArtifact(measured_probe);
    }

    const void_translator = b.addExecutable(.{
        .name = "void_translator",
        .root_source_file = b.path("src/adapters/void_translator.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(void_translator.root_module, modules);
    b.installArtifact(void_translator);

    const void_translator_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/void_translator.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(void_translator_tests.root_module, modules);
    const run_void_translator_tests = b.addRunArtifact(void_translator_tests);
    test_step.dependOn(&run_void_translator_tests.step);

    const ingestion_scale = b.addExecutable(.{
        .name = "ingestion_scale",
        .root_source_file = b.path("src/adapters/ingestion_scale.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(ingestion_scale.root_module, modules);
    b.installArtifact(ingestion_scale);

    const ingestion_scale_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/ingestion_scale.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(ingestion_scale_tests.root_module, modules);
    const run_ingestion_scale_tests = b.addRunArtifact(ingestion_scale_tests);
    test_step.dependOn(&run_ingestion_scale_tests.step);

    const invention_chain = b.addExecutable(.{
        .name = "invention_chain",
        .root_source_file = b.path("src/adapters/invention_chain.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(invention_chain.root_module, modules);
    b.installArtifact(invention_chain);

    const invention_chain_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/invention_chain.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(invention_chain_tests.root_module, modules);
    const run_invention_chain_tests = b.addRunArtifact(invention_chain_tests);
    test_step.dependOn(&run_invention_chain_tests.step);

    const invention_relaxed = b.addExecutable(.{
        .name = "invention_relaxed",
        .root_source_file = b.path("src/adapters/invention_relaxed.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(invention_relaxed.root_module, modules);
    b.installArtifact(invention_relaxed);

    const invention_relaxed_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/invention_relaxed.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(invention_relaxed_tests.root_module, modules);
    const run_invention_relaxed_tests = b.addRunArtifact(invention_relaxed_tests);
    test_step.dependOn(&run_invention_relaxed_tests.step);

    const invention_global = b.addExecutable(.{
        .name = "invention_global",
        .root_source_file = b.path("src/adapters/invention_global.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(invention_global.root_module, modules);
    b.installArtifact(invention_global);

    const novelty_invention = b.addExecutable(.{
        .name = "novelty_invention",
        .root_source_file = b.path("src/adapters/novelty_invention.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(novelty_invention.root_module, modules);
    b.installArtifact(novelty_invention);

    const engine_genesis = b.addExecutable(.{
        .name = "engine_genesis",
        .root_source_file = b.path("src/adapters/engine_genesis.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(engine_genesis.root_module, modules);
    b.installArtifact(engine_genesis);

    const generated_geometry_invention = b.addExecutable(.{
        .name = "generated_geometry_invention",
        .root_source_file = b.path("src/adapters/generated_geometry_invention.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(generated_geometry_invention.root_module, modules);
    b.installArtifact(generated_geometry_invention);

    const geometry_artifact_compiler = b.addExecutable(.{
        .name = "geometry_artifact_compiler",
        .root_source_file = b.path("src/adapters/geometry_artifact_compiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(geometry_artifact_compiler.root_module, modules);
    b.installArtifact(geometry_artifact_compiler);

    const phase_lattice_inventor = b.addExecutable(.{
        .name = "phase_lattice_inventor",
        .root_source_file = b.path("src/adapters/phase_lattice_inventor.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(phase_lattice_inventor.root_module, modules);
    b.installArtifact(phase_lattice_inventor);

    const alien_breakthrough_inventor = b.addExecutable(.{
        .name = "alien_breakthrough_inventor",
        .root_source_file = b.path("src/adapters/alien_breakthrough_inventor.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(alien_breakthrough_inventor.root_module, modules);
    b.installArtifact(alien_breakthrough_inventor);

    const conceptless_inventor = b.addExecutable(.{
        .name = "conceptless_inventor",
        .root_source_file = b.path("src/adapters/conceptless_inventor.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(conceptless_inventor);

    const synthesized_conceptless_breakthrough = b.addExecutable(.{
        .name = "synthesized_conceptless_breakthrough",
        .root_source_file = b.path("src/adapters/synthesized_conceptless_breakthrough.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(synthesized_conceptless_breakthrough);

    const recursive_conceptless_inventor = b.addExecutable(.{
        .name = "recursive_conceptless_inventor",
        .root_source_file = b.path("src/adapters/recursive_conceptless_inventor.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(recursive_conceptless_inventor);

    const recursive_conceptless_inventor_v2 = b.addExecutable(.{
        .name = "recursive_conceptless_inventor_v2",
        .root_source_file = b.path("src/adapters/recursive_conceptless_inventor_v2.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(recursive_conceptless_inventor_v2);

    const recursive_conceptless_inventor_v3 = b.addExecutable(.{
        .name = "recursive_conceptless_inventor_v3",
        .root_source_file = b.path("src/adapters/recursive_conceptless_inventor_v3.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(recursive_conceptless_inventor_v3);

    const recursive_conceptless_inventor_v4 = b.addExecutable(.{
        .name = "recursive_conceptless_inventor_v4",
        .root_source_file = b.path("src/adapters/recursive_conceptless_inventor_v4.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(recursive_conceptless_inventor_v4);

    const program_synthesis_inventor = b.addExecutable(.{
        .name = "program_synthesis_inventor",
        .root_source_file = b.path("src/adapters/program_synthesis_inventor.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(program_synthesis_inventor);

    const program_synthesis_v3 = b.addExecutable(.{
        .name = "program_synthesis_v3",
        .root_source_file = b.path("src/adapters/program_synthesis_v3.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(program_synthesis_v3);

    const mul_free_challenge = b.addExecutable(.{
        .name = "mul_free_challenge",
        .root_source_file = b.path("src/adapters/mul_free_challenge.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(mul_free_challenge);

    const practrand_emit_mulfree = b.addExecutable(.{
        .name = "practrand_emit_mulfree",
        .root_source_file = b.path("src/adapters/practrand_emit_mulfree.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(practrand_emit_mulfree);

    const mul_free_comparison = b.addExecutable(.{
        .name = "mul_free_comparison",
        .root_source_file = b.path("src/adapters/mul_free_comparison.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(mul_free_comparison);

    const domain_u64_mixer_mulfree_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/domain_u64_mixer_mulfree.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_domain_u64_mixer_mulfree_tests = b.addRunArtifact(domain_u64_mixer_mulfree_tests);
    test_step.dependOn(&run_domain_u64_mixer_mulfree_tests.step);

    const practrand_emit_mulfree_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/practrand_emit_mulfree.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_practrand_emit_mulfree_tests = b.addRunArtifact(practrand_emit_mulfree_tests);
    test_step.dependOn(&run_practrand_emit_mulfree_tests.step);

    const reachability_tester = b.addExecutable(.{
        .name = "reachability_tester",
        .root_source_file = b.path("src/adapters/reachability_tester.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(reachability_tester);

    const champion_pairwise = b.addExecutable(.{
        .name = "champion_pairwise",
        .root_source_file = b.path("src/adapters/champion_pairwise.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(champion_pairwise);

    const sorting_inventor = b.addExecutable(.{
        .name = "sorting_inventor",
        .root_source_file = b.path("src/adapters/sorting_inventor.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(sorting_inventor);

    const sorting_reachability_tester = b.addExecutable(.{
        .name = "sorting_reachability_tester",
        .root_source_file = b.path("src/adapters/sorting_reachability_tester.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(sorting_reachability_tester);

    const general_inventor = b.addExecutable(.{
        .name = "general_inventor",
        .root_source_file = b.path("src/adapters/general_inventor.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(general_inventor);

    const chain_runner = b.addExecutable(.{
        .name = "chain_runner",
        .root_source_file = b.path("src/adapters/chain_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(chain_runner);

    const chain_runner_sort = b.addExecutable(.{
        .name = "chain_runner_sort",
        .root_source_file = b.path("src/adapters/chain_runner_sort.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(chain_runner_sort);

    const meta_engine_runner = b.addExecutable(.{
        .name = "meta_engine_runner",
        .root_source_file = b.path("src/adapters/meta_engine_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(meta_engine_runner);

    const meta_engine_baseline = b.addExecutable(.{
        .name = "meta_engine_baseline",
        .root_source_file = b.path("src/adapters/meta_engine_baseline.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(meta_engine_baseline);

    const meta_engine_runner_sort = b.addExecutable(.{
        .name = "meta_engine_runner_sort",
        .root_source_file = b.path("src/adapters/meta_engine_runner_sort.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(meta_engine_runner_sort);

    const meta_engine_baseline_sort = b.addExecutable(.{
        .name = "meta_engine_baseline_sort",
        .root_source_file = b.path("src/adapters/meta_engine_baseline_sort.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(meta_engine_baseline_sort);

    const meta_meta_engine_runner = b.addExecutable(.{
        .name = "meta_meta_engine_runner",
        .root_source_file = b.path("src/adapters/meta_meta_engine_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(meta_meta_engine_runner);

    const meta_meta_chain_runner = b.addExecutable(.{
        .name = "meta_meta_chain_runner",
        .root_source_file = b.path("src/adapters/meta_meta_chain_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(meta_meta_chain_runner);

    const mmm_chain_runner = b.addExecutable(.{
        .name = "mmm_chain_runner",
        .root_source_file = b.path("src/adapters/mmm_chain_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(mmm_chain_runner);

    const mmm_qd_probe = b.addExecutable(.{
        .name = "mmm_qd_probe",
        .root_source_file = b.path("src/adapters/mmm_qd_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(mmm_qd_probe);

    const mmm_holdout_hillclimb = b.addExecutable(.{
        .name = "mmm_holdout_hillclimb",
        .root_source_file = b.path("src/adapters/mmm_holdout_hillclimb.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(mmm_holdout_hillclimb);

    // Exp2: comptime mulfree meta-engine binary (approach A)
    const mmm_holdout_hillclimb_mulfree = b.addExecutable(.{
        .name = "mmm_holdout_hillclimb_mulfree",
        .root_source_file = b.path("src/adapters/mmm_holdout_hillclimb_mulfree.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(mmm_holdout_hillclimb_mulfree);

    // Exp2: export concrete mixer from a mulfree MetaProgram
    const meta_mixer_export_mulfree = b.addExecutable(.{
        .name = "meta_mixer_export_mulfree",
        .root_source_file = b.path("src/adapters/meta_mixer_export_mulfree.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(meta_mixer_export_mulfree);

    const mmmm_qd_probe = b.addExecutable(.{
        .name = "mmmm_qd_probe",
        .root_source_file = b.path("src/adapters/mmmm_qd_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(mmmm_qd_probe);

    const mmmm_holdout_hillclimb = b.addExecutable(.{
        .name = "mmmm_holdout_hillclimb",
        .root_source_file = b.path("src/adapters/mmmm_holdout_hillclimb.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(mmmm_holdout_hillclimb);

    const bittape_inventor = b.addExecutable(.{
        .name = "bittape_inventor",
        .root_source_file = b.path("src/adapters/bittape_inventor.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(bittape_inventor);

    const bittape_inspect = b.addExecutable(.{
        .name = "bittape_inspect",
        .root_source_file = b.path("src/adapters/bittape_inspect.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(bittape_inspect);

    const champion_holdout_validation = b.addExecutable(.{
        .name = "champion_holdout_validation",
        .root_source_file = b.path("src/adapters/champion_holdout_validation.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(champion_holdout_validation);

    const lineage_audit = b.addExecutable(.{
        .name = "lineage_audit",
        .root_source_file = b.path("src/adapters/lineage_audit.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lineage_audit);

    const meta_mixer_export = b.addExecutable(.{
        .name = "meta_mixer_export",
        .root_source_file = b.path("src/adapters/meta_mixer_export.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(meta_mixer_export);

    const mixer_csv_emit = b.addExecutable(.{
        .name = "mixer_csv_emit",
        .root_source_file = b.path("src/adapters/mixer_csv_emit.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(mixer_csv_emit);

    const search_strategy_meta = b.addExecutable(.{
        .name = "search_strategy_meta",
        .root_source_file = b.path("src/adapters/search_strategy_meta.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(search_strategy_meta);

    const recursive_engine_loop = b.addExecutable(.{
        .name = "recursive_engine_loop",
        .root_source_file = b.path("src/adapters/recursive_engine_loop.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(recursive_engine_loop);

    const trained_semantic_bench = b.addExecutable(.{
        .name = "trained_semantic_bench",
        .root_source_file = b.path("src/adapters/trained_semantic_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(trained_semantic_bench);

    const semantic_structure_probe = b.addExecutable(.{
        .name = "semantic_structure_probe",
        .root_source_file = b.path("src/adapters/semantic_structure_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(semantic_structure_probe.root_module, modules);
    b.installArtifact(semantic_structure_probe);

    const train_hypervectors = b.addExecutable(.{
        .name = "train_hypervectors",
        .root_source_file = b.path("src/adapters/train_hypervectors.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(train_hypervectors);

    const practrand_emit = b.addExecutable(.{
        .name = "practrand_emit",
        .root_source_file = b.path("src/adapters/practrand_emit.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(practrand_emit);

    const program_synthesis_bootstrap = b.addExecutable(.{
        .name = "program_synthesis_bootstrap",
        .root_source_file = b.path("src/adapters/program_synthesis_bootstrap.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(program_synthesis_bootstrap);

    const program_synthesis_bootstrap_v2 = b.addExecutable(.{
        .name = "program_synthesis_bootstrap_v2",
        .root_source_file = b.path("src/adapters/program_synthesis_bootstrap_v2.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(program_synthesis_bootstrap_v2);

    const absolute_invention = b.addExecutable(.{
        .name = "absolute_invention",
        .root_source_file = b.path("src/adapters/absolute_invention.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(absolute_invention.root_module, modules);
    b.installArtifact(absolute_invention);

    const targeted_invention = b.addExecutable(.{
        .name = "targeted_invention",
        .root_source_file = b.path("src/adapters/targeted_invention.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(targeted_invention.root_module, modules);
    b.installArtifact(targeted_invention);

    const anchor_readout_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/anchor_readout.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(anchor_readout_tests.root_module, modules);
    const run_anchor_readout_tests = b.addRunArtifact(anchor_readout_tests);
    test_step.dependOn(&run_anchor_readout_tests.step);

    const anchor_distribution_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/anchor_distribution.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(anchor_distribution_tests.root_module, modules);
    const run_anchor_distribution_tests = b.addRunArtifact(anchor_distribution_tests);
    test_step.dependOn(&run_anchor_distribution_tests.step);

    const understanding_bench = b.addExecutable(.{
        .name = "understanding_bench",
        .root_source_file = b.path("src/adapters/understanding_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(understanding_bench.root_module, modules);
    b.installArtifact(understanding_bench);

    // verify_cli: code→SMT verification for discovered champions.
    // Standalone — no Ghost modules. Links to system libz3.
    const verify_cli = b.addExecutable(.{
        .name = "verify_cli",
        .root_source_file = b.path("src/adapters/verify_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    verify_cli.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    verify_cli.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
    verify_cli.root_module.linkSystemLibrary("z3", .{});
    verify_cli.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(verify_cli);

    // verify_qflia_smoke: standalone smoke test exercising the exact
    // verifySmt pattern wired into ghost_engine/src/invent_cli.zig.
    const verify_qflia_smoke = b.addExecutable(.{
        .name = "verify_qflia_smoke",
        .root_source_file = b.path("src/adapters/verify_qflia_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    verify_qflia_smoke.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    verify_qflia_smoke.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
    verify_qflia_smoke.root_module.linkSystemLibrary("z3", .{});
    verify_qflia_smoke.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(verify_qflia_smoke);

    const understanding_bench_tests = b.addTest(.{
        .root_source_file = b.path("src/adapters/understanding_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGhostImports(understanding_bench_tests.root_module, modules);
    const run_understanding_bench_tests = b.addRunArtifact(understanding_bench_tests);
    test_step.dependOn(&run_understanding_bench_tests.step);
}

const GhostModules = struct {
    flame: *std.Build.Module,
    void: *std.Build.Module,
    flux: *std.Build.Module,
    vsa: *std.Build.Module,
    vsa_decoder: *std.Build.Module,
    aetheric: *std.Build.Module,
    sovereign: *std.Build.Module,
    lore: *std.Build.Module,
    manifold: *std.Build.Module,
    absolute_final: *std.Build.Module,
    absolute_archived: *std.Build.Module,
    absolute_production: *std.Build.Module,
    absolute_proof_core: *std.Build.Module,
    grounded_core: *std.Build.Module,
    infinity_core: *std.Build.Module,
    null_core: *std.Build.Module,
};

fn makeGhostModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) GhostModules {
    const modules = GhostModules{
        .flame = b.createModule(.{ .root_source_file = b.path("src/flame.zig"), .target = target, .optimize = optimize }),
        .void = b.createModule(.{ .root_source_file = b.path("src/void.zig"), .target = target, .optimize = optimize }),
        .flux = b.createModule(.{ .root_source_file = b.path("src/flux.zig"), .target = target, .optimize = optimize }),
        .vsa = b.createModule(.{ .root_source_file = b.path("src/vsa.zig"), .target = target, .optimize = optimize }),
        .vsa_decoder = b.createModule(.{ .root_source_file = b.path("src/adapters/vsa_decoder.zig"), .target = target, .optimize = optimize }),
        .aetheric = b.createModule(.{ .root_source_file = b.path("src/aetheric.zig"), .target = target, .optimize = optimize }),
        .sovereign = b.createModule(.{ .root_source_file = b.path("src/sovereign.zig"), .target = target, .optimize = optimize }),
        .lore = b.createModule(.{ .root_source_file = b.path("src/lore.zig"), .target = target, .optimize = optimize }),
        .manifold = b.createModule(.{ .root_source_file = b.path("src/manifold.zig"), .target = target, .optimize = optimize }),
        .absolute_final = b.createModule(.{ .root_source_file = b.path("src/absolute_final.zig"), .target = target, .optimize = optimize }),
        .absolute_archived = b.createModule(.{ .root_source_file = b.path("src/archived_cores/absolute.zig"), .target = target, .optimize = optimize }),
        .absolute_production = b.createModule(.{ .root_source_file = b.path("src/archived_cores/absolute_production.zig"), .target = target, .optimize = optimize }),
        .absolute_proof_core = b.createModule(.{ .root_source_file = b.path("src/archived_cores/absolute_proof_core.zig"), .target = target, .optimize = optimize }),
        .grounded_core = b.createModule(.{ .root_source_file = b.path("src/archived_cores/grounded_core.zig"), .target = target, .optimize = optimize }),
        .infinity_core = b.createModule(.{ .root_source_file = b.path("src/archived_cores/infinity.zig"), .target = target, .optimize = optimize }),
        .null_core = b.createModule(.{ .root_source_file = b.path("src/archived_cores/null_core.zig"), .target = target, .optimize = optimize }),
    };

    addGhostImports(modules.flame, modules);
    addGhostImports(modules.void, modules);
    addGhostImports(modules.flux, modules);
    addGhostImports(modules.vsa, modules);
    addGhostImports(modules.vsa_decoder, modules);
    addGhostImports(modules.aetheric, modules);
    addGhostImports(modules.sovereign, modules);
    addGhostImports(modules.lore, modules);
    addGhostImports(modules.manifold, modules);
    addGhostImports(modules.absolute_final, modules);
    addGhostImports(modules.absolute_archived, modules);
    addGhostImports(modules.absolute_production, modules);
    addGhostImports(modules.absolute_proof_core, modules);
    addGhostImports(modules.grounded_core, modules);
    addGhostImports(modules.infinity_core, modules);
    addGhostImports(modules.null_core, modules);
    return modules;
}

fn addGhostImports(module: *std.Build.Module, modules: GhostModules) void {
    module.addImport("flame", modules.flame);
    module.addImport("void", modules.void);
    module.addImport("flux", modules.flux);
    module.addImport("vsa", modules.vsa);
    module.addImport("vsa_decoder", modules.vsa_decoder);
    module.addImport("aetheric", modules.aetheric);
    module.addImport("sovereign", modules.sovereign);
    module.addImport("lore", modules.lore);
    module.addImport("manifold", modules.manifold);
    module.addImport("absolute_final", modules.absolute_final);
    module.addImport("absolute_archived", modules.absolute_archived);
    module.addImport("absolute_production", modules.absolute_production);
    module.addImport("absolute_proof_core", modules.absolute_proof_core);
    module.addImport("grounded_core", modules.grounded_core);
    module.addImport("infinity_core", modules.infinity_core);
    module.addImport("null_core", modules.null_core);
}
