# Mega Research Round — Final Checkpoint (2026-05-23)

Nine parallel experiments testing different axes of the Ghost Sovereign
program-synthesis stack. The round was designed to answer open questions
that accumulated after the Engine-3 live-macro-graduation result (2026-05-22):
MUL-necessity, alternative fitness functions, cross-domain generality,
new output domains.

Pre-flight commit: `fe09d0ff` (clean checkout of prior WIP).
Source commit after round: `ee2d31b9` (28 files, 7587 insertions).

---

## Summary Table

| Exp | Name | Key finding | Verdict |
|-----|------|------------|---------|
| 1 | Bit-tape fitness fix | Per-bit avalanche eliminates imbalance; BRank still fails | Necessary, not sufficient |
| 2 | MUL-free meta-engine | Meta-engine reaches 16 MiB PractRand vs flat SA's 1 MiB; BRank fails all | MUL-necessity holds |
| 3 | MUL-free + LMG | Zero improvement over Exp2 on all seeds | LMG inert on linear opsets |
| 4 | Engine-3 seed repro | DEAD=47.32 exact; 1111/ABCD=45.83 same champion | Ceiling reproducible; 45.83 is dominant attractor |
| 5 | MUL-free L24 | 2/3 seeds escape -215 to -162 (late-epoch); both fail PractRand | Floor is cap artifact; escape ≠ quality |
| 6 | Sort-net 3-tier | 1/3 seeds find valid MMMP (~75% correct sorters) | High seed sensitivity; 3-tier weaker than 2-tier chain here |
| 7 | SAC fitness | FIRST Z3-bijective mixer (seed DEAD); bijective ≠ PractRand-safe | SAC is distinct quality axis |
| 8 | Dual-output | DEAD_A: bijective + PractRand PASS; 2/6 programs pass PractRand | Escape-and-lock; slot-A/B asymmetry; DEAD_A fully verified |
| 9 | Opset discovery | Null result — all seeds stuck at iter-0 quality | Penalty restriction too indirect |

---

## Exp1: Bit-Tape Fitness Fix

**Question:** does per-bit avalanche objective eliminate the imbalance
that caused the prior bit-tape GA to game the aggregate fitness?

**Result:** YES for balance — min per-bit flip probability rises from
0.17 to 0.50 (2/3 seeds). But BRank test still fails catastrophically
at 16 MiB. The per-bit reform eliminates the gaming but reveals the
harder problem: linear structure in XOR/AND/NOT ops.

**Verdict:** per-bit balance necessary, not sufficient. GF(2)-linearity
of the substrate is the fundamental barrier.

See: `bittape_fitness_fix_2026_05_23.md`

---

## Exp2: MUL-Free Meta-Engine

**Question:** does the 3-tier MMP/MMMP meta-engine discover better
MUL-free mixers than flat SA (which caps out at -215)?

**Result:** meta-engine converges to the same -215 attractor (2/3 seeds
converge to the identical 5-instruction champion), but reaches 16 MiB
PractRand tier vs flat SA's 1 MiB ceiling. BRank still fails on all seeds.

**Verdict:** MUL-necessity conjecture holds at meta-engine tier. -215 is
a strong attractor; the meta-engine navigates to it efficiently but
cannot escape the structural limitation.

See: `meta_engine_mulfree_exp2_2026_05_23.md`

---

## Exp3: MUL-Free + Live-Macro-Graduation

**Question:** does LMG (which breaks the 44.30 ceiling in the unrestricted
domain) help the MUL-free meta-engine?

**Result:** zero improvement (delta=0 all seeds). Byte-identical results
to Exp2.

**Verdict:** LMG is inert on GF(2)-linear opsets. Composing MUL-free
macros produces MUL-free compositions — linearity is closed under composition.

See: `meta_engine_mulfree_lmg_exp3_2026_05_23.md`

---

## Exp4: Engine-3 Seed Reproducibility

**Question:** is the Engine-3 47.32 ceiling a seed-specific artifact or
a robust, reproducible attractor?

**Result:** seed DEAD reproduces to 47.3244 (byte-identical to original
Engine-3 champion). Seeds 1111 and ABCD both converge to 45.83 with the
same 5-instruction champion (XOR + OR_SHIFT + MUM + ROTL + SHL_XOR).
All three use MUM (multiplication); all non-bijective at 8 bits; all
pass PractRand 16 MiB.

**Verdict:** 47.32 is reproducible but rare; 45.83 is the dominant
global attractor. The 45.83 basin is not a local fluke — it's the
stable convergence point for 2/3 fresh seeds.

See: `engine3_seed_repro_exp4_2026_05_23.md`

---

## Exp5: MUL-Free with Extended Program Length (L24)

**Question:** is the -215 floor a cap artifact (12-instruction limit)
or a fundamental limit of MUL-free mixing?

**Result:** 2/3 seeds escape to ~-162 via late-epoch discoveries (seed
DEAD at iter 22, seed 1111 at iter 19). Floor IS a cap artifact. But
both escaped champions fail PractRand: DEAD (ADD-dominant) fails mod3n
with p≈1e-3578; 1111 (XOR-dominant) fails BRank.

**Verdict:** cap artifact confirmed, but the escape is a fitness-metric
escape, not a quality escape. The op-family determines the PractRand
failure mode. MUL/MUM breaks both mod3n and BRank simultaneously.

See: `mulfree_l24_exp5_2026_05_23.md`

---

## Exp6: Sort-Net 3-Tier Meta-Engine

**Question:** does the 3-tier MMMP meta-engine improve over 2-tier for
the sort-network domain (N=8)?

**Result:** 1/3 seeds finds a valid MMMP (holdout=134.62, sc≈75%). 2/3
seeds remain at the -1,000,000 sentinel floor. No fully-correct sort networks
(sc=1.0). The successful MMMP uses an iterative ACCEPT_IF_BETTER loop.

**Verdict:** 3-tier architecture partially works but has high seed sensitivity
and is weaker than the 2-tier logical-depth successor chain (which produced
Z3-verified correct sorters). LMG and constrained-init not wired to sort adapters —
likely a key reason for poor convergence.

See: `sort_net_3tier_meta_exp6_2026_05_23.md`

---

## Exp7: SAC Fitness

**Question:** does SAC (Strict Avalanche Criterion) fitness produce
different programs than composite fitness, and does it find bijective programs?

**Result:** seed DEAD's champion (BSWAP + ROTL + SPLITMIX_STEP + ADD_CONST +
SHR_XOR, 5 instructions) is the **first Z3-verified bijective mixer in this
research round**. But bijective ≠ PractRand-safe: the bijective champion fails
BRank due to GF(2)-linear structure from BSWAP+ROTL. Non-bijective SAC
champions (1111, ABCD) both pass PractRand. 2/3 seeds reach 5% SAC deviation
from ideal (vs 17% random baseline).

**Verdict:** SAC is a genuinely distinct quality axis. It implicitly favors
bijectivity (non-bijective programs can achieve zero-deviation SAC for some
input/output pairs). But bijection requires more than SAC — the champion
needs non-linear structure (SPLITMIX_STEP alone insufficient to overcome
BSWAP+ROTL linearity).

See: `sac_fitness_exp7_2026_05_23.md`

---

## Exp8: Dual-Output Domain

**Question:** can the 3-tier meta-engine simultaneously discover two
independent high-quality 64-bit mixers?

**Result:** All three seeds escape the −751 sentinel. DEAD: -0.252 (38-unit gap).
1111: -18.62 (58-unit). ABCD: -115.50 (110-unit). All escape-and-lock.
Export binary `meta_mixer_export_dual` built post-analysis; Z3 + PractRand run
on all 6 extracted programs (A + B per seed).

Z3: all "A" programs BIJECTIVE; all "B" programs non-bijective — consistent
slot asymmetry from the shared inner search loop.
PractRand: DEAD_A PASS; ABCD_B PASS; other 4 FAIL (BRank or mod3n per op family).
**DEAD_A (ADD_ROT + SHR_XOR + ROTL + MUL, 4 instr) is bijective + PractRand
PASS — the only fully-verified mixer from the dual-output experiment.**

**Verdict:** dual-output produces quality mixers but with slot asymmetry and
38–110 unit anchor/holdout gaps. Sparse PractRand pass rate (2/6) and
escape-and-lock pattern confirm the dual landscape is harder than single-mixer.

See: `dual_output_exp8_2026_05_23.md`

---

## Exp9: Opset Discovery (Null Result)

**Question:** can the 3-tier meta-engine discover which opset (subset of
15 mixer opcodes) enables the best inner mixers?

**Result:** null result — all 3 seeds stuck at iter-0 quality -10752.70
for all 24 iterations. Root causes: (1) penalty-based restriction (−20
per disallowed op) is too indirect, (2) InnerSaSteps=1 gives only 2
quality evaluations per opset call (too noisy), (3) period_check in
evaluateQuality makes each call slow even at minimum steps.

**Verdict:** the opset hypothesis (MUL-necessity via opset path) is
plausible but untested. Success requires direct generation restriction
(randomProgram emits only allowed ops) + lightweight fitness (no period_check).

See: `opset_discovery_exp9_2026_05_23.md`

---

## Cross-Cutting Findings

**MUL-necessity is now supported by 7 independent experiment conditions:**

| # | Architecture | Result | Failure mode |
|---|-------------|--------|-------------|
| 1 | Bit-tape (XOR/AND/NOT only) | PractRand FAIL | BRank (GF(2)-linear) |
| 2 | MUL-free flat SA | PractRand FAIL | BRank |
| 3 | MUL-free meta-engine (Exp2) | PractRand FAIL | BRank |
| 4 | MUL-free + LMG (Exp3) | PractRand FAIL | BRank |
| 5 | MUL-free L24, ADD-dominant (Exp5 DEAD) | PractRand FAIL | mod3n (modular bias) |
| 6 | MUL-free L24, XOR-dominant (Exp5 1111) | PractRand FAIL | BRank |
| 7 | SAC bijective champion, linear-heavy (Exp7 DEAD) | PractRand FAIL | BRank |

The failure mode is predictable from the dominant op class: ADD ops → mod3n,
XOR/ROTL/BSWAP ops → BRank. MUL/MUM breaks both failure modes simultaneously.

**The 45.83 attractor is the dominant convergence point** for the
unrestricted Engine-3 architecture. 47.32 is achievable but rare (1/3
seeds in both the original run and this reproducibility check).

**SAC fitness is a useful distinct axis:** it implicitly promotes bijectivity
(the first bijective mixer of the round came from SAC training) but does not
guarantee PractRand safety. The bijection + SAC combination is necessary but
not sufficient for statistical quality.

**The 3-tier meta-engine works less well for non-mixer domains:** sort-net
gets 1/3 seed success with sc≈75% (vs 100% for the 2-tier successor chain).
Opset discovery gets zero improvement. The unrestricted mixer domain is the
strongest domain for the current architecture.

---

## Open Questions

1. **Opset via direct restriction:** implement randomProgram(allowed_ops) to
   test whether the meta-engine can discover that MUL-containing opsets
   produce better mixers (the opset hypothesis proper).

2. **Dual-output export:** build `meta_mixer_export_dual` to extract and
   verify dual champion programs. Are the two discovered mixers independently
   bijective? Do they pass PractRand separately?

3. **Sort-net adapter completeness:** wire LMG and constrained-init to the sort
   adapters. Test whether those mechanisms close the gap to the successor chain's
   sc=1.0 result.

4. **Bijection + nonlinearity combination:** can SAC fitness be combined with
   a nonlinearity requirement (e.g., minimum SPLITMIX_STEP count) to find
   bijective programs that also pass BRank?

5. **Scale of the 45.83 attractor:** is 45.83 a strict local maximum or can it
   be escaped with more iterations/seeds? The 47.32 ceiling is accessible — can
   the 45.83 basin be deterministically avoided with better initialization?
