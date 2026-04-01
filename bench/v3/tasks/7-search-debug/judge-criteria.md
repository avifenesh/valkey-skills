# Judge Criteria: valkey-search Query Debug

## What to Evaluate

The agent was given 5 broken FT.SEARCH / FT.AGGREGATE queries and asked to diagnose and fix each one without modifying the index schema.

## Per-Query Diagnosis (worth ~60%)

### Query 1 - Wrong field name
- Bug: `@title:{laptop}` references a field that does not exist in the schema.
- Fix: Change to `@name:{laptop}` or `@name:laptop` (the field is TEXT, not TAG, so curly braces are optional but still valid for exact token matching).
- Key understanding: FT.SEARCH field references must match the SCHEMA definition.

### Query 2 - Numeric range syntax
- Bug: `@price:[100 500]` is actually valid syntax in valkey-search, but depending on version or context, the agent should verify it works and return results. If the agent identifies no bug here, they should confirm it works.
- Acceptable fix: Confirm the syntax is correct, or use `FILTER price 100 500` as an alternative. The query may return 0 results if there is another issue (like the field not being indexed).
- Key understanding: Numeric range filter syntax in FT.SEARCH.

### Query 3 - Case sensitivity on TAG
- Bug: `@category:{electronics}` uses lowercase, but the index was created with CASESENSITIVE on the category TAG field. The actual data uses `Electronics` (capitalized).
- Fix: Change to `@category:{Electronics}`.
- Key understanding: CASESENSITIVE TAG fields require exact case matching.

### Query 4 - Wrong DIALECT for KNN
- Bug: `DIALECT 1` does not support the `*=>[KNN ...]` vector search syntax. DIALECT 2 or higher is required.
- Fix: Change `DIALECT 1` to `DIALECT 2` (or `DIALECT 3` / `DIALECT 4`).
- Key understanding: Vector similarity search (KNN) requires DIALECT 2+. DIALECT 1 is the legacy default.

### Query 5 - Missing REDUCE COUNT
- Bug: The aggregation only has `REDUCE SUM 1 @price AS total` but is missing `REDUCE COUNT 0 AS count`.
- Fix: Add `REDUCE COUNT 0 AS count` after the existing SUM reduce.
- Key understanding: FT.AGGREGATE GROUPBY can chain multiple REDUCE operations.

## Explanation Quality (worth ~25%)

FIXES.md should contain:
- Clear identification of each bug
- Explanation of why the original query failed
- Description of the fix applied
- Demonstrates understanding of valkey-search syntax, not just trial and error

## Process Quality (worth ~15%)

- Did not recreate or modify the index
- Did not modify setup.py
- Queries actually execute successfully after fixes
- Used systematic debugging approach (checking schema, testing incrementally)
