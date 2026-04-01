## Task 8: valkey-json Type-Aware Operations - Judge Criteria

### Correct JSONPath v2 Usage (25%)

- Uses JSONPath v2 filter syntax (`$..items[?(@.price>100 && @.quantity>2)]` or equivalent) rather than client-side iteration for filtering.
- Understands that JSONPath queries on nested arrays return matching elements, not the parent document - agent must correctly map back to order IDs.
- Does not confuse JSONPath v1 (dot-bracket) with v2 (filter expressions).

### Type Awareness (25%)

- Recognizes that `JSON.GET` with JSONPath returns arrays (even for scalar paths like `$.payment.status`), and handles unwrapping correctly.
- Uses `JSON.NUMINCRBY` on a numeric path (not fetching, incrementing in Python, and writing back).
- Uses `JSON.ARRINSERT` with a serialized JSON value argument (not a Python dict directly).
- Understands `JSON.SET ... NX` condition semantics: sets only if path does not exist.
- Correctly serializes the tracking event as a JSON string when passing to ARRINSERT.

### Bulk Operation Efficiency (25%)

- Uses `JSON.MGET` with multiple keys in a single call rather than looping `JSON.GET` for operation 4.
- Uses pipelining where appropriate for operations that touch all 100 keys (operations 2, 3, 5, 6).
- Does not make 100 individual round-trips when a pipeline or batch command exists.

### Edge Case Handling (25%)

- Handles orders with empty `$.items` arrays (no crash, just no match).
- Handles orders with empty `$.statusHistory` (ARRTRIM on empty array should not crash).
- Handles the NX condition correctly: pre-existing values must not be overwritten.
- Handles `JSON.GET` returning `None` or `"[]"` for missing paths.
- Does not assume fixed counts - works with whatever the setup script produces.
