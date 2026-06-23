# Ghost Engine: Mathematical Foundations

The Ghost Engine is built on the mathematics of **High-Dimensional Vector Space Alignment** (VSA).

## 1. HyperVector Resonance
We operate in a 1024-dimensional bitspace. Meaning is not stored in values, but in the **Hamming Distance** between vectors. 
*   **Nearness**: A Hamming distance < 400 indicates semantic resonance.
*   **Void**: A Hamming distance > 600 indicates semantic orthogonality.

## 2. The Majority Rule (Bundling)
To "memorize" multiple vectors into a single point in the matrix, we use a bitwise Majority Rule:
1.  Align N vectors.
2.  For each bit position, if more than 50% of the vectors have a `1`, the resulting bit is `1`.
3.  This creates a "composite" vector that retains a high degree of resonance with all its constituent parts.

## 3. Boundary Detection and Cascade Etching
The engine detects structural boundaries in the input stream by monitoring resonance energy. When energy drops below a threshold (indicating low similarity to existing state), a boundary is triggered. Boundaries cascade context upward through syntax, phrase, concept, and global HyperVector registers, etching the current context into the MeaningMatrix at each level.

## 4. No-Float Determinism
By using only bitwise operations, the engine achieves **Absolute Determinism**. The same input will always produce the exact same resonance across any hardware that supports the standard VSA instruction set.

## 5. Determinism and Resonance Safety
The mathematical core of Ghost is designed for bit-perfect reproducibility. Any divergence in how bitwise logic is applied will lead to semantic decay:
*   **The No-Float Mandate**: Never introduce floating-point math (`f32`, `f64`) into `vsa_core.zig` or `src/shaders/`. Even a single rounding error will break bit-perfect determinism across different hardware architectures.
*   **Resonance Thresholds**: The engine uses multiple thresholds defined in `src/config.zig`. Boundary detection uses energy values: soul boundary at 200, paragraph at 400, phrase at 400-600 (configurable), word at 400. The surprise threshold is 850 (skip etching if already known), and the search trigger is 750. Modifying these will change the engine's perception.
*   **Vector Bundling (Majority Rule)**: The Majority Rule implementation (a & b) | (b & c) | (c & a) is the engine's only way to "memorize." Any change to how bitwise bundling is handled in the GPU kernels will result in a state that the CPU cannot interpret correctly.

