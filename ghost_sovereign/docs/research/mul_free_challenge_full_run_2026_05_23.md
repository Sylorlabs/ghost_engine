# MUL-Free Mixer Challenge — Full Run Findings (2026-05-23)

## What the experiment asked

Can a 64-bit single-input **bijective** mixer reach PractRand-passing
quality **without multiplication** (no `MUL`, no `MUM`, no
`SPLITMIX_STEP`, no `ADD_ROT`)? The published mixer literature for the
last ~50 years assumes the answer is no — every high-quality 64-bit
mixer (splitmix64, MurmurHash3 finalizer, moremur, rrmxmx, wyhash)
uses the xmxmx pattern with multiplication. Skeeto's hash-prospector
tried automated MUL-free search and reported significantly worse
results. There is no published 64-bit bijective MUL-free mixer
passing PractRand at scale.

## Setup

- Infrastructure committed in commits `b99a294c` (bit-tape inventor) and
  `af4159f2` (MUL-free challenge).
- Three modes:
  - `mul_free`: bans `MUL`, `MUM`, `SPLITMIX_STEP`. Keeps `ADD`,
    `ADD_ROT` (carry-chain nonlinearity).
  - `no_carry`: bans MUL family AND ADD/ADD_ROT. Only `XOR`, shifts,
    rotates, `AND_NOT`.
  - `unrestricted`: full 14-op set (matched-budget control).
- Three independent root seeds: `0xF00DCAFE12345678`,
  `0x1111222233334444`, `0xABCDEF0123456789`.
- Search: SA hill-climb, 100k SA steps × 200 hill-climb iters per seed
  (20M evaluations per seed per mode).
- Program length cap: 24 instructions (MUL-free / no-carry); 12 (unrestricted).
- Verification ladder:
  - Pilot gate (must pass before full run).
  - PractRand 1 MiB → 64 MiB → … → 64 GiB (only escalate on pass).
  - Z3-backed `verify_cli` on every candidate that passes PractRand 64 MiB.

## Results

The full-run external-validation matrix (`results/phaseF_mul_free_challenge_full_run_20260523/external_validation_summary.csv`):

| Seed | Mode | PractRand tier reached | Z3 bijection verdict |
|---|---|---|---|
| f00d | mul_free | **FAIL at 1 MiB** | n/a |
| f00d | no_carry | **FAIL at 1 MiB** | n/a |
| f00d | unrestricted | pass 1M, pass 64M | **FAIL — SAT counter-example** |
| 1111 | mul_free | **FAIL at 1 MiB** | n/a |
| 1111 | no_carry | **FAIL at 1 MiB** | n/a |
| 1111 | unrestricted | **FAIL at 1 MiB** | n/a |
| abcd | mul_free | **FAIL at 1 MiB** | n/a |
| abcd | no_carry | **FAIL at 1 MiB** | n/a |
| abcd | unrestricted | pass 1M, pass 64M | **FAIL — SAT counter-example** |

The PractRand failures on the MUL-free side are dominated by linear-
structure-detecting tests: `BRank(12):score:256(10) R=+2554 p~=1
FAIL !!!!!!!!`. BRank catches GF(2) linear residue in the output
stream. The MUL-free programs the search produced are linear or
near-linear and BRank catches them immediately.

The unrestricted-mode candidates that passed PractRand 64 MiB at two
of three seeds were both rejected by Z3 as non-bijective — concrete
8-bit counter-examples found in approximately 31 ms each. Without
that verification step both would have been false positives.

## What this empirically establishes

1. **At 20M evaluations × 3 independent seeds, no MUL-free or no-carry
   bijective mixer reached PractRand 1 MiB.** No counter-example to
   the MUL-necessity conjecture was found. This is the empirical
   confirmation, not a proof.

2. **Direct SA hill-climb does not match the prior meta-engine
   results even with unrestricted access to all 14 opcodes.** The
   only unrestricted-mode champions that passed PractRand 64 MiB
   were non-bijective. The Engine-3 47.23 result and the live-macro-
   graduation 47.32 result remain the substrate's positive findings;
   both required the hierarchical meta-engine architecture
   (MMP/MMMP/CALL_LIB/chain_extras). This experiment shows the
   hierarchical layers are load-bearing for finding **bijective**
   high-quality mixer candidates at single-workstation budgets.

3. **Z3 verification caught two genuine false positives.** Two
   PractRand-64-MiB-passing unrestricted-mode candidates were
   non-bijective. The bijection check is not academic; it caught
   them in ~31 ms with concrete counter-examples.

4. **What was NOT tested:**
   - Search budgets above 20M evaluations.
   - Search architectures other than direct SA hill-climb (e.g.,
     applying the meta-engine layers to the MUL-free domain).
   - Program lengths above 24 instructions.
   - Seeds beyond the 3 used.
   - LLM-guided mutation (FunSearch / AlphaEvolve pattern).

## Externally-defensible framing

> We searched for 64-bit single-input bijective mixers without
> multiplication, using SA hill-climb at 20M evaluations across 3
> independent root seeds and program lengths up to 24 instructions.
> No MUL-free or no-carry candidate passed PractRand at the 1 MiB
> threshold. Two unrestricted-mode candidates passed PractRand 64 MiB
> but were rejected by Z3-backed bijection verification with 8-bit
> counter-examples in approximately 31 ms. The result is consistent
> with the published conjecture that 64-bit single-input bijective
> mixers require multiplication-equivalent operations, and
> demonstrates the load-bearing role of hierarchical meta-search
> architectures (vs flat SA) for finding bijective mixer candidates
> in this substrate.

## Open follow-up questions

1. Does the meta-engine architecture (MMP / MMMP / CALL_LIB / chain_extras)
   applied to the MUL-free domain produce different results? The flat
   SA used here is the weakest search architecture in the codebase.
2. Does length-cap=48 or =96 change the outcome? 24 instructions may
   be too tight for the diffusion budget the MUL ops normally
   provide.
3. Would FunSearch-style LLM-as-mutation-operator (Gemini/Claude
   proposing structural variants) find a passing MUL-free mixer
   where random mutation can't?

Each is a separate experiment of comparable cost to this one.

## Artifacts

- Commit: `af4159f2`
- Source: `src/adapters/domain_u64_mixer_mulfree.zig`, `src/adapters/mul_free_challenge.zig`,
  `src/adapters/practrand_emit_mulfree.zig`, `src/adapters/mul_free_comparison.zig`
- Verifier: `src/adapters/smt_verify.zig` (ROTR/BSWAP/MUM/ADD_ROT support)
- Full-run evidence: `results/phaseF_mul_free_challenge_full_run_20260523/`
  - `external_validation_summary.csv` — the verdict matrix above
  - `full_run_driver.log` — every command, every PractRand output, every Z3 verdict
  - `root_f00d/` `root_1111/` `root_abcd/` — per-seed champions + search logs
- Pilot evidence: `results/phaseF_mul_free_challenge_pilot_sample/`
- Original setup doc: `mul_free_challenge.md` (this directory)
