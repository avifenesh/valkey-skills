# Judge Criteria: Task 1 - Valkey Bug Investigation and Fix

Evaluate the agent's three deliverables: ANALYSIS.md, fix.patch, verify.sh.

## Root Cause Analysis (25%)
- Correctly identifies t_hash.c and the missing field existence check
- Explains the sequence: HDEL removes field, HEXPIRE creates orphaned TTL metadata
- Shows understanding of Valkey hash field TTL internals

## Patch Quality (30%)
- Valid unified diff targeting t_hash.c
- Adds minimal field existence check before TTL set
- Would compile and work if applied
- Doesn't break existing HEXPIRE on valid fields

## Verification Script (25%)
- Tests HEXPIRE on deleted field (expects 0)
- Tests HEXPIRETIME on deleted field (expects -2)
- Tests normal HEXPIRE on existing fields still works
- Runnable and well-structured

## Impact Analysis (20%)
- Identifies affected commands (HTTL, HPTTL, HPERSIST, HEXPIREAT)
- Explains memory leak mechanism
- Describes incorrect return values
