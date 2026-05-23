# Synthesized Conceptless Breakthrough

`src/adapters/synthesized_conceptless_breakthrough.zig` is the VSA-free engine synthesized
from the prior `alien_breakthrough_inventor` geometry constants.

It is intentionally standalone at runtime:

- imports `std` only
- does not import `vsa`
- does not import `flame`
- does not use `flame.Laws`
- does not use VSA concepts or concept names in scoring
- is installed in `build.zig` without `addGhostImports`

## What "Synthesized By The Old Engine" Means

The source uses the old generated engine's geometry constants as its seed:

- source genome hash: `0xAF63CF03E028E569`
- source genome seed: `0x5604D7E8AC1D9E6A`
- source prototype words copied from `alien_breakthrough_inventor`

From those constants it derives its own private reference orbit and optimizes an anti-reference
field. No VSA envelope or Flame law table is used by the new engine.

## Checked Result

Command:

```sh
./zig-out/bin/synthesized_conceptless_breakthrough --trials=24 --csv=results/synthesized_conceptless_breakthrough.csv
```

Run on 2026-05-19:

- self-reference envelope max: `283`
- target distance: `284`
- result: `24/24` trials past target
- best minimum reference distance: `291`
- clearance over self-reference envelope: `+8`
- best field hash: `0xE47F99B8ABC739EE`
- CSV: `results/synthesized_conceptless_breakthrough.csv`

For comparison, the earlier `conceptless_inventor` run had self-reference envelope max `288`
and best minimum reference distance `290`, clearance `+2`. This generated VSA-free engine has
larger clearance on its own self-reference orbit, but the two use different derived reference
orbits, so compare them as architecture behavior, not identical benchmark rows.

## Honest Limit

This still does not prove useful external invention. It proves the old geometry engine can seed a
new, VSA-free, Flame-free geometry engine that escapes its own generated reference orbit more
strongly than the first conceptless prototype.
