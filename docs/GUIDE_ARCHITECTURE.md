# Ghost Engine Architecture Guide

This is the short operator view of the shipped stack. Deferred work lives in [docs/ARCHITECTURE_PHASE1.md](docs/ARCHITECTURE_PHASE1.md).

## Runtime Shape

- `ghost_sovereign` is the main Linux-first runtime
- `ohl_trainer` consumes corpus text and etches state
- `sigil_core` compiles Sigil source
- `probe_inference` is a probe utility
- `ghost_code_intel` is the deterministic code-intel pilot
- `ghost_patch_candidates` stages proof-backed patch candidates
- `ghost_task_intent` grounds bounded natural-language requests into supported flows

The runtime mounts one committed shard, creates one shard-local scratch overlay, runs `boot.sigil`, and then starts the REPL and optional embedded shell.

## Shards

Implemented Layer 1 behavior:

- core shard: default committed state
- project shard: selected with `--project-shard=<id>` or `GHOST_PROJECT_SHARD=<id>`
- scratch behavior: temporary overlay attached to the mounted shard

Scratch is local to the mounted shard. It is not a separate committed runtime target.

## Reasoning

- Layer 2a is optional Vulkan acceleration for bounded helper work only
- Layer 2b is CPU-first and authoritative for branch-heavy reasoning
- Layer 3 is a small honesty gate at the output boundary

Proof policy is the default. Exploratory policy exists in code and is used inside patch-candidate exploration, but final permission stays honesty-gated.

## Code Intel And Patching

- `ghost_code_intel` supports `impact`, `breaks-if`, and `contradicts`
- native support is Zig-first with bounded C/C++ source and header indexing
- symbolic ingestion covers docs, config, markup, and DSL-like files so symbolic concepts can ground into bounded code/runtime targets
- `ghost_patch_candidates` runs `explore_then_proof`, verifies through the bounded execution harness, and prefers the smallest verified survivor
- both tools emit support graphs with explicit `permission` and `minimumMet` fields

## Shell And Sigil

`POST /api/sigil` accepts:

- Sigil VM source
- `begin scratch`, `discard`, `commit`, `snapshot`, `revert`, `rollback`
- `/commit_abstractions ...`
- `/reuse_abstractions ...`
- `/merge_abstractions ...`
- `/prune_abstractions ...`
- `/stage_patch_candidates ...`

`begin scratch` captures a discard baseline. `commit` makes staged shard-local changes live. `discard` throws staged work away. `snapshot` and `revert` operate only when scratch is inactive.

## Operational Extras

- panic dumps are implemented and deterministic on Linux at `/tmp/ghost-dd-panic.bin`
- code-intel results persist under the selected shard in `code_intel/`
- patch batches persist under the selected shard in `patch_candidates/`
- abstraction lineage, reuse, merge, and prune state persist under the selected shard in `abstractions/`

## Current Limits

- Linux is the primary documented environment
- the shipped boot path uses one startup script: `boot.sigil`
- there is no active binary plugin system
- the code-intel pilot is bounded and deterministic, not full semantic understanding
- runtime verification exists in the harness, but the benchmark suite does not yet contain a positive runtime-verified patch fixture
