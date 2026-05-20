# Alien Breakthrough Inventor

`src/adapters/alien_breakthrough_inventor.zig` is the strongest outside-envelope engine
found by asking `engine_genesis` to search for a stronger breakthrough candidate.

Command used to generate it:

```sh
./zig-out/bin/engine_genesis --seed=1 --trials=16 --evolve-trials=4 --emit=src/adapters/alien_breakthrough_inventor.zig --csv=results/alien_breakthrough_genesis.csv
```

Independent run:

```sh
./zig-out/bin/alien_breakthrough_inventor --trials=32 --csv=results/alien_breakthrough_inventor.csv
```

## Checked Result

Run on 2026-05-19:

- VSA max envelope: `290`
- generated geometry min distance: `291`
- nearest anchor: `HARDWARE`
- independent run: `32/32` past envelope
- best closure: `14486650`
- CSV: `results/alien_breakthrough_inventor.csv`

This beats the prior phase-lattice best closure of `14795384` while staying outside the
VSA envelope.

## Honest Verdict

This is a stronger local invention engine, not the extraordinary breakthrough yet. It is still
optimizing chamber geometry and closure. The result is real because it emits and runs a separate
Zig engine, but the improvement is incremental.

The next honest bar for "alien breakthrough" is a generated engine that produces a readable
new algorithm or code artifact and beats a holdout benchmark that was not used in the generator.
