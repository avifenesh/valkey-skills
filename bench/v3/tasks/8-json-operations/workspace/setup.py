#!/usr/bin/env python3
"""Load 100 nested JSON order documents into Valkey for benchmark task 8."""

import json
import random
import sys

import valkey

random.seed(42)

FIRST_NAMES = [
    "Alice", "Bob", "Carol", "Dave", "Eve", "Frank", "Grace", "Hank",
    "Iris", "Jack", "Kate", "Leo", "Mia", "Nate", "Olive", "Paul",
    "Quinn", "Rosa", "Sam", "Tina", "Uma", "Vic", "Wendy", "Xander",
    "Yara", "Zane",
]

LAST_NAMES = [
    "Smith", "Jones", "Brown", "Davis", "Wilson", "Moore", "Taylor",
    "Anderson", "Thomas", "Jackson", "White", "Harris", "Martin", "Garcia",
    "Clark", "Lewis", "Hall", "Young", "King", "Wright",
]

ITEM_NAMES = [
    "Widget", "Gadget", "Sprocket", "Flange", "Bracket", "Coupler",
    "Sensor", "Relay", "Adapter", "Connector", "Actuator", "Regulator",
    "Capacitor", "Resistor", "Inductor", "Transistor", "Diode", "Fuse",
    "Valve", "Pump",
]

CITIES = [
    "Portland", "Seattle", "Denver", "Austin", "Chicago", "Boston",
    "Miami", "Atlanta", "Phoenix", "Detroit",
]

STREETS = [
    "Main St", "Oak Ave", "Pine Rd", "Elm Blvd", "Cedar Ln",
    "Maple Dr", "Birch Way", "Walnut Ct", "Spruce Pl", "Ash Ter",
]

PAYMENT_METHODS = ["card", "paypal", "bank_transfer", "crypto"]


def make_items():
    """Generate 1-4 order items with varying prices and quantities."""
    count = random.randint(1, 4)
    items = []
    for _ in range(count):
        items.append({
            "name": random.choice(ITEM_NAMES),
            "price": random.randint(50, 500),
            "quantity": random.randint(1, 5),
        })
    return items


def make_status_history(order_num, is_shipped):
    """Generate status history. Shipped orders get 3-8 entries; others get 1-3."""
    base = {"status": "placed", "timestamp": "2025-01-15T10:00:00Z"}
    history = [base]

    if is_shipped:
        history.append({"status": "confirmed", "timestamp": "2025-01-15T12:00:00Z"})
        history.append({"status": "processing", "timestamp": "2025-01-16T09:00:00Z"})
        history.append({"status": "shipped", "timestamp": "2025-01-18T14:00:00Z"})
        # Some shipped orders get extra history to test ARRTRIM
        extra = random.randint(0, 4)
        for i in range(extra):
            history.append({
                "status": f"update_{i}",
                "timestamp": f"2025-01-{19 + i:02d}T10:00:00Z",
            })
    else:
        if random.random() > 0.5:
            history.append({"status": "confirmed", "timestamp": "2025-01-15T12:00:00Z"})
        if random.random() > 0.7:
            history.append({"status": "processing", "timestamp": "2025-01-16T09:00:00Z"})

    return history


def make_order(order_num, payment_status, is_shipped):
    """Build a complete order document."""
    first = random.choice(FIRST_NAMES)
    last = random.choice(LAST_NAMES)
    order_id = f"ORD-{order_num:03d}"

    return {
        "orderId": order_id,
        "customer": {
            "name": f"{first} {last}",
            "email": f"{first.lower()}.{last.lower()}@test.com",
        },
        "items": make_items(),
        "payment": {
            "method": random.choice(PAYMENT_METHODS),
            "status": payment_status,
            "retryCount": 0,
        },
        "statusHistory": make_status_history(order_num, is_shipped),
        "shipping": {
            "address": {
                "street": f"{random.randint(100, 9999)} {random.choice(STREETS)}",
                "city": random.choice(CITIES),
                "zip": f"{random.randint(10000, 99999)}",
            }
        },
    }


def main():
    r = valkey.Valkey(host="localhost", port=6379, decode_responses=True)

    try:
        r.ping()
    except valkey.ConnectionError:
        print("[ERROR] Cannot connect to Valkey on localhost:6379")
        print("Run: docker compose up -d")
        sys.exit(1)

    # Clear any previous data
    existing = r.keys("order:ORD-*")
    if existing:
        r.delete(*existing)

    # Assign payment statuses: ~20 failed, ~30 shipped, rest completed/pending
    # Deterministic assignment using seed
    statuses = []
    shipped_flags = []

    for i in range(1, 101):
        if i <= 20:
            statuses.append("failed")
        elif i <= 50:
            statuses.append("completed")
        elif i <= 80:
            statuses.append("pending")
        else:
            statuses.append("completed")

    # Shuffle to distribute randomly
    random.shuffle(statuses)

    # Assign shipped: orders 1-30 get shipped status history entries
    # (shuffled separately)
    shipped_indices = set(random.sample(range(100), 30))

    pipe = r.pipeline()
    failed_count = 0
    shipped_count = 0
    high_price_qty_count = 0

    for i in range(100):
        order_num = i + 1
        payment_status = statuses[i]
        is_shipped = i in shipped_indices

        if payment_status == "failed":
            failed_count += 1
        if is_shipped:
            shipped_count += 1

        order = make_order(order_num, payment_status, is_shipped)

        # Track orders matching the filter query (any item with price>100 AND qty>2)
        has_match = any(
            item["price"] > 100 and item["quantity"] > 2
            for item in order["items"]
        )
        if has_match:
            high_price_qty_count += 1

        key = f"order:{order['orderId']}"
        pipe.execute_command("JSON.SET", key, "$", json.dumps(order))

    pipe.execute()

    print(f"[OK] Loaded {100} orders")
    print(f"  Failed payment orders: {failed_count}")
    print(f"  Shipped orders: {shipped_count}")
    print(f"  Orders with item price>100 AND qty>2: {high_price_qty_count}")

    # Write counts to a metadata file for test validation
    meta = {
        "total_orders": 100,
        "failed_count": failed_count,
        "shipped_count": shipped_count,
        "high_price_qty_count": high_price_qty_count,
    }
    with open("setup_meta.json", "w") as f:
        json.dump(meta, f, indent=2)

    print(f"[OK] Metadata written to setup_meta.json")


if __name__ == "__main__":
    main()
