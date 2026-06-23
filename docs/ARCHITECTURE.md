# Ghost Engine Architecture

This file describes implemented behavior only. Deferred work lives in [docs/ARCHITECTURE_PHASE1.md](docs/ARCHITECTURE_PHASE1.md).

## Current Top Level

| Path | Current role |
|---|---|
| `build.zig` | Build graph, installed executables, benchmark step |
| `src/main.zig` | Linux-first runtime entrypoint, shard mount, boot Sigil, shell startup |
| `src/trainer.zig` | Corpus trainer with Vulkan workers or CPU fallback |
| `src/shell.zig` | OS switch for the embedded shell |
| `src/shell_linux.zig` | Primary embedded HTTP and WebSocket shell |
| `src/shell_windows.zig` | Secondary compatibility shell path |
| `src/sigil_core.zig` | Sigil compiler |
| `src/sigil_vm.zig` | Sigil VM execution over committed or scratch meaning surfaces |
| `src/sigil_runtime.zig` | Runtime control-plane state |
| `src/sigil_snapshot.zig` | Scratch, commit, snapshot, discard, and revert control flow |
| `src/abstractions.zig` | Explicit abstraction distillation, reuse, merge, prune, lineage, and provenance |
| `src/code_intel.zig` | Deterministic code-intel pilot with native and symbolic indexing |
| `src/task_intent.zig` | Narrow natural-language grounding into supported code-intel or patch flows |
| `src/patch_candidates.zig` | Explore-to-proof patch planning, verification, and minimality selection |
| `src/execution.zig` | Bounded verification harness for build, test, and runtime steps |
| `src/technical_drafts.zig` | Deterministic human-readable rendering over bounded traces |
| `src/bench_serious_workflows.zig` | Serious-workflow benchmark runner and report writer |
| `src/panic_dump.zig` | Deterministic panic dump recorder |
| `src/vsa_vulkan.zig` | Vulkan runtime and bounded GPU helper dispatch |
| `src/shaders/` | Compute shader sources and checked-in `.spv` binaries |
| `tools/seed_lattice.zig` | Seeds committed shard state |

## Installed Binaries

`build.zig` installs:

- `ghost_sovereign`
- `ohl_trainer`
- `probe_inference`
- `sigil_core`
- `ghost_code_intel`
- `ghost_patch_candidates`
- `ghost_task_intent`

The serious-workflow benchmark runner is built and exposed through the `zig build bench-serious-workflows` step. It is not an installed runtime binary.

## Layer Model

Layer 1 is implemented as shard-aware state.

- core committed shard: `platforms/linux/x86_64/state/shards/core/core/`
- project committed shards: `platforms/linux/x86_64/state/shards/projects/<id>/`
- scratch behavior: a temporary overlay bound to the currently mounted committed shard

Each committed shard owns:

- `unified_lattice.bin`
- `semantic_monolith.bin`
- `semantic_tags.bin`
- `sigil/scratch/`
- `sigil/committed/`
- `sigil/snapshot/`
- `abstractions/`
- `code_intel/`
- `patch_candidates/`

Layer 2a is implemented as bounded GPU helpers only.

- candidate scoring
- neighborhood scoring
- contradiction filtering

Layer 2b is CPU-first and authoritative.

- bounded hypothesis expansion
- contradiction pruning
- branch-cap enforcement
- final selection

Layer 3 is a tiny honesty gate.

- it decides whether bounded search resolved cleanly
- it can stop on low confidence, contradiction, budget, or internal error
- it is not a separate reasoning engine

Proof policy is the default. Exploratory policy exists as an explicit alternate budget in code and is used inside the patch-candidate handoff flow, but it is not a hype-first best-effort mode.

## Runtime And Shell

`ghost_sovereign`:

- mounts the selected committed shard
- verifies lattice checksums on startup
- creates a shard-local scratch overlay
- executes `boot.sigil`, or falls back to `LOOM VULKAN_INIT`
- enables Vulkan only when Sigil allows it and runtime init succeeds
- flushes and crystallizes mapped state on clean shutdown

Current runtime flags:

- `--project-shard=<id>`
- `--scratchpad-bytes=<n>`
- `--reasoning-mode=proof|exploratory`
- `--daemon`
- `--no-shell`

The Linux shell surface is:

- `GET /api/stats`
- `GET /api/corpora`
- `GET /api/state`
- `GET /api/probe`
- `POST /api/train`
- `POST /api/stoptrain`
- `POST /api/pause`
- `POST /api/resume`
- `POST /api/checkpoint`
- `POST /api/control`
- `POST /api/sigil`
- `GET /?channel=chat`

## Sigil, Scratch, And Replay

Sigil is a bounded Ghost procedure/control DSL, not an authority language.

Sigil can express:

- local control-plane tuning such as `MOOD`, `LOOM`, `LOCK`, and `SCAN`
- scratch-session meaning candidates through `BIND`, `ETCH`, and `VOID`
- explicit lifecycle commands routed through snapshot control

Sigil cannot authorize final support, create proof, execute arbitrary shell,
promote negative knowledge, silently mutate packs, or bypass support/proof
gates. Sigil VM output is candidate/control/procedure state only until external
verifier evidence supports a claim through the normal proof path. Static
validation runs before VM execution and fails closed on unknown statements,
unsupported `LOOM` commands, authority-forbidden tokens, invalid bytecode shape,
and meaning mutations outside an explicit scratch-session execution scope.

`POST /api/sigil` accepts:

- Sigil VM source
- exact snapshot-control commands
- explicit abstraction commands
- explicit patch-staging commands

Implemented control commands:

- `begin scratch`
- `discard`
- `commit`
- `snapshot`
- `revert`
- `rollback`

Behavior:

- `begin scratch` writes a shard-local scratch baseline
- `discard` restores that baseline and clears staged abstraction and patch output
- `commit` applies scratch data to permanent mappings, applies staged abstractions, clears staged patch batches, and writes the committed snapshot
- `snapshot` writes a full shard-local snapshot only when scratch is inactive
- `revert` restores the saved snapshot only when scratch is inactive

Snapshot replay covers Sigil state and abstraction lineage state for the mounted shard. Scratch is session-local and intentionally discardable.

## Code Intel

`ghost_code_intel` is implemented as a deterministic pilot.

- query kinds: `impact`, `breaks-if`, `contradicts`
- output is bounded and honesty-gated
- results persist under the selected shard in `code_intel/last_result.json`
- ambiguous targets return `unresolved`
- the tool does not claim full-language semantic understanding

Current indexed surfaces:

- Zig source
- bounded native source and headers: `.c`, `.cc`, `.cpp`, `.cxx`, `.h`, `.hh`, `.hpp`, `.hxx`
- `.comp` and `.sigil`
- symbolic files such as markdown, text, config, markup, and DSL-like sources

Trace output uses the repository's current layer names:

- `layer1`: deterministic repo index size
- `layer2a`: target-resolution candidates
- `layer2b`: query hypotheses, abstraction traces, and symbolic groundings
- `layer3`: honesty status and confidence

Support graph output is part of the JSON result. It includes:

- `permission`: final output permission (`supported` or `unresolved`)
- `minimumMet`: whether the minimum support threshold for final permission was met
- `flowMode`: current reasoning flow name
- `unresolvedReason`: why support permission was denied when unresolved

## Task Intent

`ghost_task_intent` and the `--intent=` options on `ghost_code_intel` and `ghost_patch_candidates` provide narrow task-intent grounding.

Implemented grounding scope:

- action matching for build, implement, refactor, explain, verify, compare, and plan
- explicit target extraction from files, functions, modules, shards, concepts, symbols, quoted strings, and path-like tokens
- bounded constraint capture such as determinism, Linux-first, no-new-deps, API stability, performance, and language hints
- deterministic dispatch into `code_intel` or `patch_candidates`

If the request does not ground into a supported flow, the parser returns `clarification_required` or `unresolved`.

## Patch Candidates

`ghost_patch_candidates` consumes bounded `code_intel` output and produces proof-backed patch scaffolds.

Implemented behavior:

- initial analysis runs in exploratory mode
- generated candidates are clustered and trimmed into a proof queue
- proof mode verifies queued candidates through the bounded execution harness
- surviving verified candidates are ranked again under proof policy
- the selected winner prefers smaller verified scope through the minimality model `bounded_refactor_minimality_v1`
- if no candidate survives verification or proof selection, final output is `unresolved`

Patch output includes:

- staged or CLI JSON with candidate hunks and per-candidate verification traces
- `handoff` telemetry for exploration and proof phases
- `supportGraph` with `flowMode` set to `explore_then_proof`

## Abstractions, Provenance, And Trust

Abstractions are explicit. They are not inferred implicitly from arbitrary runtime behavior.

Implemented commands:

- `/commit_abstractions ...`
- `/reuse_abstractions ...`
- `/merge_abstractions ...`
- `/prune_abstractions ...`
- `/stage_patch_candidates ...`

Current trust and provenance behavior:

- abstraction records carry lineage ids, lineage versions, trust class, decay state, and bounded provenance entries
- cross-shard reuse is available while mounted on a project shard
- merge can refuse on incompatible records or provenance/trust violations
- promotion requires a strictly higher-trust destination
- snapshot write and restore paths include abstraction catalog state and reuse state for the mounted shard

## Execution Harness

`src/execution.zig` implements the verifier used by patch candidates and the serious-workflow benchmark.

Current guarantees:

- workspace-root confinement
- allowlisted shell tools only for shell steps
- bounded `zig build` and `zig run` surfaces only
- capped output capture
- bounded timeouts
- explicit failure signals such as `disallowed_command`, `timed_out`, `nonzero_exit`, and `invariant_failed`

The harness is Linux-first and is deliberately narrower than a general shell agent.

## Benchmarks

The serious-workflow suite measures implemented workflow behavior, not open-ended chat performance.

Latest Linux report in this workspace:

- 15 total cases, 15 passed
- patch compile-pass rate: 85% (12/14)
- test-pass rate: 75% (9/12)
- runtime-pass rate: 0% (0/0) because no positive runtime-verified patch fixture exists yet
- latency per verified result: 6940 ms
- cold start / warm start: 40 ms / 56 ms
- cold cache changed files / warm cache changed files: 11 / 0

## Panic Dumps

Panic dump support is implemented.

- the runtime installs `panic_dump.panicCall` as the panic hook
- Linux dumps are written to `/tmp/ghost-dd-panic.bin`
- the binary format is deterministic and versioned
- dumps include the last bounded reasoning trace and scratch references when present

## Deferred

Future work belongs in [docs/ARCHITECTURE_PHASE1.md](docs/ARCHITECTURE_PHASE1.md), not here.
