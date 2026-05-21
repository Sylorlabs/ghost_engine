# DomainSpec Architecture and Three-Domain Validation

Status: built, run, three independent domains all produce INVENTION (strict) under the unified engine. 2026-05-20.

## What this is

A comptime-generic invention engine in Zig that takes a *domain spec*
as a parameter. The engine code (search loop, champion pool, quality
gate, reachability search, verdict ladder) is identical across domains.
A new domain is a single module that satisfies a fixed interface.

The deliverable tests a bounded version of the strict definition:
*"given the basics or data, can invent in a new domain."* What "given
the basics" means operationally is "given a Spec module that implements
the contract." This is evidence for a reusable invention interface, not
proof of universal all-domain invention.

## The interface contract

A Spec module must expose:

```zig
pub const DOMAIN_NAME: []const u8
pub const Program: type
pub const Quality: type
pub const DistanceResult: type
pub const ReachabilityResult: type

pub fn randomProgram(rng: *u64) Program
pub fn mutate(p: Program, rng: *u64) Program
pub fn crossover(a: Program, b: Program, rng: *u64) Program

pub fn evaluateQuality(p: Program) Quality
pub fn qualityScalar(q: Quality) f64        // SA composite signal
pub fn qualityPasses(q: Quality) bool       // gate for INVENTION
pub fn isFinite(q: Quality) bool

pub fn distanceToLibrary(p: Program, allocator) !DistanceResult
pub fn reachability(p: Program, allocator) !ReachabilityResult

pub fn isEquivalent(d: DistanceResult) bool
pub fn isTrivialVariant(d: DistanceResult) bool
pub fn isRemix(d: DistanceResult) bool
pub fn isReachable(r: ReachabilityResult) bool

pub fn printProgram(p: Program, writer: anytype) !void
pub fn programToCsv(p: Program, writer: anytype) !void
```

The engine never reads `Program` internals. It calls Spec methods only.

## The engine

`src/adapters/invention_engine.zig`. Owns:

- **Champion pool** of fixed size 16
- **Default search loop**: simulated annealing with mutation/crossover,
  Metropolis acceptance against the worst pool member, exponential cooling
  `t(i) = t_start * 0.001^(i/iterations)`
- **Configured search loop**: `searchWithConfig` can vary mutation rate,
  crossover rate, pool size, parent selection, replacement policy,
  acceptance policy, and cooling schedule. This is the surface used by
  the meta-domain.
- **Verdict ladder**:
  EQUIVALENT → TRIVIAL_VARIANT → NEAR_EQUIVALENT → REMIX → REACHABLE
  → NON_QUALITY → INVENTION (strict)
- **`Engine(Spec).grade(p, allocator)`** — runs distance + reachability +
  quality and returns a `Verdict`

The same engine instantiates per-domain via Zig's comptime generics:

```zig
const MixerEng   = engine.Engine(domain_u64_mixer);
const SortEng    = engine.Engine(domain_sort_net);
const BoolEng    = engine.Engine(domain_boolean);
```

Same code, three different domains, no engine modification.

## Three domain instances

| Domain | I/O | Operators | Quality | Library | Divergence axis |
|---|---|---|---|---|---|
| `domain_u64_mixer.zig` | `u64 → u64` | 10 arithmetic ops | avalanche / balance / chi-square / period | splitMix64, Murmur, xorshift, Wang | functional (bit_agreement) |
| `domain_sort_net.zig` | `[8]u8 → [8]u8` | 28 compare-exchange | exact correctness over 8! | Floyd-8, Batcher-8 | structural (comparator edit) |
| `domain_boolean.zig` | `u4 → u1` (truth table) | AND/OR/XOR/NAND/NOR/NOT | truth-table match to PARITY-4 (0x6996) | Tree, Cascade, AltTree | structural (gate edit) |

Each domain module is roughly 300 lines. The vast majority of those
lines are domain-specific *math* (how to mutate a comparator sequence,
how to evaluate a truth table, how to compute avalanche). The
*shape* — what functions must exist, what they return, how the engine
calls them — is identical.

## Results across all three domains

Single binary, `general_inventor`, runs each domain via a CLI flag.

| Domain | Iterations | Seed | Verdict |
|---|---|---|---|
| `u64_mixer` | 8,000 | `0xABCDEF0123456789` | **INVENTION (strict)** |
| `sort_net` | 50,000 | `0xCAFEBABE12345678` | **INVENTION (strict)** |
| `boolean` | 200,000 | `0x1234567890ABCDEF` | **INVENTION (strict)** |

Each verdict reproduced in this session by the *same engine binary*
operating on different domain spec modules. The engine never read a
domain-specific line of code.

### Discovered artifacts

**u64-mixer:**
```
r4 = SPLITMIX_STEP(r0, r3, imm=0x8D029D8DD04F50B8)
r1 = SHL_XOR(r3, r0, imm=0x59BBEB12708C2E41)
r7 = ADD(r3, r4, imm=0x1013CDC291C52F69)
r7 = SPLITMIX_STEP(r7, r1, imm=0x97CD43D3D617AE3A)
```

**sort-net-N8:** A 22-comparator correct sorter, structurally divergent
from both Floyd-8 and Batcher-8. Persisted at
`results/general_inventor_champion.csv`.

**boolean (PARITY-4):**
```
g0 = a XOR d
g1 = g0 XOR b
g2 = g1 XOR c     (output)
```
Computes `(((a XOR d) XOR b) XOR c) = a XOR b XOR c XOR d` = PARITY-4.
This is structurally distinct from the library's three canonical forms
(Tree, Cascade, AltTree).

## What the boolean domain taught us

The boolean parity-4 search needed ~10× more iterations than u64 mixers
to converge. The first run at 20K iterations plateaued at 10/16
truth-table matches without finding a correct implementation. At 200K
iterations the same engine, same seed family, found a correct circuit
quickly.

This is a real domain characteristic, not an engine flaw. Boolean gate
sequences have a much harsher fitness landscape than u64 mixers:
nearby gate-sequence edits can flip many truth-table bits at once. The
engine doesn't need to change; the iteration budget per domain does.

**A general framework surfaces facts like this that domain-specific
code obscures.** With three separate inventors we'd have noticed three
separately-tuned iteration budgets and shrugged. With one engine over
three Specs the variance attaches to the *domain*, where it belongs.

## Search-strategy meta-domain status

The next self-application experiment exists as
`src/adapters/domain_search_strategy.zig` and
`src/adapters/search_strategy_meta.zig`. It treats an engine strategy as
the program:

```text
(mutation_rate, crossover_rate, pool_size, t_start, cooling_exponent, restart_period,
 parent_selection, replacement_policy, acceptance_policy, cooling_schedule)
```

This seam is real engineering, but it has not produced a supported
self-improvement claim. The first four-case `4/4 vs 3/4` result was
rejected as invalid because it used `n=4`, trained and tested on the
same seeds, used starved budgets, and relied on uncalibrated novelty
thresholds.

The current harness uses:

- 24 total `(domain, seed)` cases.
- 8 train, 8 validation, 8 test.
- train-only meta-search selection.
- held-out validation/test reporting.
- paired bootstrap confidence intervals.
- calibrated strategy-distance thresholds.

Latest scaled smoke result at `--budget-scale=0.02`:

| Split | Baseline strict hits | Meta champion strict hits | Delta |
|---|---:|---:|---:|
| train | 7/8 | 7/8 | 0.0000 |
| validation | 4/8 | 6/8 | 0.2500 |
| test | 5/8 | 6/8 | 0.1250 |

The champion was outside the calibrated library-distance floor and
improved raw held-out validation/test hit rate in this scaled run. The
runner still printed `claim_status=unresolved` because the test
bootstrap CI lower bound crossed zero and the run used
`budget_scale=0.02`, not the full calibrated budgets. Full-budget
self-improvement remains unproven. The detailed research note is in
`docs/search_strategy_meta.md`, with CSV artifacts in
`results/search_strategy_meta.csv`, `results/search_strategy_cases.csv`,
and `results/search_strategy_champion.csv`.

There is also a recursive promotion runner,
`src/adapters/recursive_engine_loop.zig`. It starts from the
train-selected canonical strategy, searches for a candidate replacement,
tests that candidate against the incumbent on held-out validation/test
splits, and promotes only when the held-out gate passes. Scaled runs are
dry runs; only `--budget-scale=1.0` can produce a supported promotion.
This is the current implementation of the "loop of newer and better
invention engines" idea, but it remains bounded by the battery domains
and does not prove universal all-domain invention.

Latest scaled recursive run:

```bash
./zig-out/bin/recursive_engine_loop --generations=4 --meta-iters=32 --pool=24 --budget-scale=0.02
```

It ran four generations and rejected all promotions. The candidates were
outside the calibrated library-distance floor, and one reached `8/8`
train strict hits, but none improved held-out validation/test enough to
promote:

| Generation | Train delta | Validation delta | Test delta | Decision |
|---:|---:|---:|---:|---|
| 1 | 0.0000 | 0.0000 | -0.2500 | rejected |
| 2 | 0.0000 | -0.1250 | -0.2500 | rejected |
| 3 | 0.0000 | -0.1250 | -0.2500 | rejected |
| 4 | 0.1250 | 0.0000 | 0.0000 | rejected |

The final incumbent stayed `vanilla_sa` with train `7/8`, validation
`4/8`, and test `5/8` strict hits at `budget_scale=0.02`. The loop
therefore proved conservative promotion behavior, not recursive
improvement.

## Files

- `src/adapters/invention_engine.zig` — the generic engine
- `src/adapters/domain_u64_mixer.zig` — u64-mixer Spec module
- `src/adapters/domain_sort_net.zig` — sorting-network Spec module
- `src/adapters/domain_boolean.zig` — boolean function Spec module
- `src/adapters/domain_search_strategy.zig` — search-strategy meta Spec
- `src/adapters/search_strategy_meta.zig` — held-out meta-search runner
- `src/adapters/recursive_engine_loop.zig` — evidence-gated recursive
  engine-promotion loop
- `src/adapters/general_inventor.zig` — unified driver binary
- `docs/domain_spec.md` — this file
- `docs/search_strategy_meta.md` — self-application research status

## Build and run

```
zig build -Doptimize=ReleaseFast

./zig-out/bin/general_inventor --domain=u64_mixer --iters=8000   --seed=ABCDEF0123456789
./zig-out/bin/general_inventor --domain=sort_net  --iters=50000  --seed=CAFEBABE12345678
./zig-out/bin/general_inventor --domain=boolean   --iters=200000 --seed=1234567890ABCDEF
```

## Where this lands against the strict definition

Recap of the criteria for "we have an invention engine that can invent
anything given basics":

| Criterion | Status |
|---|---|
| Operational, falsifiable invention test | ✅ Verdict ladder |
| Engine reliably produces INVENTION in one domain | ✅ 20/20 u64-mixer, 20/20 sort-net |
| Engine produces INVENTION in multiple distinct domains | ✅ Three domains (mixer, sort, boolean) all pass |
| Same engine code across domains | ✅ Comptime-generic `Engine(Spec)` |
| New domain is a spec module, not a fork | ✅ Three Spec modules, one engine |
| Engine takes domain "as data" with no recompilation | ⚠ Domain selection at compile time (Zig comptime). True data-driven loading would require switching to a dynamic dispatch or scripting interface — a different language-level decision. |

The penultimate row is the bounded property being tested: *give the
engine the basics for a new domain, it invents in that domain*. That
property has current evidence across three finite program-like Spec
modules. It is not a theorem over every possible domain, and it does
not cover domains that cannot be represented cleanly by the current
Spec contract. The final row notes a separate engineering gap: domain
selection is at *compile time* (Zig generics resolve statically), not
*runtime* via, say, a config file.

## Honest scope statement

What we have proven:
- One engine, three structurally different domains, three INVENTION
  (strict) verdicts.
- Functional-divergence and structural-divergence axes both flow
  through the same engine code unchanged.
- The interface contract was *derived from* the two existing instances
  (u64 mixers + sorts) and then validated by a third (boolean) — the
  abstraction survived contact with a new instance.

What we have not yet proven:
- Universal all-domain invention.
- Self-improvement. The search-strategy meta-domain is currently a
  held-out falsification harness and its latest scaled run is
  unresolved.
- Generality to domains with non-program structure (e.g., proof search,
  graph algorithms with unbounded state, learned-parameter models). The
  current Spec assumes a finite-length program-like representation.
- Reachability for domains where "composition" itself is not well
  defined as ordered concatenation.
- Robustness across radically different program-search topologies
  (e.g., differentiable spaces would need a different engine, not just
  a different spec).

The architectural pattern is empirically validated; its outer limits
are not yet mapped. The next research step is to try a domain whose
program representation is *unbounded* or *graph-shaped* — that is the
real test of the interface's outer envelope.
