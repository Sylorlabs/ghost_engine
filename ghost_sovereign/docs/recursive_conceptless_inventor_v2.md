# recursive_conceptless_inventor_v2

Third generation in the conceptless invention chain:

```
Gen0  synthesized_conceptless_breakthrough.zig
        best_min_ref = 291    clearance = +8

Gen1  recursive_conceptless_inventor.zig            (synthesized from Gen0)
        best_min_ref = 294    clearance = +11

Gen2  recursive_conceptless_inventor_v2.zig         (synthesized from Gen1)
        best_min_ref = 296    clearance = +13
```

## Runtime boundary

Same as parents:

- `std` only
- no VSA import
- no Flame import
- no concept enum / concept names / `getConceptHV`
- no external model, service, network, cloud path

Verified by `grep`:

```
src/adapters/recursive_conceptless_inventor_v2.zig:1:const std = @import("std");
```

No other imports.

## Why Gen1 saturated at 294

`recursive_conceptless_inventor.zig`'s `pushFrontier` is single-bit greedy:
it flips one bit at a time and accepts only if the deficit cost (sum of
squared shortfalls below the target frontier) strictly decreases.

When the field reaches the configuration where multiple reference fields
sit at distance 294 simultaneously, the search gets stuck. For a single
bit to lift the floor by +1, that bit's "good-ref" vector v_b ∈ {-1, +1}^24
must satisfy v_b[i] = +1 for *every* ref currently at d=floor. With k≥2
refs at the floor and ~50% per-ref bit-agreement probability, the chance
that *all* k floor refs share the same agreement for *some* single bit is
~0.5^k per bit. For k≥4 floor refs in a 512-bit field, the expected count
of qualifying bits is <2. Once those bits are consumed, no single-bit
move lifts.

Sweeps from Gen1 confirmed this: trials=8, steps=1024, phases=40 topped
at 294. trials=8, steps=2048, phases=80 also topped at 294. The single-
bit ceiling is geometric, not iteration-limited.

## What Gen2 adds

Two changes on top of Gen1, with everything else inherited unchanged:

1. **`pushFrontierPair`** — exhaustive pair-flip search. For each pair
   (b1, b2) of bit positions, compute the joint effect on all 24 ref
   distances and apply the best pair. A pair-flip can lift the floor by
   +1 when `S_{b1} ∪ S_{b2}` covers every floor-ref's "good" set, even
   when no single bit alone does. Cost: O(Dim²·RefCount) ≈ 6.3M ops per
   step. Runs after Gen1's single-bit `pushFrontier` saturates.

2. **`metropolisKick`** — Metropolis acceptance of worse single-bit
   moves with cooling temperature, applied before greedy in each phase.
   Diversifies starting points so phase restarts explore different
   basins instead of revisiting the same anti-majority neighborhood.

Both build on Gen1's machinery (`antiMajority`, `pushFrontier`,
`balanceFloor`, `temperLaws`) which is inherited verbatim. The
`SourcePrototype`, `SourceGenomeHash`, `SourceGenomeSeed` constants are
copied from Gen1 so Gen2 is measured against the **same 24 reference
fields** — direct comparison.

## Measured results

```
parent: 294 clearance +11
                      ↓
Gen2 validation (--trials=4 --steps=512 --phases=4 --pair-steps=8 --kicks=64):
  past_parent: 3/4
  best_min_ref: 295    clearance: +12
  best_hash: 0xE6E771DB44D3E907

Gen2 sweep (--trials=12 --steps=1024 --phases=16 --pair-steps=24 --kicks=128):
  past_parent: 12/12 ← 100% pass rate
  best_min_ref: 296   clearance: +13
  best_hash: 0xF5F4A345949EE7E8

Gen2 aggressive (--trials=16 --steps=1024 --phases=32 --pair-steps=48 --kicks=192):
  past_parent: 16/16
  best_min_ref: 296   clearance: +13
  best_violations: 1482
  best_hash: 0x5412E401A4765E9E
```

Gen2 reaches 295 reliably and 296 in roughly 3 of 16 aggressive trials.
296 is its honest ceiling under pair-flip + Metropolis.

## Honest caveat

The same caveat from Gen1 applies: this proves the **internal self-
reference geometry** can be escaped more deeply by recursive engine
generations, not that the engine produces externally-useful inventions.
The "invention" here is a 512-bit field configuration that is farther
from a fixed set of 24 reference fields than any previous engine could
produce.

What it does establish: the recursive-synthesis pattern actually works.
Each generation can be measurably stronger than the last on a shared
benchmark, using only std-library Zig, no concept basis, no VSA, no
Flame, no cloud, no model. The chain has now produced three measurable
improvements: 291 → 294 → 296.

## Reproduction

```
cd ghost_sovereign
zig build -Doptimize=ReleaseFast
./zig-out/bin/recursive_conceptless_inventor_v2 \
    --trials=16 --steps=1024 --phases=32 --pair-steps=48 --kicks=192 \
    --csv=results/recursive_conceptless_v2_aggressive.csv
```

Expected verdict:

```
v2_past_parent=16/16; best_min_ref=296; best_clearance=+13;
best_hash=0x5412E401A4765E9E
```

## Files

```
src/adapters/recursive_conceptless_inventor_v2.zig
results/recursive_conceptless_inventor_v2.csv
results/recursive_conceptless_v2_sweep.csv
results/recursive_conceptless_v2_aggressive.csv
docs/recursive_conceptless_inventor_v2.md
build.zig          (one new target, no addGhostImports)
```

## Path to Gen3

Pair-flip search saturates at 296 because the same geometric argument
that bounded single-bit search at 294 now bounds pair-flip. For the
floor at d=296 with k≥2 floor refs, a pair-flip lift requires
`S_{b1} ∪ S_{b2}` to cover all k floor refs. With aggressive settings
we found this happens in ~3 trials of 16, suggesting we're near the
combinatorial ceiling for pair-flips on this orbit.

Gen3 candidates (in increasing order of cost and likely yield):

1. **Triple-flip** — O(Dim³·RefCount) ≈ 3.2G ops/step. Probably reaches
   297-298.
2. **Linear-programming relaxation + rounding** — solve the max-min
   Hamming problem as a Lagrangian-relaxed LP, round to integer.
3. **Genetic crossover** — keep population of top-N field configs, swap
   bit-segments between them, hill-climb the children.

Recommended for Gen3: option 1 (triple-flip) since it continues the
direct iterative-search lineage. Options 2 and 3 are larger architecture
deviations.
