# Valkey Usage Review

We're running Valkey 9.0.3 in cluster mode (6 nodes, 3 primary + 3 replica) in production. Our application is a high-traffic e-commerce platform. Below are descriptions of how we use Valkey across different services. For each, tell us if our approach is good or if there's a better way. Be specific - cite commands, data structures, or patterns.

---

## 1. Session Management

We store user sessions as JSON strings with `SET session:{userId} <json>`. Sessions are created at login and we clean them up with a nightly cron job that runs `KEYS session:*` and checks the `lastActive` field in each value, deleting stale ones. We considered TTL but our product team sometimes needs to extend sessions retroactively, and we didn't want to track the remaining TTL.

---

## 2. Product Catalog Cache

Our catalog service caches product data. When a product is updated, we delete all cached entries related to it. We use `DEL` to remove 5-10 keys per product update (price, description, images, variants, etc). During sales events we might invalidate thousands of keys at once in a loop calling DEL for each key.

---

## 3. User Profiles with Field-Level TTL

We store user profiles as hashes: `HSET user:{id} name "Alice" email "a@b.com" prefs "{...}" verification_token "abc123"`. The verification token should expire after 24 hours, but we can't set TTL on individual hash fields. So we store the token as a separate key `verification:{id}` with `SETEX`. This means user data is split across two keys and we need to check both on every profile load.

---

## 4. Rate Limiting

We implemented sliding window rate limiting. For each API key, we use a sorted set where the score is the timestamp and the member is a unique request ID. On each request we: ZADD the request, ZREMRANGEBYSCORE to remove entries older than the window, then ZCARD to check the count. This works but we're seeing high memory usage on the rate limiter keys.

---

## 5. Distributed Lock

We implement locks with `SET lock:{resource} {owner} NX EX 30`. To release, we GET the lock, check if we own it, then DEL it. In high contention scenarios, we sometimes see a race where the lock is released by the wrong owner because between the GET and DEL, the lock expired and was acquired by someone else.

---

## 6. Real-time Inventory

Each warehouse reports stock levels. We use a simple `SET inventory:{sku}:{warehouse} <count>` pattern. To get total inventory for a SKU across all warehouses, we run `KEYS inventory:{sku}:*` then `GET` each key and sum the values in the application. This runs on every product page load.

---

## 7. Job Queue

We built a job queue using LIST. Producers LPUSH jobs, consumers RPOP them. For reliability we switched to BRPOPLPUSH to move jobs to a processing list, and return them if the worker crashes. Works fine, but we recently started getting ordering issues - jobs processed out of order and some seem to be duplicated after worker restarts.

---

## 8. Conditional Updates

Our pricing service needs to update product prices, but only if the current price matches what the service expects (optimistic locking). Currently we use WATCH/MULTI/EXEC transactions: WATCH the key, GET the current price, compare in app code, then MULTI SET new price EXEC. Under high contention the WATCH fails frequently and we retry in a loop, which causes latency spikes.

---

## 9. Full-text Search

Our search service indexes product names and descriptions. We store each product's searchable text as a key, and when a user searches, our application fetches ALL product keys with `KEYS product:*`, loads each value, and does string matching in the application layer. We cache search results for 60 seconds. We know this is slow but aren't sure what the alternative is with Valkey.

---

## 10. Pub/Sub Notifications

We use Pub/Sub to notify services of events (order placed, inventory changed, etc). Some services are occasionally slow or temporarily disconnected. We've noticed that when a subscriber reconnects, it misses all messages published while it was down. We're considering adding a retry mechanism that re-publishes messages that weren't acknowledged.

---

## 11. Monitoring and Slow Commands

We monitor slow commands using `SLOWLOG GET 100` and parse the results to find performance bottlenecks. We've noticed the slowlog doesn't capture some commands we expected to be slow. We're also missing information about which client issued the slow command.

---

## 12. Leaderboard with Expiring Scores

We have a daily leaderboard that resets each day. Currently we use a sorted set `leaderboard:{date}` and ZADD scores. To show "top 100 today", we use ZREVRANGE. The problem: old leaderboards accumulate forever. We run a weekly cleanup job that SCAN+DEL old leaderboard keys. We wish we could just set a TTL on the whole sorted set, but we heard you can't set TTL on sorted sets.

---

Provide your assessment for each of the 12 scenarios. For each one, state whether the current approach is correct, what the specific problem is (if any), and what the concrete improvement should be.
