# Task 8: valkey-json Type-Aware Operations

You have a Docker environment running Valkey with the valkey-json module. A setup script has loaded 100 nested JSON order documents into keys `order:ORD-001` through `order:ORD-100`.

Each order document has this structure:

```json
{
  "orderId": "ORD-001",
  "customer": {"name": "Alice Smith", "email": "alice@test.com"},
  "items": [{"name": "Widget", "price": 150, "quantity": 3}],
  "payment": {"method": "card", "status": "completed", "retryCount": 0},
  "statusHistory": [{"status": "placed", "timestamp": "2025-01-15T10:00:00Z"}],
  "shipping": {"address": {"street": "123 Main St", "city": "Portland", "zip": "97201"}}
}
```

Approximately 20 orders have `payment.status = "failed"` and approximately 30 orders have a `"shipped"` entry in their `statusHistory` array.

## Your Task

Open `operations.py` and implement the 6 operations marked with TODO. Each function must use valkey-json commands (`JSON.GET`, `JSON.SET`, `JSON.NUMINCRBY`, `JSON.ARRINSERT`, `JSON.ARRTRIM`, `JSON.MGET`, etc.) through a Valkey client.

### Operations to Implement

1. **JSONPath v2 filter** - Find all orders where any item has `price > 100` AND `quantity > 2`. Return the list of matching order IDs.

2. **NUMINCRBY** - Increment `$.payment.retryCount` by 1 for every order with `payment.status = "failed"`. Use `JSON.NUMINCRBY`.

3. **ARRINSERT** - For every order that has `"shipped"` in its statusHistory, insert a tracking event `{"status": "tracking_sent", "timestamp": "2025-03-01T00:00:00Z"}` at index 0 of `$.statusHistory`. Use `JSON.ARRINSERT`.

4. **Cross-key MGET** - Fetch `$.customer.email` from 50 specific order keys (`order:ORD-001` through `order:ORD-050`) in a single `JSON.MGET` call. Return the list of emails.

5. **ARRTRIM** - For all 100 orders, trim `$.statusHistory` to keep only the last 5 entries. Use `JSON.ARRTRIM`.

6. **SET with NX** - For each order, attempt to set `$.payment.refundId` to `"REF-{orderId}"` but only if that path does not already exist. Orders that already have a `refundId` must remain unchanged. Use the appropriate JSON.SET condition.

## Setup

```bash
docker compose up -d
python3 setup.py
python3 operations.py
```

## Requirements

- All operations must use `JSON.*` commands (not plain `GET`/`SET` with manual serialization).
- Handle missing paths gracefully (no crashes).
- Operations should be efficient (use bulk commands where available).
