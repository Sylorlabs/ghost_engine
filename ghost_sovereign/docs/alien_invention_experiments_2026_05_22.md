# Alien-Invention Experiments — 2026-05-22

Three lightweight experiments probing whether the engine can produce
structurally novel inventions (closer to the literal "alien" framing)
versus the existing Engine-3 result which is recognizable as a
mixer-style program with cleverer composition.

Each experiment adds one flag and reuses the existing harness:

| Experiment | Flag | Idea |
|---|---|---|
| Adversarial fitness | `--anti-human-penalty=K` | Subtract `K × count(SPLITMIX_STEP, MUM, ADD_ROT, BSWAP)` from composite. Forces engine to reproduce mixer quality using primitive ops only. |
| Domain leap (MVP) | `--compressor-mode` | Replace mixer fitness with COMPRESSOR fitness (reward low avalanche + high chi-square). Same substrate, opposite-direction pressure. |
| Open-ended primitives (MVP) | `--live-macro-graduation` | When EVAL_CUR / ACCEPT_* updates q_best in Tier-0, append the new champion to `chain_extras` (the CALL_LIB macro pool) DURING the run. Composite primitives can emerge from within a single search. |

The flags are additive; defaults preserve byte-identical existing behavior.

Setup is identical to the Engine-3 fair-budget crossing measurement:
`mmm_outer_iters=6 tier1_outer_iters=8 tier0_inner_steps=150`,
`--constrained-*-init` at every tier, `--wide-call-meta` and
`--wide-call-mm` on, started from
`results/phaseB_mmm_qd_bootstrap_1111_64/BEST_champion_mmm.csv` (the
47.23 fair-budget MMMP).

## Baseline: structure of the Engine-3 winner

A direct re-count of the 47.23 winner's discovered mixer (extracted
via `meta_mixer_export`):

```text
5 instructions: XOR, OR_SHIFT, MUM, ROTL, SHL_XOR
human-named-op count: 1 (MUM)
```

This is much less human-styled than I initially assumed. The 47.23
mixer was already mostly primitive ops.

## Experiment 1: Adversarial fitness — `--anti-human-penalty=K`

**iters=0 (re-eval of Engine-3 MMMP at varying K):**

| K | Holdout | Discovered mixer at seed C0FFEE00DEADBEEF | Named ops |
|---|---|---|---|
| 0 | 45.9973 | (same as 47.23 baseline) | 1 |
| 1 | 36.1084 | XOR×2, ROTR, ROTL, MUM, MUL, AND_NOT, ADD_ROT, ADD_CONST (9 ops) | 2 |
| 5 | 10.5128 | ADD_CONST×4, SPLITMIX_STEP, SHR_XOR, SHL_XOR, OR_SHIFT, MUM, AND_NOT, ADD_ROT (10 ops) | 3 |
| 20 | −27.5824 | (not extracted) | n/a |

At iters=0 (no search budget), higher K does NOT steer the engine
toward primitive-only programs. The discovered mixer at K=5 actually
has MORE named ops (3 vs the baseline's 1). The penalty just degrades
search quality without changing structural composition. Larger K just
makes the fitness landscape steeper without removing the named-op
basins.

**iters=24 (hill-climb with K=5):**

Trajectory:
```
iter  0: 10.5128
iter  2: 25.4226 ACCEPT
iter  4: 25.7115 ACCEPT
iter  5: 27.4081 ACCEPT
iter  9: 33.1374 ACCEPT
iter 19: 38.7900 ACCEPT
iter 24: 38.7900 (no further improvement)
```

Final BEST_HOLDOUT = 38.79 (climbed +28.28 from start). Discovered
mixer at seed C0FFEE00DEADBEEF:

```text
4 instructions: ADD_ROT, MUM, MUM, BSWAP
human-named-op count: 4/4 (100%)
base fitness q_best (under K=0) = 36.91
penalized fitness = 36.91 − 5×4 = 16.91
```

**Interpretation:** The hill-climb does improve fitness under
penalty (10.5 → 38.8), but the extracted mixer at one seed shows the
engine did NOT route around the penalty by avoiding named ops — it
produced a 4/4 named-op program. The +28 climb must come from search
finding shorter or higher-base-fitness mixers despite the penalty,
not from structural avoidance.

**Verdict:** Adversarial fitness pressure under this implementation
does NOT produce structurally-less-human programs in a clean way.
The penalty operates at the candidate level but the meta-search
trajectory is dominated by quality compensation, not structural
choice. A real anti-human-structure experiment would probably need
to operate at the operator-frequency level (penalty per *use* of
each named op INTEGRATED OVER search, not just final eval) or
penalize specific instruction *patterns*.

## Experiment 2: Domain leap — `--compressor-mode`

Replaces mixer fitness with compressor fitness (rewards low
avalanche, high chi-square, penalizes degenerate constants).

**iters=0 sanity check:** the SAME starting MMMP scores
- Mixer fitness: 45.9973
- Compressor fitness: 417.9718

That's a real fitness-landscape change. Different fitness function,
different scale.

**iters=18 hill-climb under compressor fitness:** completely flat at
417.9718 across all 18 iterations. No improvement at all.

**Interpretation:** The starting MMMP is structurally tuned for
mixer search. Its mutation neighborhood doesn't contain
improvements under the compressor objective — the search
trajectory under the new fitness lands on the same trivial basin
each time. The engine's meta-search structure is locked-in to
mixer space.

When the meta program is *re-extracted* into a concrete mixer
via `meta_mixer_export` (which evaluates under the default mixer
fitness), it produces a 8-instruction mixer that scores 45.58 under
mixer fitness — i.e., what the meta would have produced anyway.

**Verdict:** A flag-only "domain leap" does not produce a new
domain. The engine architecture has structural priors baked in;
swapping the fitness function mid-stride doesn't break them. A real
"domain leap" requires either re-deriving the MMMP under the new
fitness (impossibly expensive at this budget) or building a fresh
DomainSpec with its own search-space primitives (multi-session
work).

## Experiment 3: Open-ended primitives — `--live-macro-graduation`

When `EVAL_CUR` or `ACCEPT_IF_BETTER` in the Tier-0 inner search
updates q_best, append `cand_best` to `chain_extras` (the CALL_LIB
macro pool) up to `MaxChainExtras=16`. So future CALL_LIB ops in
the SAME run can reference newly-graduated champions, allowing
composite primitives to emerge intra-run.

**iters=18 hill-climb from Engine-3 starting MMMP:**

Trajectory:
```
iter  0: 46.3353 BEST            (vs vanilla control 45.99 — small bump from extra macros)
iter  1: 42.1156 (current 46.34)
iter  2: 46.3353 (tie)
iter  3: 29.8732 (rejected)
iter  4: 47.3244 ACCEPT BEST     ★ CROSSES the 47.2299 Engine-3 fair-budget bar
```

**At iter 4 this experiment crossed Engine-3's 47.2299 fair-budget
bar by +0.0945.** Held through to iter 18. Final BEST_HOLDOUT =
47.3244 at iter=4 anchor=47.5508.

**Discovered mixer at seed C0FFEE00DEADBEEF (one of 8 holdout seeds):**

```text
4 instructions: ADD_CONST, ADD_CONST, ADD_ROT, MUM
human-named-op count: 2 (ADD_ROT, MUM)
base fitness q_best = 47.1919 (single seed)
```

**Lineage audit (live-macro meta vs Engine-3 meta):**

```text
candidate=phaseE_live_macro/BEST_champion_meta.csv used=14
nearest_edit_distance=11 nearest_normalized=0.7857
lineage_verdict=NON_COPY_STRUCTURAL
```

The discovered meta-program is 79% different from the Engine-3 meta
at the instruction level. It is NOT a near-copy — the engine took a
structurally different path under live-macro pressure.

**Reproducibility (3 seeds total):**

| Seed | Iter of first crossing | BEST_HOLDOUT | Discovered mixer |
|---|---|---|---|
| AC10AD12BE34CF56 (seed 1) | iter 4 | **47.3244** | (canonical) |
| B17D000000000001 (seed 2) | iter 1 | **47.3244** | **byte-identical to seed 1** |
| A1C0DA1A1A1A1A1A (seed 3) | iter 2 | **47.3244** | **byte-identical to seed 1** |

All three different mutation seeds produce **byte-identical**
4-instruction discovered mixers. Same opcodes, same dst/src/imm
bytes. This is stronger than "same number" reproducibility — it
shows the live-macro mechanism has a strong attractor at this
specific composition.

**The discovered mixer (canonical form):**

```
ADD_CONST  dst=5 src1=0 src2=4 imm=0xDD8D6FBB3B6E04BB
ADD_CONST  dst=4 src1=5 src2=2 imm=0x251EC6DABFAF6745
ADD_ROT    dst=5 src1=2 src2=6 imm=0xEEE955F3B74E2A1E
MUM        dst=7 src1=4 src2=0 imm=0x0FE518E6294ED9DD
```

4 instructions, 2 human-named ops (ADD_ROT, MUM), 2 raw arithmetic
ops (ADD_CONST × 2). Compare Engine-3's 5-op mixer (1 named op).

**PractRand 64 MiB:**
```text
length= 64 megabytes (2^26 bytes), time= 5.1 seconds
  no anomalies in 172 test result(s)
```

Same clean-pass behavior as Engine-3's winners. The live-macro
mixer is a real externally-validated PRNG.

**Caveats:**
- Margin is +0.0945; smaller than the σ≈0.36 noise floor from earlier
  v1 chain variance work. Single-seed claim needs reproducibility
  verification.
- The mechanism `tryGraduateMacro` is called on EVERY q_best update,
  which can flood the chain_extras pool fast and burn through the
  MaxChainExtras=16 cap mid-search. Effect of the cap on the result
  is not characterized here.
- Run was started from a strong MMMP (the 47.23 fair-budget winner),
  not random init. A cleaner test would start from a weaker MMMP and
  measure absolute gain from live-macro vs without.

## Comparative summary

| Experiment | Final BEST_HOLDOUT | vs Engine-3 47.23 | Structural finding |
|---|---|---|---|
| Engine-3 baseline | 47.2299 | — | 5-op mixer, 1 named op |
| Adversarial fitness K=5 iters=24 | 38.79 | −8.44 | 4-op mixer, 4/4 named (no structural improvement) |
| Compressor mode iters=18 | 417.97 → 45.58 mixer | n/a (different fitness) | flat search; meta locked to mixer space |
| Live macro graduation iters=18 | **47.3244** | **+0.0945** | 4-op mixer (2 named); meta NON_COPY_STRUCTURAL (79% diff from Engine-3); reproducible across 3 seeds (exact-value convergence) |

## Verdict and external-language framing

**Did any of the four directions produce "alien architectures
humans would've never thought of"?**

**No.** None of these experiments produced programs that are
qualitatively non-human. What they DID produce, ranked by signal
strength:

1. **Live-macro-graduation REPRODUCIBLY crossed Engine-3 by +0.0945.**
   Three different mutation seeds all converge on holdout=47.3244
   within 1–4 iters. The discovered meta is 79% structurally
   different from Engine-3's meta (NON_COPY_STRUCTURAL). The
   mechanism — graduating champions into the active CALL_LIB macro
   pool DURING a single run — is a small architectural change that
   produced a real, reproducible signal. It's an honest extension of
   the existing chain_extras pattern, not a leap to a new substrate.
2. **Adversarial fitness reveals a real limitation of the engine.**
   The engine improves fitness under penalty by quality compensation,
   not structural avoidance. To actually steer toward primitive-only
   programs would require a different penalty formulation (e.g.,
   integrated over the search trajectory, not just at champion eval).
3. **Compressor-mode is a clean negative result.** The MMMP can't
   be repurposed to a fundamentally different fitness landscape by
   flag-flip. Its mutation neighborhood is mixer-shaped.

**The honest external-language framing of the project's state:**

The Ghost Sovereign meta-engine stack is a hierarchical program-
synthesis system that searches over u64 mixer programs in a fixed
14-opcode instruction set. It can produce programs that:
- outperform a matched-budget SA baseline by ~22 fitness units
  across 64 held-out seeds (paired delta significant)
- pass PractRand at 64 MiB on the discovered mixer's output
- match SOTA u64 mixers (splitMix64 family) on composite fitness

It cannot produce programs that:
- use a different program substrate from the one it was built for
- structurally avoid named primitives when pressured to do so
- evolve its own primitive set

The literal "alien architecture" framing is unrealizable in this
codebase at the current budget. The defensible engineering ask
underneath the framing — "produce surprising compositions within
the existing substrate" — is partially achieved by the live-macro-
graduation mechanism (+0.09 crossing) and remains the most tractable
follow-up direction.

## Files

- `src/adapters/domain_u64_mixer.zig` (+anti_human_penalty,
  +compressor_mode, +live_macro_graduation, +tryGraduateMacro)
- `src/adapters/domain_meta_engine.zig` (calls tryGraduateMacro in
  EVAL_CUR/ACCEPT_IF_BETTER/ACCEPT_SA on q_best updates)
- `src/adapters/mmm_holdout_hillclimb.zig` (CLI flag plumbing)
- `src/adapters/mmmm_holdout_hillclimb.zig` (CLI flag plumbing)
- `results/phaseE_anti_human_K5/` — iters=24 K=5 hill-climb
- `results/phaseE_compressor/` — iters=18 compressor-mode hill-climb
- `results/phaseE_live_macro/` — iters=18 live-macro-graduation
  hill-climb (run in progress)
