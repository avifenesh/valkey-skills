## Judging Criteria: Bloom Capacity Planning

### Capacity Math Correctness (30%)
- Per-filter capacity set to ~50M (daily volume).
- Error rate per filter calculated correctly so the aggregate FP rate across 30 filters stays at or below 0.1%. A single filter's target error rate should be roughly 0.1% / 30 = ~0.0033% (or tighter). Accept any defensible derivation.
- Memory estimate per filter is realistic for the chosen capacity and error rate.

### FP Rate Aggregation Understanding (25%)
- The solution must demonstrate awareness that querying N independent bloom filters compounds the false positive probability.
- Formula: aggregate FP ~= 1 - (1 - p)^N, or the simpler approximation p * N for small p.
- The per-filter error rate must be derived from the aggregate target, not just set to 0.1%.

### Memory Awareness (25%)
- Total memory across 30 filters must stay within 8GB.
- Solution should use BF.INFO to verify actual memory consumption.
- NONSCALING filters are preferred (avoids unpredictable expansion) or a controlled expansion factor with justification.

### Rotation Strategy (20%)
- Daily key naming convention is clear and parseable.
- Rotation creates a new filter and cleanup removes expired ones.
- Multi-filter query checks all active filters (up to 30).
- Edge cases: first day (no old filters), exactly 30 days (boundary), 31st day (oldest removed).
