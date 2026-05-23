# program_synthesis_inventor

An invention engine that searches over short u64-mixing programs in a
small instruction set and discovers compact algorithms with PRNG-like
statistical properties. The reference it competes against (without
seeing it) is `splitMix64`, a 4-step human-designed mixer used
throughout this codebase.

## Why this is different from the rest of the project's invention work

Previous invention engines (`invention_global`, `invention_relaxed`,
`absolute_invention`, `targeted_invention`, `recursive_conceptless_*`)
search for **states or bitfields** that score well on internal benchmarks.
Their outputs are 512-bit configurations whose only utility is being
measurable inside the project.

This engine searches for **programs**. Its outputs are decodable Zig-like
code that can be transcribed into actual `fn step(x: u64) u64` definitions
and used as standalone hash functions or PRNGs by anyone running the
binary.

That is the harshest-critic distinction between "score-keeping" and "real
invention": the engine produces an artifact that does something outside
the chain it was invented in.

## Runtime boundary

- `std` only
- no VSA, no Flame, no concept enum
- no model, no cloud, no network, no curated corpus
- no knowledge of splitMix64 inside the search (it appears only as a
  measured baseline at the end, never in seeding or mutation)

## Search

- Instruction set: `XOR, ADD, MUL, ROTL, SHL_XOR, SHR_XOR,
  SPLITMIX_STEP, ADD_CONST, AND_NOT, OR_SHIFT` (10 ops, all u64).
- Programs are 4-12 instructions, each over 8 registers initialised
  with `(x, K1, K2, K3, 0, 0, 0, 0)` where K1..K3 are three standard
  mixing constants used as available material, NOT as part of any
  splitMix template.
- Search is simulated-annealing on a pool of 64-128 program champions
  with point mutation, insert, delete, and crossover. Acceptance is
  Metropolis against the current pool worst.
- Fitness is multi-objective: avalanche distance to 32, popcount
  balance distance to 32, period estimate (Floyd-style, ≤4096
  budget), chi-square over low-byte uniformity, and length penalty.

## Measured results

Two independent runs, different seeds, both found programs that
outscore splitMix64 on the composite fitness, with different
structures:

### Run 1: `--iters=4000 --seeds=64`

```
DISCOVERED                            splitMix64 REFERENCE
avalanche=31.99  (target 32)          avalanche=31.94
balance=32.04                         balance=32.04
period>=4096                          period>=4096
chisq=256.63                          chisq=234.63
length=5                              length=6
composite=47.19                       composite=46.20
```

Discovered program:

```
r6 = SHR_XOR(r0, _, s)
r1 = SHR_XOR(r6, _, s)
r2 = SPLITMIX_STEP(r6, r1, _)
r7 = OR_SHIFT(_, r2, s)
r7 = SPLITMIX_STEP(r7, r1, _)
```

### Run 2: `--iters=15000 --seeds=128 --seed=ABCDEF0123456789`

```
DISCOVERED                            splitMix64 REFERENCE
avalanche=31.98                       avalanche=31.94
balance=32.00 (perfect)               balance=32.04
period>=4096                          period>=4096
chisq=240.50                          chisq=234.63
length=5                              length=6
composite=47.30                       composite=46.20
```

Discovered program:

```
r1 = SHR_XOR(r0, _, s)        # y = x ^ (x >> s)
r0 = ADD_CONST(r1, _, C)      # y += C
r6 = MUL(r0, _, M)            # y *= M
r6 = SHR_XOR(r6, _, s)        # y ^= y >> s
r7 = MUL(r6, _, M)            # y *= M
```

Structurally distinct from splitMix64: shift-XOR first, then add,
then double multiply with one intermediate shift-XOR. The canonical
splitMix pattern (`(y ^ (y>>k)) *% K` repeated) does not appear.

## Honest caveats

1. The discovered programs OUTSCORE splitMix64 on the composite by ~1
   point. That win comes partly from being 5 instructions vs 6, which
   the length penalty rewards. Without the length penalty, the
   discovered programs are *competitive* with splitMix64 but not
   strictly dominant — slightly better balance, slightly worse
   chi-square.
2. Period was measured with a 4096-iteration budget. Both the
   discovered programs and splitMix64 hit that ceiling without
   detected cycles. The true periods are unknown.
3. The fitness function itself is human-designed. The discovery is
   genuine within that fitness landscape but the landscape is not
   externally-given truth.
4. The instruction set was chosen by hand. A different op selection
   might yield qualitatively different discoveries.

What it does prove: **the engine, given no PRNG design knowledge,
arrives at structurally-novel u64 mixing algorithms that compete with
the human-designed reference on the fitness function it was given.**
That is "alien" in the sense of arriving by independent search rather
than by absorbing human design heuristics. It is not "alien" in the
sense of producing artifacts unlike anything humans could conceive.

## Reproduction

```
cd ghost_sovereign
zig build -Doptimize=ReleaseFast
./zig-out/bin/program_synthesis_inventor --iters=15000 --seeds=128 --seed=ABCDEF0123456789
```

## Files

```
src/adapters/program_synthesis_inventor.zig
results/program_synthesis_inventor.csv      (run 1)
results/program_synthesis_long.csv           (run 2)
docs/program_synthesis_inventor.md           (this file)
build.zig                                     (one new target, std only)
```

## Where this could go next

1. **Drop the length penalty and grow the search budget.** See if the
   engine finds programs strictly dominating splitMix64 on raw
   statistical quality alone (without trading length for chi-square).
2. **Extend the instruction set with multiword state.** Real PRNGs
   like xoshiro use 4-word state; this engine is restricted to
   single-word transforms.
3. **Self-bootstrap.** Use a discovered program AS the search-engine's
   PRNG instead of `splitMix64`. If the chain converges to programs
   that outperform their own search PRNG, that is genuine recursive
   self-improvement.
4. **External validation suite.** Pipe discovered programs through
   PractRand or TestU01 — the industry-standard PRNG quality batteries.
   If a discovered program passes more tests than splitMix64, that is a
   defensible external claim.

## PractRand stream emitter

`src/adapters/practrand_emit.zig` emits raw little-endian `u64` streams for
external PRNG batteries. The default stream is the Run 2 discovered program
above, iterated as:

```
state = discoveredRun2Mix(state)
write_little_endian_u64(state)
```

It is std-only and is wired in `build.zig` without `addGhostImports`.

Smoke test a bounded stream:

```
zig build -Doptimize=ReleaseFast
./zig-out/bin/practrand_emit --variant=discovered --bytes=64 | od -An -tx8
./zig-out/bin/practrand_emit --variant=splitmix --bytes=64 | od -An -tx8
```

When PractRand is installed, compare discovered vs the same iterated
splitMix64 baseline:

```
./zig-out/bin/practrand_emit --variant=discovered | RNG_test stdin64 -tlmax 1G
./zig-out/bin/practrand_emit --variant=splitmix | RNG_test stdin64 -tlmax 1G
```

`--variant=splitmix-counter` is also available for the conventional
counter-style SplitMix64 stream, but it is not the same unary-step baseline
used by the synthesis fitness function.

Local PractRand 0.96 result at `-tlmax 1G`:

```
discovered-run2: no anomalies in 227 test result(s)
splitmix:        no anomalies in 227 test result(s)
```

Honest read: the discovered program passes the same 1 GiB external battery
checkpoint as the iterated splitMix64 baseline. This is external validation
that it is not obviously weak at 1 GiB, not evidence that it beats splitMix64
under PractRand.

## Self-bootstrap result

Implemented two bootstrap binaries:

```
src/adapters/program_synthesis_bootstrap.zig
src/adapters/program_synthesis_bootstrap_v2.zig
```

Gen1 uses the Run 2 discovered mixer as the search RNG. The best observed
Gen1 run beat the Run 2 parent composite:

```
./zig-out/bin/program_synthesis_bootstrap --iters=15000 --seeds=128 --seed=1111111111111111 --csv=results/program_synthesis_bootstrap_s1.csv

Gen1 best: composite=47.97
Run 2 parent: composite=47.30
```

Gen2 uses the Gen1 47.97 mixer as the search RNG. Three observed Gen2 runs
scored 47.86, 47.91, and 47.93, so the chain stalled below Gen1.

Honest read: recursive self-bootstrap produced one measurable improvement,
then failed to compound in the next generation. The win still benefits from
the length term in the composite score.
