I have a valkey-search index named `products` with about 200 product documents stored as Hash keys (`product:1`, `product:2`, ...). You can run `python3 setup.py` to populate everything.

I need help writing 6 query functions in `queries.py`. Each function has a docstring explaining what it should query and return. They all use `client.execute_command()` to run raw FT.SEARCH and FT.AGGREGATE commands against the `products` index.

## Index schema

The index is defined in `setup.py`. Open it to see the full `FT.CREATE` command with field names, types, and options. Pay attention to which fields are TEXT, NUMERIC, or TAG, and note the TAG separator and case-sensitivity settings.

## A few things to watch out for

- The index is already created by `setup.py` - don't call FT.CREATE or FT.DROPINDEX in queries.py
- Parse the raw response arrays returned by `execute_command()` into the Python types specified in each function's docstring
- Run `python3 queries.py` to verify - all 6 should print OK
- Results get written to `results.json` for validation

## Parsing notes

- FT.SEARCH returns a flat array: `[count, key1, [field, value, ...], key2, [field, value, ...], ...]`
- FT.AGGREGATE returns a flat array: `[count, [field, value, ...], [field, value, ...], ...]`
- Use LIMIT to control pagination and SORTBY for ordering
- For large result sets, you may need to increase the default LIMIT (which is 0 10)
