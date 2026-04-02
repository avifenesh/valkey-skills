# valkey-search Query Builder

A valkey-search index named `products` has been set up with 200 product documents stored as Hash keys (`product:1`, `product:2`, ...). Run `python3 setup.py` first to populate the data.

## Your task

Implement the 6 query functions in `queries.py`. Each function has a docstring explaining what to query and what to return. Use `client.execute_command()` to run raw FT.SEARCH and FT.AGGREGATE commands against the `products` index.

## Index schema

The index is defined in `setup.py`. Open it to see the full `FT.CREATE` command with field names, types, and options. Pay attention to which fields are TEXT, NUMERIC, or TAG, and note the TAG separator and case-sensitivity settings.

## Constraints

- Do NOT call FT.CREATE or FT.DROPINDEX in queries.py - the index already exists
- Parse the raw response arrays returned by `execute_command()` into the Python types specified in each function's docstring
- Run `python3 queries.py` to verify your implementations - all 6 should print OK
- The results are written to `results.json` for validation

## Hints

- FT.SEARCH returns a flat array: `[count, key1, [field, value, ...], key2, [field, value, ...], ...]`
- FT.AGGREGATE returns a flat array: `[count, [field, value, ...], [field, value, ...], ...]`
- Use LIMIT to control pagination and SORTBY for ordering
- For large result sets, you may need to increase the default LIMIT (which is 0 10)
