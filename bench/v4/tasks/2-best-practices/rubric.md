# Valkey Best Practices Assessment - Rubric

Scoring guide for AI judges. Each question is worth 1 point. Award full credit for answers that include the key terms and demonstrate correct understanding. Award partial credit (0.5) for mostly correct answers missing minor details. Award 0 for wrong answers or answers that describe Redis behavior instead of Valkey behavior.

---

## Q1: COMMANDLOG vs SLOWLOG
**Expected answer:** COMMANDLOG (Valkey 8.1+) tracks three types of events:
1. `slow` - commands exceeding execution time threshold (default: 10000 microseconds / 10ms)
2. `large-request` - commands exceeding request size threshold (default: 1048576 bytes / 1MB)
3. `large-reply` - commands exceeding reply size threshold (default: 1048576 bytes / 1MB)

Syntax: `COMMANDLOG GET 10 slow`, `COMMANDLOG GET 10 large-request`, `COMMANDLOG GET 10 large-reply`. The type argument is mandatory for COMMANDLOG (unlike SLOWLOG which defaults to 10 entries and has no type).

Migration: `SLOWLOG GET 10` maps to `COMMANDLOG GET 10 slow`, `SLOWLOG LEN` maps to `COMMANDLOG LEN slow`, `SLOWLOG RESET` maps to `COMMANDLOG RESET slow`. SLOWLOG still works as a backward-compatible alias but only covers the `slow` type. The old config names `slowlog-log-slower-than` and `slowlog-max-len` are registered aliases for `commandlog-execution-slower-than` and `commandlog-slow-execution-max-len`.

**Key terms that must appear:** COMMANDLOG, slow, large-request, large-reply, 10000, 1048576
**Common wrong answer (Redis trap):** Saying only SLOWLOG exists, or not knowing about large-request/large-reply types, or not knowing the type argument is mandatory in COMMANDLOG syntax.

---

## Q2: Hash field TTL commands
**Expected answer:** The command is `HSETEX` (Valkey 9.0+). Full syntax:
```
HSETEX key [NX | XX] [FNX | FXX] [EX s | PX ms | EXAT t | PXAT t | KEEPTTL] FIELDS n field value [field value ...]
```

The `FIELDS n` argument specifies the count of field-value pairs that follow - n must match the number of field names provided.

HTTL return values: `-1` if the field exists but has no TTL, `-2` if the field does not exist. A positive integer means the remaining TTL in seconds.

Other key commands: HGETEX (get fields and set/refresh/remove TTL), HEXPIRE, HPEXPIRE, HEXPIREAT, HPEXPIREAT, HPERSIST, HTTL, HPTTL, HEXPIRETIME, HPEXPIRETIME (11 new commands total).

**Key terms that must appear:** HSETEX, FIELDS n, -1, -2, HGETEX
**Common wrong answer (Redis trap):** Redis has no per-field TTL on hashes at all. A model trained on Redis would not know HSETEX, HGETEX, or the FIELDS n syntax. Some might confuse with Redis 7.4's HEXPIRE which has a different syntax.

---

## Q3: Conditional operations - IFEQ and DELIFEQ
**Expected answer:**
- `SET key new_value IFEQ expected_value` (Valkey 8.1+): atomically updates a key only if its current value matches expected_value. Returns OK on match, nil on mismatch. Cannot be combined with NX or XX.
- `DELIFEQ key expected_value` (Valkey 9.0+): atomically deletes a key only if its current value matches. Returns 1 if deleted, 0 if not.

For safe Redlock unlock, DELIFEQ replaces the Lua script:
```
-- Before (Lua): EVAL "if server.call('get',KEYS[1]) == ARGV[1] then return server.call('del',KEYS[1]) else return 0 end" 1 lock:resource my_random_token
-- After: DELIFEQ lock:resource my_random_token
```

DELIFEQ is the native replacement for the canonical Redlock unlock pattern across all N instances.

**Key terms that must appear:** IFEQ, DELIFEQ, atomic, 1, 0, Lua, Redlock
**Common wrong answer (Redis trap):** Redis does not have IFEQ or DELIFEQ. Models would suggest Lua scripts or WATCH/MULTI/EXEC as the only approach to conditional operations.

---

## Q4: I/O threads - when NOT to enable
**Expected answer:** The deprecated directive is `io-threads-do-reads`. In current Valkey, when io-threads > 1, reads are always offloaded - there is no separate toggle. The directive is listed in the deprecated configs in src/config.c and is silently ignored.

On a 4-core system, the maximum safe io-threads value is 2. Over-subscribing was specifically measured: on a Raspberry Pi CM4 with 4 cores, io-threads=5 dropped performance from 416K to 336K RPS (compared to proper settings). The key rule: never set io-threads >= number of available cores.

`events-per-io-thread` (default: 2, hidden config) controls how many pending events are needed per I/O thread before that thread is activated. The formula is: target_threads = numevents / events_per_io_thread. Setting it to 0 forces all threads active. Threads are parked via mutex when idle and unparked when load increases.

**Key terms that must appear:** io-threads-do-reads, deprecated, 2 (for 4-core), 336K, events-per-io-thread
**Common wrong answer (Redis trap):** Redis guides tell users to set `io-threads-do-reads yes` as a required companion to io-threads. Models would repeat this outdated advice. They would also not know the specific degradation numbers or the events-per-io-thread hidden config.

---

## Q5: Lazyfree defaults - Valkey vs Redis
**Expected answer:** All five lazyfree parameters and their Valkey defaults:
1. `lazyfree-lazy-eviction` - `yes`
2. `lazyfree-lazy-expire` - `yes`
3. `lazyfree-lazy-server-del` - `yes`
4. `lazyfree-lazy-user-del` - `yes`
5. `lazyfree-lazy-user-flush` - `yes`

In Redis 7.x, these default to `no` (except lazyfree-lazy-user-flush which was added later). Valkey changed all five defaults to `yes` (verified in src/config.c lines 3253-3257, all have default value 1).

Practical consequence of `lazyfree-lazy-user-del yes`: the DEL command behaves identically to UNLINK - it unlinks the key from the keyspace and queues background memory deallocation. There is no practical difference between DEL and UNLINK with this default. The change is transparent to clients.

**Key terms that must appear:** lazyfree-lazy-user-del, lazyfree-lazy-expire, yes (as default), DEL, UNLINK
**Common wrong answer (Redis trap):** Models trained on Redis would say these default to `no` and advise users to explicitly set them to `yes`. They would also say DEL is always synchronous and you must use UNLINK for non-blocking deletes.

---

## Q6: rename-command vs ACL
**Expected answer:** rename-command limitations (at least four):
1. Config file only - cannot be changed at runtime
2. Applies globally - all users affected equally (no per-user control)
3. Breaks replication - renamed commands on primary don't match replica if configs differ
4. Breaks scripts - Lua scripts and modules using renamed commands fail silently
5. Breaks tooling - monitoring tools that use KEYS, CONFIG, or DEBUG will fail
6. No logging/audit trail of who attempted the renamed command
7. AOF incompatible - AOF files contain original command names, replay breaks if commands are renamed differently

ACL alternative: Use `ACL SETUSER` with `-@dangerous` category to deny dangerous commands per user. The @dangerous category includes FLUSHALL, FLUSHDB, DEBUG, KEYS, SHUTDOWN, REPLICAOF, CONFIG, etc.

Per-user advantages: runtime changes, per-user control, replication safe, audit logging via ACL LOG, subcommand control (e.g., +config|get -config|set), category-based rules, key pattern restrictions.

**Key terms that must appear:** @dangerous, ACL SETUSER, per-user, runtime, ACL LOG, replication
**Common wrong answer (Redis trap):** Models may recommend rename-command as the primary method without knowing its limitations, or not mention the @dangerous category.

---

## Q7: Client-side caching protocol and invalidation
**Expected answer:** CLIENT TRACKING enables server-assisted client-side caching. The server tracks keys read by each client and sends invalidation messages when those keys change.

The invalidation channel name for RESP2 redirect mode is `__redis__:invalidate` (the legacy `__redis__` prefix is retained even in Valkey, verified in src/tracking.c).

Two tracking modes:
1. Default (key-based): server remembers every key served to the client, precise invalidation, higher memory usage
2. Broadcasting (prefix-based): clients subscribe to key prefixes with `CLIENT TRACKING ON BCAST PREFIX user:`, less precise but lower server memory

OPTIN mode: tracking off by default, client must send `CLIENT CACHING YES` before each read to track it. OPTOUT mode: tracking on by default, client sends `CLIENT CACHING NO` before reads to skip tracking. NOLOOP option prevents a client from receiving invalidation for its own modifications.

Server config: `tracking-table-max-keys` (default: 1000000) controls maximum tracked keys globally. When exceeded, entries are evicted and invalidation is sent to affected clients.

**Key terms that must appear:** __redis__:invalidate, BCAST, OPTIN, OPTOUT, tracking-table-max-keys, 1000000, CLIENT CACHING
**Common wrong answer (Redis trap):** Models might not know the exact invalidation channel name retains the `__redis__` prefix in Valkey. They might not know the tracking-table-max-keys default or the OPTIN/OPTOUT sub-modes.

---

## Q8: Cluster enhancements in Valkey 9.0
**Expected answer:**
1. Numbered databases in cluster mode: Before 9.0, cluster mode was restricted to database 0 - SELECT returned an error. The config directive is `cluster-databases` (default: 1, meaning only database 0). Set e.g. `cluster-databases 16` to enable databases 0-15. Each database is a separate namespace; the same key name in different databases are independent entries. Hash slot assignment still applies regardless of database number.

2. Atomic slot migration: Traditional resharding migrates keys one at a time, causing ASK redirects during migration. Clients must handle both ASK and MOVED redirects. Valkey 9.0 serializes the entire slot as an AOF-format payload and transfers it atomically. Clients see only standard MOVED redirects (no ASK redirects during migration). The cutover is instant with zero intermediate states. No special configuration needed - enabled automatically in 9.0+.

**Key terms that must appear:** cluster-databases, default 1, SELECT, atomic, ASK, MOVED, AOF-format
**Common wrong answer (Redis trap):** Redis does not support numbered databases in cluster mode at all. Models would say "cluster mode only supports database 0" without knowing Valkey changed this. They would not know about atomic slot migration.

---

## Q9: AOF persistence defaults and hybrid mode
**Expected answer:** `aof-use-rdb-preamble` defaults to `yes` in Valkey. When enabled, AOF rewrite creates a base file in RDB format (binary snapshot) while incremental files remain in AOF command format. This gives fast restarts (RDB loads quickly) with AOF durability.

Worst-case data loss for `appendfsync everysec`: 2 seconds, not 1 second. The reason: if the background fsync takes longer than 1 second (e.g., disk contention), the main thread delays writes for up to an additional 1 second. If 2 seconds elapse without fsync completing, a blocking write is forced. This is documented per antirez's persistence analysis.

`repl-diskless-load` four values:
1. `disabled` (default) - save RDB to disk then load (safest)
2. `on-empty-db` - load directly into memory only if database is empty
3. `swapdb` - load into a separate database, swap atomically on success (replica serves old data until new load completes, requires 2x memory)
4. `flush-before-load` - flush current database then load directly

`swapdb` provides the best availability because the replica continues serving the old dataset during the load. The swap is atomic on completion.

**Key terms that must appear:** aof-use-rdb-preamble, yes, 2 seconds, swapdb, flush-before-load, on-empty-db
**Common wrong answer (Redis trap):** Models might say the default for aof-use-rdb-preamble is `no` (it was `no` in older Redis versions). They commonly state worst-case data loss as "1 second" for appendfsync everysec. They may not know the `flush-before-load` option for repl-diskless-load.

---

## Q10: GEOSEARCH BYPOLYGON and performance features
**Expected answer:** BYPOLYGON syntax (Valkey 9.0+):
```
GEOSEARCH key [FROMMEMBER member | FROMLONLAT longitude latitude] BYPOLYGON num-vertices lon1 lat1 lon2 lat2 ... lonN latN [ASC | DESC] [COUNT count [ANY]] [WITHCOORD] [WITHDIST] [WITHHASH]
```

The first argument after BYPOLYGON is `num-vertices` specifying how many vertex coordinate pairs follow. The polygon is automatically closed. GEOSEARCHSTORE also supports BYPOLYGON.

Valkey 9.0 performance features (no code changes needed):
1. Pipeline memory prefetch - up to 40% higher throughput for pipelined commands (batch key prefetching)
2. Zero-copy responses - up to 20% higher throughput for large value reads (eliminates buffer copies)
3. SIMD BITCOUNT/HLL - up to 200% higher throughput (further SIMD improvements)
4. Multipath TCP (MPTCP) - up to 25% latency reduction (multiple network paths)
5. Atomic slot migration - faster resharding with bulk transfer

Pipeline memory prefetch provides up to 40% higher throughput.

**Key terms that must appear:** BYPOLYGON, num-vertices, prefetch, 40%, zero-copy, 20%
**Common wrong answer (Redis trap):** Redis does not have BYPOLYGON for GEOSEARCH. Models would only know BYRADIUS and BYBOX. They would not know about Valkey's specific pipeline prefetch or zero-copy response optimizations.
