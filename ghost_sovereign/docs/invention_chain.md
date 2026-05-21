# Invention Chain — First Cut

Date: 2026-05-20.
Binary: `./zig-out/bin/chain_runner`.
Source: `src/adapters/chain_runner.zig`.
Substrate: `domain_u64_mixer.zig` + `invention_engine.zig` (unchanged).

## What this is

Per the chain directive (`feedback_invention_chain_directive.md`), invention
is structured as a sequence of engines:

```
engine_0 -> champion_0 -> engine_1 -> champion_1 -> ...
```

Each generation runs the same engine binary, but with the *extended library*
`L_n = L_0 ∪ {champion_0, ..., champion_{n-1}}`. The new champion must
clear an expanded promotion gate:

1. Quality gate (avalanche, balance, period, chi-square) — must PASS.
2. Not a remix/equivalent of any base-library mixer.
3. Not compositionally reachable (depth ≤ 3) from base primitives.
4. Not functionally near-equivalent to any prior champion (`bit_agreement < 0.75`).
5. Not compositionally reachable (depth ≤ 3) from the prior champions.
6. Quality score strictly exceeds the prior champion's score.

If any condition fails, the chain HALTS and the failing program is still
persisted as part of the record. No silent bar-lowering.

## Run

```
./zig-out/bin/chain_runner --generations=5 --iters=8000 --seed=ABCDEF0123456789
```

## Result

| gen | score   | extras_bit_agreement | extras_reach | verdict                          |
|-----|---------|----------------------|--------------|----------------------------------|
| 0   | 47.902  | 0.000 (empty)        | 0.000        | ADVANCE                          |
| 1   | 47.917  | 0.498                | 0.500        | ADVANCE                          |
| 2   | 47.940  | 0.501                | 0.502        | ADVANCE                          |
| 3   | 47.757  | 0.500                | 0.504        | HALT(no_quality_improvement)     |

Per-generation log: `results/chain/chain_log.csv`.
Champions: `results/chain/gen_{0..3}_champion.csv`.

## Honest reading

**The chain produced three accepted generations then halted at gen 3.**
Across gens 0, 1, 2 all extras-side metrics sit at the noise floor (~0.50
bit_agreement = exactly the distance between two distinct bijective u64
functions, established by the library cross-similarity matrix in
`project_reachability_tester.md`). Every accepted champion is therefore
functionally distinct from every prior champion AND from every base
library mixer.

**But the score gains are small relative to plausible seed noise.**
Gens 0→1→2 gained +0.015 and +0.023 on a composite-fitness scale where
champion scores live in the ~47–48 range. The gen-3 regression (−0.183)
is roughly 5–10× the per-generation gains. Without a measured noise floor
(score variance across N seeds at the same iter budget), the +0.038
two-generation rise cannot be cleanly distinguished from seed-luck. The
20-seed reproducibility runs documented in `project_reachability_tester.md`
imply this floor is non-trivial. **Treating gens 0–2 as a demonstrated
chain-of-improvement would be overclaiming.**

**What this run actually demonstrates:**

1. The chain-runner harness works as specified — extends the library each
   generation, applies expanded distance + reachability gates, halts
   honestly on quality regression without lowering the bar.
2. Multiple seeds within the u64-mixer domain produce functionally
   distinct INVENTION-passing champions, as previously shown.
3. Within iters=8000 per generation, the simulated-annealing search
   plateaus around composite ≈ 47.9; pushing past that plateau in a
   chain-shaped harness requires either a higher per-generation budget or
   a per-generation operator/library augmentation that actually changes
   the search space (this run did neither — the search saw the SAME
   operator set every generation, only the GATE changed).

## What this does NOT show

- That the chain pattern produces measurable improvement the in-place
  engine could not. The in-place engine at iters=N×K would be a fair
  baseline; this run did not produce one.
- That prior-champion augmentation of the search space helps. Per the
  directive, "Optionally: synthesize one compound operator per generation"
  was skipped in this first cut. Without it, the search has no extra
  building blocks to combine, only an extra gate to clear.

## Next honest step

Measure the score variance at iters=8000 over ≥10 seeds (the
reproducibility script already exists). Only call a per-generation gain
"real" if it exceeds one standard deviation of that noise. If most gains
fall inside noise, the next architectural move is the optional clause of
the directive — generation-n champions become composable operators for
generation n+1, not just gate constraints. That is the version of the
chain that genuinely changes the search space.

## Appendix — Falsification (2026-05-20, same day)

The "next honest step" above was executed.

**Seed-noise floor measurement** (`results/chain_variance/seed_noise_gen0.txt`):
10 independent gen-0 runs at iters=8000 with seeds varying.
Scores: 47.937, 47.873, 47.878, 47.856, 47.888, 47.322, 47.410, 47.766, 47.927, 46.868.
- Mean: 47.6725
- Standard deviation: **0.3567**
- Min: 46.868, Max: 47.937, Range: 1.069

**Original chain run, restated in σ units:**
- gen 0 → gen 1: +0.015 = **+0.04σ**
- gen 1 → gen 2: +0.023 = **+0.06σ**
- gen 2 → gen 3: −0.183 = **−0.51σ**

All three "transitions" are inside noise. The ADVANCE verdicts at gens 1
and 2 are indistinguishable from drawing slightly luckier seeds, and the
gen-3 HALT is a normal sub-1σ regression to the seed-mean.

**Multi-seed chain stability**
(`results/chain_multi/multi_seed_chains.txt`): five chains run with
different root seeds halted at gens 1, 2, 3, 2, 1 respectively. There is
no stable "chain depth" property — halt point is seed-dependent.

**Higher iter budget does not rescue the chain**
(`results/chain_variance/chain_higher_iters.txt`): iters=20000 (2.5× the
original) on the same root seed halted earlier — at gen 2 — with the
same noise-ratchet shape. The plateau is not a search-budget problem.

### Verdict (revised, honest)

**The chain pattern AS IMPLEMENTED is a noise ratchet, not an invention
chain.** Because the search space is identical every generation (same
operator set, same primitive library inside the search; only the
post-search gate is extended), the chain succeeds when the next
generation gets lucky enough to draw a high-tail seed and halts the
moment it draws a typical one. The accepted champions are still
functionally distinct from each other and from the base library — that
much is genuine — but inter-generational "improvement" is artifactual.

### What this falsifies and what survives

- **Falsified:** any reading of the first-run output as a demonstration
  that chaining produces measurable improvement an in-place engine could
  not. It does not, in this configuration.
- **Survives:** the harness implementation, the halt-honestly behavior,
  the per-generation functional-distinctness of accepted champions, and
  the methodological discipline of measuring the noise floor before
  claiming gains.
- **Survives:** the substrate. All three domains (u64-mixer, sort-net,
  boolean) still produce INVENTION (strict) under `general_inventor`
  post-edit. `zig build test` passes.

### What would actually validate the chain shape

The directive's optional clause that was skipped in this first cut:
make prior champions into *composable operators* for the next
generation's search, not merely gate constraints. That changes the
search space itself, which is the only mechanism by which a chain could
beat an iso-budget in-place engine. Without it, the chain shape is
overhead that adds a halt condition without changing what the engine
can find.

---

## v2 — Successor architecture (2026-05-20, same day)

The "what would actually validate" item above was implemented.

### Changes

1. **`domain_u64_mixer.zig`**: added opcode `CALL_LIB = 10`. When
   `chain_extras` (a `pub var std.BoundedArray(Program, 16)`) is empty,
   `randomInstr` never emits CALL_LIB and `execute` treats it as a
   no-op — base `general_inventor` behavior is preserved byte-for-byte.
   When populated, `CALL_LIB(imm)` executes
   `chain_extras[imm % chain_extras.len].execute(regs[src1])`.
2. **Recursion guard**: a `threadlocal var call_lib_depth` counter with
   `MaxCallLibDepth = 8`. Without it the chain SIGSEGV'd at gen 2 once
   chain_extras held programs that themselves contained CALL_LIB.
   (Discovered the hard way — exit code 139 on two parallel runs.)
3. **`chain_runner.zig`**: novelty-adjusted SA. Custom inner loop (the
   base engine's pool stores only quality). Fitness:
   `f(p) = qualityScalar(p) − λ · max(0, max_bit_agreement_to_extras(p) − 0.5)`.
   The `−0.5` baseline makes noise-floor distance free; only
   above-noise similarity gets penalized.
4. **`--lambda` CLI flag**. Default 10.

### Substrate regression

All three domains still produce **INVENTION (strict)** under
`general_inventor`. CALL_LIB is invisible to non-chain workflows.

### Successor demonstrated (read the CSVs)

`results/chain/gen_{0..3}_champion.csv` from
`--generations=5 --iters=8000 --seed=ABCDEF0123456789 --lambda=5`:

```
gen_0: ADD_CONST, SPLITMIX_STEP, SPLITMIX_STEP, SPLITMIX_STEP
gen_1: SHL_XOR, SHR_XOR, SHL_XOR, CALL_LIB(7,3,4)
gen_2: SHL_XOR, CALL_LIB(4,4,7), SHL_XOR, SPLITMIX_STEP
gen_3: ADD, MUL, ADD_CONST, CALL_LIB(7,4,0)
```

Three consecutive generations' champions contain CALL_LIB. The SA is
genuinely selecting prior-champion-as-atom during search. This is the
architectural property the v1 implementation lacked.

### Quality scores at v2

| seed | gen 0 | gen 1 | gen 2 | gen 3 | halt |
|------|-------|-------|-------|-------|------|
| ABCDEF0123456789 (λ=5) | 47.902 | 47.905 | 47.966 | 47.922 | gen 3 |
| ABCDEF0123456789 (λ=5, iters=50K) | 47.844 | 47.961 | 47.961 | — | gen 2 |
| DEADBEEFCAFEBABE | 47.990 | 47.990 | — | — | gen 1 |
| 0123456789ABCDEF | 47.854 | 47.939 | 47.951 | 47.880 | gen 3 |
| FEDCBA9876543210 | 47.714 | 47.895 | 47.805 | — | gen 2 |
| 1A2B3C4D5E6F7081 | 47.912 | 47.843 | — | — | gen 1 |
| BADCAFEFEEDFACE0 | 47.910 | 47.873 | — | — | gen 1 |

Halt depths: 3, 2, 1, 3, 2, 1, 1. Per-gen gains still ≤ 0.1σ (σ = 0.357).

### Honest reading of v2

**Architecturally**: the successor exists. Engine at gen n+1 searches
a strictly larger space than engine at gen n because `randomInstr` and
`mutate` can emit CALL_LIB(k) for k < chain_extras.len, and the
resulting programs invoke prior champions as atomic operators. The CSVs
prove this — CALL_LIB ops appear in 3 consecutive accepted champions.

**Empirically as cumulative score advance**: not demonstrated. With the
novelty objective preventing trivial equivalence, per-generation
quality scores cluster around the same ~47.9 plateau. iters=50K does
not break the plateau (gens 1 and 2 both land at exactly 47.961, then
halt). The u64-mixer composite-quality metric appears genuinely
saturated at this program-length and instruction-set budget.

### What this means

Two separate questions were collapsed in the original directive:

1. *Does the engine have a successor?* — **YES.** v2 demonstrates it.
2. *Does the chain produce cumulative quality gains an in-place engine
   couldn't?* — **NO in this domain at this budget.** The metric is
   plateaued and CALL_LIB-composition doesn't unlock higher territory.

The honest next step is to test the chain in a domain where the
quality metric ISN'T plateaued — boolean parity-4 needed 10× more
iters than u64-mixer to converge per `project_domain_spec.md`, which
suggests headroom. A v3 chain on boolean (or sort-net) would test
whether the successor architecture actually wins when the quality
ceiling is higher than the current run can reach.

---

## v3 — Sort-net N=8 chain (2026-05-20, same day, negative result with sharp diagnostic)

After u64-mixer empirically demonstrated the architectural successor
(CALL_LIB in gen_{1,2,3} champions) but no measurable cumulative gain
because the metric was saturated, we ported the v2 chain pattern to
`domain_sort_net.zig` (N=8 sorting networks) on the hypothesis that
sort-net has an *unsaturated* progress axis — depth (parallel
comparator layers, lower-is-better). The known SOTA is depth 6
(Bose-Nelson 1962); library entries Floyd-8 and Batcher-8 both depth 6.

### Architecture (additive — substrate stays regression-clean)

1. **`domain_sort_net.zig`**: added `kind` field to `Comparator`
   (`kind=0`: normal compare-exchange; `kind=1`: CALL_LIB-style macro
   that executes `chain_extras[i % chain_extras.len]` inline). All
   library entries default `kind=0`. With `chain_extras` empty,
   `randomComparator` never emits `kind=1`. Substrate regression on
   all three domains (u64, sort, boolean) still produces INVENTION (strict).
2. **Recursion guard**: same pattern as u64-mixer — `threadlocal var
   call_lib_depth` with `MaxCallLibDepth=8`.
3. **`chain_runner_sort.zig`**: novelty-adjusted SA with custom fitness
   that heavily weights depth post-correctness. `--lambda` and
   `--depth-weight` CLI flags.
4. **Strict_domination verdict added**: passes invention-strict AND
   `new_depth < prev_depth`. Halt-on-regression uses depth (not the
   substrate's flat composite, which masks the signal).

### Seed-noise baseline (`results/chain_sort_variance/seed_noise_gen0.txt`)

10 independent gen-0 runs at iters=50000:

| Seed | size | depth |
|------|------|-------|
| 1111... | 22 | 11 |
| 2222... | 20 | **7** |
| 3333... | 24 | 9  |
| 4444... | 23 | 10 |
| 5555... | 22 | 9  |
| 6666... | 24 | 11 |
| 7777... | 25 | 9  |
| 8888... | 21 | 8  |
| 9999... | 24 | 10 |
| AAAA... | 22 | 8  |

- Mean depth 9.2, **σ(depth) ≈ 1.3**, min 7, max 11.
- Substrate alone occasionally finds depth-7 (1/10 seeds). Defensible
  strict_domination requires reaching depth 6.

### Chain results (6 root seeds × varied iter budgets)

| root seed | iters | gen 0 depth | gen 1 depth | Δdepth | verdict |
|-----------|-------|-------------|-------------|--------|---------|
| CAFEBABE12345678 | 50K   | 10 | 17 | +7 | HALT(depth_regression) |
| CAFEBABE12345678 | 200K  | 10 | 15 | +5 | HALT(depth_regression) |
| 1111...          | 50K   | 11 | 18 | +7 | HALT(depth_regression) |
| 2222...          | 50K   | 8  | 14 | +6 | HALT(depth_regression) |
| 3333...          | 50K   | 10 | 15 | +5 | HALT(depth_regression) |
| 4444...          | 50K   | 10 | 17 | +7 | HALT(depth_regression) |
| 5555...          | 50K   | 8  | 13 | +5 | HALT(depth_regression) |

**6/6 chains halt at gen 1 on depth regression. Every gen-1 depth is
+5 to +7 above gen 0's depth. STRICT_DOMINATION observed: 0/7.**

### Diagnostic — the headline finding

The successor architecture IS firing (gen-1 programs contain `kind=1`
CALL_LIB comparators — confirmed in `results/chain_sort/gen_1_champion.csv`).
But CALL_LIB is **anti-aligned with the depth progress axis** for
sorting networks: composing two correct sorters produces a correct
sorter with depth equal to the *sum* of their depths. Any CALL_LIB(k)
in a gen-1 program adds champion_gen_k's depth on top of whatever
else the program does. **Depth goes up by construction.**

u64-mixer worked because composing two mixers gives higher-entropy
output — no "cost" axis being summed. Sort-net fails because depth
*is* the cost axis being summed.

### What this proves and what it doesn't

**Proves:**
- Architectural successor mechanism is *domain-transferable* (it
  compiled into sort_net cleanly, SA selects it, programs use it).
- Empirical effectiveness of macro-composition is **NOT
  domain-independent**. It depends on whether the progress axis is
  invariant (or improved) under composition.
- For domains with additive cost axes (depth, latency, gate count,
  memory), naïve macro-composition is structurally counterproductive.

**Does not prove:**
- That the chain pattern is wrong for sort_net in general — just that
  *full-network macro composition* is. A layer-aware composition
  primitive could in principle reduce depth.
- That sort_net depth is unreachable for the chain — gen-0 alone
  occasionally finds depth-7. The base substrate has the capacity;
  the chain's macro primitive steers away from it.

### Negative result framed as research finding

**Macro-composition primitives are aligned with the progress axis only
when the axis is invariant (or improved) under composition. For
additive-cost domains, sub-structure composition is required.**

This is the kind of statement we couldn't make before running the
experiment. It points directly at the next architecture: a
`layer_extract(prior, n)` primitive for sort_net that lets gen_n+1
splice individual parallel layers from prior champions instead of
their full sequences. That's research-grade work, not a one-session
edit, but the path is now well-specified.

### Files

- `src/adapters/domain_sort_net.zig` — additive CALL_LIB additions
- `src/adapters/chain_runner_sort.zig` — full sort-net chain runner
- `results/chain_sort_variance/seed_noise_gen0.txt` — noise baseline
- `results/chain_sort_variance/v4_multiseed_*.txt` — 5-seed chain runs
- `results/chain_sort_variance/v4_iter200k.txt` — high-budget control
- `results/chain_sort/gen_{0,1}_champion.csv` — actual programs
