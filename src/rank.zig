//! rank.zig — the RuneRank ladder, extracted from triad.zig (which pulls in VSA). VSA-FREE: the rank ladder is
//! the engine's epistemic promotion system (noise→emerging→pattern→validated→verified), independent of any
//! hypervector. The structured engine (feature_sim / structured_lattice / exact_lattice / forge) depends on this;
//! the legacy triad re-exports it. This is the keystone that lets the structured engine stop depending on the VSA
//! core via RuneRank — so ghost_core can eventually be lean (no vsa) for the structured binaries.
const cfg = @import("config.zig"); // VSA-free constants

pub const RuneRank = enum(u8) {
    /// Confirmed by human or successful test. Never demoted.
    verified = 1,
    /// Automated verification passed (pytest, compiler, etc.)
    validated = 2,
    /// Seen 100+ times across 3+ distinct contexts.
    pattern = 3,
    /// Seen 5+ times. Under observation.
    emerging = 4,
    /// Seen 1 time. Auto-pruned after TTL expires.
    noise = 5,

    pub fn label(self: RuneRank) []const u8 {
        return switch (self) {
            .verified => "VERIFIED",
            .validated => "VALIDATED",
            .pattern => "PATTERN",
            .emerging => "EMERGING",
            .noise => "NOISE",
        };
    }
    pub fn isQueryable(self: RuneRank) bool {
        return @intFromEnum(self) <= @intFromEnum(RuneRank.pattern);
    }
    pub fn promotionTarget(self: RuneRank) ?RuneRank {
        return switch (self) {
            .noise => .emerging,
            .emerging => .pattern,
            .pattern => .validated,
            .validated => .verified,
            .verified => null,
        };
    }
};

pub const RANK_EMERGING_MIN_OBSERVATIONS: u32 = cfg.V2_RANK_EMERGING_MIN_OBS;
pub const RANK_PATTERN_MIN_OBSERVATIONS: u32 = cfg.V2_RANK_PATTERN_MIN_OBS;
pub const RANK_PATTERN_MIN_CONTEXTS: u32 = cfg.V2_RANK_PATTERN_MIN_CTX;
pub const RANK_NOISE_TTL_MS: u64 = cfg.V2_NOISE_TTL_MS;
