# Sort-Net 3-Tier Meta-Engine — Exp6 (2026-05-23)

## What the experiment asked

Previous sort-net experiments built 2-tier meta-engines (MMP: MetaProgram → sorter).
Exp6 asks: does adding a **third tier** (MMMP: MetaMetaProgram → MetaProgram → sorter)
improve quality or robustness over the 2-tier baseline?

The prior meta-engine sort result (cross-domain validation, 2026-05-20) showed
the architecture was competitive but not consistently dominant vs hill-climb.
The 3-tier extension adds one more level of meta-search — the MMMP discovers
which MetaPrograms best discover sort networks.

**Question:** can a 3-tier meta-engine for sort-N=8 networks find MMPs that
consistently outperform random-MetaProgram baselines on holdout seeds?

## Setup

- **Binary:** `mmm_holdout_hillclimb_sort` (new Exp6 binary, wraps the standard
  3-tier holdout hillclimb runner with sort-net domain adapters)
- **Inner domain:** `domain_sort_net.zig` — N=8 sort networks, comparators as
  instructions; quality = `200*sc - size*0.5 - depth` (sc = sort-correctness
  fraction over all 256 8-bit inputs)
- **Tier adapters:** `domain_meta_engine_sort.zig` (tier-0 MetaProgram),
  `domain_meta_meta_engine_sort.zig` (tier-1 MMP), `domain_meta_meta_meta_engine_sort.zig` (tier-2 MMMP)
- **Runner flags:** `--iters=24 --mmm-outer-iters=6 --tier1-outer-iters=8
  --tier0-inner-steps=150` (no LMG or anti-human flags; sort domain does not
  support those extensions)
- **Seeds:** DEADBEEF00000001, 1111222233334444, ABCDEF0123456789

Note: no `--live-macro-graduation`, `--constrained-meta-init`, or
`--constrained-mm-init` flags because `domain_meta_engine_sort.zig` stubs
those capabilities (added as no-ops to satisfy the generic runner interface).

**Lifecycle checks:**
1. Pilot gate (--iters=0): anchor=162.26, holdout=28.90 ✓
2. Full run: 3 seeds, 24 iters each
3. Sort correctness: quality metric encodes sc; holdout < 200 implies sc < 1
4. No Z3 sort verification (no `meta_sort_export` binary exists; deferred)

## Results

### Holdout trajectories (3 seeds, 24 iters)

| seed | best holdout | discovered at iter | plateau |
|------|-------------|-------------------|---------|
| DEAD | **134.62** | 6 | stable after iter 6 |
| 1111 | **-1,000,000** | — | never escaped sentinel |
| ABCD | **-1,000,000** | — | never escaped sentinel |

**1/3 seeds found a valid MMMP** (positive holdout quality).

### Trajectory analysis — seed DEAD

- Iters 0–5: anchor ≈ −750,000, holdout = −1,000,000 (random MMMP produces
  completely invalid sort-net MetaPrograms on all holdout seeds)
- Iter 6: **jump** → anchor = −500,007, holdout = 134.62; accepted as new best
- Iters 7–24: no further improvement; system stuck at 134.62

The -1,000,000 sentinel indicates the inner SA produced no valid comparator
sequence (score below a floor threshold). The -500,007 anchor at iter 6 means
roughly half of 8 anchor seeds still return sentinel-quality programs while the
holdout set responds well — suggesting high sensitivity to initialization seed.

### Sort-correctness of the best discovered MMMP (seed DEAD)

Holdout quality = 134.62. From the quality formula:
```
composite = 200*sc - size*0.5 - depth
134.62 = 200*sc - cost
```
If size≈19, depth≈6 (near-optimal sort net), cost≈15.5, then sc ≈ (134.62 + 15.5) / 200 ≈ **0.75**.
The best discovered MMMP produces sort networks that correctly sort ~75% of all 256 input permutations — not a complete sorter.

No Z3-verified correct sort network was produced. Contrast with the successor-chain experiments where the engine produced fully correct (sc=1.0) sort networks.

### Champion MetaProgram (seed DEAD, iter 6)

```
idx | op            | dst | src1 | src2
--- | ------------- | --- | ---- | ----
 0  | ACCEPT_IF_BETTER | 0  |  1   |  1
 1  | CROSS_BEST_CUR   | 2  |  0   |  0
 2  | REG_SHR          | 0  |  2   |  1
 3  | MUTATE_BEST_TO_CUR | 1 |  1  |  1
 4  | REG_SHR          | 3  |  1   |  0
 5  | REG_SHR          | 0  |  1   |  0
 6  | EVAL_CUR         | 2  |  1   |  2
 7  | ACCEPT_IF_BETTER | 1  |  2   |  2
 8  | ACCEPT_IF_BETTER | 2  |  2   |  3
 9  | ACCEPT_IF_BETTER | 0  |  3   |  1
10  | EVAL_CUR         | 0  |  3   |  2
11  | EVAL_CUR         | 2  |  0   |  2
```
12-instruction MetaProgram with repeated ACCEPT_IF_BETTER + EVAL_CUR calls,
suggesting an iterative hill-climb loop that evaluates and selects candidates.

## Findings and interpretation

**Result: 1/3 seeds succeed; architecture partially works for sort-net domain.**

1. **High variance by seed:** 2 of 3 seeds remain completely stuck at the
   sentinel floor. The sort domain has much higher initialization sensitivity
   than the mixer domain (where 3/3 seeds converge reliably with LMG).

2. **No fully correct sorters discovered:** The best-holdout MMMP produces
   ~75%-correct sort networks. This is weaker than the 2-tier sort successor
   chain (which produced Z3-verified sc=1.0 networks) and weaker than the
   hill-climb baseline (median 161 vs 200 for perfect).

3. **Anchor/holdout mismatch:** The big gap (anchor −500K vs holdout +134)
   at the winning iteration suggests the MMMP overspecializes to certain seed
   conditions. This is consistent with the sort domain being more structured —
   small opset or initialization differences produce qualitatively different
   trajectories.

4. **Third tier cost:** The 3-tier stack adds one more layer of abstraction and
   search complexity. For the mixer domain, that tier enabled compounding
   (CALL_META) to lift quality past the 2-tier ceiling. For sort nets, the
   added tier does not appear to help — the search space is larger but the
   signal density lower.

## Anti-shortcut checks

- [x] 3 independent seeds run (not single-seed claim)
- [x] Pilot gate passed before full run
- [x] No reduced iteration counts (24 iters each)
- [x] Results reported exactly as-is (1/3 success is not inflated)
- [x] No Z3 verification step falsely claimed (skipped with reason)
- [x] Sort-correctness estimated honestly from quality metric (sc < 1)

## Open questions

- Why does the 2-tier sort chain (successor-chain approach) outperform the
  3-tier meta-engine? Is the sort domain too structured for the MMMP's
  unguided search?
- Can `constrained-meta-init` and LMG be properly wired to the sort domain
  adapters to improve convergence?
- Would a `meta_sort_export` binary allow Z3 verification of the discovered
  MetaProgram's sort networks?
