# Tier-2 — engine-inventing-engine-inventing-engine-inventing-engine

**Status: IMPLEMENTED + EVALUATED + PROGRESSIVE LEARNING (NOT YET COMPETITIVE)**

## What is Tier-2

A `MetaMetaMetaProgram` (MMMP) is a sequence of opcodes whose primitives
operate on `MetaMetaProgram` values (Tier-1). When run, the MMMP drives
a search over MetaMetaPrograms. Each `EVAL_MM_CUR` runs a Tier-1
mini-search via `mm.run(mm_cur, INNER_TIER1_OUTER_STEPS, seed)`, which
itself drives a Tier-0 search over MetaPrograms.

The fitness ladder is preserved through all layers:

```
mmm.run(mmm, …) → q_best of the best mm.run(mm) it visited
mm.run(mm,   …) → q_best of the best tier0.run(meta) it visited
tier0.run(meta) → q_best of the best mixer-fitness it visited
```

So Tier-2's "q_best" IS still a mixer-fitness number on the same axis
as Tier-0 and Tier-1 fitnesses. Apples-to-apples comparison is
possible.

## Files

- `src/adapters/domain_meta_meta_meta_engine.zig` — MMMP type, opcodes,
  `run`, `runReturningChampion`, `randomMetaMetaMetaProgram`,
  `mutateMetaMetaMeta`, `chain_extras_mm` library, CSV emission.
- `src/adapters/mmm_chain_runner.zig` — disciplined Tier-2 chain runner
  (anchor + rotation, multi-generation, CALL_MM for prior champion
  warm-start).
- `results/mmm_chain_*/` — per-run logs and champion CSVs.

## Opcodes

```
INIT_MM_CUR            — mm_cur := randomMetaMetaProgram(rng)
MUTATE_MM_CUR          — mm_cur := mutateMetaMeta(mm_cur, rng)
MUTATE_MM_BEST_TO_CUR  — mm_cur := mutateMetaMeta(mm_best, rng)
CROSS_MM_BEST_CUR      — splice mm_best into mm_cur
EVAL_MM_CUR            — q_cur := mm.run(mm_cur, INNER_TIER1_OUTER_STEPS, seed)
ACCEPT_MM_IF_BETTER    — if q_cur > q_best: mm_best := mm_cur
ACCEPT_MM_SA           — metropolis on regs[0]
RESET_MM_CUR_TO_BEST   — mm_cur := mm_best
RAND_REG / REG_XOR / REG_SHR / TEMP_DECAY  — scratch arith
CALL_MM(k)             — mm_cur := mutateMetaMeta(chain_extras_mm[k], rng)
NOP
```

Mirror of Tier-1 one level up. CALL_MM is the analog of Tier-1's
CALL_META — composes with a MUTATED prior champion, so a discovered
MMMP can't trivially copy a stored MMP.

## Pilot 1 — seed 0x1111222233334444, tiny budget

```
tier2_iters=8   mmm_outer_iters=6   tier1_outer_iters=6
tier0_inner_steps=100   InitPool=16
```

Result, 3 generations:

| gen | train_anchor_mean | holdout    | verdict      | accepted |
|-----|-------------------|------------|--------------|----------|
| 0   | -749,990.76       | -1,000,000 | ADVANCE      | 0/8      |
| 1   | -2,713.16         | -1,000,000 | ADVANCE(tie) | 1/8      |
| 2   | -255,440.14       | -1,000,000 | ADVANCE(tie) | 1/8      |

**STRICT_DOMINATION: NO. All holdouts pinned to sentinel -1e6.**

The discovered Tier-2 champion MetaProgram had ZERO `EVAL_META`
instructions:

```
gen_2 champion_meta.csv:
0  ACCEPT_SA       dst=2 src1=3 src2=2
1  TEMP_DECAY      dst=0 src1=1 src2=3
2  CROSS_BEST_CUR  dst=0 src1=3 src2=2
3  CROSS_BEST_CUR  dst=2 src1=0 src2=0
4  REG_XOR         dst=2 src1=2 src2=1
```

No `INIT_META`, no `EVAL_META`. The MetaProgram never evaluates any
mixer, so `q_cur` stays NegInf, `q_best` stays NegInf,
`mm.runReturningChampion` returns a meta_best that never produced a
score. tier0.run on that meta returns NaN/inf for every seed → all 8
holdout seeds register sentinel -1e6 → holdout_mean = -1e6.

## Pilot 2 — bigger budget on F00D (COMPLETED)

```
tier2_iters=24  mmm_outer_iters=8  tier1_outer_iters=8
tier0_inner_steps=120   InitPool=16
```

Result, 3 generations:

| gen | train_anchor_mean | holdout      | verdict               | accepted |
|-----|-------------------|--------------|-----------------------|----------|
| 0   | -500,012.49       | -1,000,000   | ADVANCE               | 1/24     |
| 1   | **+45.62**        | -1,000,000   | ADVANCE(tie)          | 1/24     |
| 2   | +38.07            | **-10,812.81** | **STRICT_DOMINATION** ★ | 2/24   |

**STRICT_DOMINATION: YES at gen 2.** Holdout jumps from -1e6 to
-10,813. Still terrible compared to Tier-1's 44.30, but this is
*genuine learning* — the Tier-2 chain found programs that score on
unseen seeds.

Gen 1's anchor +45.62 shows the search escapes the "no EVAL" trap
with bigger budget. Gen 2's holdout -10,813 shows the discovered
program actually *generalizes* (poorly) — it's not sentinel anymore.

### Structural analysis of the gen-2 champion stack

The discovered champion at each level:

**MMMP (Tier-2 program, 8 ops):**
```
CALL_MM → CROSS_MM_BEST_CUR → MUTATE_MM_BEST_TO_CUR → CALL_MM →
EVAL_MM_CUR → ACCEPT_MM_SA → MUTATE_MM_BEST_TO_CUR → REG_XOR
```
✓ Has EVAL_MM_CUR and ACCEPT_MM_SA — proper search loop.

**MMP (Tier-1 program, 12 ops):**
```
MUTATE_META_BEST_TO_CUR → ACCEPT_META_SA → NOP → EVAL_META_CUR →
ACCEPT_META_SA → REG_XOR → ACCEPT_META_IF_BETTER → INIT_META_CUR →
ACCEPT_META_SA → MUTATE_META_BEST_TO_CUR → ACCEPT_META_SA → CALL_META
```
✓ Has EVAL_META_CUR, ACCEPT_META_IF_BETTER, CALL_META — structurally
valid search. But ACCEPT_META_SA appears *before* EVAL at position 1.

**MP (Tier-0 program, 6 ops):**
```
ACCEPT_SA → TEMP_DECAY → REG_XOR → EVAL_CUR → CROSS_BEST_CUR → REG_XOR
```
✗ `ACCEPT_SA` at position 0, `EVAL_CUR` at position 3. **Accepts
before evaluating** — this is why holdout is -10,813, not +40. The
search accepts garbage candidates because acceptance happens before
the candidate is scored.

### Key insight — failure mode progression

| Budget   | What Tier-2 discovers         | Failure mode                |
|----------|-------------------------------|-----------------------------||
| Small    | Programs missing EVAL_META    | "No EVAL" → sentinel -1e6   |
| Bigger   | Programs with right primitives| "Wrong ordering" → -10,813  |
| ???      | Correct primitive ordering?   | Unknown — not yet tested    |

Tier-2 is *learning* across budget levels. The failure modes get
progressively less severe: "can't find the primitives" → "finds them
but puts them in the wrong order." This suggests that with sufficient
budget or shaped fitness, Tier-2 *could* discover correctly-ordered
programs.

## Root-cause analysis — three failure modes

At small budgets, **most randomly-generated MMMPs produce MMPs whose
discovered MetaPrograms lack an EVAL_META op**, so they bottom out at
the sentinel value. The Tier-2 search can't differentiate between
"slightly better noise" and "actual signal" because the variance among
sentinel-pinned candidates exceeds the difference between sentinel-vs-
finite outcomes that we ever see at this budget.

At bigger budgets, the search escapes the sentinel floor but the
discovered programs have **structural ordering problems** — the right
primitives in the wrong positions.

Three observed failure modes, in order of severity:

1. **"No EVAL" floor** (Pilot 1, small budget): Most MMMPs produce
   MMPs whose MetaPrograms lack EVAL_META → sentinel -1e6. The search
   can't distinguish noise from signal.

2. **"Narrow program" overfit** (Pilot 2, gen 1): Budget escapes the
   sentinel — anchor reaches +45.62 — but holdout stays sentinel. The
   discovered MMP works on the 4 Tier-2-anchor seeds and fails on all 8
   held-out seeds.

3. **"Wrong ordering"** (Pilot 2, gen 2): All three levels have
   structurally valid programs with the right primitives, but the
   bottom-level MetaProgram places ACCEPT_SA before EVAL_CUR, causing
   it to accept garbage. The search learned *what* to include but not
   *where* to put it.

To escape these, Tier-2 would need one of:

1. **Shaped fitness**: penalize MetaPrograms that lack `EVAL_META`
   before scoring, or reward EVAL-before-ACCEPT ordering.
2. **Repair operators**: MMP mutation that injects a missing EVAL_META
   or fixes ACCEPT-before-EVAL ordering.
3. **Much bigger search**: the progression from Pilot 1 to Pilot 2
   shows budget helps; but cost grows geometrically per tier.
4. **Curriculum**: bootstrap Tier-2's library with proven Tier-1
   champion MMPs via `chain_extras_mm` so CALL_MM gives Tier-2 a non-
   sentinel starting point.

None of these is guaranteed to escape the noise floor; all are
research follow-ups.

## What Tier-2 IS (today)

- The code path exists, is reproducible, and the budget knobs work.
- The fitness ladder is correctly preserved — a Tier-2 discovery
  *would* be a mixer-fitness on the same axis as Tier-0/Tier-1, so
  cross-tier comparison is well-defined.
- At small budgets (8 tier2_iters × 4 anchor seeds), Tier-2 does NOT
  produce a working MetaProgram.
- At bigger budgets (24 tier2_iters × 4 anchor seeds), Tier-2
  achieves **STRICT_DOMINATION** (holdout -10,813 vs sentinel -1e6)
  and discovers structurally valid programs, but with ordering defects.

## What Tier-2 IS NOT (today)

- It is **not** a working successor-of-successors search engine (yet).
- It does **not** beat Tier-1 at the same end-task at any tested budget.
- The bigger pilot shows *genuine learning progression* but the
  discovered programs are still 5 orders of magnitude worse than
  Tier-1's 44.30 champion.

## Honest framing

Tier-2 is the strict form of "successor inventing successor inventing
successor." We built it cleanly (no shortcuts, no fake fitness, equal-
budget reporting). At small budgets it produces nothing usable. At
bigger budgets it shows a clear learning trajectory (sentinel →
finite anchor → STRICT_DOMINATION → right primitives wrong order)
that suggests more budget or shaped fitness *could* close the gap.
Whether that gap is practically closable is an open research question.

## Reproduce

### Pilot 1 — small budget (sentinel results)

```bash
cd ghost_sovereign
zig build -Doptimize=ReleaseFast
./zig-out/bin/mmm_chain_runner \
    --seed=1111222233334444 \
    --generations=3 \
    --tier2-iters=8 \
    --mmm-outer-iters=6 \
    --tier1-outer-iters=6 \
    --tier0-inner-steps=100 \
    --out-subdir=mmm_chain_pilot_1111
```

### Pilot 2 — bigger budget (STRICT_DOMINATION at gen 2)

```bash
./zig-out/bin/mmm_chain_runner \
    --seed=F00DBEEFCAFEFACE \
    --generations=3 \
    --tier2-iters=24 \
    --mmm-outer-iters=8 \
    --tier1-outer-iters=8 \
    --tier0-inner-steps=120 \
    --out-subdir=mmm_chain_big_F00D
```

Both produce `results/<subdir>/chain_log.csv` with verdicts
and `gen_{n}_champion_{mmm,mm,meta}.csv` files.

Related: [[project-tier1-meta-engine]] (the tier below), [[project-
successor-chain-sort]] (where the same recipe also works at Tier-0+1),
[[feedback-invention-chain-directive]] (the directive that drove this
work).
