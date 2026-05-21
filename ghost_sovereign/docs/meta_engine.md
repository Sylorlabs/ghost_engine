# Engine-Inventing-Engine: Tier-0 (Meta-Engine over u64-mixer)

**Date:** 2026-05-20
**Status:** Architecture works; first run overfits and does not generalise.

## Premise

Previous chain work (see `invention_chain.md`) had a fixed SA loop in
the runner that searched for *target programs* (mixers, sort nets).
The engine itself never changed across generations; only the gate did.
Even with `CALL_LIB` composition, the search space transformations
were too small to demonstrate cumulative gain.

This work flips that: **the engine is itself a program** in a new
opcode set whose opcodes are engine-primitives (`INIT_CUR`,
`MUTATE_CUR`, `EVAL_CUR`, `ACCEPT_IF_BETTER`, `ACCEPT_SA`, ...). A
*MetaProgram* is a sequence of these opcodes; executing it for K steps
runs an inner search over u64-mixer programs and returns `q_best`.
The outer search discovers MetaPrograms whose `q_best` is high.

If this works at Tier 0, Tier 1 is straightforward: outer search
becomes itself a MetaMetaProgram, and so on.

## Files

- `src/adapters/domain_meta_engine.zig` — opcode set, `MetaProgram`,
  `run()`, mutation / random construction.
- `src/adapters/meta_engine_runner.zig` — outer SA search over
  MetaPrograms. Held-out validation pass at the end.
- `src/adapters/meta_engine_baseline.zig` — hand-coded reference
  engines (null / random-restart / canonical hill-climb) for
  comparison.
- `results/meta_engine/outer_log.csv` — per-iteration outer-search
  trace.
- `results/meta_engine/best_meta.csv` — discovered champion.

## Opcode set

```
INIT_CUR              cand_cur := randomProgram(rng)
MUTATE_CUR            cand_cur := mutate(cand_cur, rng)
MUTATE_BEST_TO_CUR    cand_cur := mutate(cand_best, rng)
CROSS_BEST_CUR        cand_cur := crossover(cand_best, cand_cur, rng)
EVAL_CUR              q_cur := quality(cand_cur)  [+initialises best on first call]
ACCEPT_IF_BETTER      if q_cur > q_best: best := cur
ACCEPT_SA             metropolis using regs[0] as temperature
RESET_CUR_TO_BEST     cand_cur := cand_best
RAND_REG / REG_XOR / REG_SHR / TEMP_DECAY   scratch-register ops
NOP
```

A MetaProgram has 4..16 opcodes. The opcodes execute top-to-bottom
once per inner step.

## Baseline results (`inner_steps=400`, `eval_seeds=10`)

| Reference engine        | mean    | min      | max    |
| ----------------------- | ------- | -------- | ------ |
| null (eval-only)        | -7779.0 | -10877.7 | -255.2 |
| random-restart          |   24.79 |  -17.38  |  44.44 |
| canonical hill-climb    |  -3.78  |  -98.88  |  47.64 |

`null` confirms a non-evaluating meta-program returns garbage. Random-
restart hits +24.79 because at 400 random tries it usually finds at
least one decent program. The canonical hill-climb has *higher* max
(47.64) but *lower* mean — it spikes when the initial random program
is workable and crashes when it's not.

## Outer-search run

Command:
```
meta_engine_runner --outer-iters=300 --inner-steps=400 --eval-seeds=5
                   --seed=0xDEADBEEF12345678
```

Headline numbers:
- Outer-search-time fitness (5 seeds): **47.40** at iter 214.
- Held-out validation (20 independent seeds): **mean = 25.01**, range
  -89.85 to +47.77.

The held-out mean exactly equals random-restart's baseline. The
discovered engine does *not* generalise.

## Honest diagnosis

The outer search overfits to its 5-seed evaluation set. A MetaProgram
that happens to score well on those particular 5 seeds wins, but the
relationship between "scoring well on those 5 seeds" and "being a good
engine in general" is weak at `eval_seeds=5`. This is the same noise-
ratchet pathology that the original `chain_runner v1` exhibited — the
mechanism works mechanically, but the metric is too noisy at the budget
used.

The structural content of the discovered meta-programs is meaningful
(`MUTATE_BEST_TO_CUR`, `EVAL_CUR`, `ACCEPT_IF_BETTER` all appear, in
the right order, in both runs documented above). The outer search IS
composing engine-like structure from the opcode set. But "engine-like
structure" is not the same as "engine that wins on held-out seeds."

## What this DOES demonstrate

- The substrate (`domain_meta_engine.zig`) faithfully represents an
  engine as a finite program in a small opcode set.
- Outer search reliably climbs from random-program quality (~-55) to
  competitive territory (~47) on training seeds, then plateaus.
- The discovered programs contain the right primitives in roughly
  the right order. The shape is engine-shaped.
- Baselines are in place: null, random-restart, canonical hill-climb.

## What it does NOT demonstrate

- Generalisation. Held-out validation says the discovered engine is no
  better than `random-restart` at this budget.
- Cumulative improvement across tiers. We have not yet run Tier-1
  (MetaMetaProgram outer search) and have no reason to expect a chain
  to compound without first fixing the overfit.

## v2 — seed rotation (same day)

`fitnessOfEpoch()` rotates the eval seed set by outer iteration index;
both `best` and `candidate` are re-evaluated on the new seeds each
iteration so the comparison is fair. A meta-program can only win if
it beats `best` on a freshly drawn seed set.

Same command, output dir `results/meta_engine_v2/`:

| metric                              | v1 (fixed seeds) | v2 (rotation) | random-restart baseline |
| ----------------------------------- | ---------------- | ------------- | ----------------------- |
| outer-search best (training seeds)  | 47.40            | 43.77         |                         |
| **held-out 20 seeds, mean**         | **25.01**        | **33.12**     | **24.79**               |
| held-out max                        | 47.77            | 47.77         | 44.44                   |
| accepted outer mutations            | 5/300            | 64/300        |                         |

Held-out mean climbed by ~8 points and now meaningfully beats random-
restart. The discovered v2 engine has 12 ops with two `RAND_REG` setup
calls, four mutation ops (`MUTATE_CUR` ×3, `MUTATE_BEST_TO_CUR` ×1,
`CROSS_BEST_CUR` ×1) before a single `EVAL_CUR` — effectively a
longer step length than the canonical hill-climb. This shape was
discovered by outer search, not hand-designed.

### Honest v2 verdict

- The engine-inventing-engine substrate **works**: outer SA over
  MetaPrograms produces a program that, when validated on held-out
  seeds, beats `random-restart` mean by ~8 points.
- It does **not** yet exceed `canonical hill-climb`'s upper tail
  (max 47.64 either way) — the discovered engine has higher mean but
  similarly poor min when the initial random program is degenerate.
- The architecture has been demonstrated mechanically and the overfit
  pathology has been characterised and fixed in one cycle. This is
  the first defensible positive demonstration in this project's
  chain-of-engines line of work.

## v3 — hold-out gate with 4-seed probe (FAILED)

Added a 4-seed hold-out probe; outer mutation accepted only if cand
also met `best_holdout - 2.0` on the probe. Used `eval_seeds=10`.

Result: held-out mean **–1043** (catastrophic). The 4-seed probe was
too small to detect catastrophic-init failures, and the 2.0
tolerance allowed gradual hold-out degradation. v3 confirmed the
hold-out gate *architecture* works (35 rejected_by_holdout) but the
hyperparameters were wrong.

## v4 — strict hold-out + catastrophe veto (also worse)

Bumped hold-out to 16 seeds, removed tolerance, added a catastrophe
veto (any single hold-out seed below –100 → reject).

Result: held-out mean **21.66** — better than v3 but worse than v2.
Only 7/300 outer mutations accepted (vs 64 in v2). The veto pushed
search toward random-search-like programs (the discovered champion
has `INIT_CUR` in the middle of the loop). Over-constrained.

**Architectural finding:** at this domain/budget, **seed rotation
alone is sufficient generalisation defense**. Adding strict hold-out
gates over-constrains search and produces worse engines than
rotation-only.

## v5 — rotation-only at high budget (inner_steps=1000)

Same setup as v2 (rotation only, `eval_seeds=5`) but at
`inner_steps=1000` where canonical hill-climb already scores 47.07.

Result: held-out **46.81**, max 47.93. Discovered engine is 6 ops,
near-canonical hill-climb shape. **Engine-inventing-engine matches
but does not beat** canonical hill-climb when the baseline is
already strong.

## Scaling comparison (v2 champion, evaluated at multiple budgets)

The v2 champion (discovered at `inner_steps=400`) was re-evaluated
at multiple budgets and compared head-to-head against baselines:

| inner_steps | random-restart | hill-climb | **v2 discovered** |
| ----------- | -------------- | ---------- | ----------------- |
| 200         |   3.19         |  -1088     | **18.36**         |
| 400         |  21.01         |  -519      | **36.18**         |
| 1000        |  34.30         |  47.07     | **47.29**         |
| 2000        |  39.65         |  47.62     | **47.63**         |

The v2 engine matches or beats canonical hill-climb at EVERY budget,
and at low budgets the gap is transformative (hill-climb is dragged
down by catastrophic stuck-init outliers; v2 has no such failure mode).
This is generalisation across budget — v2 was searched at 400 and
still wins at 1000 and 2000.

## Honest characterization across all v1–v5 experiments

| metric                              | v1 fixed | v2 rotation | v3 4-seed-gate | v4 strict-gate | v5 hi-budget |
| ----------------------------------- | -------- | ----------- | -------------- | -------------- | ------------ |
| held-out mean                        | 25.01   | **33.12**   |  -1043         |  21.66         |  46.81       |
| held-out min                         | -89.85  | -89.85      | -10714         | -89.06         |  39.71       |
| held-out max                         | 47.77   | 47.77       |  47.82         | 47.81          |  47.93       |
| accepted outer mutations             | 5/300   | 64/300      |  26/300        |  7/300         |  46/200      |
| inner_steps                          | 400     | 400         |  400           |  400           |  1000        |

**Strongest result remains v2 at inner_steps=400.** Architecture choice
matters: seed rotation alone outperforms rotation + hold-out gate at
this budget.

**Engine-inventing-engine works where hand-coded engines have known
weaknesses** (catastrophic stuck-init at low budget) and **rediscovers
canonical structure** where they're already near-optimal. It does not
yet find an algorithmic advantage at high-budget regime, where the
quality metric is saturated.

## Runner robustness fixes (post-session-2)

Two bugs surfaced during reproducibility testing:

1. **Drift to no-op engines.** Pure seed rotation could let a
   degenerate engine (one that never calls `EVAL_CUR` → returns
   score 0) "win" on an adversarial epoch where the real best scored
   negative. Fix: maintain `best_ever` separately, updated only when
   a candidate beats it on a *stable* anchor seed set; report
   `best_ever` as the final champion.

2. **Sentinel collision.** `fitnessOf` substituted `0.0` for inf/nan
   (no-EVAL case). But a real eval that scored *negative* ranked
   *below* 0, so the init pool preferred no-op programs over
   evaluating-but-bad ones. Fix: substitute `-1e6` so any real eval
   beats "never evaluated."

3. **Init pool of 32.** Seed many random meta-programs and keep the
   one with highest anchor score. Guarantees the search starts from
   a non-degenerate engine.

## Reproducibility batch (4 seeds, u64-mixer)

Same protocol as v2 (`outer=300 inner=400 eval_seeds=5 rotation-only`)
with robustness fixes, 4 independent root seeds:

| seed | anchor | val mean | val min | val max | accepted |
| ---- | ------ | -------- | ------- | ------- | -------- |
| r0   | 47.12  | **45.49** |  16.69  | 47.87   | 62/300   |
| r1   | 47.56  | **44.14** |  -0.51  | 47.97   | 68/300   |
| r2   | 45.39  |  26.74    | -234.03 | 47.85   | 69/300   |
| r3   | 44.63  | **43.53** |  10.92  | 47.96   | 47/300   |

**3 of 4 runs produced engines with held-out mean 44+** (random-restart
baseline at this budget: 21.01). Mean across runs: 40.0 — beats v2's
33.12. The architecture **reproducibly produces winning engines**
across diverse seeds; one of four (r2) had a catastrophic-min seed
in its validation set but its anchor was still 45.

## Cross-domain test: sort_net N=8

Same outer-search protocol applied to a structurally different
target (additive cost axis via depth, structural divergence,
correctness gate instead of continuous quality).

**Sort-net baseline curve** (eval_seeds=20):

| inner_steps | random-restart | hill-climb |
| ----------- | -------------- | ---------- |
| 100         | 14.79          |  77.58     |
| 200         | 23.10          | 134.50     |
| 400         | 29.91          | 166.05     |
| 1000        | 48.65          | 172.64     |

**Discovered engine** (`inner_steps=400`, single run):
- best_ever_anchor = 175.90
- held-out validation mean = **171.59** (min 133.25, max 180.00)
- vs canonical hill-climb at same budget: 166.05
- **discovered engine wins by +5.54 points** at inner_steps=400
- Effective budget improvement: discovered at 400 ≈ hill-climb at 1000

The discovered engine is 7 ops, contains **two mutation primitives
per step** (`MUTATE_CUR` + `MUTATE_BEST_TO_CUR`) and **two
evaluations** with three accept ops mixed in:

```
[0] MUTATE_CUR              — perturb current
[1] ACCEPT_IF_BETTER        — greedy on cur
[2] MUTATE_BEST_TO_CUR      — perturb from best
[3] ACCEPT_SA               — metropolis
[4] EVAL_CUR
[5] ACCEPT_SA
[6] EVAL_CUR
```

Canonical hill-climb has one of each. Outer search discovered that
*diversified per-step exploration* outperforms single-point
hill-climb on sort-net at constrained budgets. This is a real
algorithmic insight — not a hand-designed heuristic — emerged from
the engine-inventing-engine search.

## Sort-net reproducibility (4 additional seeds — CORRECTION)

The +5.54 sort-net result above was a single run; a follow-up 4-seed
reproducibility test was run to verify. Results:

| seed | anchor | held-out mean | held-out min | held-out max | beats hill-climb 166.05? |
| ---- | ------ | ------------- | ------------ | ------------ | ------------------------ |
| run1 | 175.90 | 171.59        | 133.25       | 180.00       | ✓ +5.54                  |
| r0   | 176.29 | 156.68        |  41.06       | 178.50       | ✗ -9.37                  |
| r1   | 177.35 | **176.76**    | 166.69       | 179.50       | ✓ +10.71                 |
| r2   | 175.75 | 161.40        |  59.09       | 177.50       | ✗ -4.65                  |
| r3   | 177.24 | 159.40        |  22.53       | 178.00       | ✗ -6.65                  |

**2 of 5 (40%) beat hill-climb on held-out mean**; **median across
5 runs: 161.40** — slightly below hill-climb 166.05. **All 5 scored
175–177 on the 8-seed anchor** but held-out spread is wide. The
anchor set is too small / too similar to rotation pool — there's
residual overfit.

**Revised cross-domain claim**: engine-inventing-engine on sort_net
produces engines **competitive with** (not consistently beating)
hand-coded hill-climb. Architecture works cross-domain; reliability
needs more anchor diversity to be claimed as a beat-baseline result.

The original "+5.54 strong win" framing in the cross-domain section
above was based on a single lucky run. This correction supersedes
it — the honest read is "competitive median, occasional wins."

## Cross-domain summary

| domain    | hand-coded hill-climb | discovered engine | margin |
| --------- | --------------------- | ----------------- | ------ |
| u64-mixer (inner_steps=400) | -519 (crashes)       | 36.18 (v2)        | +555   |
| u64-mixer (inner_steps=1000)| 47.07                | 47.29             | +0.22  |
| sort_net (inner_steps=400, n=5 seeds, MEDIAN) | 166.05    | 161.40     | -4.65 (median) |
| sort_net (inner_steps=400, BEST of 5 seeds)   | 166.05    | 176.76     | +10.71 (best)  |

Engine-inventing-engine demonstrated across two structurally
distinct domains. Decisive wins at low u64-mixer budgets; on
sort_net, the median discovered engine is slightly below hill-climb
but the best is +10.7 — high variance across seeds. The substrate
is working; reliable cross-domain dominance requires more anchor
diversity than the current 8-seed anchor provides.

## Next steps (in priority order)

1. **Seed rotation in outer search**: each outer iteration evaluates
   all candidates on a *different* seed set drawn from a seed
   schedule. Prevents the SA from memorising favorable seeds.
2. **Hold-out gate**: only accept an outer mutation if it improves on
   both the training seed set *and* a small held-out probe set. Cheap
   sanity check.
3. **Increase eval_seeds floor**: at minimum `eval_seeds=10` on each
   outer evaluation; budget the outer run accordingly.
4. Once (1)+(2) yield a discovered engine that *beats random-restart
   on held-out seeds*, then it's defensible to try Tier-1: replace
   the outer SA with a MetaMetaProgram and search for MetaMeta
   engines whose discovered meta-engines beat the hand-coded outer
   SA.

## What NOT to do

Do not claim the discovered 47.40 figure as engine-inventing-engine
success. The held-out 25.01 is the truth-of-the-matter; this is a
first-cut harness with a known overfit pathology, not yet a working
demonstration of engine self-invention. Per project [feedback-claude-
role], audit before celebrating.
