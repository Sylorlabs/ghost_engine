# Recursive Conceptless Inventor

`src/adapters/recursive_conceptless_inventor.zig` is the next invention engine synthesized from
`synthesized_conceptless_breakthrough.zig`.

It keeps the same runtime boundary as the parent:

- imports `std` only
- does not import `vsa`
- does not import `flame`
- does not use VSA concepts
- does not use `flame.Laws`
- is installed in `build.zig` without `addGhostImports`
- makes no model, service, or network call

## What Changed

The parent engine escaped its private self-reference orbit with best minimum reference distance
`291` against an envelope max of `283`, for clearance `+8`.

This child preserves that same inherited reference orbit so the measurement is directly comparable.
It replaces the parent search with a moving maximin frontier:

1. derive the same 24 self-reference fields as the parent
2. synthesize an anti-majority start field
3. push a distance frontier until every reference clears it
4. balance the weakest distance floor
5. run a small self-law tempering pass that may reduce violations without lowering the achieved
   distance floor

The self-laws are diagnostic only. The primary claim is distance escape on the parent's inherited
reference envelope.

## Checked Result

Command:

```sh
./zig-out/bin/recursive_conceptless_inventor --trials=24 --steps=512 --phases=20 --csv=results/recursive_conceptless_inventor.csv
```

Run on 2026-05-19:

- inherited envelope max: `283`
- parent best minimum reference distance: `291`
- child target to beat parent: `292`
- result: `24/24` trials beat the parent target
- best child minimum reference distance: `294`
- best child clearance over inherited envelope: `+11`
- best selected field hash: `0x9EB89E40D0D6F289`
- CSV: `results/recursive_conceptless_inventor.csv`

Bounded sweeps with `--steps=1024 --phases=40` and `--steps=2048 --phases=80` also topped out at
minimum distance `294`, so this pass did not find a `295` state.

## Honest Limit

This is a stronger VSA-free geometry engine than the parent on the same internal benchmark. It is
not proof of useful external invention yet. It proves recursive local synthesis can produce a child
engine that escapes the inherited reference envelope more strongly than the parent without using VSA,
Flame, concept names, external models, or network calls.
