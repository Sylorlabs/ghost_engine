# Ghost Engine Modding Surface

The supported extension surface is Sigil plus the embedded shell. Deferred work lives in [docs/ARCHITECTURE_PHASE1.md](docs/ARCHITECTURE_PHASE1.md).

## Supported Today

- `boot.sigil` is loaded at startup by `ghost_sovereign`
- `sigil_core` compiles `.sigil` source into `.sigbc`
- `POST /api/sigil` executes live Sigil and accepts shell control commands
- `/commit_abstractions ...` stages explicit abstraction distillation
- `GET /?channel=chat` opens the chat WebSocket bridge
- `--project-shard=<id>` or `GHOST_PROJECT_SHARD=<id>` switches the committed shard you are modding against

The runtime resolves `boot.sigil` through `build_options.project_root`, which is compiled into the binary.

## Practical Workflow

For shard-local experimentation:

1. `begin scratch`
2. send Sigil or `/commit_abstractions ...`
3. `commit` to make staged work live, or `discard` to throw it away

For shard-local checkpointing outside scratch:

1. `snapshot`
2. make live changes
3. `revert` or `rollback` to restore the snapshot

`/commit_abstractions` is not implicit learning. It is an explicit command, it requires an active scratch session, and its staged output only becomes live on `commit`.

## Live Endpoints

Sigil:

```text
POST /api/sigil
```

The request body can be raw Sigil text or JSON with a `script` or `sigil` field.

Chat:

```text
GET /?channel=chat
```

Send JSON text frames such as:

```json
{"type":"input","text":"Describe the current resonance field."}
```

## Sigil Surface

Working VM keywords:

- `MOOD`
- `LOOM`
- `LOCK`
- `SCAN`
- `BIND`
- `ETCH`
- `VOID`
- `TEST`

Working shell control commands:

- `begin scratch`
- `discard`
- `commit`
- `snapshot`
- `revert`
- `rollback`

Working `LOOM` commands:

- `VULKAN_INIT`
- `CPU_ONLY`
- `TIER_1`
- `TIER_2`
- `TIER_3`
- `TIER_4`

Compile manually when needed:

```bash
./zig-out/bin/sigil_core boot.sigil
```

## Not Supported

- Binary plugins
- Hot-loaded `.dll` or `.so` modules
- Automatic plugin discovery on boot
- A separate productized plugin API in the shell
- Automatic semantic distillation without an explicit `/commit_abstractions` command
- A user-facing runtime selector for exploratory reasoning mode

The repo contains compatibility and platform helpers outside this surface. They are not the current modding API.
