# Sigil Reference

This file documents the current source-backed shell and Sigil surface. It does not describe deferred ideas.

## VM Keywords

| Token | Notes |
|---|---|
| `MOOD` | Accepts a string, identifier, or integer |
| `LOOM` | Accepts a compute-mode command |
| `LOCK` | Accepts a numeric slot or symbolic label |
| `SCAN` | Accepts a string or identifier target |
| `BIND` | Accepts a rune value and label |
| `ETCH` | Accepts a label plus an optional weight |
| `VOID` | Hard-locks a label to zero |
| `TEST` | Executes a `{ ... }` block when the literal condition is true |

## Snapshot Control Commands

These are recognized by `POST /api/sigil` before VM execution:

| Command | Behavior |
|---|---|
| `begin scratch` | Starts a shard-local scratch session and writes a discard baseline |
| `discard` | Restores the scratch baseline, clears staged abstractions and patch batches, ends the session |
| `commit` | Applies scratch changes to permanent state, applies staged abstractions, clears staged patch batches, writes the committed snapshot |
| `snapshot` | Writes a full shard-local snapshot when scratch is inactive |
| `revert` | Restores the last snapshot when scratch is inactive |
| `rollback` | Alias for `revert` |

`snapshot`, `revert`, and `rollback` are rejected while a scratch session is active.

## Shell Workflow Commands

These are shell commands, not Sigil VM keywords. When sent through `POST /api/sigil`, the current Linux shell requires an active scratch session before staging them.

| Command | Current behavior |
|---|---|
| `/commit_abstractions ...` | Distills and stages abstraction output under the selected shard |
| `/reuse_abstractions ...` | Stages cross-shard reuse decisions for project shards |
| `/merge_abstractions ...` | Stages compatible abstraction merges and provenance-preserving promotions |
| `/prune_abstractions ...` | Stages decay-state updates or bounded collection of prunable concepts |
| `/stage_patch_candidates ...` | Stages proof-backed patch candidates under the selected shard |

Current staging rules:

- staged abstraction output becomes live only on `commit`
- staged patch batches are scratch-only and are cleared by `discard` or `commit`
- `revert` restores the last committed snapshot for the mounted shard when scratch is inactive
- merge and promote paths can be refused by provenance or trust rules

## Internal Opcodes

- `halt`
- `jmp_if_false`

## Operand Modes

- `none`
- `string`
- `integer`
- `rune_and_string`
- `loom_command`
- `immediate_bool`

## `LOOM` Commands

- `VULKAN_INIT`
- `CPU_ONLY`
- `TIER_1`
- `TIER_2`
- `TIER_3`
- `TIER_4`

Unknown `LOOM` values compile to `none` and are ignored by the VM.

## Syntax

- strings use double quotes
- integers can be decimal or hex
- comments can start with `//` or `#`
- `ETCH` weights can be written as a plain number or `@weight`
- `TEST` uses braces for its block

## Live Execution

The embedded shell executes through:

```text
POST /api/sigil
```

The request body can be raw text or JSON with a `script` or `sigil` field.
