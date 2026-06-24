//! ghost_core — LEAN structured-engine core.
//!
//! The VSA/LLM/GPU engine (vsa_*, gemma, the GPU stack, the agentic platform) was removed in the
//! invention-engine transition; it is preserved on origin at branch `backup/vsa-llm-gpu-engine`,
//! fully recoverable. What remains here is the VSA-free substrate the structured/exact invention
//! engine stands on: the rank ladder + a couple of leaf utilities. No HyperVector, no XOR, no GPU.
pub const rank = @import("rank.zig"); // RuneRank ladder (VSA-free)
pub const config = @import("config.zig"); // tuning constants (VSA-free)
pub const sys = @import("sys.zig"); // print/io helpers (VSA-free)
pub const forge = @import("forge.zig"); // structured rank-lattice training store (VSA-free)
pub const VERSION = @import("build_options").ghost_version;
