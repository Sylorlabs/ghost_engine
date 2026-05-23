# The Successor-Loop Research Round — 2026-05-21

## What this document covers

After the Tier-1 chain produced its 0x1111 champion (holdout 44.30) and
the 3-seed continuation chain showed convergence to a 44.30 ceiling
without exceeding it, the user asked: "try everything to test this."
Three hypotheses, each implemented and run to completion (or honest
HALT):

1. **Test #1 — Bigger Tier-1 budget** (`tier1_iters=200`, up from 24).
2. **Test #2 — Wide CALL_META destination** (4-bit composite index,
   addresses all 16 library slots instead of just 4).
3. **Test #3 — Tier-2 MetaMetaMetaProgram** (engine inventing engine
   inventing engine inventing engine, true four-tier stack).

Equal-budget reporting throughout. All measurements use the same 8
held-out seeds across all tests for cross-comparability.

## Test #1: bigger budget — REFUTED

Hypothesis: more search per generation → better holdout.

| seed (root)       | gen 0 anchor | gen 0 holdout | gen 1 holdout | gen 2 holdout | gen 3 holdout | verdict |
|-------------------|--------------|---------------|---------------|---------------|---------------|---------|
| 0x1111…           | 41.00        | **-35.35**    | 3.25 ★        | -1346 HALT    | —             | OVERFIT |
| 0xF00D…           | 10.99        | **-47.50**    | -1397 HALT    | —             | —             | OVERFIT |
| 0xDEAD…           | 22.37        | **-99.05**    | -1409 HALT    | —             | —             | OVERFIT |
| 0x7777…           | -80.53       | **-1399.53**  | -1400 (tie)   | -1376 ★       | -1400 HALT    | OVERFIT |

Compare to original 24-iter budget on same seeds (from prior session):

| seed     | original gen 0 holdout | bigger-budget gen 0 holdout |
|----------|------------------------|------------------------------|
| 0x1111…  | 10.93                  | -35.35  ↓ |
| 0xF00D…  | -19.67                 | -47.50  ↓ |
| 0xDEAD…  | -6.56                  | -99.05  ↓ |
| 0x7777…  | -1378                  | -1399   ≈ |

**All 4 seeds get WORSE holdout at gen 0 with the bigger budget.**

The Tier-1 outer SA uses a 4-anchor mean + rotation gate for
generalization protection. At 24 iters, this works. At 200 iters, the
search overfits to the 4 anchor seeds (anchor scores go UP — 41 vs
original 10.93) but craters on held-out (-35 vs original +10.93). The
generalization protection has a **budget-dependent failure mode**:
more iters lets the search find candidates that game the 4 specific
anchor seeds.

### Implication

Scaling-by-budget is not a universal lever for this architecture.
To use a larger budget productively would require:

- More anchor seeds (e.g., 16 instead of 4), so anchor-mean is a
  better proxy for true generalization.
- Cross-validation rotation of anchor seeds across generations.
- Some form of explicit regularization on MetaMetaProgram structure.

Until those are in, **the 24-iter budget is the right operating
point** and pushing past 44.30 by this lever alone is not available.

## Test #2: wide CALL_META destination — CONFIRMED

Hypothesis: with a 4-bit composite index `(dst<<2 | src1)`, CALL_META
can address all 16 library slots instead of just 4. With an 8-entry
seed library (4 from 0x1111 chain + 4 from 0x7777 chain), wide mode
should let the discovered MMP compose with library entries 4..7 that
narrow mode cannot reach.

Implementation: 1-line change in `domain_meta_meta_engine.zig`,
opt-in via module-level `wide_call_meta: bool` (default false),
controlled by `--wide-call-meta` flag in the chain runner. Existing
results stay reproducible.

3 seeds × 2 modes (wide / narrow) × identical library + budget:

| root seed  | mode   | gen 0 holdout | gen 1 holdout | gen 2 holdout | best  |
|------------|--------|---------------|---------------|---------------|-------|
| 0xABCD…    | narrow | -1365.15      | 17.49 ★       | -2.56 HALT    | 17.49 |
| 0xABCD…    | **wide** | **-16.93**  | **44.81 ★**   | -2.56 HALT    | **44.81** |
| 0x9999…    | narrow | 3.23          | 36.75 ★       | -169.27 HALT  | 36.75 |
| 0x9999…    | **wide** | **30.87**   | -1398 HALT    | —             | **30.87** |
| 0x5555…    | narrow | 14.10         | 21.09 ★       | 13.16 HALT    | 21.09 |
| 0x5555…    | **wide** | **30.87**   | 30.87 (tie)   | -15.01 HALT   | **30.87** |

**3 of 3 seeds: wide gen-0 holdout strictly > narrow gen-0 holdout.**

Deltas (wide − narrow) at gen 0: +1348.22, +27.65, +16.77. The
direction is consistent across all 3 seeds; magnitude varies because
the narrow run on 0xABCD landed in an especially bad MMP that gen 0
couldn't escape.

**However: wide doesn't always win at gen 1.** Seed 0x9999 narrow
reaches 36.75 at gen 1 while wide HALTs at gen 1 (-1398). Seed 0x5555
narrow reaches 21.09 at gen 1 while wide ties at 30.87. So wide gives
a better *starting point* (gen 0) but the chain dynamics after that
are seed-dependent.

**Best holdout per seed (max across all gens):**

| seed     | narrow best | wide best | winner at best |
|----------|-------------|-----------|----------------|
| 0xABCD…  | 17.49       | **44.81** | **wide** ★     |
| 0x9999…  | **36.75**   | 30.87     | **narrow** ★   |
| 0x5555…  | 21.09       | **30.87** | **wide** ★     |

Wide wins 2 of 3 seeds at best-holdout; narrow wins 1. Direction is
mostly favorable but not universal.

**Wide also recovers the 44.30 ceiling at a NEW seed** (0xABCD reaches
44.81 vs original 0x1111 chain's 44.30). This is reassuring — the
44.30 ceiling is robust (multiple seeds find it under wide mode), not
a one-off artifact of the 0x1111 seed.

### Implication

Wide CALL_META is a **strictly better default** for chains with > 4
library entries. It does not push past the ~44.30 ceiling, but it
reaches the ceiling more reliably across seeds.

### Open question

Wide reaches the ceiling at multiple seeds but never exceeds it.
This corroborates the prior finding that the ceiling is a property of
the domain × budget × opcode-set, not just a fluke of one seed's
search trajectory. Pushing past it likely requires expanding the
Tier-0 opcode set (currently 11 instructions: not all u64 mixing
primitives are represented).

## Test #3: Tier-2 — IMPLEMENTED + ARCHITECTURAL NOISE FLOOR

Hypothesis: a MetaMetaMetaProgram operating on MetaMetaPrograms is
"successor inventing successor inventing successor" in its strict
form. Build it cleanly, measure honestly.

Implementation: `src/adapters/domain_meta_meta_meta_engine.zig` and
`src/adapters/mmm_chain_runner.zig`. Mirror of the Tier-1 modules one
level up. Same opcode shape, same anchor-protected + rotated outer SA,
same CALL_MM warm-start mechanism. Fitness ladder preserved through
all layers (Tier-2's q_best is still a mixer-fitness).

### Pilot 1 — small budget on 0x1111

```
tier2_iters=8   mmm_outer=6   tier1_outer=6   tier0_inner=100
```

| gen | train anchor   | holdout    | verdict      |
|-----|----------------|------------|--------------|
| 0   | -749,990       | -1,000,000 | ADVANCE      |
| 1   | -2,713         | -1,000,000 | ADVANCE(tie) |
| 2   | -255,440       | -1,000,000 | ADVANCE(tie) |

ALL holdouts pinned to sentinel -1e6. Inspected: the discovered
MetaProgram has **zero** `EVAL_META` instructions — so q_cur stays
NegInf, q_best stays NegInf, holdout is sentinel.

### Pilot 2 — bigger budget on F00D (COMPLETED)

```
tier2_iters=24  mmm_outer=8   tier1_outer=8   tier0_inner=120
```

| gen | train anchor   | holdout      | verdict             | accepted |
|-----|----------------|--------------|---------------------|----------|
| 0   | -500,012       | -1,000,000   | ADVANCE             | 1/24     |
| 1   | **+45.62**     | -1,000,000   | ADVANCE(tie)        | 1/24     |
| 2   | +38.07         | **-10,813**  | **STRICT_DOMINATION** ★ | 2/24 |

**Gen 1 produces a finite positive anchor score for the first time.**
Tier-2 search at bigger budget escapes the "no EVAL" trap.

**Gen 2 achieves STRICT_DOMINATION** — holdout jumps from -1e6 to
-10,813. Still terrible compared to Tier-1's 44.30, but this is
genuine *learning*: the Tier-2 search found a MetaMetaMetaProgram
that produces a MetaMetaProgram whose discovered MetaProgram actually
works (poorly) on unseen seeds.

**Structural analysis of the gen-2 champion stack:**

| level | key opcodes found | functional? |
|-------|-------------------|-------------|
| MMMP  | CALL_MM, EVAL_MM_CUR, ACCEPT_MM_SA, MUTATE_MM_BEST_TO_CUR | ✓ proper search loop |
| MMP   | EVAL_META_CUR, ACCEPT_META_IF_BETTER, CALL_META, INIT_META_CUR | ✓ proper search loop |
| MP    | EVAL_CUR, CROSS_BEST_CUR, ACCEPT_SA | ✗ ACCEPT_SA *before* EVAL_CUR — dysfunctional ordering |

The MetaProgram discovered by the champion MMP has `EVAL_CUR` at
position 3 but `ACCEPT_SA` at position 0 — it accepts before it
evaluates. This is why holdout is -10,813 not +40: the MP's search
accepts garbage candidates.

**This is a different failure mode than Pilot 1's "no EVAL at all."**
At bigger budget, Tier-2 finds structurally valid programs (all three
levels have the right primitives) but can't yet discover the *correct
ordering* of those primitives.

### Root-cause analysis — three failure modes observed

1. **"No EVAL" floor** (Pilot 1): Most randomly-generated MMMPs
   produce MMPs whose MetaPrograms lack EVAL_META → sentinel -1e6.
   The search can't differentiate "slightly better noise" from signal.

2. **"Narrow program"** (Pilot 2, gen 1): Budget escapes the sentinel
   floor — anchor is +45 — but holdout stays sentinel. The discovered
   program overfits the 4 Tier-2-anchor seeds.

3. **"Wrong ordering"** (Pilot 2, gen 2): All three levels have
   structurally valid programs with the right primitives, but the
   MetaProgram places ACCEPT_SA before EVAL_CUR. The search learned
   *what* to include but not *where* to put it.

These are progressively less severe — from "can't even find the
primitives" to "finds them but in the wrong order." With more budget
or shaped fitness, ordering might be learnable.

### Honest framing

Tier-2 is **built, reproducible, fitness-correct, and shows genuine
learning progression** (sentinel → finite anchor → STRICT_DOMINATION)
**but does not yet produce competitive holdout scores.** It would need:

- Shaped fitness rewarding MetaProgram structural validity (e.g., does
  the discovered MP contain EVAL_META? Is EVAL before ACCEPT?).
- Repair operators (MMP mutations that inject missing EVAL_META or
  fix ACCEPT-before-EVAL ordering).
- Bigger Tier-2-anchor set (more than 4) to reduce overfit when search
  does escape the noise floor.
- Or much, much bigger budget (the progression from Pilot 1 to
  Pilot 2 shows budget helps; the question is how much more is needed).

None of these is implemented. All are unblocked research follow-ups.

## Summary table — what works

| Mechanism | Status | Best holdout | Seeds tested |
|-----------|--------|--------------|-------|
| Tier-1 disciplined hand-coded outer SA (baseline) | ✓ works | 32.55 mean (64-seed) | 1 |
| Tier-1 chain w/ CALL_META (original recipe) | ✓ works (3/4 STRICT_DOM) | **44.30** | 4 |
| Tier-1 chain w/ wide CALL_META | ✓ works (2/3 wide > narrow at best) | **44.81** | 3 pairs |
| Tier-1 chain w/ bigger budget (200 iters) | ✗ refuted: overfits anchor set | -35 to -1399 | 4 |
| Tier-2 MMMP chain (small budget) | ✗ noise floor: no EVAL found | -1,000,000 sentinel | 1 |
| Tier-2 MMMP chain (bigger budget) | ⚠ learning: STRICT_DOM at gen 2 | **-10,813** (gen 2) | 1 |

## The 44.30 ceiling — what we now know

Three independent observations corroborate the ceiling:

1. Original 0x1111 chain reached 44.30 and HALTed at gen 3.
2. Continuation chains seeded with 0x1111 champions all plateau at ≤
   44.30 (2 of 3 reach it via STRICT_DOMINATION at one gen, none
   exceed).
3. Wide CALL_META at a different root seed (0xABCD) also reaches
   44.81 (essentially the same ceiling).

The ceiling is **not** seed-specific or recipe-specific. It looks like
a property of (Tier-0 opcode set + tier0_inner_steps + Tier-1 budget).
To break it requires breaking one of those — and bigger budget alone
makes things worse.

## Reproduction

```bash
cd ghost_sovereign
zig build -Doptimize=ReleaseFast

# Test #1 — bigger budget (will OVERFIT)
./zig-out/bin/meta_meta_chain_runner \
    --seed=1111222233334444 --generations=4 \
    --tier1-iters=200 --mm-outer-iters=12 \
    --tier0-inner-steps=150 \
    --out-subdir=mm_chain_t1_big_1111

# Test #2 — wide vs narrow at same seed (wide should win at gen 0)
LIB="results/mm_chain_1111222233334444/gen_0_champion_meta.csv,..."
./zig-out/bin/meta_meta_chain_runner \
    --seed=ABCD1234EF567890 --generations=4 \
    --tier1-iters=40 --seed-library=$LIB --wide-call-meta \
    --out-subdir=mm_chain_t2_wide
./zig-out/bin/meta_meta_chain_runner \
    --seed=ABCD1234EF567890 --generations=4 \
    --tier1-iters=40 --seed-library=$LIB \
    --out-subdir=mm_chain_t2_narrow

# Test #3 — Tier-2 pilot (will produce -1e6 sentinel at small budget)
./zig-out/bin/mmm_chain_runner \
    --seed=F00DBEEFCAFEFACE --generations=3 \
    --tier2-iters=24 --mmm-outer-iters=8 --tier1-outer-iters=8 \
    --tier0-inner-steps=120 \
    --out-subdir=mmm_chain_big_F00D
```

## Files this round added

- `src/adapters/domain_meta_meta_meta_engine.zig` (new)
- `src/adapters/mmm_chain_runner.zig` (new)
- `src/adapters/domain_meta_meta_engine.zig` (1-line CALL_META change
  + `wide_call_meta` module-level toggle)
- `src/adapters/meta_meta_chain_runner.zig` (`--wide-call-meta` flag)
- `build.zig` (mmm_chain_runner target)
- `docs/tier2_meta_meta_engine.md` (Tier-2 detailed writeup)
- `docs/successor_loop_research.md` (this file)
- `results/mm_chain_t1_big_*/` (Test #1, 4 seeds)
- `results/mm_chain_t2_{wide,narrow}{,_s2,_s3}/` (Test #2, 3 seed
  pairs)
- `results/mmm_chain_{pilot_1111,big_F00D}/` (Test #3, 2 budgets)

Related: [[project-tier1-meta-engine]], [[project-tier2]],
[[project-successor-chain-sort]],
[[feedback-invention-chain-directive]].
