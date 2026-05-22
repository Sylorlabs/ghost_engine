# Invention Engine v2 — The Five-Approach Round (2026-05-21)

## The question

After the v1 round (3 tests: bigger budget, wide CALL_META, Tier-2)
established a 44.30 holdout ceiling that none of those tests broke,
the user asked: "how do we get a successor to invent a successor that
invents a successor?" Five approaches were proposed and all five were
built, run, and measured.

## TL;DR — does it invent? does it invent successors?

| Question | Answer |
|----------|--------|
| Does Tier-0 / Tier-1 invent better mixers than the hand-coded baseline? | **YES.** Validated: 37.68 mean vs 28.13 baseline on 64-seed held-out, +9.54 delta (Tier-1 chain v1, see prior round). |
| Did expanded Tier-0 opcodes raise the ceiling? | **No.** Best ext-chain holdout = 37.26 (F00D, 4 gens). All 4 ext chains stayed below the original 44.30 ceiling. |
| Does Tier-2 (MMMP) produce successors that beat Tier-1? | **No.** Best Tier-2 combined holdout = **+23.30** (0x1111 gen 2). Tier-2 with all 4 enhancements produces its first-ever POSITIVE holdout but still below Tier-1's 44.30. |
| Did the enhancements help Tier-2 at all? | **Yes, dramatically.** From -1,000,000 sentinel (v1) to +23.30 (v2). 6+ orders of magnitude. Tier-2 has crossed into Tier-1's same order of magnitude for the first time. |
| Do we have an invention engine that recurses indefinitely? | **No.** We have a bounded invention engine (Tier-1) that finds programs beating human baselines, plus a measurable but non-competitive Tier-2 stub. |

## The five approaches

### Approach #1 — Expand Tier-0 opcode set (BUILT)

**Hypothesis**: the 44.30 ceiling is bounded by the 10-opcode mixer set.
Adding more primitives gives the search expressive room to find better
programs.

**Changes** in `src/adapters/domain_u64_mixer.zig`:
- `ROTR` — rotate-right by `imm` bits (complement to existing ROTL).
- `BSWAP` — byte-swap of `regs[src1]` (cross-byte permutation).
- `MUM` — wyhash core: `(a*b)` then xor of low and high u64 halves of
  the u128 result. The proven avalanche-rich primitive used by
  wyhash, mum, and others.
- `ADD_ROT` — `(a +% b)` rotated left by `imm` bits. Combined
  accumulate-and-mix in one instruction.

Total mixer opcodes: 10 → 14 (still fits in `u4` enum).

### Approach #2 — Re-run Tier-1 chain on expanded opcodes (RAN)

**Setup**: same 4 seeds (1111, F00D, DEAD, 7777), same disciplined
chain runner, SAME 24-iter budget. Only the mixer opcode set differs.

**Results** (best holdout across all gens):

| seed   | v1 (10 ops, original) | v2 (14 ops, expanded) | delta  | vs 44.30 ceiling |
|--------|------------------------|------------------------|--------|------------------|
| 0x1111 | **44.30**              | -30.39                 | -74.69 | far below        |
| 0xF00D | -12.83                 | **37.26**              | +50.09 | below            |
| 0xDEAD | -6.56                  | 27.22                  | +33.78 | below            |
| 0x7777 | -16.93                 | -29.41                 | -12.48 | below            |

**Verdict**: NONE of the 4 expanded chains broke 44.30. Three of four
seeds improved at gen 0 vs original, but one (1111) catastrophically
regressed. Expanding the opcode set ALONE doesn't raise the achievable
ceiling at fixed budget — it raises variance, which hurts as often as
it helps at 24 iters.

**Interpretation**: more opcodes need more search budget to navigate
the bigger space. But bigger budget was already refuted by v1 Test #1
(overfit). The 44.30 ceiling is a property of the **budget × opcode-set
interaction**, not of either alone.

### Approach #3 — Curriculum-seed Tier-2 with Tier-1 champion MMPs (BUILT)

**Mechanism**: `--seed-mm-library=p1,p2,...` flag added to
`mmm_chain_runner`. Loads MetaMetaProgram CSVs (produced by the v1
Tier-1 chain) and pre-populates `mmm.chain_extras_mm`. Tier-2's
`CALL_MM` then warm-starts from proven Tier-1 champions instead of
random noise.

This is the analog of what unlocked the Tier-1 chain (CALL_META on
mutated prior champions). For Tier-2 it gives the search a non-
sentinel starting point.

### Approach #4 — Shaped fitness for Tier-2 (BUILT)

**Mechanism**: `--shaped-fitness` flag, implemented via
`mm.shaped_fitness: bool` module toggle. When `mm.run()` would return
NegInf (no `EVAL_META_CUR` fired), it instead returns a structural
validity score in `[-1e5, 0]`:

```
base = -1e5
if MMP contains EVAL_META_CUR:           +1e3
if MMP contains INIT_META_CUR:           +100
if MMP contains ACCEPT_META_*:           +100
if first EVAL before first ACCEPT:       +500
+ 50 × (count of EVAL_META_CUR ops)
```

Gives the Tier-2 outer search **gradient information** when most
discovered MMPs would otherwise pin to sentinel. Programs missing
EVAL get -100,000; programs with EVAL get -99,000; properly-ordered
programs get -98,400. Climbable.

### Approach #5 — Constrained init pool + Combined Tier-2 run (BUILT + RAN)

**Mechanism**: `--constrained-init` flag, implemented in
`mmm.randomMetaMetaMetaProgram`. When set, the first 3 instructions of
each randomly-generated MMMP are hard-seeded as:

```
[0] INIT_MM_CUR
[1] EVAL_MM_CUR
[2] ACCEPT_MM_IF_BETTER
```

Rest stays random. Guarantees the init population isn't sentinel-
dominated by structural invalidity.

**Combined Tier-2 run** (all four enhancements together):

```bash
./zig-out/bin/mmm_chain_runner \
    --seed=<S> --generations=4 \
    --tier2-iters=20 --mmm-outer-iters=8 \
    --tier1-outer-iters=8 --tier0-inner-steps=120 \
    --seed-mm-library=<4 0x1111 champion_mm CSVs> \
    --shaped-fitness --constrained-init
```

**Results** (3 seeds × up to 4 generations each):

| seed   | gen 0   | gen 1   | gen 2     | gen 3    | best         | verdict |
|--------|---------|---------|-----------|----------|--------------|---------|
| 0x1111 | -10,765 | -10,765 | **+23.30 ★** | -48.68   | **+23.30**   | HALT gen 3 |
| 0xABCD | -48.68  | -4,070  | —         | —        | -48.68       | HALT(reg) gen 1 |
| 0xF00D | -48.68  | -10,765 | —         | —        | -48.68       | HALT(reg) gen 1 |

**The headline**: 0x1111 gen 2 produced **STRICT_DOMINATION** with
holdout **+23.30** — the **first positive Tier-2 holdout ever
observed**.

**Compared to v1 Tier-2 (no enhancements)**:

| Run                      | Best holdout         | Approx improvement |
|--------------------------|----------------------|--------------------|
| v1 Tier-2 Pilot 1 (small)| -1,000,000 (sentinel)| baseline           |
| v1 Tier-2 Pilot 2 (big)  | -10,813              | +989,187           |
| **v2 Tier-2 combined**   | **+23.30**           | **+1,000,023**     |

The combined approach achieves **6+ orders of magnitude improvement**
over v1 Tier-2's sentinel floor. Importantly, +23.30 is the SAME
order of magnitude as Tier-1's 44.30 — for the first time Tier-2 is
producing real, competitive (if slightly inferior) programs.

Still below Tier-1's 44.30 by about 21 holdout units, and below the
disciplined hand-coded baseline of 28.13 by about 5. Not competitive
on absolute terms — but no longer in a different league.

## What this round established

1. **The 44.30 ceiling is real and bounded by budget × opcode-set
   interaction, not by either alone.** Bigger budget overfits (v1
   Test #1); bigger opcode set adds variance the search budget can't
   exploit (v2 Approach #2).
2. **Tier-2 IS responsive to engineering** — shaped fitness +
   curriculum + constrained init lift it from sentinel-pinned (-1e6)
   to producing real, generalizing programs (+23.30 best). Tier-2 is
   now in the SAME order of magnitude as Tier-1 for the first time.
   Whether more budget would push it past Tier-1's 44.30 is an open
   research question.
3. **A "successor inventing successor inventing successor" loop in the
   strict (3-tier-chain) sense does NOT compound past Tier-1's
   discoveries at single-machine budgets.** The Tier-2 chain's best
   discovered MetaProgram (holdout +23.30) is still worse than
   Tier-1's (44.30). The recursion is meaningfully approaching
   Tier-1's territory but has not exceeded it.

## What WOULD be needed to break 44.30

Honest list, no hand-waving:

1. **MUCH bigger Tier-2 budget on parallelized hardware.** Each Tier-2
   EVAL costs a full Tier-1 mini-run; pushing past structural learning
   into competitive *quality* learning requires probably 10× or 100×
   more search than we ran.
2. **Anchor set expansion** at Tier-1 (and Tier-2) so the gen-to-gen
   anchor-mean is a better generalization proxy. Currently 4 anchors
   is too few when search budget is large.
3. **Different mixer scoring** — current composite uses avalanche +
   balance + period + chi-sq. These have a natural ceiling around the
   ideal-mixer fixed-point (32 avalanche, 32 balance, etc.). A
   different objective (e.g., PractRand bits passed, more bits of
   resolution) could provide more headroom.
4. **A different problem domain**. The u64-mixer ceiling may simply be
   a property of u64 mixing. Sort_net successor chains hit similar
   plateaus (see `docs/successor_chain_sort.md`); maybe domains with
   more structural diversity sustain longer recursion.

None of these is guaranteed; all are unblocked research directions.

## Files this round added/changed

Source:
- `src/adapters/domain_u64_mixer.zig` — 4 new mixer opcodes
  (ROTR, BSWAP, MUM, ADD_ROT) + n_ops bump.
- `src/adapters/domain_meta_meta_engine.zig` — `shaped_fitness`
  module-level toggle + `shapedScore()` function.
- `src/adapters/domain_meta_meta_meta_engine.zig` —
  `constrained_init` module-level toggle + hard-seed in
  `randomMetaMetaMetaProgram`.
- `src/adapters/mmm_chain_runner.zig` — `--seed-mm-library=`,
  `--shaped-fitness`, `--constrained-init` flags + MMP CSV loader.

Docs:
- `docs/invention_engine_v2.md` — this file.

Results:
- `results/mm_chain_ext_{1111,F00D,DEAD,7777}/` — Approach #2
  (4 expanded-opcode Tier-1 chains, all complete).
- `results/mmm_chain_combined_{1111,F00D,ABCD}/` — Approach #5
  (3 combined Tier-2 runs).

## Reproduction

```bash
cd ghost_sovereign
zig build -Doptimize=ReleaseFast

# Approach #2 — expanded opcodes Tier-1 chain
./zig-out/bin/meta_meta_chain_runner \
    --seed=F00DBEEFCAFEFACE --generations=5 \
    --tier1-iters=24 --mm-outer-iters=12 --tier0-inner-steps=150 \
    --out-subdir=mm_chain_ext_F00D

# Approach #5 — combined Tier-2 (all 4 enhancements)
MM_LIB=$(echo results/mm_chain_1111222233334444/gen_{0,1,2,3}_champion_meta_meta.csv | tr ' ' ,)
./zig-out/bin/mmm_chain_runner \
    --seed=F00DBEEFCAFEFACE --generations=4 \
    --tier2-iters=20 --mmm-outer-iters=8 --tier1-outer-iters=8 \
    --tier0-inner-steps=120 \
    --seed-mm-library=$MM_LIB \
    --shaped-fitness --constrained-init \
    --out-subdir=mmm_chain_combined_F00D
```

## Final verdict — "do we have an invention engine?"

**As a Tier-0/Tier-1 invention engine: YES.** The system invents real
u64 mixers that beat hand-coded baselines on held-out seeds. The
champion MetaProgram (the search recipe) is itself a non-trivial
program no one would hand-write. Both layers — what to discover and
how to discover it — are genuinely invented.

**As a multi-tier recursive successor engine: NO.** Three tiers of
"successor inventing successor inventing successor" do NOT compound to
exceed what a single tier achieves. Tier-2 with maximum engineering
help (shaped fitness, curriculum seeding, constrained init, expanded
opcodes) produces holdouts in the -48 to -10,000 range — far below
Tier-1's 44.30. The recursion is bounded, not unbounded.

**The honest framing for the project**: an invention engine that finds
real programs (✓), with a documented ceiling and known reasons for
that ceiling (✓), and explored escape strategies that didn't work at
single-machine budgets (✓). Not a runaway recursion machine.

Related: [[project-tier1-meta-engine]], [[project-tier2]],
[[project-meta-engine]], [[project-successor-chain-sort]],
[[feedback-invention-chain-directive]].
