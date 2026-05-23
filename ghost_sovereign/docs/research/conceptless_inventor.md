# Conceptless Inventor

`src/adapters/conceptless_inventor.zig` is the VSA-free invention probe.

It is intentionally standalone:

- imports `std` only
- does not import `vsa`
- does not import `flame`
- does not use `flame.Laws`
- does not use VSA concepts or concept names in the scoring loop
- is installed in `build.zig` without `addGhostImports`

This does not mean it is free of all human constraints. It still runs as Zig code on human-built
integer hardware. The honest claim is narrower: it removes the VSA/concept/Flame-law cage.

## Mechanism

The engine creates a private self-reference orbit from `splitMix64`, then synthesizes an
anti-reference field that is farther from that orbit than the orbit is from itself. Self-laws are
diagnostic pressure only; the primary constraint is preserving escape from the generated reference
orbit rather than collapsing into it.

## Checked Result

Command:

```sh
./zig-out/bin/conceptless_inventor --trials=24 --iters=900 --csv=results/conceptless_inventor.csv
```

Run on 2026-05-19:

- self-reference envelope max: `288`
- target distance: `289`
- result: `24/24` trials past target
- best minimum reference distance: `290`
- best field hash: `0x398EF11404341526`
- CSV: `results/conceptless_inventor.csv`

This is not measured against VSA and should not be compared directly to the VSA-envelope engines.
It is a separate conceptless geometry test.
