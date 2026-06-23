# Invention engine → ghost_engine integration

Moves the `boundary_crossing` research-lab discovery loops into `ghost_engine` and wires their certified output
into the existing rune/sigil/shard representation, using a **beyond-XOR (ADD/MUL)** encoding rather than the
GF(2) `vsa_math.bind` (XOR), which the Closure Principle shows plateaus at chance on nonlinear readouts.

## What landed (branch `feat/invention-engine`, worktree off clean commit `97aa8ff2`)

**Step 1 — all 10 loops moved in** (`src/invention/`, `zig build discover` → `zig-out/bin/ghost_*`):
`ghost_discover_laws`, `ghost_feature_invent`, `ghost_invent_sensors`, `ghost_invent_compound`,
`ghost_labs_search`, `ghost_closedform`, `ghost_auto_discover`, `ghost_divisor_discover`, `ghost_double_discover`,
`ghost_recur_discover`. Pure-`std`, self-contained (build/run even while the core is mid-change), beyond-XOR by
construction (integer ADD/MUL). Verified: `ghost_divisor_discover` rediscovers Gauss `Σ_{d|n}φ(d)=n` + Möbius
inversion; `ghost_recur_discover`/`ghost_closedform` recover certified closed forms.

**Step 2 — beyond-XOR encoder → rune** (`src/invention/beyond_xor_encode.zig`, `ghost_beyond_xor_encode`):
- *Closure escape, measured.* Linear readout on additive/XOR features = **50%** on parity; with the MUL
  cross-term = **100%**. ADD/MUL escapes the GF(2) closure.
- *Discovery → rune.* A discovery is bundled (ADD) over role⊗filler MUL-binds, then projected (sign of random
  projections = LSH) to a 4096-bit `vsa_math.HyperVector` — the exact type `rune_lattice.observe()` takes.
  Distinct discoveries → orthogonal runes (cross-resonance ≈ 2048/4096).
- *Integration point (sigil/shards/runes kept, not replaced):*
  ```zig
  const slot = rune_lattice.observe(sig, context_hash, now_ms); // store discovery as a rune
  rune_lattice.verify(slot, now_ms);                            // certified ⇒ promote its rank
  ```

## Honest state / what's pending

- `ghost_core` is **unbuildable at this commit**: `src/ghost.zig` imports `zenith/wingman.zig`, which is absent
  from tracked history (used by `daemon.zig`). The `zenith_wingman_bridge` install is commented out on this branch
  to get a buildable base. The invention tools sidestep this entirely (no `ghost_core` import).
- Because of that, the encoder produces **lattice-compatible rune signatures** and documents the `observe`/`verify`
  calls, but does not yet call the live `rune_lattice` (its dep chain — `ghost_state`, `vsa_vulkan` → Vulkan —
  rides on the broken core). Wiring the live calls is a ~10-line change once `ghost_core` builds.

## Next
1. Land `src/zenith/{wingman,bridge}.zig` (or stub) so `ghost_core` builds → re-enable `zenith_wingman_bridge`.
2. Wire `ghost_beyond_xor_encode` to call the real `rune_lattice.observe/verify` (and persist via shards).
3. Verifier ladder: pipe a discovered closed form through `z3_bridge` to upgrade "certified on [1,M]" → proven ∀n.
4. Merge `feat/invention-engine` once the engineer's in-flight `main.zig`/zenith refactor lands.
