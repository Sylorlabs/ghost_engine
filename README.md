# Ghost — Structured/Exact Invention Engine

A small, CPU-only machine-**discovery** engine. No LLM, no GPU, no neural net, no hardcoded
answers. It invents mathematical facts from primitives and keeps only the ones a **sound
computational verifier** certifies — `generate → test → keep`, the FunSearch/AlphaEvolve shape,
done with exact arithmetic instead of a learned model.

Runs in **seconds**, in **megabytes**, on a **single CPU core**. Whole engine is 23 source files.

> **History.** This repo previously hosted a VSA/LLM/GPU engine (Z3 static analyzer + a Vector
> Symbolic Architecture "Oracle" + a native Gemma stack + an agentic platform). That was removed
> in the *invention-engine transition* — the structured/exact architecture replaced it. The full
> old engine is preserved and recoverable on origin at branch **`backup/vsa-llm-gpu-engine`**.

---

## What it does

Each tool enumerates candidate facts over a bounded grammar, **certifies each by exact computation**
over a finite range, refutes the rest **by explicit counterexample**, and abstains honestly when it
can't decide. Nothing is retrieved or looked up — the programs it proves were never written down.

```
$ zig build && ./zig-out/bin/ghost_discover_laws
generated 231 equivalence candidates · refuted 224 by counterexample · 41 laws survived
    n is a perfect square  ⟺  d(n) is odd            (Fermat)
    sigma(n) is odd        ⟺  n is square or twice a square

$ ./zig-out/bin/ghost_rune_forge
    etch [VERIFIED ] sum_{d|n} phi(d) == n        (certified over [1,4000])   (Gauss)
    etch [VERIFIED ] sum_{d|n} mu(d)  == [n==1]   (certified over [1,4000])   (Möbius)
    etch [NOISE    ] sum_{d|n} d == n             (REFUTED: counterexample n=2)
```

## Architecture (VSA-free)

| Layer | File(s) | Role |
|-------|---------|------|
| **Rank ladder** | `rank.zig` | epistemic promotion `noise → emerging → pattern → validated → verified`; `verified` never demoted. The keystone — extracted out of the old VSA `triad`, depends on nothing but `config`. |
| **Structured lattice** | `invention/structured_lattice.zig`, `invention/feature_sim.zig` | id-keyed frequency promotion + char-trigram cosine similarity (replaces the old hypervector rune lattice — no Hamming, no XOR). |
| **Exact lattice** | `invention/exact_lattice.zig` | certified-knowledge store: identity = exact canonical form (content-addressed, O(1) equality match, not fuzzy), riding the rank ladder. |
| **Forge** | `forge.zig` | rank-based training store over the structured lattice (no weights, no vectors). |
| **Core** | `ghost.zig`, `config.zig`, `sys.zig` | lean `ghost_core` module the tools link against. |

## The tools

**Certified-knowledge (link `ghost_core`):**
- `ghost_rune_forge` — forge discoveries into certified runes on the exact lattice (etch/lock/prune/shard).
- `ghost_medic_ingest` / `ghost_medic_solve` — structured diagnostic runes + a generate→verify→keep self-heal loop.

**Standalone discovery (pure `std`):**
- `ghost_discover_laws` — pairwise laws over integer features; rediscovers Fermat, digit-sum ÷3/÷9, σ-parity.
- `ghost_feature_invent` — invents the *vocabulary*: feature-programs deduped by behavior (→ discovered identities).
- `ghost_invent_sensors` — invents the *sensors* (`d(n)`, `σ(n)`, `isqrt`) from arithmetic + a loop-fold.
- `ghost_invent_compound` — compounding: facts unlocked only by round-2 compound features (e.g. Fermat).
- `ghost_closedform` — closed forms for iterative sequences via finite differences (Faulhaber, Nicomachus) + honest abstention.
- `ghost_auto_discover` — points the generator at its own program space; surfaces proven identities between different loops.
- `ghost_divisor_discover` — Dirichlet/divisor sums: Gauss `Σφ(d)=n`, Möbius inversion, `Σd=σ(n)`.
- `ghost_double_discover` — multivariable double sums (reflection/symmetry identities).
- `ghost_recur_discover` — order-1/2 recurrences → polynomial/geometric closed form, else abstain.
- `ghost_labs_search` — a genuinely-open target (Low-Autocorrelation Binary Sequences); certifies artifacts, no records claimed.

## Build & run

Requires only Zig (0.14+). No libc, no Z3, no Vulkan, no system packages.

```bash
zig build            # builds all 13 tools into zig-out/bin/
zig build test       # runs the structured-engine test suite
./zig-out/bin/ghost_divisor_discover
```

## Honest bounds

This is a real **component** of inductive discovery, not general intelligence. The grammars are
bounded, the sound verifier is *handed* to the engine (not invented by it), and the scale is small.
What it does that a lookup system cannot: it generates programs nobody wrote and proves them by
computation, refuting the rest by counterexample. Certifications are finite-range (e.g. `[1,4000]`),
i.e. strong empirical certificates, not general proofs — cross-checked independently in Python for
the headline results. It measures; it doesn't argue.
