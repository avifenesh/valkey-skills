# Valkey Usage Review

We're running Valkey 9.0.3 in cluster mode (6 nodes, 3 primary + 3 replica) in production. Our application is a high-traffic e-commerce platform. Below are descriptions of how we use Valkey across different services. For each, tell us if our approach is good or if there's a better way. Be specific - cite commands, data structures, or patterns.

---

## 1. Session Management

We store user sessions as JSON strings with `SET session:{userId} <json>`. Sessions are created at login and we clean them up with a nightly cron job that runs `KEYS session:*` and checks the `lastActive` field in each value, deleting stale ones. We considered TTL but our product team sometimes needs to extend sessions retroactively, and we didn't want to track the remaining TTL.

---

## 2. Product Catalog Cache

Our catalog service caches product data. When a product is updated, we delete all cached entries related to it. We use `DEL` to remove 5-10 keys per product update (price, description, images, variants, etc). During sales events we might invalidate thousands of keys at once in a loop calling DEL for each key.

---

## 3. Real-time Inventory

Each warehouse reports stock levels. We use a simple `SET inventory:{sku}:{warehouse} <count>` pattern. To get total inventory for a SKU across all warehouses, we run `KEYS inventory:{sku}:*` then `GET` each key and sum the values in the application. This runs on every product page load.

---

## 4. Rate Limiting

We implemented sliding window rate limiting. For each API key, we use a sorted set where the score is the timestamp and the member is a unique request ID. On each request we: ZADD the request, ZREMRANGEBYSCORE to remove entries older than the window, then ZCARD to check the count. This works but we're seeing high memory usage on the rate limiter keys.

---

## 5. Leaderboard

We have a gaming leaderboard with millions of users. Scores are stored in a sorted set. To display the leaderboard page, we fetch the top 100 with ZREVRANGE. When a user wants to see their rank, we use ZREVRANK. This all works well. However, we also need to show "leaderboard by region" - currently we maintain a separate sorted set per region and update both the global and regional sets on every score change.

---

## 6. Job Queue

We built a job queue using LIST. Producers LPUSH jobs, consumers RPOP them. For reliability we switched to BRPOPLPUSH to move jobs to a processing list, and return them if the worker crashes. Works fine, but we recently started getting ordering issues - jobs processed out of order and some seem to be duplicated after worker restarts.

---

## 7. Distributed Lock

We implement locks with `SET lock:{resource} {owner} NX EX 30`. To release, we GET the lock, check if we own it, then DEL it. In high contention scenarios, we sometimes see a race where the lock is released by the wrong owner.

---

## 8. Analytics Counters

We track page views, clicks, and conversions per product per day. Each counter is a separate key: `counter:{event}:{productId}:{date}`. We increment with INCR. At the end of each day, a batch job collects all counters by running `KEYS counter:*:{today}`, reads each value, writes to the database, then deletes them all. We have about 500K counter keys per day.

---

## 9. Full-text Search

Our search service indexes product names and descriptions. We store each product's searchable text as a key, and when a user searches, our application fetches ALL product keys with `KEYS product:*`, loads each value, and does string matching in the application layer. We cache search results for 60 seconds. We know this is slow but aren't sure what the alternative is with Valkey.

---

## 10. Pub/Sub Notifications

We use Pub/Sub to notify services of events (order placed, inventory changed, etc). Some services are occasionally slow or temporarily disconnected. We've noticed that when a subscriber reconnects, it misses all messages published while it was down. We're considering adding a retry mechanism that re-publishes messages that weren't acknowledged.

---

Provide your assessment for each of the 10 scenarios. For each one, state whether the current approach is correct, what the specific problem is (if any), and what the concrete improvement should be.
