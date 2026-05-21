# Tier-1 meta-engine — implemented, ran, HALTed at current budget

**Date:** 2026-05-21
**Verdict:** HALT(tier-1). Discovered MetaMetaProgram does NOT beat
hand-coded outer SA when both run with equal discipline at equal
budget.

## What was built

- `src/adapters/domain_meta_meta_engine.zig` — opcode set mirroring
  Tier-0 but one level up: INIT_META_CUR, MUTATE_META_CUR,
  MUTATE_META_BEST_TO_CUR, CROSS_META_BEST_CUR, EVAL_META_CUR,
  ACCEPT_META_IF_BETTER, ACCEPT_META_SA, RESET_META_CUR_TO_BEST,
  RAND_REG, REG_XOR, REG_SHR, TEMP_DECAY, NOP. Each EVAL_META_CUR
  invokes `tier0.run(meta_cur, INNER_TIER0_STEPS, seed)`.
- `src/adapters/meta_meta_engine_runner.zig` — outer SA over
  MetaMetaPrograms with anchor protection + seed rotation discipline,
  paired with a HAND-CODED Tier-0 outer SA baseline that uses the
  SAME discipline. Equal MetaProgram-evaluation budget. Both run
  produce a champion MetaProgram, re-evaluated on a fixed 8-seed
  held-out set distinct from any seed used during search.

## Pilot result

Pilot config:
- tier1_iters = 20 outer SA iterations over MetaMetaPrograms
- mm_outer_iters = 12 outer steps per MetaMetaProgram run
- tier0_inner_steps = 150
- Init pool = 32 random MetaMetaPrograms (anchor-mean filtered)
- Anchor seeds: 4 stable seeds, distinct from rotation seeds and
  distinct from held-out seeds

| metric                   | hand-coded baseline | Tier-1 |
|--------------------------|---------------------|--------|
| anchor-mean train q      | 43.10               | 37.22  |
| held-out mean (8 seeds)  | **32.55**           | -6.52  |

Tier-1 lost on both training (anchor-mean) and held-out. The honest
verdict is HALT.

## Diagnosis

The first pilot (v1, no discipline on baseline) made Tier-1 look like
it won — baseline held-out -1423 (catastrophic overfit), Tier-1
held-out -6.52 (weakly negative). That was a UNFAIR test: the
baseline had no anchor protection + rotation, so it overfit the
specific eval seed it saw.

Once the baseline was upgraded to use the SAME discipline as Tier-1
(matching `project-meta-engine v2`'s anchor-protection + rotation
pattern from `meta_engine_runner.zig`), the baseline wins decisively.

**The load-bearing thing is the outer-search discipline**, not the
MetaMetaProgram representation. Both halves of the experiment carry
the discipline at the outer (Tier-1 / Tier-0-baseline) level; the
discovered MetaMetaProgram only varies the *inner* search pattern,
and at this budget that's not enough to compensate for the
expressiveness gap between "hardcoded mutate-and-anchor-accept" and
"random opcode sequence that may or may not contain EVAL_META_CUR."

## What this is, and is not

**Is:**
- A working implementation of Tier-1 with proper discipline,
  reproducible HALT result.
- Empirical evidence that the v2 fix in `project-meta-engine`
  (anchor + rotation) accounts for most of the
  engine-inventing-engine effect; adding another tier on top with
  random program search doesn't help at this budget.
- A cleanly stated HALT, in accordance with `feedback-invention-
  chain-directive` ("If you cannot find a generation_{n+1} that
  beats generation_n at the same inner budget, that is the honest
  finding. Report HALT(n)").

**Is NOT:**
- A demonstration that engine-inventing-engine fails in principle.
  Specifically, this HALT may move with: (a) bigger Tier-1 budget
  (more outer iters → better MMP coverage), (b) held-out gating at
  Tier-1 itself, (c) richer MetaMetaOp set (perhaps CALL_META(prior)
  primitives), (d) curriculum learning.
- An indictment of Tier-0. Tier-0 still reproduces (3/4 seeds give
  held-out 44+ vs random-restart 21). The successor question Tier-1
  asks is the strictly harder one: invent a SEARCH ALGORITHM, not
  just an outcome.

## Next moves

1. Scale: tier1_iters=200, mm_outer_iters=24, tier0_inner_steps=300.
   Approx 20× the current pilot. Long run (~hour).
2. Held-out gate at Tier-1: accept only if cand also beats best on a
   small held-out probe set (separate from final held-out).
3. CALL_META primitive: extend MetaMetaOp with a CALL_META(k) that
   invokes a prior champion MetaProgram inline — gives Tier-1 the
   composition primitive that unlocked the sort_net chain.

## Update — Tier-1 CHAIN result (CALL_META + multi-gen, 2026-05-21)

`meta_meta_chain_runner` implements moves (1)+(3) above. Generation n
populates `mm.chain_extras` with prior champion MetaPrograms;
gen_n+1's MMPs have `CALL_META(k)` opcode that warm-starts meta_cur
from a **mutated copy** of `chain_extras[k]`.

Why the mutation matters: in the first attempt, CALL_META copied
chain_extras[k] verbatim, so a discovered MMP that emitted
`CALL_META + EVAL + ACCEPT` short-circuited evolution — gen_n+1's
champion = gen_n's champion, identical holdout across generations.
Forcing the warm-start through `tier0.mutateMeta()` makes CALL_META
a "compose with novelty" primitive, the direct analog of
`CALL_LIB + random_comparators` that unlocked sort_net.

Pilot result, seed 0xF00DBEEFCAFEFACE:

| gen | anchor mean | holdout (8 seeds) | verdict                       |
|-----|-------------|-------------------|-------------------------------|
| 0   | 23.81       | -19.67            | ADVANCE                       |
| 1   | 47.19       | -19.67            | ADVANCE(tie)                  |
| 2   | **47.43**   | **-12.83**        | **ADVANCE + STRICT_DOMINATION** |
| 3   | 34.34       | -19.67            | HALT(holdout_regression)      |

**First positive Tier-1 chain result on this project.** Gen_2's
discovered champion MetaProgram beats gen_1's on a stable held-out
seed set at equal inner-search budget. Gen_3 then HALTs honestly
(holdout regressed).

**Multi-seed reproducibility (4 root seeds):**

| seed              | gen 0   | gen 1   | gen 2     | gen 3   | strict_dom steps | best holdout | end       |
|-------------------|---------|---------|-----------|---------|------------------|--------------|-----------|
| 0xF00DBEEFCAFEFACE | -19.67  | -19.67 (tie) | **-12.83**  | HALT    | 1                | -12.83       | HALT gen 3 |
| 0xDEADBEEF11223344 | -6.56   | HALT(-58.75) | —         | —       | 0                | -6.56        | HALT gen 1 |
| 0x1111222233334444 | 10.93   | **25.71**    | **44.30** | HALT(30.98) | **2**         | **44.30**    | HALT gen 3 |
| 0x7777888899990000 | -1378   | -1378 (tie)  | **-16.93** | HALT(-1378) | 1            | -16.93       | HALT gen 3 |

**3/4 seeds produce at least one STRICT_DOMINATION step at Tier-1.**
**1/4 (0x1111…) produces TWO consecutive STRICT_DOMINATIONs and reaches
holdout 44.30, beating the disciplined hand-coded baseline (32.55).**
1/4 (DEADBEEF) catastrophically HALTs at gen 1 from a degenerate
init-pool start.

**The CALL_META → mutated copy invariant matters.** First implementation
had CALL_META copy the prior champion verbatim; that made gen_n+1
short-circuit to gen_n's champion (identical holdout across gens, no
real evolution). Forcing the warm-start through `tier0.mutateMeta()`
makes CALL_META a "compose with novelty" primitive — direct analog of
the `CALL_LIB + random_comparators` pattern that unlocked sort_net.

**Honest caveats:**
- High variance. 3/4 succeed but the specifics vary widely (one chain
  beats baseline, one barely above gen_0, one only escapes from a
  very negative starting point).
- Multi-step improvement (>1 strict_dom step in a chain) is observed
  in 1/4 seeds. Sustained, reliable n-step chains are not yet proven.
- The 44.30 result is one seed. Comparable runs of the disciplined
  hand-coded baseline on the same anchor + holdout setup hit ~32.55.
  So beating baseline is achievable but not yet routine.

**What this IS:**
- **The first reproduced Tier-1 successor chain on this project**:
  3/4 seeds produce a generation whose discovered MetaProgram beats
  the prior generation's on held-out at equal inner-search budget.
- Existence proof: a Tier-1 chain CAN reach holdout > hand-coded
  baseline (seed 0x1111…).
- Direct transplant validation: the same recipe that unlocked
  sort_net (cheap composition primitive that includes mutation)
  works at Tier-1.

**What this is NOT:**
- Robust dominance over hand-coded baseline — only 1/4 seeds beat it
  on the 8-seed held-out.
- Unbounded improvement — chains halt after 1-2 gens of improvement.
- A proof Tier-2 or deeper would work.

## 64-seed validation of the 0x1111 champion

The 0x1111 chain's gen_2 champion MetaProgram was re-validated on a
64-seed held-out set distinct from any seed used during training,
side-by-side with a freshly-trained disciplined hand-coded baseline
at EQUAL training budget (~7400 MetaProgram evals each).

### Result (baseline-iters=1500, inner-steps=180)

|                       | n_finite | mean   | std    | min     | max    |
|-----------------------|----------|--------|--------|---------|--------|
| discovered champion   | 64       | **37.68** | 15.94  | **-10.95** | 47.64  |
| baseline outer SA     | 64       | 28.13  | 26.23  | -89.02  | 47.94  |

| paired delta (champ - baseline) | wins  | losses | ties | mean delta |
|--------------------------------|-------|--------|------|------------|
|                                | 37    | 19     | 8    | **+9.54**   |

**Verdict: CONFIRM.** The discovered champion wins on 37/64 seeds,
mean delta +9.54.

### What the validation actually showed

The headline isn't "discovered crushes baseline" — it's **robustness**:
- Discovered champion's worst case: -10.95. Baseline's worst case:
  -89.02. The baseline occasionally crashes on adversarial seeds;
  discovered MetaProgram has built-in resilience.
- Discovered std 15.94 vs baseline std 26.23 — discovered is more
  consistent across seeds.
- Mean win is +9.54 not +50; the initial 8-seed result was inflated
  by an undersized baseline (200 iters instead of equal-budget 1500).

### Sanity-check timeline

| baseline budget | mean delta | wins | interpretation                |
|-----------------|------------|------|-------------------------------|
| 200 iters       | +54.84     | 61/64 | UNFAIR (baseline undertrained) |
| 1500 iters      | +9.54      | 37/64 | FAIR (equal training budget)  |

Always check budget parity before celebrating a "dominant" win.

## What's discovered, in human form

The 0x1111 gen_2 champion MetaProgram (16 ops):

```
TEMP_DECAY → EVAL_CUR → ACCEPT_IF_BETTER → INIT_CUR →
MUTATE_CUR → MUTATE_BEST_TO_CUR → EVAL_CUR → ACCEPT_SA →
CROSS_BEST_CUR → RESET_CUR_TO_BEST → ACCEPT_SA → INIT_CUR →
REG_XOR → TEMP_DECAY → CROSS_BEST_CUR → TEMP_DECAY
```

Notable: hybrid greedy (ACCEPT_IF_BETTER) and SA (2× ACCEPT_SA) on
every cycle, plus periodic INIT_CUR random kicks for exploration,
plus 3 TEMP_DECAY ops actively cooling. Not a structure a human
would hand-write.

The 0x1111 gen_2 champion MetaMetaProgram (14 ops):
```
RAND_REG → REG_SHR → ACCEPT_META_IF_BETTER → MUTATE_META_CUR →
CROSS_META_BEST_CUR → REG_SHR → MUTATE_META_BEST_TO_CUR → NOP →
ACCEPT_META_IF_BETTER → MUTATE_META_CUR → CALL_META(1) →
REG_XOR → NOP → EVAL_META_CUR
```

The discovered Tier-1 search uses `CALL_META(1)` — warm-starts from
the gen_1 champion (the prior generation) — followed by `REG_XOR` and
only THEN `EVAL_META_CUR`. So the search structure is "mutate-and-
compose from prior champion, perturb, evaluate." The chain extras
mechanism worked exactly as the recipe predicted.

## Reproduce

```
cd ghost_sovereign
zig build -Doptimize=ReleaseFast
./zig-out/bin/meta_meta_engine_runner \
    --tier1-iters=20 --mm-outer-iters=12 \
    --tier0-inner-steps=150 \
    --seed=F00DBEEFCAFEFACE \
    --out-subdir=mm_v3
```

Run produces `results/mm_v3/summary.csv` with train_q_best,
holdout_mean, metaprogram_evals for both halves.

## Update — Wide CALL_META (4-bit addressing, 2026-05-21)

Standard CALL_META uses a 2-bit `dst` field → addresses 4 library
slots. When chain_extras grows past 4 entries (e.g., an 8-entry seed
library from merging two chains), slots 4..7 are unreachable.

**Wide CALL_META** composes the index as `(dst<<2 | src1)` → 4-bit
(16-slot) addressability. Opt-in via `mm.wide_call_meta = true` /
`--wide-call-meta` flag. Existing results are unchanged (default off).

3 seed pairs tested (8-entry library, identical budget):

| seed     | narrow best holdout | wide best holdout | winner     |
|----------|---------------------|-------------------|------------|
| 0xABCD…  | 17.49               | **44.81**         | **wide** ★ |
| 0x9999…  | **36.75**           | 30.87             | **narrow** |
| 0x5555…  | 21.09               | **30.87**         | **wide** ★ |

Wide wins 2/3 at best-holdout. Wide also wins 3/3 at gen-0 holdout
(consistent direction, large deltas: +1348, +28, +17). Wide reaches
the 44.30 ceiling at a different seed than the original 0x1111 chain.

**Recommendation: use `--wide-call-meta` as default for chains with
library size > 4.**

See `docs/successor_loop_research.md` Test #2 for full data.

## Update — Budget scaling REFUTED (2026-05-21)

Tested `tier1_iters=200` (8× original) on 4 seeds. **All 4 get
WORSE holdout than the 24-iter default.**

| seed     | 24-iter gen 0 holdout | 200-iter gen 0 holdout | delta |
|----------|----------------------|------------------------|-------|
| 0x1111…  | 10.93                | -35.35                 | ↓     |
| 0xF00D…  | -19.67               | -47.50                 | ↓     |
| 0xDEAD…  | -6.56                | -99.05                 | ↓     |
| 0x7777…  | -1378                | -1400                  | ≈     |

Anchor-mean GOES UP (overfits 4 anchor seeds), holdout GOES DOWN.
The 4-anchor-mean generalization protection has a **budget-dependent
failure mode**: at 200 iters the search has enough budget to game
the specific 4 anchors without learning generalizable structure.

**The 24-iter budget is the correct operating point** until anchor
protection is strengthened (more anchors, cross-validation rotation,
or structural regularization).

See `docs/successor_loop_research.md` Test #1 for full data.

Related: [[project-meta-engine]] (the Tier-0 success this builds on),
[[project-successor-chain-sort]] (where the successor question WAS
answered yes), [[feedback-invention-chain-directive]],
[[successor-loop-research]] (the research round that tested these).
