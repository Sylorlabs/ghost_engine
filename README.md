# Ghost Engine

An autonomous, formally-verified static analyzer and repair tool for Zig.

Ghost Engine is an industrial-grade developer tool that goes beyond traditional linting. Instead of simply reporting bugs, it formally proves their existence using Satisfiability Modulo Theories (SMT), synthesizes a mathematical repair, re-proves the corrected logic, and emits the safe code—all completely autonomously.

## Hybrid Architecture

Ghost Engine is built on a "Hybrid Architecture" that combines the deterministic proof capabilities of the Z3 SMT solver with the geometric pattern-matching of a Vector Symbolic Architecture (VSA).

### 1. The Pass-Through Parser
Traditional static analyzers often fail when encountering complex metaprogramming, inline assembly, or SIMD vector mathematics. Ghost Engine uses a **Pass-Through Parser** that gracefully ignores syntax it does not understand. It surgically extracts only the standard Zig control-flow and memory operations it recognizes, maps them to its internal structural representation, and passes everything else through unharmed. This guarantees that deploying Ghost Engine on a complex, 5,000-line file will not arbitrarily corrupt or drop advanced compiler macros.

### 2. Formal Verification (Z3)
When Ghost Engine identifies a potential vulnerability, it does not rely on heuristics. The engine lowers the execution path into an SMT-LIB time-series and queries the Z3 Prover. 

Ghost Engine currently sweeps for three major vulnerability classes concurrently:
- **Array Bounds Manipulation** (Out-of-bounds indexing)
- **Arithmetic Safety** (Division by zero)
- **Temporal Memory Safety** (Use-After-Free and Null-Dereferences)

If Z3 returns `UNSAT` (Unsatisfiable), the code is mathematically proven to be safe. If it returns `SAT` (Satisfiable), a vulnerability has been verified.

### 3. VSA Synthesis (The Oracle)
Upon a `SAT` verdict, Ghost Engine engages the Oracle—a high-dimensional Vector Symbolic Architecture (VSA). The VSA combinatorially searches its Concept Codebook for structural repairs (e.g., control-flow guards, state nullification) and injects them into the failing topological path.

The engine then re-submits the patched AST to Z3. Only when Z3 returns a guaranteed `UNSAT` verdict will the engine procedurally emit the finalized, safe code back into your file.

### 4. The CI/CD Sentinel
Ghost Engine is designed to act as an automated gatekeeper for production repositories. By integrating the engine into GitHub Actions, it serves as a CI/CD Sentinel. 

When a Pull Request is opened, the Sentinel intercepts modified files and runs a concurrent vulnerability sweep. If an unsafe state (`SAT`) is detected, the pipeline automatically fails, blocking the merge. Crucially, the Sentinel doesn't just block the PR; it outputs the fully synthesized, `UNSAT`-verified code patch directly into the CI logs for the developer to apply.

---

## Capabilities & Examples

Ghost Engine does not alter your formatting or destroy your complex logic. It simply injects the necessary guards and state resets to achieve mathematical safety.

### 1. Bounds Safety Validation

**Before (Vulnerable):**
```zig
pub fn bounds_vulnerable(a: *[4]u32, i: u32, j: u32) void {
    const tmp = a[i];
    a[i] = a[j];
    a[j] = tmp;
}
```

**After (Repaired):**
```zig
pub fn bounds_vulnerable(a: *[4]u32, i: u32, j: u32) void {
    if (i >= a.len) return; // SYNTHESIZED: Bounds Guard
    if (j >= a.len) return; // SYNTHESIZED: Bounds Guard
    const tmp = a[i];
    a[i] = a[j];
    a[j] = tmp;
}
```

### 2. Arithmetic Safety Validation

**Before (Vulnerable):**
```zig
pub fn zero_div_vulnerable(a: u32, b: u32) u32 {
    return a / b;
}
```

**After (Repaired):**
```zig
pub fn zero_div_vulnerable(a: u32, b: u32) u32 {
    if (b == 0) return 0; // SYNTHESIZED: Zero-Div Guard
    return a / b;
}
```

### 3. Temporal Memory Safety (Use-After-Free)

**Before (Vulnerable):**
```zig
pub fn uaf_vulnerable() void {
    var ptr = alloc();
    free(ptr);
    deref(ptr);
}
```

**After (Repaired):**
```zig
pub fn uaf_vulnerable() void {
    var ptr = alloc();
    free(ptr);
    ptr = null; // SYNTHESIZED: State Reset
    if (ptr != null) { // SYNTHESIZED: Control Guard
        deref(ptr);
    }
}
```

---

## Installation & Usage

Ghost Engine requires Zig and the Z3 Prover.

### Building the CLI (`ghost-lint`)
```bash
sudo apt-get install libz3-dev z3
zig build-exe src/main.zig -O ReleaseSafe -lc -lz3 -I/usr/include -L/usr/lib/x86_64-linux-gnu -femit-bin=ghost-lint
```

### Running the Sweeper
```bash
./ghost-lint src/my_file.zig
```
If vulnerabilities are found, the safe AST will be written to `ghost_compiled.zig`.
