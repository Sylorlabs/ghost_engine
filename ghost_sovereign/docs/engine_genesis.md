# Engine Genesis

`src/adapters/engine_genesis.zig` is the local geometry-to-Zig compiler for invention engines.

It takes the outside-envelope chamber geometry, derives a genome from that geometry plus the
Flame law table, locally evolves the genome against closure and novelty, then emits a standalone
Zig adapter:

```sh
./zig-out/bin/engine_genesis --trials=16 --evolve-trials=3 --emit=src/adapters/generated_geometry_invention.zig --csv=results/engine_genesis.csv
```

The emitted engine is built as:

```sh
./zig-out/bin/generated_geometry_invention --trials=16 --csv=results/generated_geometry_invention.csv
```

This is all local deterministic Zig. It does not call a hosted model, embedding API, remote
compiler, or service.

## Checked Result

Run on 2026-05-19:

- generated source: `src/adapters/generated_geometry_invention.zig`
- generated binary: `zig-out/bin/generated_geometry_invention`
- VSA max envelope: `290`
- generated engine min distance: `291`
- generated engine full run: `16/16` past envelope
- generated engine best closure: `14829513`
- CSV: `results/generated_geometry_invention.csv`

This beats the earlier `prototype_lock` run on closure while staying outside the VSA envelope:
`prototype_lock` best closure was about `20448584`; the generated engine independently measured
`14829513`.

## Honest Limit

The generated engine still speaks chamber geometry. It does not yet emit human-readable inventions
or runnable non-engine artifacts. The next compiler stage is:

```text
outside geometry -> engine genome -> generated Zig engine -> benchmark -> readable design/code artifact
```

The current result proves the system can generate a new local Zig invention engine that performs
better than the hand-wired novelty-pressure engine on the measured outside-envelope closure target.
