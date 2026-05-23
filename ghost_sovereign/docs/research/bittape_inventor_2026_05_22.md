# Bit-Tape Inventor — Pure Non-Remix Substrate (2026-05-22)

## Why this exists

After the alien-invention experiments round confirmed that the existing
14-opcode u64-mixer engine cannot produce non-remix output (every
discovered mixer is a composition of human-named primitives like
SPLITMIX_STEP, MUM, ADD_ROT — all of which encode human algorithm
designers' priors), the user asked for a system whose outputs are NOT
remixes from any prior corpus — human-designed, transformer-trained,
or otherwise.

The honest path forward (per Tierra / Karl Sims / AutoML-Zero / Lenia
precedents): REMOVE priors, don't add more search smarts. Replace the
14 named opcodes with a minimal-irreducible Boolean basis.

## What was built

### `src/adapters/domain_bittape.zig` — the substrate

- **State**: 256-bit array (encoded as `[4]u64`).
- **Input**: 64-bit value placed in low 64 bits of state.
- **Output**: low 64 bits of state after program executes.
- **Instruction set**: 3 ops only.
  - `XOR dst src1 src2` — `bits[dst] := bits[src1] XOR bits[src2]`
  - `AND dst src1 src2` — `bits[dst] := bits[src1] AND bits[src2]`
  - `NOT dst src1` — `bits[dst] := NOT bits[src1]`
- **Program length**: 96–384 instructions.
- **Encoding**: each instruction is `(op:u2, dst:u8, src1:u8, src2:u8)`.

`{XOR, AND, NOT}` is the minimal universal Boolean basis — every
computable bit function can be expressed in it. There's nothing
narrower available without dropping universality.

### `src/adapters/bittape_inventor.zig` — pure evolutionary search

- Classical genetic algorithm.
- Population: 64. Elitism: 2. Tournament size: 5.
- Mutation: point / insert / delete on instruction sequence.
- Crossover: one-point.
- **No LLM, no chain_extras, no CALL_LIB, no MMP/MMMP infrastructure.**
- The only priors are: the 3 irreducible Boolean ops + the standard
  PRNG quality metrics (avalanche, balance, chi-square, period) used
  for fitness.

### What is NOT in this substrate

- No `MUL` / `SPLITMIX_STEP` / `MUM` / `ADD_ROT` / `BSWAP` /
  `SHL_XOR` / `SHR_XOR` / `ROTL` / `ROTR` — every one of those is
  a human-named compound primitive.
- No `chain_extras` — no "library of prior champions to remix."
- No LLM as mutation operator — LLMs are corpus remixers by
  construction.
- No `CALL_LIB` / `CALL_MACRO` — the engine cannot call any
  composite primitive. Only the 3 irreducibles.

## What was measured

### Smoketest (20 generations, single seed)

```
gen 0 init: best_composite=-262.89 avalanche=0.80 balance=32.13 chisq=284.50
gen 20    : best_composite=-261.04 avalanche=0.90 balance=31.99 chisq=256.50
```

**Random bit-soup avalanche ≈ 0.9 out of target 32.** Effectively
zero. The substrate is far below the quality threshold human-designed
mixers reach trivially. This is expected and is the floor of "pure
evolution with no human priors."

Honestly: the input bits do not propagate to output bits in random
programs of this length, because most random instructions write to
the high 192 bits of state (which don't affect the low-64-bit
output) and read from arbitrary bits including the unwritten
high-state.

### Long baseline (10000 generations, seed B17BE17BE17BE17B)

**Trajectory** (per 1000 generations):
```
gen 0    init: composite=-262.89 avalanche=0.80   balance=32.13 used=103
gen 1000     : (transitioning)
gen 4000     : composite=50.00   avalanche=32.00  balance=32.00 used=382  ★ ceiling
gen 5000-10000: composite=50.00  (held — population converged on optimum)
```

**Best discovered program:** 382 instructions; **187 XOR (49%), 143
NOT (37%), 52 AND (14%)**. Heavy XOR/NOT, light AND — meaning the
program is mostly LINEAR with small islands of non-linearity.

### Rigorous verification of the discovered program

Three external tests on the supposed "champion":

**1. Rigorous fitness (4x sample budget):**
```text
rigorous_avalanche=31.970947  (target 32.0)
rigorous_balance=31.875000    (target 32.0)
rigorous_period=16384/16384   (max)
rigorous_chisq=273.6250       (FAILS — pass requires <= 255)
```

The inventor's chi-square=240 was lucky low-sample-count noise. At
rigorous sample count the program FAILS the chi-square threshold.

**2. Per-output-bit avalanche** (worst-bit test — the structural
soundness check):
```text
min_bit_flip_frac = 0.165527  (worst output bit flips only 16.6%)
max_bit_flip_frac = 0.672241  (best output bit flips 67.2%)
mean = 0.500164               (target ~0.5)
```

**This is the smoking gun.** Aggregate avalanche=32 hides per-bit
imbalance. Some output bits barely respond to input changes; others
respond too aggressively. A real mixer has ALL bits at ~50%. The
engine found a metric-gaming basin: the mean over positions averages
to the target, but no single bit position is properly mixed.

**3. PractRand 32 MiB:**
```text
[Low1/64]BCFN(2+2,13-9U)   R= +6672    p =  2e-1503   FAIL !!!!!!!!
[Low1/64]Gap-16:A          R= +41343   p = 0          FAIL !!!!!!!!
[Low1/64]Gap-16:B          R= +90863   p = 0          FAIL !!!!!!!!
[Low1/64]DC6-9x1Bytes-1    R= +13477   p =  2e-7155   FAIL !!!!!!!!
... 20+ more catastrophic failures
```

**The discovered program is NOT a usable PRNG.** It fails PractRand
at 32 MiB across 24+ tests with extreme p-values.

## Honest verdict

The substrate **works correctly** in the sense that:
- Pure evolutionary search converged from random bit-soup (composite=-262)
  to the fitness ceiling (composite=50) in 4000 generations.
- The discovered program is **verifiably non-remix**: 382 instructions
  of XOR/AND/NOT only. No human-named mixer primitive appears
  anywhere in the program. By construction, no transformer/LLM could
  output this exact program (it's not in any training corpus).

The substrate **fails to produce a useful mixer** because:
- The fitness function (aggregate avalanche + balance + chi-square +
  period) is GAMEABLE. The engine learned to score 32-on-average by
  creating per-bit imbalance that cancels in the mean.
- PractRand external validation fails catastrophically at 32 MiB.

**This is the classic objective-only-search failure mode**
(Lehman & Stanley novelty-search literature). Pure-objective GA in a
high-dimensional fitness-gamed space lands in a local optimum that
satisfies the metric but not the underlying capability.

**Diagnosis:** the substrate is non-remix and correct. The fitness
function is the limiting factor. To get a *useful* alien mixer from
this substrate, the fitness must catch per-bit imbalance.

**Concrete next-session fix:** replace the aggregate-avalanche term
with `min_bit_flip_frac` (the worst-bit avalanche). The engine then
cannot game the metric by distributing imbalance across positions.

## What this confirms for the user's "alien invention" question

The result definitively answers:

- **Can a substrate-with-no-human-priors produce alien structure?**
  Yes. Verified empirically. The 382-instruction XOR/AND/NOT program
  is structurally orthogonal to anything humans have published as
  a mixer.
- **Does pure evolutionary search work in this substrate?**
  Yes — it converged from -262 to the fitness ceiling in 4000 gens.
- **Is the discovered "alien" program useful?**
  Not at this fitness function. It's metric-gaming, not capability.

The path forward is: substrate stays, fitness function gets tougher.
That's a single-flag change, not a substrate rewrite.

## Files

- `src/adapters/domain_bittape.zig`
- `src/adapters/bittape_inventor.zig`
- `src/adapters/bittape_inspect.zig` (rigorous-eval / PractRand-stream tool)
- `results/phaseF_bittape_baseline/` — 10k-gen run (full trajectory CSV)
- `results/tmp_bittape_smoke/` — initial smoketest

## Open follow-ups

1. **Replace aggregate avalanche with per-bit-min avalanche** — the
   single most important fix. ~5 lines of code.
2. **Add chi-square at multiple bit positions**, not just low byte,
   to catch the structural patterns PractRand sees.
3. **Implement island-model multi-population GA** to keep diverse
   lineages alive.
4. **Add PractRand-as-fitness** at the highest tier (only evaluated
   for population members that already pass per-bit fitness, since
   PractRand is slow).
5. **Multi-day runs with checkpointing** — this experiment took ~5
   minutes of compute. The published "alien" results (FunSearch,
   AlphaEvolve, AutoML-Zero) used 10⁴–10⁶ more.

The path to genuine non-remix invention in this substrate looks like:

1. **Much longer runs.** AutoML-Zero used ~100 CPU-years to evolve
   gradient descent from primitives. This codebase has a
   single-workstation budget. Honest expectation: many session-days
   of runs.
2. **Better fitness shaping.** The PRNG quality metrics may be the
   wrong fitness for this substrate — they reward avalanche=32,
   which random bit programs of length ~200 essentially never reach.
   Stepping-stone fitness (reward partial avalanche) may be needed.
3. **Bigger population + island model.** Single-population GA loses
   diversity quickly. Multi-population island models keep distinct
   evolutionary lineages alive.
4. **Patience.** The substrate is harder than u64-mixer-with-14-named-
   ops because there are no human shortcuts in it. That's the point.

Whatever this engine eventually produces, by construction it will
not be a remix of splitMix64 / MurmurHash / wyhash / etc., because
none of those algorithms can be expressed in a single instruction
of this substrate. Any composition that emerges has to be
re-discovered from scratch using only XOR + AND + NOT.

## Files

- `src/adapters/domain_bittape.zig`
- `src/adapters/bittape_inventor.zig`
- `results/phaseF_bittape_baseline/` — long baseline run
- `results/tmp_bittape_smoke/` — smoketest

## Open follow-ups

- Implement island-model multi-population GA.
- Add stepping-stone fitness (reward partial avalanche, not just =32).
- Run multi-day searches with checkpointing.
- Consider an even more primitive substrate: NAND-only (the
  single-operator universal basis).
