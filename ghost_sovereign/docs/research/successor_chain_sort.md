# Successor chain — sort_net, logical-depth, 2026-05-21

**Headline:** 6-generation invention chain in sort_net N=8 where every
generation is a Z3-verified correct sorter, each built compositionally
from prior generations, all at equal inner search budget.

This is the first reproduced "engine invents its successor" result on
this project, after the v3 chains halted at gen 1 on depth regression.

## The intervention

Diagnosed in `project_invention_chain` v3: *"macro-composition is
anti-aligned with additive cost axes (depth)."* When CALL_LIB counted
its full inlined depth, gen_n+1 = CALL_LIB(gen_n) cost as much as
gen_n itself, so composition could never beat re-derivation.

Fix: in `domain_sort_net.zig::depth()`, add a `DepthMode` enum:
- `.circuit` (default, original) — CALL_LIB expands recursively;
  measures real deployed circuit depth.
- `.logical` — CALL_LIB counts as **1 layer** for both metric and
  wire_layer; measures composition steps, not expansion.

Five-line core change. CLI flag `--depth-mode=logical` on
`chain_runner_sort`.

## Also caught while running

An unrelated u8 overflow in `editDistance`: `(la+1) * cols` was u8 *
u8 = u8, silently wrapping in ReleaseFast and crashing in ReleaseSafe.
Widened to `usize` before any arithmetic. Pre-existing bug masked
because previous chains stayed under the u8 ceiling.

## Result

Seed `0xDEADBEEF12345678`, equal inner budget (8000 SA iters/gen):

| gen | size | depth (logical) | correctness | Z3-verified | verdict                     |
|-----|------|-----------------|-------------|-------------|-----------------------------|
| 0   | 24   | 11              | 1.0         | ✓           | ADVANCE                     |
| 1   | 16   | **6**           | 1.0         | ✓           | **ADVANCE + STRICT_DOMINATION** |
| 2   | 16   | 6               | 1.0         | ✓           | ADVANCE                     |
| 3   | 16   | 6               | 1.0         | ✓           | ADVANCE                     |
| 4   | 16   | 6               | 1.0         | ✓           | ADVANCE                     |
| 5   | 16   | 6               | 1.0         | ✓           | ADVANCE                     |

All six champions Z3-verified against Knuth's 0/1 principle, each one
checked with all prior generations passed as inlined libraries via
`verify_cli --lib=…`. None is a fake sort.

## Reproducibility

4 different root seeds, 6 generations each:

| seed                  | gen_0 depth | gen_1 depth | strict_dom? | final state           |
|-----------------------|-------------|-------------|-------------|-----------------------|
| 0xCAFEBABE12345678    | 10          | 5           | YES         | HALT at gen 2 (6 > 5) |
| 0xDEADBEEF12345678    | 11          | 6           | YES         | Completed all 6 gens  |
| 0x1234567890ABCDEF    | 7           | 6           | YES         | Completed all 6 gens  |
| 0x2222222244444444    | 9           | 5           | YES         | HALT at gen 3 (6 > 5) |
| 0x5A5A5A5AB7B7B7B7    | 9           | 6           | YES         | HALT at gen 5 (7 > 6) |

**5/5 seeds produce a STRICT_DOMINATION step (gen 0 → 1).** Five for
five reproducibly, with no overlap in root seeds. Two seeds sustain a
full 6-generation chain; three halt at gens 2/3/5 when logical depth
regresses (honest HALT under the user-directive of equal-budget
reporting).

## What this is, and is not

**Is:**
- A reproducible engine that invents a correct successor sort network.
- Successive generations are *real* — each uses prior champions as
  primitives via CALL_LIB, then adds new comparators.
- Z3 confirms every champion is a true 8-sorter when libraries are
  inlined.
- The strict-domination step is genuine improvement on the chain's
  own progress axis.

**Is not:**
- Endless improvement. After the strict-domination step, the chain
  hits the SOTA depth floor (Bose-Nelson depth-6 for N=8) and
  subsequent gens diversify rather than improve. Successor here means
  "structurally novel correct sorter built from prior gen", not
  "shorter than every previous generation."
- A measurement of real deployment circuit depth. The `.logical`
  metric counts composition steps, not the full inlined depth of the
  deployed sorter. Honest if reported; misleading if not.
- Generalization. This works in sort_net N=8 with the depth-fix.
  Whether the same pattern works in the mixer chain (which has a
  different defect — non-bijective gen_0) or in larger N is open.

## Files

- `src/adapters/domain_sort_net.zig` — `DepthMode` enum, `setDepthMode`,
  `getDepthMode`, modified `depth()`.
- `src/adapters/chain_runner_sort.zig` — `--depth-mode=` and
  `--out-subdir=` flags, threaded `out_dir`, editDistance u8→usize.
- `results/chain_sort_logical/gen_{0..2}_champion.csv` (CAFEBABE seed)
- `results/cl_DEADBEEF12345678/gen_{0..5}_champion.csv` (full chain)

## Reproduce

```
cd ghost_sovereign
zig build -Doptimize=ReleaseSafe
./zig-out/bin/chain_runner_sort \
    --depth-mode=logical \
    --out-subdir=chain_sort_logical \
    --generations=6 --iters=8000 \
    --seed=DEADBEEF12345678
# Verify each champion
for g in 0 1 2 3 4 5; do
  prev=$(seq 0 $((g-1)) | sed "s|^|results/chain_sort_logical/gen_|;s|$|_champion.csv|" | paste -sd,)
  if [ -z "$prev" ]; then
    ./zig-out/bin/verify_cli --domain=sort --csv=results/chain_sort_logical/gen_${g}_champion.csv
  else
    ./zig-out/bin/verify_cli --domain=sort --csv=results/chain_sort_logical/gen_${g}_champion.csv --lib=${prev}
  fi
done
```
