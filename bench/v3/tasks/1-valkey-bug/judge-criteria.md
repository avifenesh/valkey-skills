# Judge Criteria: Task 1 - Valkey Bug Investigation

Evaluate the agent's ANALYSIS.md against these criteria:

## Root Cause Identification (30%)

- Does the analysis correctly identify t_hash.c as the file containing the bug?
- Does it pinpoint the missing field existence check in the HEXPIRE command handler?
- Does it demonstrate understanding that the hash field TTL code path skips validation of whether the target field actually exists in the hash before creating expiration metadata?

## Mechanism Explanation (25%)

- Is the explanation of how the bug manifests detailed and technically accurate?
- Does it describe the sequence: field deleted via HDEL, HEXPIRE called on that field, server creates expiration metadata without checking field existence, metadata persists as an orphan?
- Does it explain why HEXPIRETIME returns a value (the orphaned metadata is queryable) while HGETALL does not show the field (the field data was properly deleted)?

## Fix Proposal (20%)

- Is the proposed fix correct - adding a field existence check before setting TTL?
- Is the fix minimal and targeted (not an overhaul of the entire expiration system)?
- Does it specify the right location in the code path (before the expiration metadata is written)?
- Does it correctly describe the expected return value (0) when the field does not exist?

## Impact Analysis (15%)

- Does the analysis cover all three impact dimensions: incorrect return values, ghost TTLs, and memory leak?
- Is the memory leak mechanism explained (orphaned metadata entries accumulate with no cleanup path)?
- Are related commands identified (HTTL, HPTTL, HPERSIST, HEXPIREAT, HPEXPIRE, HPEXPIREAT)?

## Understanding of Valkey Internals (10%)

- Does the analysis show genuine understanding of Valkey's hash implementation?
- Does it reference relevant internal structures (hash field expiration metadata, per-field TTL tracking)?
- Is the reasoning logical and derived from architectural knowledge rather than guesswork?
