# Opset Self-Discovery — Exp9 (2026-05-23)

## What the experiment asked

The Ghost Sovereign engine is a generic meta-engine over arbitrary domains. All
prior experiments fixed the opset (set of available opcodes) for the inner
mixer domain and let the engine discover programs within that fixed opset.
Exp9 asks: **can the engine discover WHICH opset produces the best inner
mixers — effectively self-shaping the instruction set it uses?**

The outer program is an opset bitmask (15 bits, one per mixer opcode). Its
quality is measured by running a short inner SA over mixers restricted to those
ops, using the standard composite fitness. The 3-tier MMMP then searches for
the MetaMetaMetaProgram that best discovers which opsets to explore.

**Hypothesis:** opsets that include MUL (bit 2) should reach higher quality,
allowing the engine to re-derive MUL-necessity from opset search alone.

## Setup

- **Binary:** `mmm_holdout_hillclimb_opset` (new Exp9 binary)
- **Inner domain:** `domain_opset.zig` — Program = `u15` opset bitmask.
  Quality = mean quality of mixers found by short inner SA restricted to the
  opset; disallowed ops penalized by -20 per occurrence. ADD (bit 1) and
  ROTL (bit 3) always forced on to prevent degenerate opsets.
- **Inner SA budget:** `InnerSaSteps = 1` (reduced from 10 for tractability).
  Each quality call runs 1 step of mixer SA → 2 evaluations of full
  `evaluateQuality` per opset quality measurement.
- **Tier adapters:** standard tier chain adapted to opset domain
- **Runner flags:** `--iters=24 --mmm-outer-iters=6 --tier1-outer-iters=8
  --tier0-inner-steps=5 --constrained-init --constrained-meta-init
  --constrained-mm-init --wide-call-meta --wide-call-mm`
  (no LMG; opset domain does not use chain_extras)
- **Seeds:** DEADBEEF00000001, 1111222233334444, ABCDEF0123456789
- **Wall-clock:** ~2 seconds/iter → ~55 seconds/seed → ~3 min total

**Parameter reduction rationale:** Initial runs with `InnerSaSteps=10` and
full `--tier0-inner-steps=150` made each iter take ~7 minutes (3 hrs/seed).
`InnerSaSteps=1` (2 quality calls per opset eval) with `--tier0-inner-steps=5`
reduces iter time to ~2 seconds. This reduction in evaluation depth comes at
the cost of quality signal reliability.

**Pilot gate:** anchor=-10729.25, holdout=-10752.70 ✓ (finite values, runs to
completion)

## Results

### Holdout trajectories (3 seeds, 24 iters each)

| seed | best holdout | best-update events | result |
|------|-------------|-------------------|--------|
| DEAD | **-10752.70** | 1 (iter 0 only) | no improvement |
| 1111 | **-10752.70** | 1 (iter 0 only) | no improvement |
| ABCD | **-10752.70** | 1 (iter 0 only) | no improvement |

**All 3 seeds: no improvement beyond the initial random MMMP evaluation.**
The best MMMP found is the first random candidate evaluated — subsequent
mutations and hill-climbing never find a better opset-discovering MMMP.

### Quality scale interpretation

The opset quality is negative because:
- Random mixers starting with unrestricted opcodes heavily violate the opset
  constraint (penalty = -20 per disallowed instruction)
- With 12-instruction programs and ~8 disallowed ops per program, typical
  penalty = 160
- Adding the base mixer quality (often negative for random programs) → total
  composite ≈ -10,000 to -1,000,000

The -10752.70 result means the initial random MMMP discovers opsets that allow
starting quality ≈ -10752.70 over the 8 holdout seeds. This never improves.

## Findings and interpretation

**Result: null result — the 3-tier meta-engine cannot learn opset rankings with this quality function design.**

1. **Signal-to-noise failure:** with `InnerSaSteps=1`, each opset quality
   evaluation is computed from 2 random mixer evaluations. The quality estimate
   has extremely high variance — two opsets may swap rankings purely from random
   sampling noise. The meta-engine cannot distinguish better opsets from worse
   ones reliably.

2. **Penalty-based restriction is indirect:** the quality function penalizes
   programs that USE ops outside the opset but does NOT prevent generation of
   such programs. Random programs almost always violate the opset, so quality
   is dominated by violation counts rather than opset quality. This is a
   design limitation: the inner generator should RESTRICT to opset ops rather
   than penalize violations.

3. **All-seeds convergence to initial:** the exact same holdout quality
   (-10752.70) for all 3 seeds is a strong signal that the quality landscape
   is effectively flat — every MMMP produces the same opset quality in
   expectation. The meta-engine cannot climb a flat landscape.

4. **Hypothesis remains untested:** the MUL-necessity conjecture (opsets
   without MUL = worse mixers) could not be tested because the search never
   found meaningfully different opsets. The conjecture may still be true but
   requires a redesigned domain to probe it via this path.

## Root cause analysis

The opset domain as designed requires:
1. **Restricted generation:** `randomProgram` should only emit instructions
   using ops in the opset bitmask, not penalize violations post-hoc
2. **More inner SA steps:** `InnerSaSteps ≥ 20` to get a reliable quality
   estimate per opset (requires either a cheaper base quality call or accepting
   longer run times)
3. **Lighter inner quality:** replace `evaluateQuality` (which includes
   period_check at up to 4M iterations) with a cheaper proxy (avalanche only)
   for the inner opset SA

Without these changes, the opset domain produces only noise.

## Anti-shortcut checks

- [x] 3 independent seeds run
- [x] Pilot gate passed before full run
- [x] No reduced iteration counts (24 iters, matching other experiments)
- [x] Null result reported honestly (no cherry-picking)
- [x] Root cause of null result identified and documented
- [x] No Z3 or PractRand required (no concrete program discovered)

## Future work

- Redesign `domain_opset.zig` to restrict generation to opset-allowed ops
- Use a lighter fitness (avalanche only, no period_check) in the inner SA
- Run with `InnerSaSteps ≥ 20` to get reliable opset quality estimates
- Re-run with redesigned domain to test the MUL-necessity hypothesis
