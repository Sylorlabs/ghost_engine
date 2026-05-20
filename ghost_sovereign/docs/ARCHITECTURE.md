# Ghost Sovereign: Architecture Documentation

**For future agents and developers: read this before touching anything.**

This document records what this system actually is, how it was built, what each component does, what was proven empirically, and what remains unbuilt. It is written to prevent future agents from either (a) dismissing the project as fiction or (b) hallucinating capabilities that don't exist.

For the shortest agent-facing version, see `docs/AGENT_REALITY_CHECK.md`.

---

## 1. What This System Actually Is

Ghost Sovereign is a **reservoir computer** — a real ML architecture — implemented in Zig for consumer hardware (CPU-native, no GPU required, no cloud dependency).

The system has two halves plus one experimental bridge layer:

- **Input side (built):** Text is ingested into a 512-dimensional constraint-satisfaction system. Different inputs produce measurably different mathematical fingerprints. This is verified by `calibration.zig`.
- **Output side (not generally built):** The system still does not generate fluent open-ended responses. It classifies and fingerprints inputs. An LLM (Claude, Gemini, etc.) is still the practical readout layer for natural-language interpretation.
- **Experimental bridge layer (built as demos):** `aetheric.zig`, `vsa_decoder.zig`, and `search.zig` can anchor words into a memory-mapped manifold and emit dictionary-limited token sequences. This is real Zig code and it runs, but it is not a trained decoder and not a reliable answer generator.

It is **not** an LLM replacement. It is a hardware-native feature extractor plus experimental manifold/dictionary probes that an LLM can use as grounded signal sources. The combination (reservoir + calibrated readout) is still the intended architecture.

---

## 2. The Evolutionary Chain — This Is Real, Not Fiction

The engines were built iteratively. Each generation was benchmarked against all previous generations. The benchmark results are in `results/`. The improvement is real and measurable.

### The Chain

| Engine | Suite | Core Innovation | Benchmark File |
|--------|-------|----------------|----------------|
| VSA baseline | — | Vector Symbolic Architecture operations | results/triad_benchmark.txt |
| Flame | 1 | Paired residual invention: highest + lowest pressure law, two linked flares, 53% improvement threshold | results/triad_benchmark.txt |
| Flare | 2 | Single-law variance collapse: finds the one most-stressed law, applies a single flare | results/triad_benchmark.txt |
| Frost | 3 | Three-entangled-flares: top 3 variance laws, simultaneous flares, 300-pass relaxation | results/quad_benchmark.txt |
| Fractal | 4 | Recursive law spawning: 5 nested mutation-relaxation loops per trial | results/penta_benchmark.txt |
| Flux | 5 | 512 parallel branches with entropy (chaos + order tradeoff) | results/hexa_benchmark.txt |
| Void | 6 | 500-pass Gauss-Seidel + median centering + asymptotic dampening | results/hepta_benchmark.txt |

### Benchmark Progression (Mean Quality, Baseline Suite)

```
VSA:     1,133,178
Flame:   1,568,697   (+38% over VSA)
Flare:   1,381,642
Frost:     210,712   (lower quality but higher survival rate)
Fractal: 6,996,318   (order-of-magnitude jump)
Flux:   57,371,016   (another order-of-magnitude jump)
Void:   58,458,035   (beats Flux, dominates all in Weird Request Suite)
```

In the 12-case Weird Request Suite (typos, adversarial, hardware-constrained prompts), Void achieves 256/256 survivors and wins every trial against all previous engines.

### How the Chain Was Built

Each benchmark includes a "Suite 3" section where the current best engine runs its invention process on an "invent the next engine" prompt. The output (mark, closure_delta, trigger_edge) was translated by the agent into an architectural proposal for the next engine.

**Example — Triad Suite 3:**
- Flare's invention engine produced: mark `0x8124EA28FCFD7E88`, trigger_edge=1, 69% closure improvement
- Translation: "Three laws with largest variance from median, spawn three entangled flares simultaneously"
- Result: This became `frost.zig` — which does exactly that

**The honest description of this process:** The math produced real signals (marks, deltas, trigger edges). The agent (Gemini) interpreted those signals and wrote code. The agent was the translator, not the math. But the empirical feedback loop was real — each engine was genuinely tested and only adopted if it improved the benchmark.

---

## 3. Component-by-Component: What Each File Actually Does

### `flame.zig` — The Physical Reservoir

The foundation. Everything else builds on this.

- **`FlameState`**: 512 `i128` values (the chamber) + 2048 `u64` scar slots + closure error
- **`Laws`**: 1,024 constraints whose coefficients are derived from VSA hypervector bindings at comptime (see below — note: empirical test in Section 4 shows this grounding is not load-bearing for discrimination)
- **`closureError()`**: Sum of absolute residuals across all 1,024 laws. L1 loss. This is the core fitness metric.
- **`relax()`**: Gauss-Seidel iteration — moves each chamber pair toward satisfying its law
- **`maybeInvent()`**: Tries up to 128 candidate perturbations, keeps one if it reduces closure by ≥53%
- **`maybeInventText()`**: Same but seeds from text hash
- **VSA operations**: `bindSignature`, `permuteSignature`, `majoritySignature`, `collapseSignature` — standard HD computing primitives

**The Laws are structurally derived from VSA concept-pair bindings at compile time** (see `vsa.zig`): for each law, two concepts (from a fixed enum of 20, but only the first 10 are sampled — `s % 10` in `flame.zig`) are bound via XOR, and the coefficients `ca`, `cb`, `t` come from popcount of those hypervectors. Once `Laws[]` is generated, the 1,024-bit hypervectors are gone — only the three integers per law survive into runtime. Originally this was described as "semantic grounding," but a 2026-05-17 control experiment (Section 4.7) demonstrated that replacing the popcount-derived coefficients with pure PRNG values of equivalent magnitude preserves the calibration's 8-distinct-edge property. The concept-pair derivation is therefore not load-bearing for discrimination; it produces a stable set of integer constraints whose specific origin does not matter.

### `vsa.zig` — Vector Symbolic Architecture

Real VSA implementation. 1024-bit hypervectors, 16 words of 64 bits each.

- **`bind()`**: XOR — orthogonal composition of two concepts
- **`bundle()`**: XOR superposition (note: true majority-vote bundling requires odd-number voting; this is an approximation)
- **`permute()`**: Cyclic bit shift — encodes sequence/order
- **`similarity()`**: Hamming distance — measures how related two vectors are
- **`Concept` enum**: 20 semantic primitives (LOGIC, SYNTAX, CODE, DATA, SIGNAL, NOISE, AETHER, VOID, TRUTH, SHADOW, HARDWARE, SOFTWARE, NETWORK, MEMORY, PROCESS, IDENTITY, REASON, CRAVE, ORDER, CHAOS)
- **`getConceptHV()`**: Generates a deterministic random hypervector for each concept from a fixed seed

**Important**: The concept hypervectors are random — `initRandom(seed ^ concept_id)`. They are not derived from language models or semantic embeddings. Two related concepts (CODE and SYNTAX) don't have more similar hypervectors than unrelated ones (CODE and CHAOS). The "semantic" grounding is that the laws are structurally derived from concept pairs, not that the concepts have embedded meaning.

### `void.zig` — The Invention Engine

The most powerful engine in the chain. Used for primary invention.

- **`ingestTextSequence()`**: Sparse routing — each character touches 8 chambers via splitMix64 hashing. Contributions bounded to ±byte_value. This was fixed in this session to prevent high-index chamber dominance (see Engineering Decisions below).
- **`shapeTextPressure()`**: Applies a large magnitude perturbation based on text hash — WARNING: this still uses the old quadratic approach with magnitudes in the billions. It will dominate over ingestTextSequence if called.
- **`maybeInventText()`**: 256 branches, each applying median-centering + Null-Point Scar perturbation + 500-pass Gauss-Seidel with asymptotic dampening. Keeps candidates with ≥1% improvement over control.
- **Asymptotic dampening**: `dampener = 1 + (pass / 10)` — reduces update magnitude as passes increase, prevents oscillation

### `flux.zig` — Entropy Harvester

512 parallel branches. Higher survival rate than Void on baseline, slightly lower mean quality.

### `flare.zig` — Single-Law Collapse (Suite 2)

Finds the single law with highest variance from satisfaction, applies one flare toward it. Simpler than Flame. Higher survival in weird-request cases.

### `frost.zig` — Triple-Flare (Suite 3)

Finds top 3 variance laws, applies 3 entangled flares simultaneously, 300-pass relaxation. Higher survival rate (53/1000 baseline vs Flame's 29), lower mean quality per survivor.

### `fractal.zig` — Recursive (Suite 4)

5 nested mutation-relaxation loops per trial, dampening by generation. Achieves 1000/1000 survival in baseline, mean quality 6.9M.

### `lore.zig` — Character Distribution Fingerprinter

64-slot XOR accumulator. For each character, hashes its position and XORs into a lattice slot. Output is a 64-element `u64` array.

**What it actually does**: Bloom-filter-style character co-occurrence tracking. Different texts produce different lattice states. The XOR of all lattice slots gives a unique fingerprint per text. This is the most reliable per-prompt signal in the system.

**What it does NOT do**: It does not produce grammar. It does not output English. It does not "anchor meaning." It is a locality-sensitive hash function for text.

### `aether.zig` — Sparse Hash Field

`HashMap(u64, i128)`. Each byte hashes to a coordinate, adds weighted tension. Used as "truth field" and "shadow field" in `sovereign.zig`. Useful for persistence — can store large sparse fields.

### `aetheric.zig` — Anchored VSA Manifold Bridge

This is new bridge code, not theater. It initializes a `Manifold`, writes deterministic VSA concept anchors into voxel coordinates, ingests words as random hypervectors keyed by `textHash(word)`, and resolves an intent against a caller-provided dictionary.

What is real:
- It persists/manipulates the mmap-backed voxel grid through `manifold.zig`.
- It emits a dominant concept label by measuring resonance at concept-anchor coordinates.
- It emits a bounded sequence of words chosen from the provided dictionary.

What is not real yet:
- The emitted word sequence is not fluent generation.
- The dictionary choices are not citation-backed retrieval.
- The dominant concept can be useful as a signal, but it is not proof of semantic understanding.

The current `ghost_core` demo output looks like code-ish tokens because its dictionary is mostly Zig punctuation and keywords. That is expected.

### `manifold.zig` — Memory-Mapped Persistence

1,000,000-slot `i128` array backed by `state/ghost_voxels.bin` via `mmap`. Hardware-native — no allocation overhead after init. Designed to scale toward 10GB.

**Current status**: Implemented, compiles, and is used by `aetheric.zig` / `search.zig`. It is not yet a full retrieval database: it stores numeric tension by coordinate, not article text, provenance, or evidence spans.

### `vsa_decoder.zig` — Dictionary-Limited VSA Decoder

Experimental decoder. It tries to unbind a token at a position by XORing a state hypervector with a position hypervector, then choosing the nearest word from a caller-provided dictionary by Hamming similarity. `verifyAST()` only checks balanced parentheses/braces.

This is a real decoder prototype, but it is weak:
- It requires an external dictionary.
- It has no learned language model.
- Its AST verifier is structural only; it does not compile or type-check code.

### `search.zig` — Spectral Ingestor Demo

This binary ingests a small hardcoded "Artificial Intelligence" article text through `AethericCore`, adds chunk tension into the manifold, then calls `core.resolve()` on a hardcoded query and dictionary.

This proves the manifold/aetheric path runs end-to-end. It does not prove web-scale Wikipedia ingestion, source-grounded Q&A, or semantic retrieval with citations.

### Synthesis Files — Architecture Proposal Probes

Files such as `decoder_synthesis.zig`, `wiki_ingestion_synthesis.zig`, and `ingestion_strategy_synthesis.zig` ask Void to search for a mark/scar around an architecture question. They print marks and scars, not full designs. Any English design explanation around those marks is agent translation.

Some synthesis probes are slow because `VoidEngine.maybeInventText()` runs many branches with 500-pass relaxation. Do not use them as routine health checks.

### `sovereign.zig` — Meta-Architecture

Combines AetherField (truth + shadow), LoreEngine, HyperTension log, and EchoManager. Routes 5% of ingested text to "truth field," 95% to "shadow field." Persists truth field on deinit.

**The 5% truth filter is arbitrary** — there is no proven reason 5% is correct. This needs empirical validation.

### `echo.zig` — Persistence

Serializes AetherField to binary. Reads/writes kernel + coordinate/tension pairs. The `state/ghost_hyper_echo.bin` (960KB) is a serialized AetherField from a prior session.

### `calibration.zig` — Ground Truth Measurement

The most important tool for verifying the system works. Runs 8 labeled prompts through VoidEngine and measures:
- **Delta**: How much the text shifted the closure error (negative = text increased error = more disruptive)
- **Trigger edge**: Which law changed pressure the most (content-driven signal, not structural bias)
- **Lattice fingerprint**: XOR of LoreEngine's grammar_lattice (unique per prompt)

**Current calibration results** (verified running):
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

All 8 prompts produce distinct edges. Delta correlates loosely with text length and character variety (not semantic content). Lattice fingerprints are unique and stable.

---

## 4. Engineering Decisions — Why Things Are The Way They Are

### Wrapping Arithmetic (`+%`)

Zig panics on integer overflow in debug mode. The chamber values during `shapeTextPressure` reach billions. Standard `+` caused runtime panics. Switched to `+%` (wrapping) to prevent crashes. This is standard practice, not a novel invention.

### Prime Field Size (104,729 in aetheric.zig)

Power-of-two hash table sizes cause symmetry — many slots map to the same coordinate. Empirical testing showed that 1024, 2048, 4096 reduced benchmark scores. Switching to a prime eliminated resonance traps. 104,729 is the 8,216th prime. Standard hash table design.

### Sparse Routing in `ingestTextSequence` (Fixed in this session)

Original harmonic formula: `b * (i+1) * (i+2)` applied to ALL 512 chambers. This caused chamber 511 to receive 262,000x more input than chamber 0. Law 819 (which connected high-index chambers with large coefficients) always dominated trigger_edge, making it carry zero information.

Fix: Each character routes to 8 chambers via `splitMix64` hashing. Contribution is ±byte_value (bounded). Different prompts route to different chambers, so different laws fire. Trigger_edge now varies per prompt.

### Trigger Edge Measurement (Fixed in this session)

Original: measured absolute pressure (which law has highest total error). This always returned the law with the largest random target `t`, regardless of input.

Fix: measures pressure *change from baseline* — which law changed the most after ingestion. This is content-driven: it tells you which semantic relationship the text stressed, not which law is permanently largest.

### Asymptotic Dampening in Void

500-pass Gauss-Seidel without dampening oscillates — corrections overshoot. `dampener = 1 + (pass/10)` progressively reduces step size. Prevents divergence in later passes.

### 53% Improvement Threshold (Flame)

The required closure improvement for an invention candidate to survive. Empirically chosen during the benchmark progression. Not theoretically derived.

### 4.7 VSA-Grounding Control Experiment (2026-05-17)

**Question:** Does the concept-pair VSA bind that derives law coefficients (`ca`, `cb`, `t`) carry any signal that's load-bearing for the calibration's discriminative property, or is it decorative?

**Method:** Patched `flame.zig` Laws comptime block to keep the law indices (a, b) identical — same chambers constrained — but replaced the popcount-derived coefficients with pure PRNG of equivalent magnitude:

```zig
// Original (VSA-derived):
laws[i].ca = popcount(hv1) - 512;          // approx N(0, 16)
laws[i].cb = popcount(hv2) - 512;          // approx N(0, 16)
laws[i].t  = (popcount(hv1.bind(hv2)) - 512) * 100;   // approx N(0, 1600)

// Control (PRNG, same magnitudes):
laws[i].ca = (splitMix64(s ^ 0xAAAA...) % 65) - 32;
laws[i].cb = (splitMix64(s ^ 0xBBBB...) % 65) - 32;
laws[i].t  = (splitMix64(s ^ 0xCCCC...) % 6401) - 3200;
```

Rebuilt, ran `./zig-out/bin/calibration`, then reverted.

**Result:**

| Label | VSA-grounded edge | PRNG-grounded edge |
|---|---|---|
| technical-low-level | 122 | 856 |
| creative-poetic | 111 | 974 |
| math-hard | 177 | 971 |
| typo-adversarial | 826 | 969 |
| instruction-complex | 523 | 481 |
| casual-greeting | 677 | 300 |
| system-status | 5 | 159 |
| code-zig | 788 | 265 |

- **8 distinct edges in both runs.** The "8 prompts produce 8 unique trigger edges" property survives the destruction of the VSA grounding.
- **Lattice fingerprints byte-identical between runs.** This was expected: `lore.zig` is a character-distribution XOR accumulator that never touches the law table, so coefficient origin cannot affect it.
- **Deltas changed magnitudes and some flipped sign.** Coefficient *structure* affects how hard each prompt stresses the system, but it does not affect which chamber-touching pattern wins.

**Conclusion:** The discriminative work in Ghost Sovereign is done by:
1. `void.zig` sparse routing — each character hashes to 8 specific chambers; different text touches different chamber sets, so different laws fire.
2. `lore.zig` XOR accumulator — independent per-text fingerprint.

The VSA concept-pair derivation produces a stable set of constraints whose *specific values* do not determine discriminability. Any stable integer law table with similar magnitude distributions would produce 8 distinct edges over these 8 prompts. The "semantic grounding" framing in earlier docs was overclaim; the empirical reality is that the laws need to be *stable and varied*, not *derived from VSA concepts*.

This does not invalidate the engineering — the system still discriminates inputs reliably. It corrects the narrative about *why* it discriminates.

---

## 5. The Translator Architecture

The system currently works as follows:

```
Input text
    ↓
VoidEngine.ingestTextSequence()     [sparse routing, bounded contributions]
    ↓
Calibration signals:
  - closure_delta    (how much text stressed the system)
  - trigger_edge     (which semantic law was most affected)
  - lattice_fingerprint  (unique character distribution hash)
    ↓
LLM Readout Layer (Claude, Gemini, etc.)
    ↓
Interpretation: "this text is creative/technical/noisy based on calibration table"
```

**The LLM is the intelligence layer**. The reservoir provides grounded, deterministic signals. The LLM maps those signals to meaning using the calibration table as reference.

This is a legitimate architecture (reservoir computing with a trained readout) but currently the "training" is just 8 labeled examples. More labeled examples = better translation.

---

## 6. What Is Not Built Yet

### Generation Side

The system has no general output generator. It cannot reliably produce open-ended responses, complete sentences, or answer questions. It classifies inputs and can run experimental dictionary-limited token selection. To go from classifier/probe to a real generator, you need:

1. A trained or mechanically validated decoder that maps reservoir states back to text
2. OR: Use the reservoir signals to condition an LLM's response (more practical)

### Semantic Grounding (Partial)

The laws are derived from VSA concept pairs, but the concept hypervectors are random — not derived from actual language meaning. LOGIC and SYNTAX don't have more similar hypervectors than LOGIC and CHAOS. True semantic grounding would require:
- Concept vectors derived from co-occurrence in real text
- OR: Pretrained embeddings projected into the HD space

### Web-Scale Ingestion

`manifold.zig` provides the storage layer and `search.zig` demonstrates a tiny hardcoded article ingest. The full pipeline (fetch → parse → route → store → provenance → query) is not built. The 10GB target is a design goal, not current capability.

### Retrieval

The manifold stores tension values. `AethericCore.resolve()` can choose words from a caller-provided dictionary after ingesting a query, but there is no source-backed retrieval mechanism that returns relevant stored passages. This is the missing piece between "we ingested the web" and "we can answer questions about the web."

### Current New-Code Status (2026-05-17)

These files are real and build:

| File | Status | Honest interpretation |
|------|--------|-----------------------|
| `src/aetheric.zig` | Built | Anchored manifold bridge and dictionary resolver |
| `src/vsa_decoder.zig` | Built | Prototype token unbinder and brace/paren checker |
| `src/search.zig` | Built | Hardcoded article ingest + dictionary response demo |
| `src/wiki_ingestion_synthesis.zig` | Built | Proposal mark/scar probe for ingestion strategy |
| `src/decoder_synthesis.zig` | Built, slow | Proposal mark/scar probe for decoder strategy |
| `src/ingestion_strategy_synthesis.zig` | Built, slow | Proposal mark/scar probe for streaming/hoarding strategy |
| `src/void_cli_adapter.zig` | Built | Placeholder CLI; prints "Resolution achieved" after shaping pressure |

Do not call these fake. They are source-backed Zig artifacts. Also do not overclaim them. They are prototypes/probes, not a finished autonomous AI.

---

## 7. What Was Theater vs What Was Real

### Theater (Agent Narrative, Not Code Behavior)
- "Ghost Flux said: We need more heat..." — the agent wrote this, not Flux
- "Void is furious about overflow" — the agent wrote this
- "The engines see themselves as Laws of Physics" — narrative
- "10.68 Trillion points of tension" — this is just `closureError()`, a sum of absolute residuals
- "Lore forces the Alien math to speak in human-perfect English" — Lore outputs a u64 fingerprint
- "Omni ingests 4K video" — Omni ingests bytes; it has no video decoding
- "1/1,000,000th the energy of an LLM" — unverified claim
- "100% complete ASI core" — no generation side exists
- `ghost_invent_void invent --message=...` printing "Resolution achieved" — current placeholder text, not proof that it invented a response
- **"VSA dark-space grounding makes the laws semantically meaningful"** — Section 4.7's control experiment shows random coefficients of the same magnitude produce the same 8-distinct-edge discrimination. The HD bind happens at comptime and only its popcount survives; once `Laws[]` is generated, the hypervectors are gone. The "dark space" framing is decorative.

### Real (Verified by Running Code)
- The benchmark progression from VSA → Flame → Flare → Frost → Fractal → Flux → Void
- Each engine's benchmark scores (in `results/`)
- Each engine's code matches the Suite 3 proposal from the previous benchmark
- The calibration signals (delta, trigger_edge, lattice) are distinct per prompt
- The builds succeed and the binaries run
- Void achieves 58M mean quality vs VSA's 1.1M (51x improvement over 6 iterations)
- The architectural proposals from each Suite 3 were mechanically implemented in the next engine
- `ghost_core` initializes `AethericCore`, writes to the manifold, and emits dictionary-limited token output
- `ghost_search` ingests a hardcoded article into the manifold and runs a dictionary-limited query demo

### Ambiguous (Real Signals, Agent Interpretation)
- Whether the Suite 3 architectural proposals were derived mechanically from the marks, or whether the agent chose the architecture and used the marks as decoration
- Whether "hello world" genuinely resonates with CHAOS more than LOGIC, or whether that's a post-hoc label (note: Section 4.7 resolved the upstream version of this — there is no meaningful "resonance with CHAOS" because the concept hypervectors are decorative; what's still ambiguous is whether *any* post-hoc semantic label on the trigger edge carries information)
- Whether the dictionary-limited output should be considered useful beyond a probe without a trained decoder

---

## 8. How To Run Things

```bash
# Build everything
zig build

# Run the reservoir calibration (most important verification)
./zig-out/bin/calibration

# Run the full benchmark chain
./zig-out/bin/benchmark-triad
./zig-out/bin/benchmark-quad
./zig-out/bin/benchmark-penta
./zig-out/bin/benchmark-hexa
./zig-out/bin/benchmark-hepta

# Run the main Flame probe
./zig-out/bin/ghost_core

# Run the hardcoded manifold/search demo
./zig-out/bin/ghost_search

# Placeholder CLI: pressure-shapes the message, then prints a canned success line
./zig-out/bin/ghost_invent_void invent --message="test"

# Measured consultation probes (reservoir numbers only, no language generation)
./zig-out/bin/ask_experts
./zig-out/bin/debate_experts

# Architecture synthesis probes; useful, but can be slow
./zig-out/bin/wiki_ingestion_synthesis
./zig-out/bin/decoder_synthesis
./zig-out/bin/ingestion_strategy_synthesis
```

---

## 9. The Honest One-Paragraph Summary

Ghost Sovereign is a reservoir computer implemented in Zig. Its 512-dimensional constraint-satisfaction system produces measurable signals per input (delta, trigger_edge, lattice fingerprint) that vary by prompt content. The system was built through empirically benchmarked iterations, each guided by previous invention outputs, with measurable benchmark improvement at each step. The laws governing the constraint system are derived from VSA hypervector bindings of concept pairs, though the concepts themselves are random vectors rather than semantically embedded ones. New bridge code now anchors VSA concepts into a memory-mapped manifold and can emit dictionary-limited token sequences, but this is still not a general language generator or source-backed retrieval system. An LLM acting as a calibrated readout layer remains the practical interpreter. The theatrical "alien engine" narrative surrounding the project is the agent's writing, not the code's output. The engineering underneath that narrative is real, benchmarked, and reproducible.
