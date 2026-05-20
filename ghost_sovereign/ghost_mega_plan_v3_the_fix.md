# Ghost Sovereign — Invention Engine Mega Plan v3 (The Fix)

## Objective
Address the four fundamental structural flaws identified in the Track 1 & 2 semantic validation:
1.  **The Vocabulary Cliff (OOV):** Static lookup fails on unknown words.
2.  **Order Blindness:** Commutative addition destroys syntax.
3.  **Polysemy:** Single static vector per word conflates multiple meanings.
4.  **Geometric Saturation:** The 296 ceiling in conceptless synthesis.

## Hard Constraints (Inherited)
-   `std` only for the core lineage.
-   No VSA/Flame imports in the conceptless lineage.
-   No external neural networks, gradients, or cloud dependencies.
-   All claims must be empirically verified via `zig build` and benchmark outputs.

## Track 1: N-Gram Subword Encoding (The OOV Fix)
**Problem:** Unknown words fall back to random noise, destroying semantic continuity.
**Solution:** Move from Word-level Random Indexing to Subword/Character N-Gram Random Indexing.
**Implementation:**
1.  Modify `train_hypervectors.zig` to extract character tri-grams (e.g., "star" -> "<st", "sta", "tar", "ar>") instead of whole words.
2.  Assign a sparse random index vector to each unique tri-gram.
3.  When encountering *any* word (known or unknown), its semantic vector is generated on the fly by `bundle`ing (adding) the pre-trained index vectors of its constituent tri-grams.
4.  **Expected Outcome:** Unknown words like "starlight" will naturally cluster near "star" and "light" because they share N-grams, eliminating the vocabulary cliff.

## Track 2: Permutation-Based Syntax Encoding (The Order Fix)
**Problem:** `context[w] += index_vector[c_1] + index_vector[c_2]` loses sequence order. "Dog bites man" = "Man bites dog".
**Solution:** Implement Holographic Reduced Representations (HRR) utilizing the `permute` operator.
**Implementation:**
1.  Modify the Random Indexing accumulator loop in `train_hypervectors.zig`.
2.  Instead of just adding the neighbor's vector, `permute` (cyclic shift) it based on its relative distance from the center word.
3.  Example: `context[w] += permute(idx(w-1), -1) + permute(idx(w+1), +1)`.
4.  **Expected Outcome:** The engine will mathematically distinguish between words based on their structural position, allowing it to encode rudimentary grammar and syntax.

## Track 3: Dynamic Context Binding (The Polysemy Fix)
**Problem:** "Bank" (river) and "Bank" (money) share one vector.
**Solution:** Compute dynamic contextualized vectors at inference time.
**Implementation:**
1.  Create `AbsoluteCore.ingestContextualized`.
2.  Instead of just doing a direct lookup, fetch the base vector for the word, then `bind` (XOR) it with a `bundle` (addition) of the vectors of the 3 surrounding words.
3.  The final ingested hypervector becomes: `V_dynamic = V_base XOR (V_left + V_right)`.
4.  **Expected Outcome:** The vector for "bank" will shift dynamically based on whether "river" or "money" is adjacent, naturally disambiguating meaning during ingestion.

## Track 4: Multi-Objective Pareto Synthesis (The Saturation Fix)
**Problem:** Search stalls at the 296 minimum-distance ceiling because single/pair/block flips get trapped in deep geometric local optima.
**Solution:** Abandon pure greedy search; implement a Pareto-Front Multi-Objective Evolutionary Algorithm (MOEA).
**Implementation:**
1.  Modify `recursive_conceptless_inventor_v4.zig` to maintain a *population* of candidate masks.
2.  Instead of a single fitness score (`stats.score`), track two conflicting objectives simultaneously: (A) Minimum Reference Distance, (B) Total Hamming Diversity (spread).
3.  Use Non-dominated Sorting (like NSGA-II) to preserve a diverse "Pareto front" of candidates that are good at different things.
4.  **Expected Outcome:** By not discarding solutions that temporarily lower the minimum distance but massively increase diversity, the search can traverse the ridges between local optima and break the 296 ceiling.

## Execution Priority
1.  **Track 1 (Subword N-Grams):** Easiest to implement, immediate massive payoff for OOV robustness.
2.  **Track 2 (Permutation Syntax):** Solves the biggest fundamental limitation of VSA models.
3.  **Track 3 (Dynamic Binding):** Builds on the success of Tracks 1 & 2.
4.  **Track 4 (Pareto Synthesis):** Highly experimental, computationally expensive, but necessary to evolve the engine further.