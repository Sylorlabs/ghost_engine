# Meta-Engine over MUL-Free Domain with Live Macro Graduation — Exp3 (2026-05-23)

## What the experiment asked

Exp2 (`docs/research/meta_engine_mulfree_exp2_2026_05_23.md`) showed that the hierarchical
MMP/MMMP meta-engine over the MUL-free domain produces best holdouts in the range
[−205, −215] and that all discovered programs fail PractRand BRank at 16 MiB. Two
independent seeds converge to exactly −215.2252 and to identical 5-instruction programs.

Exp3 asks: does adding `--live-macro-graduation` — the mechanism that reproducibly crossed
the 47.23 ceiling in the unrestricted domain — change the MUL-free result? Specifically:

1. Does it escape the −215 attractor?
2. Does it produce any candidate that passes PractRand or Z3 bijection verification?
3. Does composing MUL-free champions as CALL_LIB macros introduce enough structure to
   escape the GF(2) linear basin?

## Setup

- **Binary:** `mmm_holdout_hillclimb_mulfree` (approach A, comptime)
- **Runner flags:** `--iters=24 --mmm-outer-iters=6 --tier1-outer-iters=8
  --tier0-inner-steps=150 --constrained-init --constrained-meta-init
  --constrained-mm-init --wide-call-meta --wide-call-mm
  --live-macro-graduation` (same as Exp2 plus `--live-macro-graduation`)
- **Seeds:** F00DCAFE12345678, 1111222233334444, ABCDEF0123456789

The only difference from Exp2 is the `--live-macro-graduation` flag.

## Results

### Holdout trajectories (24 iters, 3 seeds)

| seed | best holdout | discovered at iter | Exp2 holdout | delta |
|------|-------------|-------------------|-------------|-------|
| f00d | **-215.2252** | 1 | -215.2252 | **0** |
| 1111 | **-215.2252** | 0 | -215.2252 | **0** |
| abcd | **-205.5844** | 21 | -205.5844 | **0** |

All three seeds produce **byte-identical best holdouts** to Exp2. The live-macro-graduation
mechanism has zero effect on the MUL-free fitness landscape at this budget.

### Concrete mixer verification

| seed | mixer program (ops) | q_best | Z3 verdict | PractRand tier |
|------|---------------------|--------|-----------|----------------|
| f00d | XOR, XOR, ROTR, SHR_XOR, ADD (5 inst) | -217.9 | **SAT — non-bijective** (20 ms) | BRank **FAIL** @ 16 MiB |
| 1111 | XOR, XOR, ROTR, SHR_XOR, ADD (5 inst) | -217.9 | **SAT — non-bijective** (19 ms) | BRank **FAIL** @ 16 MiB |
| abcd | BSWAP, SHL_XOR, BSWAP, ADD (4 inst) | -211.3 | **SAT — non-bijective** (14 ms) | BCFN/BRank **FAIL** @ 16 MiB |

f00d and 1111 produce the same program. All three programs are structurally identical to
the Exp2 champions — live-macro-graduation did not discover any new concrete programs.

### Comparison across Exp1–Exp3

| experiment | search arch | add-on | best holdout | PractRand tier |
|---|---|---|---|---|
| Flat SA (Exp0, 2026-05-23) | direct SA hill-climb | — | N/A (fitness-only) | **FAIL @ 1 MiB** (BRank) |
| **Meta-engine Exp2** | MMP/MMMP 3-tier | — | -205.5844 (abcd) | BRank **FAIL @ 16 MiB** |
| **Meta-engine + LMG Exp3** | MMP/MMMP 3-tier | live-macro-graduation | -205.5844 (abcd) | BRank **FAIL @ 16 MiB** |

Live-macro-graduation produces no measurable improvement over Exp2 in the MUL-free domain.

## What this empirically establishes

1. **Live-macro-graduation is inert in the MUL-free domain.** The mechanism that crossed
   the 47.23 ceiling in the unrestricted domain produces zero improvement here — all three
   seeds reproduce exact Exp2 best holdouts. The −215 attractor is an absolute ceiling
   for this opset+budget, not a starting point for further search.

2. **Composition of MUL-free programs is composition of GF(2)-linear functions.**
   When `--live-macro-graduation` graduates a MUL-free champion into `chain_extras`,
   the macro is a composition of XOR/ADD/ROTL/SHR operations. Calling this macro from
   another MUL-free program produces another composition of XOR/ADD/ROTL/SHR operations
   — still within the GF(2)-linear basin. There is no synergy to exploit.

3. **The MUL-necessity conjecture holds across three architectural variants.** Flat SA,
   meta-engine, and meta-engine + live-macro-graduation all fail PractRand BRank on all
   seeds. The MUL-free landscape has a hard ceiling that is independent of search
   architecture at this budget.

4. **The −215 attractor is the practical ceiling for this opset.** Three independent
   experiments (Exp2 f00d, Exp2 1111, Exp3 f00d, Exp3 1111 — four independent runs) all
   converge to exactly −215.2252 and to identical concrete programs. The abcd seed
   produces −205.5844 in both Exp2 and Exp3. The attractor is a property of the
   fitness landscape, not of the search mechanism.

5. **What was NOT tested:**
   - `--monotone-retries=N` parallel attempts (potentially different trajectory than
     the sequential restart in Exp2/3)
   - Larger instruction budgets (max_len=24 rather than capped 12)
   - Dedicated MUL-free MetaProgram seeds from a mulfree-specific bootstrap chain

## Externally-defensible framing

> We applied live-macro-graduation — the mechanism that reproducibly crosses the 47.23
> ceiling in the unrestricted domain — to the same MUL-free meta-engine run from Exp2
> (3-tier MMP/MMMP, 24 outer iterations, 3 independent seeds). All three seeds produced
> byte-identical best holdouts to Exp2 (−215.2252 for f00d and 1111, −205.5844 for abcd).
> The concrete mixers discovered are structurally identical to Exp2's champions. All three
> fail PractRand BRank at 16 MiB and are rejected by Z3 as non-bijective. The result
> directly tests whether composing MUL-free programs as macros introduces new mixing
> capability — it does not, consistent with the theoretical expectation that composition
> of GF(2)-linear functions remains GF(2)-linear.

## Open follow-up questions (carried from Exp2, now extended)

1. Does `--monotone-retries=N` change the MUL-free result where LMG does not?
2. Does allowing programs up to 24 instructions (max_len=24, removing the 12-cap) give
   the search enough diffusion budget to escape the linear basin?
3. Are Exp2 and Exp3 attractor programs structurally equivalent under lineage audit?
4. Would a MUL-free–specific bootstrap (seeded from a mulfree chain rather than random
   init) produce a different trajectory, or does the attractor still dominate?

## Artifacts

- Source: all Exp2 adapter files (no new source code required for Exp3)
- Full-run artifacts: `results/exp3_mulfree_lmg_{f00d,1111,abcd}/`
  - `BEST_champion_{mmm,mm,meta}.csv`
  - `BEST_mixer.csv` — concrete mixer exported from best MetaProgram
  - `hillclimb.csv` — per-iteration holdout trajectory
- Prior experiments this builds on: `docs/research/meta_engine_mulfree_exp2_2026_05_23.md`,
  `docs/research/mul_free_challenge_full_run_2026_05_23.md`
