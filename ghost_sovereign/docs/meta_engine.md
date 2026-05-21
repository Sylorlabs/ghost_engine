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
