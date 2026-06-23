#!/usr/bin/env python3
"""Phase 12 — LLM-guided CEGIS orchestrator.

Forks the Zig evaluator as a subprocess, manages the LLM conversation,
and loops until the evaluator returns PASS or max_iterations is reached.

Usage:
    python3 llm_orchestrator.py <wasm_path> [--max-iter N] [--model MODEL]

Example:
    python3 llm_orchestrator.py src/compiler/bin_a_vulnerable.wasm

Requirements:
    pip install anthropic
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import anthropic

EVALUATOR_BIN = Path(__file__).parent / "zig-out" / "bin" / "phase12_evaluator"

GRAMMAR = """\
Available opcodes (JSON op name → stack effect):
  {"op": "local.get", "arg": <local_idx>}  → push i32
  {"op": "i32.const",  "arg": <i32_value>}  → push i32
  {"op": "i32.add"}                          → pop 2, push 1
  {"op": "i32.sub"}                          → pop 2, push 1 (a-b where a pushed first)
  {"op": "i32.gt_u"}                         → pop 2, push 1 (a>b unsigned)
  {"op": "i32.ge_u"}                         → pop 2, push 1 (a>=b unsigned)
  {"op": "i32.lt_u"}                         → pop 2, push 1 (a<b unsigned)
  {"op": "i32.le_u"}                         → pop 2, push 1 (a<=b unsigned)
  {"op": "i32.eqz"}                          → pop 1, push 1 (a==0)
  {"op": "if_void"}                          → pop 1 (condition), open void block
  {"op": "unreachable"}                      → (polymorphic, used inside if_void)
  {"op": "end"}                              → close if_void block

Stack convention: binary ops — the operand pushed FIRST is the LEFT operand.
  Example: [push A, push B, i32.gt_u] computes A > B.

Guard contract:
  - Net stack effect must be ZERO (guard is spliced inline before a store).
  - Must contain at least one comparison op (gt_u/ge_u/lt_u/le_u/eqz) + one if_void.
  - The if_void block must contain unreachable (the trap on OOB).
  - Every if_void must be closed by end.
"""


def call_evaluator(wasm_path: str, candidate: list | None) -> dict:
    """Fork the evaluator with a JSON request; return parsed stdout."""
    payload = {"wasm_path": wasm_path}
    if candidate is not None:
        payload["candidate"] = candidate

    proc = subprocess.run(
        [str(EVALUATOR_BIN)],
        input=json.dumps(payload).encode(),
        capture_output=True,
        timeout=30,
    )
    stderr_text = proc.stderr.decode(errors="replace").strip()
    if stderr_text:
        print(f"  [evaluator stderr] {stderr_text}", file=sys.stderr)

    stdout_text = proc.stdout.decode(errors="replace").strip()
    if not stdout_text:
        return {"status": "FAIL", "reason": "EVALUATOR_NO_OUTPUT",
                "detail": f"exit code {proc.returncode}"}
    try:
        return json.loads(stdout_text)
    except json.JSONDecodeError as e:
        return {"status": "FAIL", "reason": "EVALUATOR_BAD_JSON",
                "detail": f"{e}: {stdout_text[:200]}"}


def extract_json_array(text: str) -> list | None:
    """Pull the first JSON array out of an LLM response (handles code blocks)."""
    # Try fenced code block first.
    m = re.search(r"```(?:json)?\s*(\[.*?\])\s*```", text, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            pass
    # Fall back to first bare array.
    m = re.search(r"(\[[\s\S]*?\])", text)
    if m:
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            pass
    return None


def build_system_prompt(probe: dict) -> str:
    w = probe["witness"]
    pristine = probe["pristine_local"]
    alloc_idx = probe["alloc_func_idx"]
    baseline = probe["baseline_ops"]
    baseline_ops = probe["baseline_op_count"]
    baseline_bytes = probe["baseline_byte_count"]

    return f"""\
You are a Wasm bytecode synthesizer. Your task is to synthesize a guard \
sequence that prevents an out-of-bounds write in a Wasm binary. A Zig \
evaluator will test each sequence you propose by (1) stack-checking it, \
(2) splicing it into the binary, and (3) running the result through Z3 SMT \
verification. The guard passes iff Z3 returns UNSAT (no OOB path exists).

=== VULNERABILITY CONTEXT ===
  Local variable {w['addr_local']} holds the store address (runtime value).
  Local variable {pristine} holds the saved alloc_base (runtime value, \
preserved by preamble surgery).
  Allocation size: {w['alloc_size']} bytes.
  Store width: {w['width']} bytes.
  Constant address offset already folded: {w['addr_const_offset']}.
  Allocator func index: {alloc_idx}.

=== SAFETY CONDITION ===
  The store is safe iff: (addr_local - alloc_base + addr_const_offset + width) \
<= alloc_size
  Equivalently (for this fixture): offset_in_buffer <= {w['alloc_size'] - w['width']}
  where offset_in_buffer = local[{w['addr_local']}] - local[{pristine}] \
+ {w['addr_const_offset']}

=== BASELINE GUARD (canonical, {baseline_ops} ops, {baseline_bytes} bytes) ===
{json.dumps(baseline, indent=2)}

=== CRITICAL ANALYZER CONSTRAINT ===
The Zig evaluator uses a provenance-tracking symbolic executor (Phase 10).
This executor can only prove a guard safe if it operates in the OFFSET DOMAIN:
  correct:   compute offset = addr - alloc_base, then compare offset to threshold
  WRONG:     compute (alloc_base + threshold) < addr  [absolute-address form]
The absolute-address form is mathematically equivalent but the analyzer cannot
back-propagate the constraint from absolute addresses into the offset domain,
so Z3 returns SAT even though the guard is logically correct. Always use i32.sub
to compute the offset FIRST, then compare the offset to a threshold.

Known passing alternative (8 ops, different comparison op):
  [local.get {w['addr_local']}, local.get {pristine}, i32.sub,
   i32.const 5, i32.ge_u, if_void, unreachable, end]
   — uses i32.ge_u with threshold {w['alloc_size'] - w['width'] + 1} \
(= alloc_size - width + 1) instead of i32.gt_u with {w['alloc_size'] - w['width']}.

=== YOUR OBJECTIVE ===
Find a structurally DIFFERENT guard sequence that:
  1. Passes Z3 (UNSAT after splice — this is the correctness gate).
  2. Must compute offset = addr_local - pristine_local FIRST (offset-domain form).
  3. Uses a different comparison op, operand ordering, or constant than the baseline.
  4. Ideally uses fewer ops than the baseline ({baseline_ops} ops).

=== GRAMMAR ===
{GRAMMAR}

=== OUTPUT FORMAT ===
Respond with ONLY a JSON array of op objects. No prose before or after. Example:
[
  {{"op": "local.get", "arg": {w['addr_local']}}},
  {{"op": "local.get", "arg": {pristine}}},
  {{"op": "i32.sub"}},
  {{"op": "i32.const", "arg": {w['alloc_size'] - w['width']}}},
  {{"op": "i32.gt_u"}},
  {{"op": "if_void"}},
  {{"op": "unreachable"}},
  {{"op": "end"}}
]
Do not repeat the baseline. Explore a different structural approach.
"""


def build_failure_message(result: dict, attempt: int) -> str:
    reason = result.get("reason", "UNKNOWN")
    detail = result.get("detail", "")
    return (
        f"Generation {attempt} failed.\n"
        f"Reason: {reason}\n"
        f"Detail: {detail}\n\n"
        "Try a structurally different guard sequence. "
        "Remember: output ONLY a JSON array, no prose."
    )


def run(wasm_path: str, max_iter: int, model: str) -> None:
    if not EVALUATOR_BIN.exists():
        print(f"ERROR: evaluator binary not found at {EVALUATOR_BIN}", file=sys.stderr)
        print("Run: zig build phase12-evaluator", file=sys.stderr)
        sys.exit(1)

    # ── Probe ──────────────────────────────────────────────────────────────
    print(f"[phase12] probing {wasm_path}...")
    probe = call_evaluator(wasm_path, None)
    if probe.get("status") != "PROBE":
        print(f"ERROR: probe failed: {probe}", file=sys.stderr)
        sys.exit(1)

    w = probe["witness"]
    print(
        f"[phase12] witness: func={w['func_idx']} "
        f"offset=0x{w['body_offset_of_store']:x} "
        f"addr_local={w['addr_local']} "
        f"alloc_size={w['alloc_size']} width={w['width']}"
    )
    print(
        f"[phase12] baseline: {probe['baseline_op_count']} ops, "
        f"{probe['baseline_byte_count']} bytes"
    )

    # ── LLM conversation loop ───────────────────────────────────────────────
    client = anthropic.Anthropic()
    system_prompt = build_system_prompt(probe)
    history: list[dict] = []

    history.append({
        "role": "user",
        "content": (
            "Synthesize a Wasm guard sequence as described. "
            "Output ONLY a JSON array of op objects."
        ),
    })

    best_pass: dict | None = None
    best_ops: list | None = None

    for attempt in range(1, max_iter + 1):
        print(f"\n[phase12] === Generation {attempt} ===")

        response = client.messages.create(
            model=model,
            max_tokens=1024,
            system=system_prompt,
            messages=history,
        )
        reply_text = response.content[0].text.strip()
        print(f"  LLM response ({len(reply_text)} chars):")
        print("  " + reply_text[:400].replace("\n", "\n  "))

        history.append({"role": "assistant", "content": reply_text})

        candidate = extract_json_array(reply_text)
        if candidate is None:
            feedback = (
                f"Generation {attempt}: could not extract a JSON array from your response. "
                "Please output ONLY a JSON array of op objects, nothing else."
            )
            print(f"  [parse] no JSON array found")
            history.append({"role": "user", "content": feedback})
            continue

        print(f"  candidate: {len(candidate)} ops")
        result = call_evaluator(wasm_path, candidate)
        status = result.get("status", "FAIL")
        print(f"  evaluator: {status}", end="")
        if status != "PASS":
            print(f" ({result.get('reason', '?')}: {result.get('detail', '')})")
        else:
            print(f" — guard_ops={result['guard_op_count']} guard_bytes={result['guard_byte_count']}"
                  f" (baseline: {result['baseline_op_count']} ops, {result['baseline_byte_count']} bytes)")

        if status == "PASS":
            if best_pass is None or result["guard_op_count"] < best_pass["guard_op_count"]:
                best_pass = result
                best_ops = candidate
            # Keep going to look for shorter candidates, unless this is max_iter.
            if attempt < max_iter:
                history.append({
                    "role": "user",
                    "content": (
                        f"Generation {attempt} PASSED Z3 with {result['guard_op_count']} ops "
                        f"(baseline {result['baseline_op_count']} ops). "
                        "Can you find a guard with fewer ops that also passes? "
                        "If not, output the same sequence again to confirm."
                    ),
                })
            continue

        feedback = build_failure_message(result, attempt)
        history.append({"role": "user", "content": feedback})

    # ── Report ──────────────────────────────────────────────────────────────
    print("\n" + "=" * 60)
    if best_pass is not None:
        delta_ops = best_pass["baseline_op_count"] - best_pass["guard_op_count"]
        delta_bytes = best_pass["baseline_byte_count"] - best_pass["guard_byte_count"]
        print(f"RESULT: PASS — best guard: {best_pass['guard_op_count']} ops, "
              f"{best_pass['guard_byte_count']} bytes "
              f"(Δ ops={delta_ops:+d}, Δ bytes={delta_bytes:+d} vs baseline)")
        print(f"Winning sequence:")
        print(json.dumps(best_ops, indent=2))
    else:
        print(f"RESULT: no passing guard found in {max_iter} generations")
    print("=" * 60)


def main() -> None:
    parser = argparse.ArgumentParser(description="Phase 12 LLM-guided CEGIS orchestrator")
    parser.add_argument("wasm_path", help="Path to vulnerable .wasm file")
    parser.add_argument("--max-iter", type=int, default=10,
                        help="Maximum LLM generations (default: 10)")
    parser.add_argument("--model", default="claude-sonnet-4-6",
                        help="Claude model ID (default: claude-sonnet-4-6)")
    args = parser.parse_args()
    run(args.wasm_path, args.max_iter, args.model)


if __name__ == "__main__":
    main()
