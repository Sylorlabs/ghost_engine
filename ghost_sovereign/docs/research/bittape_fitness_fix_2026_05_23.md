# Bit-Tape Fitness Reform — Per-Bit Avalanche Objective (2026-05-23)

## What the experiment asked

The 2026-05-22 bit-tape inventor run
(`docs/research/bittape_inventor_2026_05_22.md`) converged a pure
genetic search over a minimal Boolean substrate (`{XOR, AND, NOT}` only,
no human-named mixer primitives) from random bit-soup to its fitness
ceiling. The discovered program was verifiably non-remix, but it was
**not a usable mixer**: it gamed the aggregate-avalanche term. Mean
avalanche read 32 (the target) while the per-output-bit distribution was
wildly imbalanced — the worst bit flipped only **16.6%** of the time and
the best **67.2%**. The mean hid the imbalance. PractRand failed
catastrophically at 32 MiB.

That writeup proposed a single-flag fix: replace the gameable aggregate
avalanche term with a **per-output-bit** objective so the engine cannot
satisfy the metric by sign-averaging. This experiment implements and
tests that fix.

**Question:** does the bit-tape substrate produce a usable mixer when the
fitness targets per-bit avalanche instead of aggregate avalanche?

## Setup

- Substrate unchanged: `src/adapters/domain_bittape.zig` — 256-bit
  state, instruction set `{XOR, AND, NOT}`, programs 96–384 instructions.
- Search unchanged: `src/adapters/bittape_inventor.zig` — classical GA,
  pop=64, tournament=5, elitism=2, mut=0.7, xover=0.5.
- **Only the fitness changed.** The composite is now:

  ```
  composite = -400 * bias_pb         (mean |0.5 - flip_frac_i| over 64 output bits)
              -100 * min_err          (how far the WORST bit sits below 0.5)
              -  5 * bal_err          (|popcount(output) - 32|)
              + 50 * period_s         (cycle-length fraction, unchanged)
              -      cs_pen           (chi-square excess over 255, unchanged)
  ```

  `bias_pb` is the driver. It penalizes EVERY output bit's deviation from
  0.5: a 0%-flip bit and a 100%-flip bit each contribute 0.5 and cannot
  cancel the way they did under the old aggregate term. `min_err` is a
  secondary sharpener on the single worst bit.

- **Reward-shape note (a failed pilot tuned this).** The first pilot used
  a raw min-bit penalty (`-400 * (0.5 - min_pb)`). It **stalled**:
  composite flat at −150 for 1000 generations, `min_pb = 0` throughout.
  A hard min over 64 bits is a near-step-function — it is pinned at 0
  while *any single* output bit is dead (the norm here, since most
  instructions write to state bits 64–255 that never reach the low-64
  output), so improving 63 bits yields no gradient. Replacing the raw min
  with the mean-deviation `bias_pb` restored a gradient on every bit; the
  second pilot climbed cleanly (composite −208 → −105 over 1000 gens) and
  was promoted to the full run.

- Three independent root seeds: `0xB17BE17BE17BE17B` (s1),
  `0xC0FFEE00C0FFEE00` (s2), `0x5EED000000000003` (s3). 10000
  generations each, run in parallel.

- **Verification ladder** (no sample counts reduced from the inventor;
  the independent checks use *more* samples):
  1. Rigorous fitness re-eval at 4× sample budget (`bittape_inspect
     --rigorous-fitness`).
  2. **Independent per-bit avalanche**: 512 samples (4× the search's 128)
     at a *disjoint* seed `0xD1FF5EED20260523` vs the search fitness seed
     `0xACEF00DBEEFCAFE`. This is the overfit detector — a champion that
     overfit the search's exact 128 samples would show a worse
     `min_bit_flip_frac` here.
  3. PractRand on the iterated output stream, 64 MiB gate.

- **Why no Z3 bijection / lineage_audit step** (present in the
  u64-mixer experiments): both tools operate on the meta-engine opcode
  `Program` type, not the bit-tape circuit. A bit-tape program is an
  arbitrary Boolean circuit over 256-bit state, not constructed to be a
  permutation, so bijection is not the relevant property and no tooling
  models it. Non-remix lineage is true by construction — the program
  contains only the three irreducible Boolean ops, zero human-named
  primitives. This matches the verification approach of the 2026-05-22
  bit-tape doc.

## Results

| seed | search composite | indep min_pb | max_pb | mean_pb | rigorous chisq (≤255) | op mix (XOR/NOT/AND) | PractRand |
|---|---:|---:|---:|---:|---|---|---|
| s1 | 49.997 | **0.500000** | 0.500000 | 0.500000 | 231.0 ✅ | 201/116/65 (17% AND) | **FAIL @ 16 MiB** (106 tests) |
| s2 | 49.961 | 0.483856 | 0.500305 | 0.498655 | 287.5 ❌ | 190/139/54 (14% AND) | **FAIL @ 16 MiB** (123 tests) |
| s3 | 47.879 | **0.500000** | 0.500153 | 0.500002 | 223.9 ✅ | 171/133/79 (21% AND) | **FAIL @ 16 MiB** (106 tests) |

Prior (2026-05-22) champion, for comparison: `min_pb = 0.166`,
`max_pb = 0.672`, rigorous chisq = 273.6 (FAIL), PractRand catastrophic.

Two findings, one positive and one negative:

**Positive — the per-bit imbalance is eliminated, and it is real.** On the
independent check (different seed, 4× samples — a metric the search could
not have gamed), s1 and s3 reach `min_bit_flip_frac = 0.500000` exactly,
mean 0.500000, with `max_pb` settled at ≈0.5000 (no over-flipping bit
either). They also pass rigorous chi-square (231, 224). This is a clean,
reproducible improvement over the prior run's `min_pb = 0.166`. The
single-flag fix the prior session proposed achieved exactly its stated
goal: the engine can no longer game an aggregate that averages to 32
while hiding per-bit imbalance. 2/3 seeds produce per-bit-clean champions
(s2 fails chi-square and is the weak seed).

**Negative — per-bit balance is necessary but nowhere near sufficient.**
All three champions fail PractRand catastrophically at the 16 MiB first
tier (below the 64 MiB gate), p=0 across BCFN, Gap, FPF, mod3n, DC6, and
others. **BRank fails on every seed** (`BRank(12):score:768 R=+22179
p~=1`), on the full word and on low-bit slices — the canonical signature
of GF(2) linear structure. The programs remain XOR-dominant (s3, the most
nonlinear, is still only 21% AND).

## What this empirically establishes

1. **The 2026-05-22 single-flag fix works as designed and is verified
   independent of the search samples.** Per-bit avalanche imbalance —
   the specific flaw the prior session identified — is eliminated
   (`min_pb` 0.166 → 0.500) and confirmed at 4× samples on a disjoint
   seed. This rules out "the engine overfit its fitness samples."

2. **It does not produce a usable PRNG.** A metric-vs-task mismatch
   remains: per-bit avalanche measures *single-step* diffusion (output
   response to one input-bit flip), while PractRand tests the *iterated
   stream* `x, f(x), f(f(x))…`. A function can have flawless one-step
   avalanche and still produce a stream with linear residue and
   short-range correlation. These do.

3. **The barrier is now identified, not hidden.** Where the prior run's
   failure was masked by metric-gaming, this run's failure is legible:
   BRank pins it to linear structure, and the broader BCFN/Gap/mod3n
   failures point to iterated-stream correlations the single-step fitness
   never tests. The substrate is XOR-dominant and the fitness rewards
   one-step diffusion, so the search has no pressure toward the
   nonlinearity and stream-decorrelation PractRand demands.

4. **What was NOT tested:** fitness terms that score the iterated stream
   directly (e.g., PractRand-as-fitness on per-bit-passing candidates);
   nonlinearity pressure (reward AND density or measured GF(2)
   nonlinearity); generations beyond 10k; seeds beyond the 3 used;
   island-model multi-population GA.

## Externally-defensible framing

> We reformed the fitness function of a pure-evolutionary search over a
> minimal Boolean substrate (XOR/AND/NOT) to target per-output-bit
> avalanche instead of aggregate avalanche, fixing a metric-gaming failure
> from the prior run. Across three independent seeds at 10,000
> generations, the reform eliminated per-bit imbalance — the worst output
> bit's flip probability rose from 0.166 to 0.500, confirmed by an
> independent check at 4× samples on a disjoint seed (2/3 seeds reach
> exactly 0.500000 and pass rigorous chi-square). However, all three
> champions fail PractRand catastrophically at the 16 MiB tier, with the
> binary-rank test (BRank) failing on every seed — the signature of GF(2)
> linear structure. The result demonstrates that per-bit avalanche
> balance is necessary but not sufficient for stream-quality randomness:
> the single-step diffusion the fitness rewards is orthogonal to the
> iterated-stream linearity and correlation that PractRand detects.

## Open follow-up questions

1. Does adding an explicit nonlinearity term (reward AND density, or a
   measured GF(2) algebraic-degree / BRank-style residue penalty) move
   the champions off the linear basin? This is the most direct attack on
   the BRank failure.
2. Does PractRand-as-fitness — evaluated only on candidates that already
   pass the per-bit test, since PractRand is slow — close the
   metric-vs-task gap? This is follow-up #4 from the prior doc, now
   well-motivated by the BRank diagnosis.
3. Would a NAND-only substrate (single universal operator, forcing
   nonlinearity into every instruction) avoid the XOR-dominant linear
   basin the `{XOR, AND, NOT}` search settled into?

Each is a separate experiment of comparable cost to this one.

## Artifacts

- Source (this experiment): `src/adapters/domain_bittape.zig`
  (per-bit fitness), `src/adapters/bittape_inventor.zig` (trajectory CSV
  now logs `best_min_pb`, `best_max_pb`, `best_bias_pb`),
  `src/adapters/bittape_inspect.zig` (independent per-bit check: 512
  samples, disjoint seed).
- Full-run evidence: `results/exp1_bittape_s1/`, `exp1_bittape_s2/`,
  `exp1_bittape_s3/` — per-seed `trajectory.csv` (10k gens) +
  `BEST_program.csv`.
- Pilots: `results/exp1_bittape_pilot/` (raw-min stall),
  `results/exp1_bittape_pilot2/` (bias-driven, validated).
- Verification: `results/exp1_bittape_validation/fitness_recheck.txt`
  (rigorous + independent per-bit + op composition, all 3 seeds),
  `results/exp1_bittape_validation/practrand_s3.txt` (full PractRand
  output, representative champion).
- Prior run this builds on: `docs/research/bittape_inventor_2026_05_22.md`.
