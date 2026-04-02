"""Query functions for Task 6: valkey-search query builder.

Implement the 6 query functions below using client.execute_command()
with FT.SEARCH and FT.AGGREGATE. Each function's docstring describes
what it should return. The 'products' index is already created by
setup.py - see that file for the schema.

Do NOT call FT.CREATE or FT.DROPINDEX here.
"""

import valkey

client = valkey.Valkey(host="localhost", port=6506, decode_responses=True)


def query_1_fulltext():
    """Find products with 'wireless' in name or description.
    Return: list of product keys (e.g. ['product:1', 'product:5', ...])."""
    raise NotImplementedError


def query_2_numeric_range():
    """Find products priced between $100 and $500 (inclusive), sorted by price ascending.
    Return: list of (key, price) tuples, e.g. [('product:3', 105.5), ('product:7', 210.0), ...]."""
    raise NotImplementedError


def query_3_tag_filter():
    """Find products in the 'Electronics' category (case-sensitive tag).
    Return: integer count of matching products."""
    raise NotImplementedError


def query_4_combined():
    """Find Electronics products with rating >= 4.0 AND in_stock = 'yes'.
    Return: list of product keys."""
    raise NotImplementedError


def query_5_aggregate():
    """Get average price per category using FT.AGGREGATE.
    Return: dict of {category: avg_price} where avg_price is a float,
    e.g. {'Electronics': 245.5, 'Books': 120.3, ...}."""
    raise NotImplementedError


def query_6_pagination():
    """Get page 3 of products sorted by rating desc (10 per page).
    Page 3 means offset 20, limit 10.
    Return: list of product keys."""
    raise NotImplementedError


if __name__ == "__main__":
    import json

    results = {}
    for i, fn in enumerate(
        [
            query_1_fulltext,
            query_2_numeric_range,
            query_3_tag_filter,
            query_4_combined,
            query_5_aggregate,
            query_6_pagination,
        ],
        1,
    ):
        try:
            results[f"q{i}"] = fn()
            print(f"Q{i}: OK ({type(results[f'q{i}']).__name__})")
        except Exception as e:
            results[f"q{i}"] = None
            print(f"Q{i}: ERROR - {e}")

    with open("results.json", "w") as f:
        json.dump(results, f, indent=2, default=str)

    print(f"\nResults written to results.json")
