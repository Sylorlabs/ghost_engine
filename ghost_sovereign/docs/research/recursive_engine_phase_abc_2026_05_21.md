# Recursive Engine Phase A/B/C Run - 2026-05-21

This note records the late-night recursive invention run. It is intentionally
evidence-first: commands, artifacts, numbers, and what did not work.

## Engine Numbering

Build order:

| Engine | Program type | Invents | Core files |
|--------|--------------|---------|------------|
| Engine 1 | `MetaProgram` | u64 mixers | `src/adapters/domain_meta_engine.zig` |
| Engine 2 | `MetaMetaProgram` / MMP | MetaPrograms | `src/adapters/domain_meta_meta_engine.zig` |
| Engine 3 | `MetaMetaMetaProgram` / MMMP | MMPs | `src/adapters/domain_meta_meta_meta_engine.zig` |
| Engine 4 | not built | MMMPs | gated on Engine 3 exceeding Engine 2 |

Engine 4 was not built in this run because Engine 3 did not beat Engine 2's
best holdout. Building it anyway would stack a non-compounding layer.

## Code Added

- `mmm_chain_runner.zig`: added `--monotone-retries=N`, parallel attempt
  workers, `--wide-call-meta`, `--wide-call-mm`,
  `--promotion-threshold=X`, and BEST artifact persistence for completed
  monotone runs.
- `domain_meta_meta_meta_engine.zig`: added wide `CALL_MM` addressing via
  `(dst << 2) | src1`.
- `meta_meta_chain_runner.zig`: added `--initial-best-holdout=X` so a
  curriculum seed does not get re-labeled as a new invention merely by tying
  itself.
- `lineage_audit.zig`: generic Meta/MMP/MMMP CSV structural audit. Reports
  exact-copy, normalized edit distance, EVAL/ACCEPT/CALL presence, and
  ordering.
- `domain_meta_engine.zig`: added `runReturningChampion()` and opt-in
  `repair_meta_ordering`; later added opt-in constrained MetaProgram
  construction via `constrained_init`.
- `domain_meta_meta_engine.zig`: later added opt-in constrained
  MetaMetaProgram construction via `constrained_init`.
- `domain_meta_meta_meta_engine.zig`: later added MMMP ordering repair for
  constrained top-level mutations.
- `domain_u64_mixer.zig`: added `programFromCsv()`.
- `meta_mixer_export.zig`: exports the concrete mixer found by a
  MetaProgram.
- `mixer_csv_emit.zig`: emits a mixer CSV as a byte stream for PractRand.
- `mmm_qd_probe.zig`: Engine-3 quality-diversity probe.
- `mmm_holdout_hillclimb.zig`: downstream holdout hillclimber for MMMPs.
- `domain_meta_meta_meta_meta_engine.zig`: Engine-4 / MMMMP core domain.
- `mmmm_qd_probe.zig`: bounded Engine-4 quality probe.

Build:

```bash
zig build -Doptimize=ReleaseFast
```

Result: passed after the repair-switch compile fix.

## Phase A - Stack All Working Engine-2 Tricks

Command:

```bash
./zig-out/bin/meta_meta_chain_runner \
  --seed=F00DBEEFCAFEFACE \
  --generations=6 \
  --tier1-iters=24 \
  --mm-outer-iters=12 \
  --tier0-inner-steps=150 \
  --monotone-retries=10 \
  --wide-call-meta \
  --seed-library=results/mm_chain_mono_F00D/BEST_champion_meta.csv \
  --out-subdir=phaseA_stack_F00D
```

Output:

```text
BEST_HOLDOUT_EVER = 47.1615 (gen 0, attempt 1)
```

Interpretation:

- This did not exceed the F00D seed's known `47.1615`.
- Later generations repeatedly rediscovered `47.1615` or lower values.
- The Phase A best was a near-copy of the seed:

```text
nearest_edit_distance=1
nearest_normalized=0.0714
lineage_verdict=NEAR_COPY_STRUCTURAL
```

64-seed validation:

```text
discovered champ mean = 24.8584
baseline outer SA mean = 23.6828
paired delta mean = 1.1756
wins=24 losses=25 ties=15
VERDICT = INCONCLUSIVE
```

Concrete mixer export and external test:

```bash
./zig-out/bin/meta_mixer_export \
  --meta=results/phaseA_stack_F00D/BEST_champion_meta.csv \
  --out=results/phaseA_stack_F00D/BEST_discovered_mixer.csv \
  --seed=C0FFEE00DEADBEEF \
  --steps=150

./zig-out/bin/mixer_csv_emit \
  --program=results/phaseA_stack_F00D/BEST_discovered_mixer.csv \
  --seed=0123456789ABCDEF \
  --bytes=64M | RNG_test stdin64 -tlmax 64M
```

PractRand result:

```text
64 megabytes: no anomalies in 172 test result(s)
```

Phase A verdict:

`PLATEAU / NEAR-COPY`, not a new invention. It preserves the high-water mark
but does not create a materially new Engine-2 search recipe.

## Phase B - Engine 3 With Monotone + Parallel

Seed library:

```bash
results/mm_chain_mono_F00D/BEST_champion_meta_meta.csv
results/mm_chain_par_1111/BEST_champion_meta_meta.csv
results/phaseA_stack_F00D/BEST_champion_meta_meta.csv
```

Command:

```bash
./zig-out/bin/mmm_chain_runner \
  --seed=1111222233334444 \
  --generations=4 \
  --tier2-iters=20 \
  --mmm-outer-iters=8 \
  --tier1-outer-iters=8 \
  --tier0-inner-steps=120 \
  --seed-mm-library=$MM_LIB \
  --shaped-fitness \
  --constrained-init \
  --wide-call-meta \
  --wide-call-mm \
  --monotone-retries=10 \
  --promotion-threshold=47.161467 \
  --out-subdir=phaseB_mmm_mono_1111
```

Best observed:

```text
gen 0 best = 42.8338
gen 1 best = 42.8338
gen 2 best = 42.9801
```

The run was interrupted during gen 3 after gen 2 evidence was persisted
because a straggler attempt was monopolizing the batch. The best numeric
artifact is `results/phaseB_mmm_mono_1111/gen_2_champion_*`.

Lineage audit:

```text
MMP nearest_normalized=0.2727
MMP lineage_verdict=NON_COPY_STRUCTURAL
MMMP has_eval=true has_accept=true has_call=true eval_before_accept=true
MetaProgram lineage_verdict=NON_COPY_STRUCTURAL
```

Weakness:

```text
MetaProgram first_eval=5
MetaProgram first_accept=2
eval_before_accept=false
```

This explains the remaining gap: Engine 3 invented a non-copy MMP/MMMP stack,
but the final lower-level search recipe still has ordering damage.

64-seed validation of the Engine-3 gen-2 MetaProgram:

```text
discovered champ mean = 31.6194
baseline outer SA mean = 10.5756
paired delta mean = 21.0438
wins=23 losses=39 ties=2
VERDICT = INCONCLUSIVE
```

Concrete mixer external test:

```text
meta_mixer_export q_best=46.217070
PractRand 64 megabytes: no anomalies in 172 test result(s)
```

Phase B verdict:

`REAL NON-COPY ENGINE-3 OUTPUT`, but not tier-compounding. Engine 3 improved
the old Tier-2 result from about `23.30` to `42.98`, but it did not beat
Engine 2's `47.1615` threshold.

## Phase B Addendum - Bootstrap Constraints + QD

The first Engine-3 run exposed a structural problem: final lower-tier
MetaPrograms could have ACCEPT before EVAL. A direct runtime repair hurt at
small budget, so the next test gave generated programs the basics from birth:

```text
--constrained-meta-init
--constrained-mm-init
--constrained-init
```

This does not make the output a copy of a seed. It only guarantees the minimal
search loop exists at each tier: INIT -> EVAL -> ACCEPT.

Constrained Engine-3 QD results:

```text
16 samples: BEST_HOLDOUT = 46.8583
64 samples, seed 1111: BEST_HOLDOUT = 46.8583
64 samples, seed ABCD: BEST_HOLDOUT = 46.8583
```

Lineage of the constrained best:

```text
MMP lineage_verdict=NON_COPY_STRUCTURAL
MMP nearest_normalized=1.0000
Meta lineage_verdict=NON_COPY_STRUCTURAL
Meta nearest_normalized=1.0000
Meta first_eval=1 first_accept=2 eval_before_accept=true
```

64-seed validation at 120 inner steps:

```text
discovered champ mean = 44.1220
baseline outer SA mean = 10.5756
paired delta mean = 33.5464
wins=37 losses=15 ties=12
VERDICT = CONFIRM
```

Fair 150-step threshold check:

```bash
./zig-out/bin/mmm_holdout_hillclimb \
  --iters=0 \
  --start-mmm=results/phaseB_mmm_qd_bootstrap_1111_64/BEST_champion_mmm.csv \
  --mmm-outer-iters=6 \
  --tier1-outer-iters=8 \
  --tier0-inner-steps=150
```

Result:

```text
BEST_HOLDOUT = 47.2299
```

That is the first strict Engine-3 > Engine-2 crossing in this run, using the
same 150-step lower-tier budget as the prior `47.1615` Engine-2 ceiling.

64-seed validation of the 150-step Engine-3 champion:

```text
discovered champ mean = 45.6284
baseline outer SA mean = 23.6828
paired delta mean = 21.9455
wins=37 losses=14 ties=13
VERDICT = CONFIRM
```

Concrete mixer export and external test:

```text
meta_mixer_export q_best=46.054688
PractRand 64 megabytes: no anomalies in 172 test result(s)
```

Budget scaling check on the same Engine-3 artifact:

```text
tier0_inner_steps=200 BEST_HOLDOUT = 47.4867
```

This is not a new structure: the 200-step MetaProgram is an exact copy of
the 150-step crossing MetaProgram. It is still useful because it shows the
Engine-3 invention scales with more lower-tier runtime.

64-seed validation at 200 inner steps:

```text
discovered champ mean = 46.9838
baseline outer SA mean = 11.0124
paired delta mean = 35.9714
wins=34 losses=10 ties=20
VERDICT = CONFIRM
```

200-step concrete mixer export and external test:

```text
meta_mixer_export q_best=47.580078
PractRand 64 megabytes: no anomalies in 172 test result(s)
```

Two 100-iteration downstream hillclimbs at the fair 150-step objective did
not widen the crossing:

```text
phaseB_mmm_hillclimb_t150_1111 BEST_HOLDOUT = 47.2299
phaseB_mmm_hillclimb_t150_ABCD BEST_HOLDOUT = 47.2299
```

An 80-iteration downstream hillclimb at the 200-step objective also did not
widen the scaled result:

```text
phaseB_mmm_hillclimb_t200_1111 BEST_HOLDOUT = 47.4867
```

A final 32-sample constrained QD sweep at the 200-step objective also
rediscovered, but did not exceed, the same incumbent:

```text
phaseB_mmm_qd_bootstrap_t200_5151 BEST_HOLDOUT = 47.4867
MMP lineage_verdict=NON_COPY_STRUCTURAL
Meta lineage_verdict=COPY vs phaseB_mmm_budget_eval_t150/BEST_champion_meta.csv
```

Phase B addendum verdict:

`STRICT BUT NARROW TIER-COMPOUNDING`. Engine 3 now beats the prior Engine-2
holdout ceiling by `+0.0684` at the fair 150-step lower-tier budget, and the
same invented structure scales to `47.4867` at 200 lower-tier steps. The
artifact is structurally non-copy at the MMP and MetaProgram layers.

## Repair Experiment

Hypothesis: forcing lower MetaPrograms to place `EVAL_CUR` before the first
ACCEPT op would remove the observed ordering damage.

Command added:

```text
--repair-meta-ordering
```

Result:

```text
repair gen 0 best = 19.0697
```

This was worse than the unrepaired Engine-3 best (`42.98`). The repair branch
was stopped after gen 0 and part of gen 1 because it was both slower and
lower scoring.

Repair verdict:

`REFUTED AT THIS BUDGET`. The repair is useful instrumentation, but it should
not be the default search path yet.

## Phase C - Engine 4

After the constrained Engine-3 150-step check crossed `47.1615`, Engine 4 was
built:

- `domain_meta_meta_meta_meta_engine.zig`
- `mmmm_qd_probe.zig`

Seeded Engine-4 probe:

```bash
./zig-out/bin/mmmm_qd_probe \
  --samples=12 \
  --seed=4444111122223333 \
  --mmmm-outer-iters=4 \
  --tier2-outer-iters=4 \
  --tier1-outer-iters=8 \
  --tier0-inner-steps=150 \
  --seed-mmm-library=results/phaseB_mmm_budget_eval_t150/BEST_champion_mmm.csv,...
```

Result:

```text
BEST_HOLDOUT = 30.9057
```

Small Engine-4 parameter sweep:

```text
tier2_outer=6: BEST_HOLDOUT = 38.4430
mmmm_outer=6: BEST_HOLDOUT = 35.8956
tier0_inner=200: BEST_HOLDOUT = 33.8154
```

Engine-4 artifact checks:

```text
MMP lineage_verdict=NON_COPY_STRUCTURAL
Meta lineage_verdict=NON_COPY_STRUCTURAL
Meta first_eval=1 first_accept=2 eval_before_accept=true
64-seed validation mean = 39.5011, VERDICT = INCONCLUSIVE
PractRand 64 megabytes: no anomalies in 172 test result(s)
```

Phase C verdict:

`IMPLEMENTED BUT NOT COMPETITIVE`. Engine 4 now exists and produces finite,
non-copy lower-tier artifacts, but it does not compound past Engine 3 in the
bounded probes. The best Engine-4 number in this run is `38.4430`, far below
Engine 3's `47.2299`.

## Prior Art Check

The web search did not show this exact Ghost stack, but it is adjacent to
known research areas:

- Genetic programming: evolving executable programs from primitives by
  selection, crossover, and mutation. See Poli, Langdon, and McPhee,
  *A Field Guide to Genetic Programming*:
  https://www.zemris.fer.hr/~yeti/studenti/izvori/A_Field_Guide_to_Genetic_Programming.pdf
- Stochastic superoptimization: stochastic search over program space with
  cost terms for correctness and performance. See STOKE:
  https://arxiv.org/abs/1211.0557
- MAP-Elites / quality-diversity: keep diverse high-performing elites instead
  of one global best. This is a strong next design candidate for the
  near-copy plateau:
  https://arxiv.org/abs/1504.04909
- Novelty search: objective-only search can get trapped; novelty pressure can
  escape deceptive local optima:
  https://pubmed.ncbi.nlm.nih.gov/20868264/

Local implication: the current monotone chain is too single-winner focused.
Quality-diversity plus constrained basics produced the first strict Engine-3
crossing. The next promising Ghost-native move is to promote this from probe
to runner: an Engine-3 quality-diversity archive keyed by structural features:

- first EVAL position
- first ACCEPT position
- CALL count
- EVAL count
- normalized edit distance from seed library
- held-out score bucket

Then promote only elites that are both high-scoring and non-copy.

## Bottom Line

- Engine 2's prior ceiling was `47.1615`.
- Phase A stacked tricks did not beat it and produced a near-copy.
- Engine 3 now has a strict but narrow fair-budget crossing:
  `47.2299` at 150 lower-tier steps.
- The same Engine-3 invention scales to `47.4867` at 200 lower-tier steps,
  with 64-seed validation mean `46.9838`.
- The crossing artifact is structurally non-copy at the MMP and MetaProgram
  layers and confirms over 64 held-out seeds.
- Engine 4 was built after the gate opened, but the bounded probes are not
  competitive (`38.4430` best observed).
- The next implementable lever is a real constrained QD/novelty-aware
  Engine-3 runner, then a better Engine-4 runner only after Engine-4 has
  comparable viability.
