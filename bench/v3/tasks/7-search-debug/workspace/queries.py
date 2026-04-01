#!/usr/bin/env python3
"""Five broken valkey-search queries. Fix each one.

The index schema (created by setup.py):
  FT.CREATE products ON HASH PREFIX 1 product:
    SCHEMA
      name TEXT SORTABLE
      description TEXT
      price NUMERIC SORTABLE
      category TAG SEPARATOR "," CASESENSITIVE
      embedding VECTOR HNSW 6 TYPE FLOAT32 DIM 128 DISTANCE_METRIC COSINE

Do not modify setup.py or recreate the index.
"""

import random
import struct
import valkey

EMBEDDING_DIM = 128

client = valkey.Valkey(host="localhost", port=6408, decode_responses=True)


def run_query(label, command_args):
    """Execute a query and print results."""
    print(f"\n{'=' * 60}")
    print(f"Query: {label}")
    print(f"Command: FT.SEARCH/FT.AGGREGATE {' '.join(str(a) for a in command_args)}")
    print(f"{'=' * 60}")
    try:
        result = client.execute_command(*command_args)
        if isinstance(result, list):
            print(f"Results: {result[0] if result else 0} matches")
            for i in range(1, len(result), 2):
                if i + 1 < len(result):
                    print(f"  {result[i]}: {result[i+1]}")
                else:
                    print(f"  {result[i]}")
        else:
            print(f"Result: {result}")
        return result
    except Exception as e:
        print(f"ERROR: {e}")
        return None


# ---------------------------------------------------------------------------
# Query 1: Full-text search for products with "laptop" in the name
# Expected: Should return products whose name contains "Laptop"
# TODO: Fix this query
# ---------------------------------------------------------------------------
def query_1():
    return run_query(
        "Find products with 'laptop' in the name",
        ["FT.SEARCH", "products", "@title:{laptop}"],
    )


# ---------------------------------------------------------------------------
# Query 2: Numeric range - find products priced between $100 and $500
# Expected: Should return products with price >= 100 and price <= 500
# TODO: Fix this query
# ---------------------------------------------------------------------------
def query_2():
    return run_query(
        "Products priced between $100 and $500",
        ["FT.SEARCH", "products", "@price:[100 500]"],
    )


# ---------------------------------------------------------------------------
# Query 3: Tag filter - find products in the Electronics category
# Expected: Should return products tagged with the Electronics category
# TODO: Fix this query
# ---------------------------------------------------------------------------
def query_3():
    return run_query(
        "Products in Electronics category",
        ["FT.SEARCH", "products", "@category:{electronics}"],
    )


# ---------------------------------------------------------------------------
# Query 4: Vector similarity - find 5 products similar to a reference vector
# Expected: Should return 5 nearest neighbors using the COSINE metric
# TODO: Fix this query
# ---------------------------------------------------------------------------
def query_4():
    random.seed(99)
    ref_vector = [random.gauss(0, 1) for _ in range(EMBEDDING_DIM)]
    blob = struct.pack(f"{EMBEDDING_DIM}f", *ref_vector)

    # Note: decode_responses=True on the client will mangle binary params.
    # The vector blob must be sent as raw bytes.
    raw_client = valkey.Valkey(host="localhost", port=6408, decode_responses=False)
    try:
        result = raw_client.execute_command(
            "FT.SEARCH", "products",
            "*=>[KNN 5 @embedding $vec]",
            "PARAMS", "2", "vec", blob,
            "DIALECT", "1",
        )
        print(f"\n{'=' * 60}")
        print("Query: Find 5 similar products by vector (KNN)")
        print(f"{'=' * 60}")
        if isinstance(result, list):
            count = result[0] if result else 0
            print(f"Results: {count} matches")
            for i in range(1, len(result), 2):
                if i + 1 < len(result):
                    key = result[i].decode() if isinstance(result[i], bytes) else result[i]
                    print(f"  {key}")
        return result
    except Exception as e:
        print(f"\n{'=' * 60}")
        print("Query: Find 5 similar products by vector (KNN)")
        print(f"{'=' * 60}")
        print(f"ERROR: {e}")
        return None


# ---------------------------------------------------------------------------
# Query 5: Aggregation - total revenue and count per category
# Expected: Should return each category with its total price sum AND count
# TODO: Fix this query
# ---------------------------------------------------------------------------
def query_5():
    return run_query(
        "Aggregate: total price and count per category",
        [
            "FT.AGGREGATE", "products", "*",
            "GROUPBY", "1", "@category",
            "REDUCE", "SUM", "1", "@price", "AS", "total",
        ],
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("Running 5 queries against the products index...")
    print("Each query has a bug. See TODO comments for instructions.\n")

    results = {}
    results["q1"] = query_1()
    results["q2"] = query_2()
    results["q3"] = query_3()
    results["q4"] = query_4()
    results["q5"] = query_5()

    print(f"\n{'=' * 60}")
    print("Summary")
    print(f"{'=' * 60}")
    for k, v in results.items():
        status = "OK" if v is not None else "FAILED"
        if isinstance(v, list) and len(v) > 0 and v[0] == 0:
            status = "EMPTY (0 results)"
        print(f"  {k}: {status}")
