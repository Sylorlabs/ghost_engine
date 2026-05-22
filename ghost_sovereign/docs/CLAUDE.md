# Ghost Sovereign — Agent Onboarding

Read this before touching anything. It will save you from wasting the entire session.

Also read `docs/AGENT_REALITY_CHECK.md` if you are deciding whether the new architectures are real or fake.

---

## What This Project Is (Ground Truth)

Ghost Sovereign is a **reservoir computer** implemented in Zig. It is a real ML architecture. It is **not** an AGI or ASI. It is also not a general language generator.

The system:
1. Takes text input
2. Runs it through a 512-dimensional constraint-satisfaction engine
3. Produces three measurable signals: `closure_delta`, `trigger_edge`, `lattice_fingerprint`
4. Those signals are fed to an LLM (you) which acts as the **readout layer**
5. New bridge demos can anchor words into a mmap manifold and emit dictionary-limited token sequences

That is the complete architecture. Everything else is framing. The new bridge demos are real code, but they are not trained generation, source-backed retrieval, or proof of autonomous understanding.

---

## Do Not Get Confused By These Things

### The "Expert Engine" Outputs
The synthesis binaries in `zig-out/bin/` (especially `ask_experts` and `debate_experts`) output **hex marks, deltas, and trigger edges — not language**. `ghost_core` is different: it emits a dominant resonance label and dictionary-limited tokens. Any philosophical dialogue you see in conversation history was written by a previous agent, not produced by the code.

### The "Alien Math" Framing
The previous agent used narrative framing like "Ghost Flux said: We need more heat." This is the agent's writing, not engine output. Do not continue this pattern. Report actual numeric output from the binaries.

### The Benchmark Chain
The benchmark progression from VSA → Flame → Flare → Frost → Fractal → Flux → Void is **real and verified**. The benchmark files in `results/` contain the actual run output. The 51x improvement over 6 iterations is a real number from real benchmarks, not a claim.

### "10 Trillion Points of Tension"
This is just `closureError()` — a sum of absolute residuals across 1,024 laws. Standard L1 loss. The number sounds large because `i128` values are large.

### "VSA Dark-Space Grounding"
The laws are derived at comptime from `concept.bind(concept)` popcount in `flame.zig:Laws`. Originally this was framed as "semantic grounding." A 2026-05-17 control experiment (see ARCHITECTURE.md §4.7) swapped the popcount-derived coefficients for pure PRNG of the same magnitude and held law indices `a, b` fixed. Calibration still produced **8 distinct edges** and **byte-identical lattice fingerprints**. The HD grounding is not load-bearing for discrimination. Discrimination comes from `void.zig` sparse routing (which chambers each character touches) and `lore.zig` XOR (character distribution fingerprint). Do not claim the system "navigates dark space" or "binds concepts at runtime" — at runtime the hypervectors are gone, only three integers per law survive.

### The New Aetheric/Search/Decoder Code
These files are real and build:
- `src/aetheric.zig`: anchors VSA concepts in `manifold.zig`, ingests words, emits a dominant concept and dictionary words.
- `src/vsa_decoder.zig`: prototype hypervector unbinder plus a brace/paren checker.
- `src/search.zig`: hardcoded article ingest and dictionary query demo.
- `src/wiki_ingestion_synthesis.zig`, `src/decoder_synthesis.zig`, `src/ingestion_strategy_synthesis.zig`: proposal probes that print marks/scars, not full designs.

Do not call these fake. Also do not overclaim them. They are prototypes/probes.

---

## Current System State (as of last verified run)

### Build
```bash
cd /home/micah/Desktop/sylorlabs\ projects/ghost_engine/ghost_sovereign
zig build   # Must exit 0 — if not, fix before anything else
```

### Calibration (run this to verify the system is working)
```bash
./zig-out/bin/calibration
```

Expected output — all 8 prompts must have distinct `edge` values:
```
technical-low-level  | delta=-104588 | edge=122 | lattice=E23DAFBF4990348E
creative-poetic      | delta=-153725 | edge=111 | lattice=904CD3229C95D0B9
math-hard            | delta=-211758 | edge=177 | lattice=F6F606D1ADFC5A31
typo-adversarial     | delta=-33358  | edge=826 | lattice=7518C463B325FDED
instruction-complex  | delta=-591    | edge=523 | lattice=98CAA04772E0DCE5
casual-greeting      | delta=-24242  | edge=677 | lattice=898880E847902B
system-status        | delta=-16345  | edge=5   | lattice=F6368E30D9856638
code-zig             | delta=-134275 | edge=788 | lattice=7252C81EE2CE24D7
```

If all edges are the same value (especially 819 or 485), something broke in ingestion. See the "Known Bugs Fixed" section below.

---

## Architecture Map

| File | What It Does | Status |
|------|-------------|--------|
| `src/flame.zig` | Core reservoir: 512 chambers, 1024 VSA-grounded laws, Gauss-Seidel relax, closureError() | Built, working |
| `src/vsa.zig` | 1024-bit hypervectors, bind/bundle/permute/similarity, 20 concept primitives | Built, working |
| `src/void.zig` | Primary engine: sparse text ingestion, 256-branch maybeInventText, 500-pass dampened relax | Built, working |
| `src/calibration.zig` | Ground truth measurement: 8 labeled prompts → delta/edge/lattice signals | Built, working |
| `src/lore.zig` | 64-slot XOR accumulator → unique text fingerprint (not "grammar", not language) | Built, working |
| `src/manifold.zig` | mmap-backed 1M-slot i128 persistence layer | Built, used by aetheric/search demos |
| `src/aetheric.zig` | Anchored VSA manifold bridge and dictionary-limited resolver | Built, demo quality |
| `src/vsa_decoder.zig` | Dictionary-based hypervector token unbinder + brace/paren checker | Built, prototype |
| `src/search.zig` | Hardcoded article ingest + dictionary query demo | Built, not source-backed retrieval |
| `src/wiki_ingestion_synthesis.zig` | Void mark/scar probe for ingestion strategy | Built |
| `src/decoder_synthesis.zig` | Void mark/scar probe for decoder strategy | Built, slow |
| `src/ingestion_strategy_synthesis.zig` | Void mark/scar probe for web-ingestion strategy | Built, slow |
| `src/void_cli_adapter.zig` | `ghost_invent_void` placeholder CLI | Built, placeholder output |
| `src/flux.zig` | 512-branch entropy engine (Suite 5, superseded by Void) | Built |
| `src/fractal.zig` | 5 nested mutation loops (Suite 4) | Built |
| `src/frost.zig` | Triple-flare engine (Suite 3) | Built |
| `src/flare.zig` | Single-law collapse (Suite 2) | Built |
| `src/sovereign.zig` | Meta-architecture: AetherField + LoreEngine + EchoManager | Built, partially wired |
| `src/aether.zig` | Sparse hash field: HashMap(u64, i128) | Built |
| `src/echo.zig` | AetherField binary serializer | Built |

If a file is not listed here, inspect it before making claims. Do not assume old docs are complete.

---

## The Laws (Critical to Understand)

1,024 laws of the form: `ca * chamber[a] + cb * chamber[b] = t`

Laws are derived from VSA hypervector bindings of concept pairs (LOGIC, SYNTAX, CODE, etc.). The coefficients come from bit densities of concept hypervectors:
```zig
laws[i].ca = popcount(hv1) - 512;   // range: roughly -50 to +50
laws[i].cb = popcount(hv2) - 512;
laws[i].t  = (popcount(hv1.bind(hv2)) - 512) * 100;  // range: roughly -5000 to +5000
```

**Important caveat**: The concept hypervectors are seeded randomly (`initRandom(0x9F19... ^ concept_id)`). LOGIC and SYNTAX don't have more similar hypervectors than LOGIC and CHAOS. The "semantic grounding" is structural (laws are derived from concept pairs) not semantic (the concepts themselves have no embedded meaning).

`closureError()` = Σ |ca*chamber[a] + cb*chamber[b] - t| over all 1,024 laws.

---

## Known Bugs (Fixed) — Do Not Reintroduce

### Bug 1: Dense harmonic ingestion (broken)
```zig
// BROKEN — chamber 511 receives 262,000x more input than chamber 0
const harmonic = @as(i128, b) * @as(i128, i + 1) * @as(i128, i + 2);
chamber[i] += harmonic;
```
This made trigger_edge always = 819 regardless of input. Fixed by sparse routing.

### Bug 2: Trigger edge measuring absolute pressure (broken)
```zig
// BROKEN — always returns the law with the largest random t target
const p = @abs(law.ca * chamber[law.a] + law.cb * chamber[law.b] - law.t);
if (p > max_p) { trigger_edge = i; }
```
Fixed by measuring pressure *change* from baseline (before vs after ingestion).

### Current correct ingestion (void.zig):
```zig
// Sparse routing: each character touches 8 chambers via hash
var rh = h;
for (0..8) |_| {
    rh = flame.splitMix64(rh);
    const chamber_idx = rh % flame.ChamberCount;
    const sign: i128 = if (rh & (1 << 63) == 0) 1 else -1;
    self.state.chamber[chamber_idx] += @as(i128, b) * sign;
}
h = rh;
```

### Current correct trigger edge measurement (calibration.zig):
```zig
// Measure change from baseline, not absolute pressure
const change = if (p_after > pressure_before[i])
    p_after - pressure_before[i]
else
    pressure_before[i] - p_after;
if (change > max_change) { max_change = change; trigger_edge = i; }
```

---

## Warnings About Specific Functions

### `VoidEngine.shapeTextPressure()` — Do Not Call For Calibration
This function applies billion-scale magnitudes to chambers. It will completely overwhelm the bounded sparse-routing ingestion and make all prompts look identical. It exists for invention, not calibration.

### Legacy `ghost_probe` / `ask_experts` / `debate_experts`
If present, these binaries apply `splitMix64`-style mark generation to a text hash and output marks/deltas rather than natural language. Treat them as proposal probes, not as evidence that "the expert responded" in prose.

### `manifold.zig` — Partially Wired
The mmap persistence layer exists and compiles. It is connected to `aetheric.zig` and `search.zig`, but it is not a full retrieval database. Do not assume it stores article text, provenance, or evidence spans.

### `ghost_core` / `ghost_search`
These binaries do run. Their output is dictionary-limited resonance text, not a fluent answer. Example behavior verified in this session:
- `ghost_core` prints a dominant resonance such as `CHAOS` and a sequence of dictionary tokens.
- `ghost_search` ingests a hardcoded AI article and emits words from a small hardcoded dictionary.

This is useful probe output, not source-grounded Q&A.

### `ghost_invent_void`
Currently prints `[Ghost Void Phase-Collapse]` and `Result: Resolution achieved...` after pressure-shaping the message. Treat that as placeholder CLI output, not as proof that Void generated an invention.

---

## What Is Not Built

1. **Output generation**: The system cannot produce responses, complete sentences, or answer questions. It classifies inputs and produces signals.
2. **Retrieval**: `search.zig` is a hardcoded dictionary demo. No mechanism returns relevant stored passages with provenance.
3. **Web-scale ingestion**: The storage layer exists. A hardcoded demo exists. The fetch→parse→route→store→query pipeline does not.
4. **True semantic grounding**: Concept hypervectors are random. LOGIC ≠ more similar to SYNTAX than to CHAOS.
5. **Trained readout**: The calibration table has 8 labeled examples. A real trained readout needs hundreds or thousands.

---

## What The Agent Should Do (Role Definition)

You are the **readout layer**. The reservoir produces math. You interpret the math.

Your job:
1. Run `./zig-out/bin/calibration` to get real signals
2. Compare new prompt signals against the calibration table
3. Interpret: "This prompt has delta=-211K and edge=177, similar to math-hard"
4. When modifying code, verify calibration output still shows 8 distinct edges after changes
5. Propose architectural improvements based on what the signals reveal, then implement them in Zig

Your job is **not**:
- Writing philosophical dialogues attributed to the engines
- Claiming "the expert said X" based on hex output
- Accepting billion-scale numbers as proof of intelligence
- Deleting source files (a previous agent did this — `rm -rf src/*` — and had to recover)

---

## The Honest One-Paragraph Summary

Ghost Sovereign is a reservoir computer built in Zig. Its 512-dimensional constraint-satisfaction system produces measurable signals per input (delta, trigger_edge, lattice fingerprint) that vary by prompt content. The system was built through empirically validated iterations, each guided by previous invention output, with measurable benchmark improvement at each step. The new aetheric/search/decoder bridge code is real and runnable, but it is a dictionary-limited probe, not a trained language generator or source-backed retrieval system. An LLM acting as a calibrated readout layer is still the practical interpreter. The theatrical "alien engine" narrative surrounding the project is the agent's writing, not the code's output. The engineering underneath that narrative is real, benchmarked, and reproducible.

---

## Meta-Engine / Invention Chain Research (as of 2026-05-21)

The project also contains a **program synthesis research stack** for
engine-inventing-engine experiments. This is separate from the
reservoir computer above.

### Architecture (3 tiers)

| Tier | Module | What it searches over | What it produces |
|------|--------|-----------------------|------------------|
| 0 | `domain_meta_engine.zig` | u64 mixer programs (MetaProgram) | A mixer with fitness score |
| 1 | `domain_meta_meta_engine.zig` | Search algorithms (MetaMetaProgram / MMP) | A MetaProgram discoverer |
| 2 | `domain_meta_meta_meta_engine.zig` | Search-algorithm discoverers (MMMP) | An MMP discoverer |

Each tier's fitness is the tier below's best score — apples-to-apples
comparison across all tiers.

### Key results

- **Tier-1 chain with CALL_META** works: 3/4 seeds produce
  STRICT_DOMINATION steps. Best holdout: **44.30** (seed 0x1111),
  beating the hand-coded baseline (32.55). Validated on 64-seed
  held-out set.
- **Wide CALL_META** (`--wide-call-meta`): 4-bit library addressing
  instead of 2-bit. Wins 2/3 seeds at best-holdout. **Recommended
  default for chains with >4 library entries.**
- **Bigger budget (200 iters)**: **REFUTED.** All 4 seeds get worse
  holdout. The 4-anchor generalization protection has a budget-
  dependent failure mode. **24 iters is the correct operating point.**
- **Tier-2 MMMP** v1: Built and runs. Shows progressive learning
  (sentinel → finite anchor → STRICT_DOMINATION → right primitives
  wrong order) but holdout is -10,813 — 5 orders of magnitude worse
  than Tier-1's 44.30. Not yet competitive.
- **Tier-2 MMMP** v2 (combined: shaped fitness + curriculum + constrained
  init + expanded opcodes): Best holdout **+23.30** (0x1111 gen 2,
  STRICT_DOMINATION). First positive Tier-2 holdout ever. 6+ orders of
  magnitude better than v1's -1e6 sentinel, but still ~21 holdout
  units below Tier-1's 44.30 ceiling and ~5 below the hand-coded
  baseline 28.13. The four-tier successor recursion approaches Tier-1
  but does NOT exceed it at single-machine budgets.
- **Expanded Tier-0 opcodes** (Approach #1 of v2 round): added ROTR,
  BSWAP, MUM, ADD_ROT (10 → 14 ops). Re-run 4 Tier-1 chains at original
  24-iter budget: best new holdout 37.26 (F00D ext). NONE of 4 chains
  broke 44.30 — expanded opcodes alone don't raise the ceiling. The
  ceiling is **budget × opcode-set interaction**.
- **44.30 ceiling**: Reproduced across multiple seeds and recipes.
  Property of the budget × opcode-set interaction, not a seed fluke
  or tier-depth limitation. v2 round refutes "more tiers" as a way
  to escape it.

### Key files

| File | Purpose |
|------|---------|
| `src/adapters/domain_meta_engine.zig` | Tier-0: MetaProgram type + run |
| `src/adapters/domain_meta_meta_engine.zig` | Tier-1: MMP type + run + wide CALL_META toggle |
| `src/adapters/domain_meta_meta_meta_engine.zig` | Tier-2: MMMP type + run |
| `src/adapters/meta_meta_chain_runner.zig` | Tier-1 chain runner (multi-gen, anchor-protected) |
| `src/adapters/mmm_chain_runner.zig` | Tier-2 chain runner |
| `src/adapters/champion_holdout_validation.zig` | 64-seed holdout validator |
| `docs/tier1_meta_engine.md` | Tier-1 detailed findings |
| `docs/tier2_meta_meta_engine.md` | Tier-2 detailed findings |
| `docs/successor_loop_research.md` | v1 research round (3 tests) |
| `docs/invention_engine_v2.md` | v2 research round (5 approaches, final verdict) |
| `results/mm_chain_*/` | Tier-1 experiment data |
| `results/mm_chain_ext_*/` | v2 expanded-opcodes chain data |
| `results/mmm_chain_*/` | Tier-2 experiment data |
| `results/mmm_chain_combined_*/` | v2 combined Tier-2 data |

### Operational warnings

- **Do NOT increase tier1_iters past 24** without also increasing
  anchor count. The search will overfit the 4 anchor seeds.
- **Use `--wide-call-meta`** when seed-library has >4 entries.
- **Tier-2 is research-only.** Even with all 4 v2 enhancements
  (shaped fitness, curriculum seed, constrained init, expanded
  opcodes) Tier-2's best holdout is -48.68 vs Tier-1's +44.30.
  Don't report it as "working" — report it as "implemented,
  responsive to engineering, not competitive with Tier-1."
- **Expanded Tier-0 opcodes are available but NOT a free win.** ROTR,
  BSWAP, MUM, ADD_ROT increase variance; at fixed 24-iter budget,
  some seeds gain, others lose. Use only with explicit budget tuning.
- **Always use the disciplined baseline** (anchor protection + seed
  rotation) for comparisons. Undisciplined baselines overfit and make
  Tier-1 look artificially good.
- **The 44.30 ceiling appears domain-bounded.** Five approaches
  (bigger budget, wide CALL_META, Tier-2, expanded opcodes, combined
  Tier-2) all failed to break it. **Update (2026-05-21):** the
  monotone-retry + parallel-attempts mode finally broke through to
  **47.16** (F00D sequential, gen 4 via CALL_META compounding). The
  new escape strategies (richer scoring axis, more tiers) would build
  on the monotone+parallel foundation.

- **Use `--monotone-retries=N`** to enforce strictly non-decreasing
  invention output. `N=10` recommended. Each gen runs up to N
  attempts on N separate threads via std.Thread; the chain only
  ADVANCEs if at least one attempt strictly beats cumulative-best
  holdout. Without this flag, the chain can accept worse champions
  (anchor-mean optimization games the 4 anchor seeds) and produce
  up-down-up holdout trajectories.
- **Parallel attempts saturate the CPU.** 10 parallel attempts per
  gen uses up to 10 cores per chain. Run one chain at a time when
  using `--monotone-retries=10` on a 12-core machine.

---

## Full Reference

See `ARCHITECTURE.md` in this directory for the complete technical reference including benchmark numbers, per-component analysis, engineering decisions, and the theater vs real distinction.
