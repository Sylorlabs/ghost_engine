# Architecture — Ghost Structured/Exact Invention Engine

This is the canonical technical reference. For a quick tour see [`../README.md`](../README.md).

> The previous Z3+VSA+Gemma+agentic engine was removed in the invention-engine transition and is
> recoverable on origin at `backup/vsa-llm-gpu-engine`. Older docs describing it were deleted;
> only `docs/ideas/` (forward-looking brainstorm notes) was kept.

## Principle

`generate → test → keep` with a **sound computational verifier**.

The engine enumerates candidate facts over a bounded grammar, certifies each by **exact
computation** over a finite range, **refutes** the rest by explicit counterexample, and
**abstains** when it cannot decide. There is no model, no training, no retrieval — the certified
results are programs that were never written down, proven by running them.

Why computation and not text: an earlier text-conjecture loop scored ~5% (correlated noise). A
verifier must be *sound* and *outside the symbols it judges*. Text isn't; arithmetic is.

## Module graph

```
ghost.zig (ghost_core)
├── rank.zig        RuneRank ladder (noise→emerging→pattern→validated→verified); verified never demoted
│   └── config.zig  tuning constants (reads build_options: test_mode/project_root/platform_subdir)
└── forge.zig       rank-based training store (no weights; logs via std.debug.print)
    └── invention/structured_lattice.zig   id-keyed frequency promotion + cosine
        └── invention/feature_sim.zig      char-trigram FeatureSet + cosine similarity

invention/exact_lattice.zig   certified-knowledge store (exact canonical-form identity) → ghost_core.rank
invention/rune_forge.zig      drives exact_lattice (etch/lock/prune/scan/shard)
medic_{ingest,solve}_cli.zig  structured diagnostics + generate→verify→keep self-heal → ghost_core.rank
invention/<discovery tools>   standalone (pure std), no ghost_core
```

No `HyperVector`, no XOR, no Hamming, no GPU, no Vulkan, no libc, no external packages.

## The rank ladder (`rank.zig`)

The engine's epistemic core, extracted out of the old VSA `triad` so nothing structured depends
on VSA. A fact is ranked, never weighted:

| rank | meaning |
|------|---------|
| `verified` (1) | certified by the sound verifier (or human). **Never demoted.** |
| `validated` (2) | automated check passed |
| `pattern` (3) | seen 100+ times across 3+ contexts |
| `emerging` (4) | seen 5+ times — a conjecture under observation |
| `noise` (5) | seen once / refuted — auto-pruned, never committed |

`rune_forge` maps this directly: a discovery enters `emerging`, becomes `verified` when certified,
or `noise` when refuted by counterexample (e.g. `Σ_{d|n} d == n` is refuted at `n=2`).

## Lattices

- **`structured_lattice` + `feature_sim`** — fuzzy store for training: id-keyed frequency promotion
  up the rank ladder, similarity by char-trigram cosine. Replaces the old hypervector rune lattice
  (no Hamming distance, no bit-packing).
- **`exact_lattice`** — certified-knowledge store: identity is the *exact canonical form*
  (content-addressed, O(1) structural equality), not a fuzzy match. Proofs aren't approximate, so
  the knowledge path is exact.

## Discovery tools (what each proves)

| tool | space | headline result |
|------|-------|-----------------|
| `discover_laws` | pairwise feature laws | Fermat (`square ⟺ d(n) odd`), digit-sum ÷3/÷9, σ-parity |
| `feature_invent` | feature-programs deduped by behavior | Fermat as a discovered identity |
| `invent_sensors` | arithmetic + loop-fold | invents `d(n)`, `σ(n)`, `isqrt` |
| `invent_compound` | round-2 compound features | Fermat unlocked only by compounding |
| `discover_closedform` | iterative sequences + finite differences | Faulhaber, Nicomachus + honest abstention |
| `auto_discover` | the loop/branch program space itself | proven identities between distinct loops |
| `divisor_discover` | Dirichlet/divisor sums | Gauss `Σφ(d)=n`, Möbius inversion, `Σd=σ(n)` |
| `double_discover` | multivariable double sums | reflection/symmetry identities |
| `recur_discover` | order-1/2 recurrences | polynomial/geometric closed forms, else abstain |
| `labs_search` | open problem (LABS merit factor) | certified artifacts; no records claimed |
| `prove_divisor` | the divisor identities, **proven** | from *check* to *proof*: multiplicative reduction → prime powers → polynomial identity at `2k+2` primes ⟹ proven `∀n` with prime exponents ≤ K (infinite class); false identities disproven by counterexample |

## Active direction: from check to proof

The discovery tools *certify* over a finite range — a strong empirical certificate, not a proof.
`prove_divisor` is the first step in elevating `verified` to **proven `∀n`**. For multiplicative
arithmetic functions the chain is sound and decidable: (1) both sides multiplicative (structural,
from the multiplicative basis); (2) multiplicative ⇒ determined by prime powers, so `∀n` reduces to
`∀ p^k`; (3) at fixed `k` both sides are polynomials in `p` of degree ≤ 2k, so agreement at `2k+2`
distinct primes is a polynomial identity — a proof for **all** `p`. This gives proofs for all `n`
with prime exponents ≤ K.

**The exponent bound is then dropped by telescoping induction on k** for the divisor-sum form
`f(n)=Σ_{d|n} h(d)`: the divisors of `p^{k+1}` are those of `p^k` plus `p^{k+1}`, so the proof
reduces to a base case + the step `g(p^{k+1})−g(p^k)=h(p^{k+1})`. The step is an *integer*
polynomial in `(p, X=p^k, k)` (the rational `1/(p−1)` in `σ` cancels in the difference); vanishing
on a `6×12` prime/exponent grid — unisolvent for `deg_p≤3, deg_X≤2, deg_k≤2` — proves it for **all**
`p,k`. Result: **Gauss, `Σ1=d(n)`, `Σd=σ(n)`, Möbius `Σμ(d)=[n=1]` are proven for all n, no exponent
ceiling.** Remaining: Möbius **inversion** is a convolution `(μ*id)`, not a `Σh(d)`, so it stays
exp-bounded until the convolution recurrence `f(p^{k+1})=p·f(p^k)+…` is added — the next step.

## Tests

`zig build test` compiles every source file and runs the assertion suites — including the
number-theory primitives and the **headline identities themselves** (Fermat in `discover_laws`;
Gauss/Möbius/σ in `divisor_discover`), so a regression in a certified result fails CI.

## Honest bounds

A real component of inductive discovery (FunSearch/AlphaEvolve shape), not general intelligence.
Grammars are bounded; the sound verifier is handed to the engine, not invented by it; certificates
are finite-range (strong empirical, not general proofs). It measures; it doesn't argue.
