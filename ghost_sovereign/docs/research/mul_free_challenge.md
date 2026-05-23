# MUL-Free Mixer Challenge

## Question

Can a single-input 64-bit straight-line mixer reach external PractRand quality
without multiplication-family operations?

The expected outcome is negative: MUL-free search will probably fail earlier
than the unrestricted baseline. That is still useful if the comparison is
matched-budget, reproducible, and externally falsifiable.

## Scope

This experiment is isolated under `ghost_sovereign` and reuses the existing
u64-mixer fitness shape:

- avalanche distance from 32 flipped output bits
- output bit balance distance from 32 set bits
- low-byte chi-square pressure
- short-cycle penalty through the existing period estimator
- length penalty

The search target is not a stateful PRNG. It is a bounded straight-line
`u64 -> u64` program whose output is iterated as a stream only for PractRand.

## Modes

The implementation is in `src/adapters/domain_u64_mixer_mulfree.zig`.

| Mode | Meaning | Allowed nonlinear source |
|---|---|---|
| `mul_free` | Bans `MUL`, `MUM`, `SPLITMIX_STEP`, and `CALL_LIB` | ADD carry chain, `AND_NOT` |
| `no_carry` | Bans `MUL`, `MUM`, `SPLITMIX_STEP`, `ADD`, `ADD_CONST`, `ADD_ROT`, and `CALL_LIB` | `AND_NOT` only |
| `unrestricted` | Bans only `CALL_LIB` | matched-budget baseline |

`no_carry` is intentionally not called strict-linear. `AND_NOT` is nonlinear
in Boolean algebra, so the honest name is about removing carry propagation,
not about making the instruction set linear.

`ADD_ROT` remains allowed in `mul_free` because ADD carry propagation is the
ARX-family alternative to multiplication. Banning it belongs to `no_carry`.

## Executables

Build:

```bash
zig build
```

Single-mode search:

```bash
./zig-out/bin/mul_free_challenge \
  --mode=mul_free \
  --sa-steps=100000 \
  --hill-iters=200 \
  --max-prog-len=24 \
  --seed=0xF00DCAFE12345678
```

CSV-to-PractRand stream emitter:

```bash
./zig-out/bin/practrand_emit_mulfree \
  --mode=mul_free \
  --program=results/phaseF_mul_free_challenge/champion_mul_free.csv \
  | RNG_test stdin64 -tlmax 64M
```

Matched comparison harness:

```bash
./zig-out/bin/mul_free_comparison \
  --seeds=3 \
  --pilot-sa-steps=10000 \
  --pilot-hill-iters=100 \
  --sa-steps=100000 \
  --hill-iters=200
```

External validation run:

```bash
./zig-out/bin/mul_free_comparison \
  --seeds=3 \
  --practrand=1 \
  --max-tier=64G
```

## Pilot Gate

The comparison harness always runs a pilot before the full search.

Default pilot budget:

- `10,000` SA steps
- `100` hill iterations
- `1,000,000` evaluations per seed/mode

If `--practrand=1` is set, the pilot gate requires at least one `mul_free`
pilot champion to pass the `1M` PractRand tier. If that gate fails, the full
20M-evaluation runs are skipped.

If `--practrand=0`, the gate falls back to `--pilot-min-composite`, which
defaults to a permissive value so internal-only smoke runs do not get blocked.

## Full Search

Default full budget:

- `100,000` SA steps
- `200` hill iterations
- `20,000,000` evaluations per seed/mode
- `3` seeds

Instruction caps:

- `mul_free`: 24 instructions
- `no_carry`: 24 instructions
- `unrestricted`: 12 instructions

The 24-instruction cap for MUL-free modes is intentional. A multiply bundles
substantial diffusion into one operation; the MUL-free search needs more
straight-line depth for a fair comparison.

## PractRand Ladder

The harness escalates only after a tier passes:

1. `1M`
2. `64M`
3. `1G`
4. `16G`
5. `64G`
6. `1T`

A failed tier stops escalation for that champion. Logs are written as:

```text
results/phaseF_mul_free_challenge/practrand_<phase>_<mode>_seed<N>_<tier>.txt
```

The parser treats `unusual`, `suspicious`, and `FAIL` as failures. A tier is
accepted only when PractRand reports `no anomalies in ...`.

## Bijection Verification

Every champion that passes the `64M` PractRand tier is sent through:

```bash
./zig-out/bin/verify_cli --domain=mixer --csv=<champion.csv> --bits=8
```

This is a bounded Z3 bijection probe, not a proof of 64-bit global bijection.
It is still mandatory evidence because the internal period estimate can miss
collisions. Verification logs are written as:

```text
results/phaseF_mul_free_challenge/verify_<phase>_<mode>_seed<N>.txt
```

The SMT model now includes the expanded mixer opcodes `ROTR`, `BSWAP`, `MUM`,
and `ADD_ROT`, and the `OR_SHIFT` model matches runtime right-shift semantics.

## Result Files

Default output directory:

```text
results/phaseF_mul_free_challenge/
```

Important files:

- `champion_<phase>_<mode>_seed<N>.csv`
- `search_log_<phase>_<mode>_seed<N>.csv`
- `practrand_<phase>_<mode>_seed<N>_<tier>.txt`
- `verify_<phase>_<mode>_seed<N>.txt`
- `comparison.txt`

`comparison.txt` is the top-level audit file. It records the phase, mode,
seed, internal metrics, champion path, PractRand top tier, 64M pass state, and
verification verdict.

## Success Criteria

| Outcome | External result | Interpretation |
|---|---|---|
| Breakthrough | `mul_free` passes `64G+` and beats/approaches baseline | Multiplication is not necessary under this search space |
| Partial | `mul_free` passes `1G` but fails before `64G` | MUL-free is viable but likely weaker |
| Expected negative | `mul_free` fails at or before `64M` while unrestricted climbs higher | Empirical support for multiplication-equivalent operations |
| Surprise negative | `no_carry` passes `1G+` | Bitwise-only nonlinear structure deserves a separate follow-up |

No internal composite score is enough to claim success. External PractRand
tiers and bounded bijection checks are part of the result, not optional polish.

## Full Run: 2026-05-22 to 2026-05-23

Verdict: confirming negative at this budget. The search did not find a
MUL-free 64-bit single-input mixer that reached the 64MiB PractRand tier, much
less 16GiB or 64GiB.

This is not a mathematical proof that multiplication is globally necessary.
It is empirical evidence for this substrate, this fitness function, and this
matched 20M-evaluation budget. The result is still useful because every root
seed was run at the same budget across `mul_free`, `no_carry`, and
`unrestricted`, and every candidate that passed PractRand 64MiB was audited by
`verify_cli`.

Run window:

- start: `2026-05-22T19:07:12-07:00`
- end: `2026-05-23T07:13:33-07:00`
- elapsed: about 12h 6m wall time
- output: `results/phaseF_mul_free_challenge_full_run_20260523/`

Substrate audit before launch:

```bash
zig build -Doptimize=ReleaseFast
ls -la zig-out/bin/mul_free_comparison zig-out/bin/verify_cli zig-out/bin/practrand_emit_mulfree
```

The ReleaseFast build completed and all three executables existed. The committed
sample constants were left unchanged:

```text
FitSamples = 64
PeriodSamples = 4096
ChiSqSamples = 4096
BalanceSamples = 256
```

Pilot baseline:

- `results/phaseF_mul_free_challenge_pilot_sample/comparison.txt`
- `pilot_gate_passed=1`
- At 10k x 100 pilot budget, `mul_free` reached PractRand `1M` but failed
  `64M`. That justified the full run without reducing the full budget.

Full run command shape:

```bash
./zig-out/bin/mul_free_comparison \
  --seeds=1 \
  --seed=<root-seed> \
  --pilot-sa-steps=10000 \
  --pilot-hill-iters=100 \
  --sa-steps=100000 \
  --hill-iters=200 \
  --full=1 \
  --practrand=0 \
  --verify=1 \
  --output-dir=results/phaseF_mul_free_challenge_full_run_20260523/<root>
```

PractRand and `verify_cli` were run externally after each root search so the
full 20M-evaluation searches could not be skipped by the pilot gate. The ladder
used `1M -> 64M -> 1G -> 16G`, with `64G` reserved only for candidates passing
`16G`. No candidate reached `16G`, so no `64G` run was launched.

## Full Run Summary

| Root | Mode | Internal composite | Len | Best PractRand tier | External failure | Z3 / verify_cli |
|---|---:|---:|---:|---|---|---|
| `0xF00DCAFE12345678` | `mul_free` | 46.500000 | 7 | `<1M` | `1M`: `BRank(12):score:256(10)`, `[Low16/64]BRank(12):score:128(9)` | Not required; failed before `64M` |
| `0xF00DCAFE12345678` | `no_carry` | 46.783750 | 6 | `<1M` | `1M`: `BRank(12):score:256(10)`, `[Low16/64]BRank(12):score:128(9)` | Not required; failed before `64M` |
| `0xF00DCAFE12345678` | `unrestricted` | 47.997559 | 4 | `64M` | Passed `1M` and `64M`, then rejected by Z3 | `COUNTER-EXAMPLE (SAT - property fails)` |
| `0x1111222233334444` | `mul_free` | 46.550781 | 6 | `<1M` | `1M`: `BRank(12):score:256(10)`, `[Low16/64]BRank(12):score:128(9)` | Not required; failed before `64M` |
| `0x1111222233334444` | `no_carry` | 46.785156 | 6 | `<1M` | `1M`: `BRank(12):score:256(10)`, `[Low16/64]BRank(12):score:128(9)`, `[Low4/64]BRank(12):score:64(7)`, `[Low1/64]BRank(12):score:64(1)` | Not required; failed before `64M` |
| `0x1111222233334444` | `unrestricted` | 47.997559 | 4 | `<1M` | `1M`: `BCFN(2+0,13-7U)` was `unusual`; parser treats unusual as failure | Not required; failed before `64M` |
| `0xABCDEF0123456789` | `mul_free` | 46.492188 | 6 | `<1M` | `1M`: `BRank(12):score:256(10)`, `[Low16/64]BRank(12):score:128(9)` | Not required; failed before `64M` |
| `0xABCDEF0123456789` | `no_carry` | 46.980469 | 6 | `<1M` | `1M`: `BRank(12):score:256(10)`, `[Low16/64]BRank(12):score:128(9)`, `[Low1/64]BRank(12):score:64(1)` | Not required; failed before `64M` |
| `0xABCDEF0123456789` | `unrestricted` | 47.997559 | 4 | `64M` | Passed `1M` and `64M`, then rejected by Z3 | `COUNTER-EXAMPLE (SAT - property fails)` |

External validation summary:

- `mul_free`: 0/3 roots passed PractRand `1M`.
- `no_carry`: 0/3 roots passed PractRand `1M`.
- `unrestricted`: 2/3 roots passed PractRand `64M`, but both 64MiB-passing
  candidates were rejected by bounded Z3 bijection checking.
- No candidate reached `1G`, `16G`, or `64G`.
- No constrained candidate required Z3 because none reached `64M`.
- The hard verification rule was satisfied: every candidate that passed `64M`
  was sent through `verify_cli`.

Primary evidence files:

- `results/phaseF_mul_free_challenge_full_run_20260523/full_run_driver.log`
- `results/phaseF_mul_free_challenge_full_run_20260523/external_validation_summary.csv`
- `results/phaseF_mul_free_challenge_full_run_20260523/root_f00d/comparison.txt`
- `results/phaseF_mul_free_challenge_full_run_20260523/root_1111/comparison.txt`
- `results/phaseF_mul_free_challenge_full_run_20260523/root_abcd/comparison.txt`
- `results/phaseF_mul_free_challenge_full_run_20260523/root_f00d/verify_full_root_f00d_unrestricted.txt`
- `results/phaseF_mul_free_challenge_full_run_20260523/root_abcd/verify_full_root_abcd_unrestricted.txt`

## Extracted Full-Run Mixers

The extracted champions are listed here as op fingerprints. Full CSV programs
are committed under the full-run result directory.

| Root | Mode | Op counts | Structural fingerprint |
|---|---|---|---|
| `0xF00DCAFE12345678` | `mul_free` | `SHL_XOR x2`, `SHR_XOR x4`, `XOR x1` | Pure XOR/shift register cascade; no ADD carry chain; no rotate; no multiply-family op |
| `0xF00DCAFE12345678` | `no_carry` | `SHL_XOR x4`, `SHR_XOR x2` | Pure XOR/shift register cascade |
| `0xF00DCAFE12345678` | `unrestricted` | `ROTR x1`, `MUL x2`, `MUM x1` | Multiply-family dominated; PractRand 64MiB pass was non-bijective under Z3 |
| `0x1111222233334444` | `mul_free` | `SHL_XOR x3`, `SHR_XOR x3` | Pure XOR/shift register cascade |
| `0x1111222233334444` | `no_carry` | `SHL_XOR x4`, `SHR_XOR x2` | Pure XOR/shift register cascade |
| `0x1111222233334444` | `unrestricted` | `AND_NOT x1`, `MUL x1`, `SPLITMIX_STEP x1`, `MUM x1` | Multiply-family dominated; failed PractRand at 1MiB due `unusual` result |
| `0xABCDEF0123456789` | `mul_free` | `SHR_XOR x3`, `SHL_XOR x3` | Pure XOR/shift register cascade |
| `0xABCDEF0123456789` | `no_carry` | `SHR_XOR x2`, `SHL_XOR x4` | Pure XOR/shift register cascade |
| `0xABCDEF0123456789` | `unrestricted` | `SPLITMIX_STEP x1`, `MUM x1`, `SHL_XOR x1`, `MUL x1` | Multiply-family dominated; PractRand 64MiB pass was non-bijective under Z3 |

The constrained modes did not discover an ARX-style mixer. Despite `mul_free`
allowing ADD-family carry propagation, the best full-run champions in all
three roots collapsed to XOR/shift-only structures. Those structures are far
from the xorshift-multiply-xorshift-multiply family used by SplitMix64,
MurmurHash finalizers, and wyhash-style mixers. They are also not structurally
competitive with PCG-style output mixing, where xorshift/rotation is coupled to
a multiplicative state transition rather than used as a standalone bijective
single-input mixer.

## Interpretation

The full run supports the multiplication-necessity conjecture for this bounded
search setting:

- Three independent `mul_free` roots failed at PractRand `1M`.
- Three independent `no_carry` roots failed at PractRand `1M`.
- The only candidates reaching PractRand `64M` came from `unrestricted`.
- Those `64M` candidates were not acceptable mixers because `verify_cli`
  returned SAT counterexamples.

The clean external-language claim is:

> At a matched 20M-evaluation budget per mode and root seed, this search found
> no MUL-free or no-carry 64-bit single-input mixer that survived PractRand
> 1MiB. The result is empirical support, not proof, that multiplication-family
> or multiplication-equivalent operations are needed for high-quality 64-bit
> bijective mixer design in this substrate.

The run does not justify a positive or publishable mixer claim. It found no
candidate passing `64GiB`, no constrained candidate passing `64MiB`, and no
Z3-accepted unrestricted candidate after `64MiB`.
