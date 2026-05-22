# verify_cli — real Z3 verification of discovered champions

**Date:** 2026-05-21 (updated same day with corrections)
**Replaces:** the hardcoded `SMT_VERIFIED_FOUNDATIONAL_TRUTH` string in
`ghost_engine/src/invent_cli.zig` (audit-flagged as a lie).

## What it does

`verify_cli` reads a discovered-champion CSV and runs it through real
Z3 (linked from `/usr/lib/x86_64-linux-gnu/libz3.so`). It returns one
of `VERIFIED`, `COUNTER-EXAMPLE`, `UNKNOWN`, or `ERROR`.

Two domains supported:

- **sort_net** (`--domain=sort`): correctness via Knuth's 0/1
  principle. A network sorts all integer inputs iff it sorts all
  Boolean inputs. Wires are SSA `Bool`; comparator (i,j) writes
  `x_i' := x_i ∧ x_j`, `x_j' := x_i ∨ x_j`. Bad-output assertion:
  some adjacent output pair has the wrong ordering. UNSAT ⇒ correct.

- **mixer** (`--domain=mixer`): bijectivity over `BitVec(W)`. Two
  symbolic inputs `a ≠ b`, both run through the same program, assert
  outputs equal. UNSAT ⇒ no collision ⇒ bijective.

Both domains support `--lib=p1,p2,…` to inline `kind=1`/`CALL_LIB`
references against prior-generation champions, exactly mirroring the
runtime `chain_extras` mechanism.

## Code→SMT, not SMT→code

The historical attempt at SMT-guided synthesis ("SMT→code") failed at
mathematical translation. This tool runs the inverse direction
("code→SMT"), which is mechanical — each opcode lowers to a fixed
SMT-LIB2 template.

## Why eval_smtlib2_string, not ast_vector

First implementation used `Z3_parse_smtlib2_string` → `Z3_mk_solver` →
`Z3_solver_assert` per formula. Z3's default error handler aborted
the process with "Error: invalid argument" when an inconsistent
ast_vector was passed. The clean path is
`Z3_eval_smtlib2_string`: parses, asserts, check-sats, returns
"sat" / "unsat" / "unknown" textually. We also install a silent error
handler via `Z3_set_error_handler` so any Z3-level error surfaces
through `Z3_get_error_code` rather than killing the process.

`(get-model)` is NOT included in emitted SMT — it errors on UNSAT
(which is the success case for our properties). Counter-example
witnesses are not currently extracted; verdict alone is the contract.

## SMT emitter correctness matters more than the runner

While developing, I discovered two bugs in the *emitter* (not the
runner) that produced false COUNTER-EXAMPLEs:

1. **MUL was wrong.** I emitted `(bvmul src1 src2)`. The runtime is
   `regs[dst] = a *% (imm | 1)` — a literal odd multiplier, not the
   second register. Corrected.
2. **SPLITMIX_STEP was wrong.** I emitted the full 3-step splitmix
   formula. The runtime is `(a ^ (a >> sh)) *% (b | 1)`. Corrected.

This is why **code→SMT verification only works if the emitter mirrors
runtime exactly.** Discrepancies are silent: solver returns wrong
verdict on correctly-functioning code. The fix path is always
"audit the runtime semantics, mirror them in the emitter" — never
"trust the emitter and audit the discovered program."

## Current results

| target                              | bits | verdict          | notes                                                    |
|-------------------------------------|------|------------------|----------------------------------------------------------|
| chain_sort/gen_0_champion           | -    | VERIFIED         | canonical 22-comparator sorter (15 ms)                   |
| chain_sort/gen_0 (first 10 comps)   | -    | COUNTER-EXAMPLE  | negative test passes (incomplete sorter rejected)        |
| chain_sort/gen_1_champion           | -    | COUNTER-EXAMPLE  | without --lib (CALL_LIB treated as identity)             |
| chain_sort/gen_1_champion + lib=gen_0 | -  | **VERIFIED**     | with CALL_LIB inlined — chain composes correctly         |
| chain/gen_0_champion                | 8    | **COUNTER-EXAMPLE** | self-feedback SPLITMIX_STEP at end → not bijective    |
| chain/gen_0_champion                | 16   | COUNTER-EXAMPLE  | same defect holds at wider width                         |
| chain/gen_1_champion                | 8/16 | VERIFIED         | only because CALL_LIB→identity hides gen_0's defect      |
| chain/gen_2_champion                | 8/16 | VERIFIED         | same caveat                                              |
| chain/gen_3_champion                | 8/16 | VERIFIED         | same caveat                                              |
| chain/gen_{1,2,3} + progressive lib | 8    | COUNTER-EXAMPLE  | non-bijection in gen_0 propagates through chain          |

**Bijectivity is not a chain invariant.** The mixer chain's fitness
function rewards avalanche/balance/chi-square, not bijection. The
"champion" status does NOT imply bijection. A user who *wants*
bijective mixers should either (a) penalize non-bijection in the
fitness, or (b) post-filter champions through verify_cli before
shipping.

The sort_net chain *does* hold up under composition: gen_1+gen_0 inlined
is a valid sorter. Different chain, different property semantics.

## Build / run

```
cd ghost_sovereign
zig build -Doptimize=ReleaseFast
./zig-out/bin/verify_cli --domain=sort  --csv=results/chain_sort/gen_0_champion.csv
./zig-out/bin/verify_cli --domain=sort  --csv=results/chain_sort/gen_1_champion.csv \
    --lib=results/chain_sort/gen_0_champion.csv
./zig-out/bin/verify_cli --domain=mixer --csv=results/chain/gen_0_champion.csv --bits=8
./zig-out/bin/verify_cli --domain=mixer --csv=results/chain/gen_3_champion.csv --bits=8 \
    --lib=results/chain/gen_0_champion.csv,results/chain/gen_1_champion.csv,results/chain/gen_2_champion.csv
```

Flags: `--lib=p1,p2,…` (CSVs to inline at CALL_LIB sites; order = chain
order), `--bits=N` (mixer width, default 8), `--timeout-ms=N` (Z3
timeout, default 30000), `--dump-smt` (echo emitted SMT-LIB2).

## Caveats

- 8/16-bit mixer verification is a fast over-approximate test. A
  64-bit-bijective program may fail 8-bit-bijectivity (and vice
  versa) when constants narrow oddly. The current emitter masks
  ADD_CONST/MUL constants and shift amounts to fit `W`.
- 64-bit mixer bijectivity is generally intractable for Z3 on
  non-trivial programs in reasonable time.
- Counter-example model extraction is not implemented (verdict only).
- The SMT emitter is the trust boundary — if a future opcode is
  added to `domain_u64_mixer.zig` and the emitter doesn't get a
  matching case, calls into that opcode silently emit a no-op
  assertion. Always add the matching emitter case when adding an
  opcode.

## Companion: real verification in invent_cli

`ghost_engine/src/invent_cli.zig` now calls libz3 directly (via the
same `Z3_eval_smtlib2_string` + silent-error-handler pattern) on the
SMT it generates. The hardcoded
`verification_status = "SMT_VERIFIED_FOUNDATIONAL_TRUTH"` is replaced
with one of:

- `SMT_UNSAT (no model exists — constraint set is contradictory)`
- `SMT_SAT (concrete model found — constraints are satisfiable)`
- `SMT_UNKNOWN (solver gave up — likely timeout)`
- `SMT_ERROR (bad SMT or runtime error)`

The standalone `verify_qflia_smoke` binary in this repo demonstrates
the exact code path that invent_cli now uses, against
invent_cli-shaped QF_LIA formulas. (Full `ghost_invent` cannot be
built right now because of unrelated pre-existing breakage in
`ghost_core` — missing `src/zenith/wingman.zig`. The invent_cli
change parses cleanly under `zig ast-check`.)
