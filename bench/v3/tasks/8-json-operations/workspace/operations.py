#!/usr/bin/env python3
"""
Task 8: valkey-json Type-Aware Operations

Implement the 6 operations below using valkey-json commands.
Each function is called in sequence by main(). The Valkey instance
has 100 order documents loaded at keys order:ORD-001 through order:ORD-100.

Requirements:
- Use JSON.* commands (JSON.GET, JSON.SET, JSON.NUMINCRBY, JSON.ARRINSERT,
  JSON.ARRTRIM, JSON.MGET, etc.) - not plain GET/SET with manual serialization.
- Handle missing paths gracefully (no crashes on missing keys or paths).
- Use bulk operations where available for efficiency.
"""

import json
import sys

import valkey


def get_client():
    """Return a connected Valkey client."""
    r = valkey.Valkey(host="localhost", port=6409, decode_responses=True)
    try:
        r.ping()
    except valkey.ConnectionError:
        print("[ERROR] Cannot connect to Valkey on localhost:6409")
        sys.exit(1)
    return r


def op1_jsonpath_filter(r):
    """
    Operation 1: JSONPath v2 Filter

    Find all orders where ANY item has price > 100 AND quantity > 2.
    Return a list of matching order IDs (e.g., ["ORD-001", "ORD-015", ...]).

    Hint: Use JSONPath v2 filter expressions with JSON.GET to query
    nested array elements.
    """
    # TODO: Implement JSONPath v2 filter query
    # Scan all 100 order keys, use a JSONPath filter expression to check
    # if any item in $.items has both price > 100 and quantity > 2.
    # Return the list of orderId strings for matching orders.
    pass


def op2_numincrby_failed(r):
    """
    Operation 2: NUMINCRBY on Failed Orders

    For every order with payment.status = "failed", increment
    $.payment.retryCount by 1 using JSON.NUMINCRBY.

    Return the count of orders that were incremented.
    """
    # TODO: Implement NUMINCRBY for failed orders
    # 1. Identify all orders where $.payment.status is "failed"
    # 2. For each, call JSON.NUMINCRBY on $.payment.retryCount
    # 3. Return the number of orders incremented
    pass


def op3_arrinsert_tracking(r):
    """
    Operation 3: ARRINSERT Tracking Event

    For every order that has "shipped" in its statusHistory, insert
    a tracking event at index 0 of $.statusHistory:
      {"status": "tracking_sent", "timestamp": "2025-03-01T00:00:00Z"}

    Use JSON.ARRINSERT. Return the count of orders updated.
    """
    # TODO: Implement ARRINSERT for shipped orders
    # 1. Find orders that have a "shipped" status entry in $.statusHistory
    # 2. Insert the tracking event at index 0 using JSON.ARRINSERT
    # 3. Return the number of orders updated
    pass


def op4_mget_emails(r):
    """
    Operation 4: Cross-Key MGET

    Fetch $.customer.email from order keys order:ORD-001 through order:ORD-050
    in a single JSON.MGET call.

    Return the list of email strings (50 entries).
    """
    # TODO: Implement JSON.MGET for 50 keys
    # Use a single JSON.MGET call to fetch $.customer.email from 50 keys.
    # Return the list of email strings.
    pass


def op5_arrtrim_history(r):
    """
    Operation 5: ARRTRIM StatusHistory

    For all 100 orders, trim $.statusHistory to keep only the last 5 entries.
    Use JSON.ARRTRIM.

    Return the count of orders that were actually trimmed (had more than 5 entries).
    """
    # TODO: Implement ARRTRIM for all orders
    # 1. For each order, check the length of $.statusHistory
    # 2. If longer than 5, use JSON.ARRTRIM to keep only the last 5
    # 3. Return the count of orders that were trimmed
    pass


def op6_set_nx_refund(r):
    """
    Operation 6: SET with NX (set-if-not-exists)

    For each order, attempt to set $.payment.refundId to "REF-{orderId}"
    (e.g., "REF-ORD-001") but ONLY if $.payment.refundId does not already exist.
    Orders that already have a refundId must remain unchanged.

    To test this properly, first set refundId on orders 1-10 to a known value,
    then run the NX set on all 100 orders. Only orders 11-100 should get new values.

    Return the count of orders where refundId was newly set.
    """
    # TODO: Implement JSON.SET with NX condition
    # 1. Pre-set $.payment.refundId for orders 1-10 to "EXISTING-{orderId}"
    # 2. Attempt JSON.SET with NX for all 100 orders
    # 3. Count how many were actually set (should be ~90)
    # 4. Return the count
    pass


def main():
    r = get_client()

    print("=== Operation 1: JSONPath v2 Filter ===")
    result1 = op1_jsonpath_filter(r)
    print(f"  Matching orders: {len(result1) if result1 else 0}")
    if result1:
        print(f"  Sample: {result1[:5]}")

    print("\n=== Operation 2: NUMINCRBY Failed Orders ===")
    result2 = op2_numincrby_failed(r)
    print(f"  Orders incremented: {result2}")

    print("\n=== Operation 3: ARRINSERT Tracking ===")
    result3 = op3_arrinsert_tracking(r)
    print(f"  Orders updated: {result3}")

    print("\n=== Operation 4: Cross-Key MGET ===")
    result4 = op4_mget_emails(r)
    print(f"  Emails fetched: {len(result4) if result4 else 0}")
    if result4:
        print(f"  Sample: {result4[:3]}")

    print("\n=== Operation 5: ARRTRIM History ===")
    result5 = op5_arrtrim_history(r)
    print(f"  Orders trimmed: {result5}")

    print("\n=== Operation 6: SET NX RefundId ===")
    result6 = op6_set_nx_refund(r)
    print(f"  Orders newly set: {result6}")


if __name__ == "__main__":
    main()
