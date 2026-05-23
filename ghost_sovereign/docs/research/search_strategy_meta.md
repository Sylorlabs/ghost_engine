# Search Strategy Meta-Domain

Status: harness built. Full-budget self-improvement remains unresolved.

## What this tests

`src/adapters/domain_search_strategy.zig` makes a search strategy itself
a DomainSpec program:

```text
(mutation_rate, crossover_rate, pool_size, t_start, cooling_exponent, restart_period,
 parent_selection, replacement_policy, acceptance_policy, cooling_schedule)
```

The meta-engine searches over those tuples. Each tuple is evaluated by
running the existing generic invention engine on a fixed battery of inner
domain runs.

## Methodology guardrails

The first four-case version of this experiment was not a valid
self-improvement result. It used `n=4`, trained and tested on the same
seeds, used starved budgets, and assigned arbitrary novelty thresholds.

The current harness fixes the measurement surface:

- 24 total `(domain, seed)` cases.
- Split as 8 train, 8 validation, 8 test.
- Meta-search selection uses only the train split.
- Validation/test are evaluated after champion selection.
- Baseline is the canonical library preset selected on train only.
- Reported deltas are paired champion-vs-baseline hit-rate deltas.
- Validation/test deltas include bootstrap 95% confidence intervals.
- Strategy novelty thresholds are derived from deterministic
  random-strategy distance calibration, not typed constants.

## Budgets

The stored full inner budgets match the earlier validated per-domain
budgets:

| Domain | Full inner budget |
|---|---:|
| `u64_mixer` | 8,000 |
| `sort_net` | 50,000 |
| `boolean` | 200,000 |

`search_strategy_meta` accepts `--budget-scale=F`. A scale below `1.0`
is a smoke or development run only. It must not be reported as evidence
of full-budget self-improvement.

## Verdict rule

The runner prints `claim_status=supported` only when all are true:

- validation delta is positive,
- test delta is positive,
- test bootstrap CI lower bound is positive,
- the strategy is outside the calibrated library floor,
- `--budget-scale=1.0`.

Otherwise the result is `claim_status=unresolved`.

## Current scaled finding

Latest bounded run:

```bash
./zig-out/bin/search_strategy_meta --iters=4 --pool=8 --budget-scale=0.02
```

This was a scaled smoke run, not a full-budget evidence run. The actual
inner budgets used were 2% of the calibrated budgets:

| Domain | Full budget | Smoke budget |
|---|---:|---:|
| `u64_mixer` | 8,000 | 160 |
| `sort_net` | 50,000 | 1,000 |
| `boolean` | 200,000 | 4,000 |

The train-selected library baseline was `vanilla_sa`.

| Split | Baseline strict hits | Meta champion strict hits | Delta |
|---|---:|---:|---:|
| train | 7/8 | 7/8 | 0.0000 |
| validation | 4/8 | 6/8 | 0.2500 |
| test | 5/8 | 6/8 | 0.1250 |

Bootstrap delta confidence intervals from the same run:

| Split | Delta | 95% CI |
|---|---:|---|
| train | 0.0000 | [-0.3750, 0.3750] |
| validation | 0.2500 | [0.0000, 0.6250] |
| test | 0.1250 | [-0.2500, 0.6250] |

The champion tuple was:

```text
mutation_rate=0.712835
crossover_rate=0.098662
pool_size=22
t_start=0.562980
cooling_exponent=1.126884
restart_period=573
parent_selection=rank_biased
replacement_policy=random_pool
acceptance_policy=metropolis
cooling_schedule=inverse
```

It was outside the calibrated library-distance floor for this parameter
space, and it improved raw held-out validation/test hit rate in this
scaled run. It still does not satisfy the support gate because the test
bootstrap CI lower bound is negative and the run used only
`budget_scale=0.02`. Therefore the run outcome is:

```text
claim_status=unresolved
```

The CSV evidence is in:

- `results/search_strategy_meta.csv` for split-level summaries.
- `results/search_strategy_cases.csv` for paired per-case baseline and
  champion outcomes.
- `results/search_strategy_champion.csv` for the selected tuple.

## Research finding

The useful result so far is methodological, not self-improvement:

- The generic engine can self-apply over engine-shaped programs.
- The first `n=4` train-equals-test result was invalid and overfit the
  grading surface.
- With held-out splits and a richer engine genome, the scaled one-shot
  run can find a candidate with better raw validation/test hit rates,
  but the confidence interval and budget gate still keep the claim
  unresolved.
- Novelty in the strategy parameter space is not enough. A strategy can
  be outside the calibrated library floor and still fail the held-out
  performance gate.

This means the meta-domain is currently a falsification and candidate
discovery harness. It has not yet demonstrated a supported better
invention engine.

## Recursive loop harness

`src/adapters/recursive_engine_loop.zig` extends the meta-domain into an
iterative loop:

1. Start with the train-selected canonical strategy as the incumbent.
2. Seed the meta-search pool with the incumbent plus canonical presets.
3. Search for a candidate strategy using train split only.
4. Evaluate candidate vs incumbent on train, validation, and test.
5. Promote the candidate only if validation and test deltas are positive
   and the test bootstrap CI lower bound is positive.
6. Disable real promotion for scaled runs. A run with `--budget-scale`
   below `1.0` is a dry run, even if its evidence gate would pass.

This is the concrete loop needed for "newer and better invention
engines": proposal, held-out measurement, promotion, repeat. The loop is
bounded by the domains in the battery; it does not prove all-domain
invention.

Smoke/dev loop:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/recursive_engine_loop --generations=3 --meta-iters=16 --pool=16 --budget-scale=0.02
```

Full-budget loop:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/recursive_engine_loop --generations=3 --meta-iters=8 --pool=8 --budget-scale=1.0
```

Loop artifacts:

- `results/recursive_engine_loop.csv` records generation-level
  incumbent-vs-candidate deltas and promotion decisions.
- `results/recursive_engine_champions.csv` records candidate and
  incumbent strategy tuples per generation.

Latest scaled loop run:

```bash
./zig-out/bin/recursive_engine_loop --generations=4 --meta-iters=32 --pool=24 --budget-scale=0.02
```

Result:

| Generation | Incumbent | Candidate novelty | Train delta | Validation delta | Test delta | Decision |
|---:|---|---|---:|---:|---:|---|
| 1 | `vanilla_sa` | outside calibrated floor | 0.0000 | 0.0000 | -0.2500 | rejected |
| 2 | `vanilla_sa` | outside calibrated floor | 0.0000 | -0.1250 | -0.2500 | rejected |
| 3 | `vanilla_sa` | outside calibrated floor | 0.0000 | -0.1250 | -0.2500 | rejected |
| 4 | `vanilla_sa` | outside calibrated floor | 0.1250 | 0.0000 | 0.0000 | rejected |

The final incumbent stayed `vanilla_sa` with train `7/8`,
validation `4/8`, and test `5/8` strict hits at `budget_scale=0.02`.
The recursive loop produced non-library candidates, including one with
perfect train `8/8`, but none improved held-out validation/test enough
to promote. This proves the loop machinery runs and refuses unsupported
promotions. It does not prove recursive improvement.

## Commands

Smoke/dev run:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/search_strategy_meta --iters=4 --pool=8 --budget-scale=0.02
```

Full-budget run:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/search_strategy_meta --iters=8 --pool=8 --budget-scale=1.0
```

The full-budget command is intentionally expensive. It is the command
that can produce evidence; scaled runs only validate the harness.
