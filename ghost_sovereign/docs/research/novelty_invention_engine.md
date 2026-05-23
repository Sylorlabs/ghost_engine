# Novelty Invention Engine

`src/adapters/novelty_invention.zig` is the local-only novelty-pressure invention probe.

It tests the specific failure from the earlier closure-only invention loop: minimizing
`closure_error` alone pulls chamber states back into the VSA-derived attractor set. This
probe adds an explicit geometric novelty target: maximize the minimum 512-bit sign
fingerprint distance from all 20 VSA concept hypervectors while still running law repair.

## Runnable command

```sh
zig build
./zig-out/bin/novelty_invention --trials=24 --iters=240 --meta-trials=4 --meta-iters=70 --csv=results/novelty_invention.csv
```

The executable is fully local Zig code. It does not call a hosted model, service, embedding
API, or data center.

## What it builds

The engine runs a deterministic pilot sweep over several local search profiles, then uses the
best measured profile for the full run. The winning profile in the first checked run was:

- `prototype_lock`
- builds a greedy outside-envelope sign prototype
- runs law relaxation while locking the chamber sign fingerprint to that outside-envelope prototype
- optimizes closure inside that constrained novelty surface

This is the "engine makes its own engine" step in the bounded sense: it synthesizes and selects
a search profile from measured local candidates before the full run.

## Checked result

Run on 2026-05-19:

- VSA inter-concept Hamming max: `290`
- greedy novelty prototype min distance: `293`
- selected engine: `prototype_lock`
- full run: `24/24` trials past the VSA envelope
- best min-concept distance: `293`
- best closure: `20448584`
- output CSV: `results/novelty_invention.csv`

Raw outside-envelope prototype scoring with zero law-relaxation passes produced closure around
`427038249` in the smoke run. The constrained `prototype_lock` repair reduced that to about
`20-24M` while keeping the sign fingerprint outside the VSA envelope.

## Honest limitation

The old closure-only attractor path still reaches lower closure, around `7.4M` in the same
probe family, but it stays inside the VSA envelope. The novelty engine proves an outside-VSA
law-repaired chamber surface exists. It does not prove the outside surface is lower closure
than the existing attractors.
