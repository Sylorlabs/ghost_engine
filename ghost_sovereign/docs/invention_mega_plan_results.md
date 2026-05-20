# Invention Mega Plan Results

Measured implementation pass after the 2026-05-19 handoff. Numbers below are
from local binaries, not narrative interpretation.

## Track 1: PractRand validation

Implemented `src/adapters/practrand_emit.zig`, a std-only raw little-endian
`u64` stream emitter for:

- `--variant=discovered`: Run 2 discovered mixer from
  `program_synthesis_inventor`.
- `--variant=splitmix`: iterated splitMix64 reference used by the synthesis
  fitness comparison.
- `--variant=splitmix-counter`: conventional counter-style SplitMix64 stream.

PractRand 0.96 at `-tlmax 1G`:

```
discovered-run2: no anomalies in 227 test result(s)
splitmix:        no anomalies in 227 test result(s)
```

Verdict: external validation passes at 1 GiB, but this is a tie, not a
PractRand win over splitMix64.

## Track 2: Program synthesis self-bootstrap

Added:

- `src/adapters/program_synthesis_bootstrap.zig`
- `src/adapters/program_synthesis_bootstrap_v2.zig`

Bootstrap Gen1 uses the Run 2 discovered mixer as the search RNG. Best observed
Gen1 run:

```
command: ./zig-out/bin/program_synthesis_bootstrap --iters=15000 --seeds=128 --seed=1111111111111111 --csv=results/program_synthesis_bootstrap_s1.csv
score:   composite=47.97, avalanche=32.0015, balance=31.9961, chisq=244.50, length=4
parent:  Run 2 composite=47.30
```

Bootstrap Gen2 uses the Gen1 47.97 mixer as its search RNG. Three observed
runs scored 47.86, 47.91, and 47.93.

Verdict: self-bootstrap produced one improvement over the parent, then stalled
below Gen1 in the next generation. Caveat: the Gen1 win still benefits from
the length term and does not prove strict raw-statistical dominance.

## Track 3: Conceptless Gen3 triple-flip

Added `src/adapters/recursive_conceptless_inventor_v3.zig`. It preserves the
std-only boundary and adds `--triple-steps` after pair frontier search.

Full planned sweep:

```
./zig-out/bin/recursive_conceptless_inventor_v3 --trials=8 --steps=512 --phases=16 --pair-steps=24 --triple-steps=4 --kicks=128 --csv=results/recursive_conceptless_inventor_v3_full.csv
```

Result:

```
v3_past_parent=0/8
best_min_ref=295
best_clearance=+12
best_hash=0xCFDAE4859E0889C2
```

Verdict: Gen3 did not beat Gen2. The documented parent target was 297; no trial
got past 295.

## Track 4: Dead VSA concept activation

Tried Option A, logarithmic coefficient scaling. Small check:

```
./zig-out/bin/invention_global --trials=100 --passes=300 --range=50000 --csv=results/invention_global_logscale_100.csv
```

Log scaling failed: it concentrated attractors into SHADOW 49%, NETWORK 33%,
SYNTAX 15%, SIGNAL 3%, with most concepts still dead. The change was reverted.

Restored Path A full recheck:

```
./zig-out/bin/invention_global --trials=1000 --passes=1000 --range=50000 --csv=results/invention_global_pathA_reverify.csv
```

Result:

```
live concepts: SYNTAX, SIGNAL, NOISE, AETHER, VOID, SHADOW, SOFTWARE, NETWORK, MEMORY, IDENTITY, REASON
still dead:    LOGIC, CODE, DATA, TRUTH, HARDWARE, PROCESS, CRAVE, ORDER, CHAOS
alien:         0/1000 past max inter-concept distance
```

Verdict: Option A failed; Path A remains the least-bad current law table.

## Track 5: AbsoluteCore semantic ingest bridge

Added `AbsoluteCore.ingestSemantic`, which hashes each whitespace-delimited
word, creates a VSA random hypervector with `vsa.Hypervector.initRandom(hash)`,
and ingests the 128-byte hypervector representation through the existing byte
walker.

`ingestion_scale` now supports `--mode=byte|semantic`.

Full semantic run:

```
./zig-out/bin/ingestion_scale --corpus=corpus/curated_pairs.txt --mode=semantic --checkpoints=0,100,1000,10000,100000,1000000 --csv=results/ingestion_scale_semantic_full.csv --state=state/ingestion_scale_semantic_full.bin
```

At 1,000,000 lines:

```
related_mean=32.2921
overlap_mean=31.0690
cohens_d=0.3109
p(R<O)=0.98052
semantic_wins=no
```

Verdict: semantic hypervector routing removes the strong spelling-cluster
effect and pushes the benchmark toward random Hamming behavior, but it does
not create semantic clustering.

## Track 6: Placeholder cleanup

Added `src/adapters/measured_consultation_probe.zig` and wired these stale
commands to real measured reservoir output:

- `ask_experts`
- `debate_experts`
- `audit_experts`
- `omni_ingest_verdict`
- `final_questions`
- `total_audit`

Each command now prints closure_before, closure_after, delta, trigger_edge, and
fingerprint rows with:

```
verdict=probe_only_no_language_generation_no_external_authority
```

Verdict: live `zig-out/bin` commands no longer print placeholder text after
`zig build`.
