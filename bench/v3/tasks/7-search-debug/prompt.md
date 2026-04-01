# Task: Debug valkey-search Queries

You have a Valkey instance with the valkey-search module loaded, running in Docker. A setup script has loaded 500 product documents into the database with a full-text, numeric, tag, and vector search index.

There are 5 queries in `queries.py` that are all broken. Each query has a comment describing what it should do and what result is expected.

Your job:

1. Start the environment with `docker compose up -d` and run `python3 setup.py` to load the data.
2. Read each query in `queries.py` and diagnose why it fails or returns wrong results.
3. Fix each query in place (edit `queries.py`). Do not modify `setup.py` or recreate the index.
4. Create `FIXES.md` with a section for each query explaining: what was wrong, why it was wrong, and what you changed.
5. Run the queries to verify they work.

The index schema (created by setup.py) is:

```
FT.CREATE products ON HASH PREFIX 1 product:
  SCHEMA
    name TEXT SORTABLE
    description TEXT price NUMERIC SORTABLE
    category TAG SEPARATOR "," CASESENSITIVE
    embedding VECTOR HNSW 6 TYPE FLOAT32 DIM 128 DISTANCE_METRIC COSINE
```

Do not drop or recreate the index. Do not modify setup.py.
