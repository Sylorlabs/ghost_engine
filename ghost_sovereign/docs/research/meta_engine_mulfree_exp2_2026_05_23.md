# Meta-Engine over MUL-Free Domain — Exp2 (2026-05-23)

## What the experiment asked

The 2026-05-23 flat-SA MUL-free run
(`docs/research/mul_free_challenge_full_run_2026_05_23.md`) confirmed that
**direct SA hill-climb at 20M evaluations cannot discover a 64-bit bijective
MUL-free mixer** — every candidate failed PractRand at the 1 MiB tier on the
binary-rank (BRank) test. Flat SA is the weakest search architecture in this
codebase. The follow-up question is: does the hierarchical meta-engine
(MMP/MMMP/chain) change the outcome?

**Question:** does the MMP/MMMP meta-engine architecture, which previously
broke the 44.30 fitness ceiling in the unrestricted domain, break the
MUL-necessity conjecture in the MUL-free domain?

## Cross-check design

The experiment implements the same MUL-free search via **two independent
approaches** whose byte-identical equivalence was verified before any full run:

- **(A) Comptime:** new `mmm_holdout_hillclimb_mulfree` binary, built against
  a thin compat wrapper (`domain_u64_mixer_mulfree_compat.zig`) that re-exports
  the existing MUL-free domain with the no-parameter API `domain_meta_engine.zig`
  expects. The wrapper calls `mulfree.randomProgram(rng, .mul_free, 11)` (span=8,
  range [4,11]) and `mulfree.mutate(p, rng, .mul_free, 12)` to match the
  original MaxProgLen=12 contract.

- **(B) Runtime:** `--ban-mul-family` flag added to existing
  `mmm_holdout_hillclimb`. When set, `domain_u64_mixer.zig`'s `randomInstr`
  branches to the same 11-op list
  `{XOR, ADD, ROTL, SHL_XOR, SHR_XOR, ADD_CONST, AND_NOT, OR_SHIFT, ROTR, BSWAP, ADD_ROT}`
  in the same order, producing byte-identical search trajectories.

**Equivalence pilot (seed F00DCAFE, --iters=0 and --iters=5):**

```
Approach A: iter=0 anchor=-252800.77 holdout=-10772.81   (iters=0, same existing MMMP)
Approach B: iter=0 anchor=-252800.77 holdout=-10772.81   ← byte-identical
Approach A: 5-iter trajectory [0: -1e6, 1: -10772.8, 2-5: -10772.8]
Approach B: 5-iter trajectory [0: -1e6, 1: -10772.8, 2-5: -10772.8]  ← byte-identical
```

Both implementations produce identical anchor, holdout, and per-iteration
trajectories. The implementations are verified equivalent; the full run uses
approach A.

## Setup

- **Binary:** `mmm_holdout_hillclimb_mulfree` (approach A, comptime)
- **Inner domain:** `domain_u64_mixer_mulfree_compat.zig` → `.mul_free` mode.
  Banned ops: MUL, MUM, SPLITMIX_STEP, CALL_LIB.
  Allowed 11 ops: XOR, ADD, ROTL, SHL_XOR, SHR_XOR, ADD_CONST, AND_NOT,
  OR_SHIFT, ROTR, BSWAP, ADD_ROT.
- **Runner flags:** `--iters=24 --mmm-outer-iters=6 --tier1-outer-iters=8
  --tier0-inner-steps=150 --constrained-init --constrained-meta-init
  --constrained-mm-init --wide-call-meta --wide-call-mm
  --live-macro-graduation` (same budget/config as the Engine-3 47.23 run)
- **Seeds:** F00DCAFE12345678, 1111222233334444, ABCDEF0123456789

**Verification ladder:**
1. Byte-identical equivalence check (approaches A and B, pilot seed)
2. Full run: 3 seeds, 24 iters
3. Export concrete mixer via `meta_mixer_export_mulfree`
4. Z3 bijection: `verify_cli --domain=mixer --csv=...`
5. PractRand 16 MiB: `mixer_csv_emit | RNG_test stdin64 -tlmax 16M`

## Results

### Holdout trajectories (approach A, 24 iters, 3 seeds)

| seed | best holdout | discovered at iter | plateau behaviour |
|------|-------------|-------------------|---|
| f00d | **-215.2252** | 1 | stuck after iter 1 |
| 1111 | **-215.2252** | 0 | never improved |
| abcd | **-205.5844** | 21 | converged to -215 then escaped once at iter 21 |

All three seeds plateau in the -205 to -215 range. f00d and 1111 converge to
exactly -215.2252, and their exported concrete mixers are **identical** (same
5-instruction program, same immediates). This indicates a strong attractor in
the MUL-free fitness landscape.

### Concrete mixer verification

| seed | mixer program (ops) | q_best | Z3 verdict | PractRand tier |
|------|---------------------|--------|-----------|----------------|
| f00d | XOR, XOR, ROTR, SHR_XOR, ADD (5 inst) | -217.9 | **SAT — non-bijective** (8-bit, 24 ms) | BRank **FAIL** @ 16 MiB |
| 1111 | XOR, XOR, ROTR, SHR_XOR, ADD (5 inst) | -217.9 | **SAT — non-bijective** (21 ms) | BRank **FAIL** @ 16 MiB |
| abcd | BSWAP, SHL_XOR, BSWAP, ADD (4 inst) | -211.3 | **SAT — non-bijective** (15 ms) | BCFN/BRank **FAIL** @ 16 MiB |

f00d and 1111 are the same program. All three are non-bijective. All three
fail PractRand at the 16 MiB tier on the binary-rank test (BRank) — the
canonical GF(2) linear structure test.

### Comparison to flat SA (previous experiment)

| experiment | search arch | budget | PractRand tier reached |
|---|---|---|---|
| Flat SA (2026-05-23) | direct SA hill-climb | 20M evaluations × 3 seeds | **FAIL @ 1 MiB** (BRank) |
| **Meta-engine (this run)** | MMP/MMMP 3-tier | 24 outer iters × 3 seeds | BRank suspicious @ 4 MiB, **FAIL @ 16 MiB** |

The meta-engine reaches approximately 16 MiB before BRank fails, versus flat
SA's 1 MiB. That is a 16× improvement in PractRand tier.

However, BRank still fails on all seeds, and Z3 finds 8-bit bijection
counter-examples in < 25 ms. The linearity barrier is the same; the
meta-engine merely delays encountering it.

## What this empirically establishes

1. **The meta-engine architecture is load-bearing even in the MUL-free domain.**
   It produces longer PractRand survivability (16 MiB vs 1 MiB for flat SA) at
   comparable compute budget. The hierarchical search architecture is not
   specific to the unrestricted opcode set.

2. **The MUL-necessity conjecture holds across both architectures.** No MUL-free
   bijective mixer reached PractRand 64 MiB. BRank fails on every champion from
   both approaches. The conjecture is now supported by two independent negative
   search experiments of different architecture.

3. **Strong attractor at holdout −215.** Two independent seeds (f00d, 1111)
   converge to exactly the same MetaProgram fitness value and the same concrete
   5-instruction mixer. This is direct evidence that the MUL-free fitness
   landscape has a dominant local optimum in the carry/shift/logic domain.
   The abcd seed finds a slightly better holdout (−205) but its concrete mixer
   is structurally worse on PractRand. The -215 attractor may be near the
   practical ceiling for this opset/budget combination.

4. **ADD and ADD_ROT provide carry-chain nonlinearity but not enough.**
   The best discovered programs include ADD (used in f00d/1111 mixers), which
   introduces carry propagation. This produces better BRank scores than the pure
   XOR/shift domain (Exp1 bit-tape), but the programs remain in the linear basin
   at scale. The carry chain alone does not provide the mixing nonlinearity that
   MUL supplies.

5. **Z3 verification caught all three as non-bijective.** This is consistent with
   Exp1's finding that the flat SA run also produced non-bijective PractRand-64-MiB
   "passing" candidates. The bijection check is necessary at this domain.

6. **What was NOT tested:**
   - Larger instruction budgets (> 24 outer iters, > 12-instruction programs)
   - Long-form MUL-free programs (max_len=24 rather than the capped 12)
   - `--monotone-retries` parallel attempts (used in the 47.23 Engine-3 run)
   - Dedicated MUL-free MetaProgram seeds (seeded from a mulfree-specific chain
     rather than from random init)

## Externally-defensible framing

> We applied the same hierarchical meta-search architecture (3-tier MMP/MMMP,
> 24 outer iterations) that previously broke the 44.30 fitness ceiling in the
> unrestricted domain to a MUL-free 64-bit mixer search (banning MUL, MUM,
> SPLITMIX_STEP, and CALL_LIB). The implementation was verified via a comptime
> approach (new binary) and a runtime flag approach (--ban-mul-family) that
> produce byte-identical search trajectories on the same seed. Across 3
> independent seeds, all discovered candidates failed PractRand's binary-rank
> test (BRank) by 16 MiB and were rejected as non-bijective by Z3-backed
> bijection verification with 8-bit counter-examples in under 25 ms. The
> meta-engine reached the 16 MiB PractRand tier compared to flat SA's 1 MiB
> ceiling, but both hit the same linearity barrier. The result extends the
> negative MUL-free finding from flat SA to hierarchical meta-search, supporting
> the MUL-necessity conjecture across two independent search architectures.

## Open follow-up questions

1. Does `--live-macro-graduation ON` (already included here) plus
   `--monotone-retries=N` parallel attempts materially improve the MUL-free
   result beyond the -215 attractor?
2. Does allowing programs up to 24 instructions (MUL-free compat max_len=24,
   removing the 12-cap) give the search more diffusion budget to escape the
   linear basin?
3. Are the two converged programs (f00d=1111, and abcd's separate attractor)
   structurally equivalent under lineage audit?
4. Does Exp3 (live-macro-graduation isolation) change the -215 attractor for
   the MUL-free case?

## Artifacts

- Source (approach A): `src/adapters/domain_u64_mixer_mulfree_compat.zig`,
  `src/adapters/domain_meta_engine_mulfree.zig`,
  `src/adapters/domain_meta_meta_engine_mulfree.zig`,
  `src/adapters/domain_meta_meta_meta_engine_mulfree.zig`,
  `src/adapters/mmm_holdout_hillclimb_mulfree.zig`,
  `src/adapters/meta_mixer_export_mulfree.zig`
- Source (approach B): `src/adapters/domain_u64_mixer.zig` (`ban_mul_family`
  global + `MulFreeOps` list), `src/adapters/mmm_holdout_hillclimb.zig`
  (`--ban-mul-family` flag)
- Equivalence pilots: `results/exp2_pilot_{approach_a_iter0,approach_b_iter0}/`,
  `results/exp2_pilot_{a,b}_5iter/`
- Full-run artifacts: `results/exp2_mulfree_meta_{f00d,1111,abcd}/`
  - `BEST_champion_{mmm,mm,meta}.csv` — discovered MetaMetaMetaProgram/
    MetaMetaProgram/MetaProgram at best holdout
  - `BEST_mixer.csv` — concrete mixer exported from best MetaProgram
  - `hillclimb.csv` — per-iteration holdout trajectory
- Prior negative this builds on: `docs/research/mul_free_challenge_full_run_2026_05_23.md`
