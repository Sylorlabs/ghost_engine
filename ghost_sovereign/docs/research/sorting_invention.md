# Sorting-Network Invention — Cross-Domain Validation

Status: built, run, INVENTION (strict) verdict obtained, 20/20 reproducibility. 2026-05-20.

## Why this exists

To answer the strict question: does the invention-engine methodology
generalize beyond u64 mixers, or is the u64-mixer result a happy
accident of one particularly well-shaped domain? This is the
second-domain instance — sorting networks for N=8 elements — chosen
specifically because it is *structurally* very different from u64 mixers
in every layer except the search engine:

| Layer | u64 mixers | Sorting networks N=8 |
|---|---|---|
| I/O type | `u64 → u64` | `[8]u8 permutation → [8]u8 sorted` |
| Operators | 10 hand-picked arithmetic ops | 28 compare-exchange `(i,j)` pairs |
| Quality | avalanche, balance, chi-square, period | exact correctness over all 8! = 40,320 permutations |
| Library | splitMix64, Murmur, xorshift, Wang | Floyd-8, Batcher-8 (both 19 comparators) |
| Divergence axis | **functional** (different output function) | **structural** (different comparator sequence) |
| Reachability | function-composition functional similarity | library-window structural edit distance |

The divergence-axis switch is the deepest test: for sorts, *every* correct
sorter computes the same function. So functional similarity = 1.0 for all
correct sorters and cannot be the divergence axis. The methodology must
shift to *structural* divergence (comparator sequence edit distance) and
*structural* reachability (does the candidate appear as a contiguous
window in any depth-k concatenation of library networks?).

## Files

- `src/adapters/sorting_inventor.zig` — SA-based search over comparator sequences
- `src/adapters/sorting_reachability_tester.zig` — quality + structural divergence + reachability
- `scripts/sorting_reproducibility.sh` — N-seed batch reproducibility runner
- `results/sorting_champion.csv` — most recent persisted champion
- `results/sorting_reproducibility/aggregate.csv` — N-seed batch results
- `results/sorting_reproducibility/champion_*.csv` — each champion's comparator sequence

## Verdict ladder (sorting domain)

| Verdict | Trigger |
|---|---|
| EQUIVALENT (structural) | `edit_dist == 0` to a library network |
| TRIVIAL VARIANT | `edit_dist <= 1` to a library network (and correct) |
| NON-SORTER | `correctness < 1.0` (fails on at least one of 8! permutations) |
| REMIX | `norm_edit <= 0.20` to a library network |
| REACHABLE | appears as a contiguous window in some depth ≤ 3 library concatenation (`norm_edit <= 0.10`) |
| **INVENTION (strict)** | correct sorter + structurally divergent + not reachable |

## Sanity layer

| Candidate | Correctness | Size | norm_edit | Verdict |
|---|---|---|---|---|
| `floyd_self` | 1.000000 | 19 | 0.000 | EQUIVALENT (structural) |
| `batcher_self` | 1.000000 | 19 | 0.000 | EQUIVALENT (structural) |
| `random_net` | 0.028000 | 22 | 0.792 | NON-SORTER (fails correctness) |

The library entries verify to 1.0 exact correctness over all 40,320
permutations. Random comparator sequences sort ~2.8% of permutations
(near baseline). The ladder discriminates correctly across all three
sanity cases.

## A real bug found during library encoding

The first attempt at encoding Bitonic-8 (24 comparators) failed
self-test at 0.200000 correctness — sorts only 20% of permutations.
The encoded comparator sequence did not actually implement the
bitonic-merge structure correctly. This is a methodological win for
the test infrastructure: the self-test caught the bug immediately
before any results were drawn from it. Bitonic-8 was replaced with
Floyd-8 (Knuth's 19-comparator optimal-known network), which
verified at 1.0. **A library entry that fails self-test cannot be
used; the test enforces this automatically.**

## Reproducibility result (N=20)

`./scripts/sorting_reproducibility.sh 20 50000`:

| Verdict | Count |
|---|---|
| INVENTION (strict) | **20 / 20** |
| NON-SORTER | 0 / 20 |
| other | 0 / 20 |

Every run produced a discovered network that:
- sorts all 40,320 permutations of 8 elements (exhaustive verification)
- is structurally divergent from both library entries (norm_edit ≥ 0.7)
- does not appear as a window in any depth ≤ 3 library concatenation

Size distribution across 20 champions:

| Size | Count |
|---|---|
| 20 | 1 |
| 21 | 3 |
| 22 | 8 |
| 23 | 6 |
| 24 | 1 |
| 25 | 1 |

Spot-check of comparator sequences from runs 1, 5, 11, 15, 20 shows
they are mutually distinct: different opening comparators, different
mid-sequence structure, different sizes. The inventor is producing
many different correct sorters, not converging on one fixed result.

## Honest caveats on the strict claim

1. **Sub-optimal by size.** The discovered networks range 20–25 comparators;
   the optimal-known size for N=8 is 19. The invention claim is "correct
   sorter that is structurally divergent from canonical library and not
   library-reachable" — *not* "optimal sorter." A Gen2 inventor that
   targets both correctness AND optimality jointly is the natural next
   move for this domain.
2. **Library is 2 networks.** Adding more known-correct sorters
   (Bose-Nelson, Green's optimal, AKS-derived networks for small N)
   would tighten the reachability claim further.
3. **Reachability is structural, not algebraic.** A future stronger
   version would test "is the candidate algebraically equivalent to a
   library composition?" — accounting for comparator reorderings that
   don't change function (independent comparators commute). The current
   test treats `(0,1) (2,3)` and `(2,3) (0,1)` as edit-distance 2 from
   each other; algebraically they are identical. Implementing the
   stronger test requires a comparator commutation graph.

## What this validates for the broader project

Combined with the u64-mixer Gen1 result, we now have empirical evidence
that the invention-engine methodology — SA over candidate space, with a
quality gate, a canonical library, a reachability search, and a
verdict ladder — produces INVENTION (strict) artifacts in at least two
domains with very different I/O types, operator sets, quality functions,
and divergence axes.

**The pattern is now justified by data, not speculation, as the basis
for a `DomainSpec` refactor.** The next step is to extract the common
interface from these two concrete instances and let the same engine
binary accept arbitrary domains as data.

## Build

```
zig build -Doptimize=ReleaseFast
./zig-out/bin/sorting_inventor --iters=50000 --seed=CAFEBABE12345678
./zig-out/bin/sorting_reachability_tester
./scripts/sorting_reproducibility.sh 20 50000
```
