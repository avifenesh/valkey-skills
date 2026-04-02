# Valkey Technical Assessment - Rubric

Scoring guide for AI judges. Each question is worth 1 point. Award full credit only for answers containing the exact key terms listed below. Award 0 for answers that describe Redis behavior instead of Valkey behavior. No partial credit.

These questions are designed so that Redis-trained knowledge produces WRONG answers. The "Redis trap" for each question describes the wrong answer a model would give without Valkey-specific knowledge.

---

## Q1: Slow command logging in Valkey 8.1+
**Expected answer:** `COMMANDLOG GET 10 slow` - the full command requires both a count AND a type argument. Before 8.1, the command was `SLOWLOG GET 10` which only required an optional count (defaulting to 10) and had no type argument. The new command requires the type argument because COMMANDLOG tracks three different log types (slow, large-request, large-reply), so you must specify which log to query.

SLOWLOG still works in 8.1+ as a backward-compatible alias that maps to the `slow` type only.

**Required terms:** `COMMANDLOG` AND `GET` AND `slow` (the type argument)
**Redis trap:** A model using Redis knowledge would answer `SLOWLOG GET 10` and not know COMMANDLOG exists, or not know the type argument is mandatory.

---

## Q2: Conditional SET based on current value
**Expected answer:** `SET mykey "new_value" IFEQ "old_value"` - the IFEQ flag was introduced in Valkey 8.1. It atomically compares the current value and updates only if it matches. Returns OK on match, nil on mismatch.

IFEQ is mutually exclusive with `NX` and `XX` - you cannot combine them in the same SET command.

**Required terms:** `IFEQ` AND (`NX` or `XX` mentioned as exclusive/incompatible)
**Redis trap:** Redis does not have IFEQ. A model would suggest a Lua script or WATCH/MULTI/EXEC as the only approach. No model would produce the IFEQ flag from Redis training data.

---

## Q3: Three COMMANDLOG entry types and their config directives
**Expected answer:**
1. Type `slow` - config: `commandlog-execution-slower-than` - default: 10000 microseconds (10ms)
2. Type `large-request` - config: `commandlog-request-larger-than` - default: 1048576 bytes (1MB)
3. Type `large-reply` - config: `commandlog-reply-larger-than` - default: 1048576 bytes (1MB)

**Required terms:** `commandlog-execution-slower-than` AND `commandlog-request-larger-than` AND `commandlog-reply-larger-than`
**Redis trap:** Redis only has `slowlog-log-slower-than`. A model would not know the two size-based config directives exist at all. These are Valkey-only configuration directives with no Redis equivalent.

---

## Q4: Setting a hash field with TTL, only if it already exists
**Expected answer:** `HSETEX session:xyz FXX EX 300 FIELDS 1 token abc123`

The command is HSETEX, introduced in Valkey 9.0. The `FXX` flag means "only set the field if it already exists" (field-level XX). The `FIELDS 1` argument specifies the count of field-value pairs that follow.

Note: `XX` applies to the key level (only if key exists), while `FXX` applies to the field level (only if field exists). Both can be used together or independently.

**Required terms:** `HSETEX` AND (`FXX` or `FIELDS`)
**Redis trap:** Redis has no HSETEX command, no per-field TTL, and no FXX flag. A model would suggest HSET + EXPIRE (key-level only) or say per-field TTL is not possible.

---

## Q5: Lazyfree default values - Valkey vs Redis 7.x
**Expected answer:** In Valkey, `lazyfree-lazy-expire` defaults to `yes`. In Redis 7.x, it defaults to `no`.

All five lazyfree parameters and their Valkey defaults (all `yes`):
1. `lazyfree-lazy-eviction` - `yes`
2. `lazyfree-lazy-expire` - `yes`
3. `lazyfree-lazy-server-del` - `yes`
4. `lazyfree-lazy-user-del` - `yes`
5. `lazyfree-lazy-user-flush` - `yes`

Source-verified from src/config.c lines 3253-3257, all have default value 1.

In Redis 7.x, `lazyfree-lazy-user-del` and most others default to `no`. Valkey changed all five to `yes`. This means DEL behaves like UNLINK by default in Valkey.

**Required terms:** `lazyfree-lazy-expire` AND `yes` (as the Valkey default)
**Redis trap:** A model using Redis knowledge would say `lazyfree-lazy-expire` defaults to `no` and advise users to explicitly enable it. This is the WRONG answer for Valkey.

---

## Q6: Safe distributed lock release without Lua
**Expected answer:** `DELIFEQ lock:order token_abc` - the DELIFEQ command was introduced in Valkey 9.0. It atomically checks the key's current value and deletes only if it matches.

Return values: `1` if the key existed and its value matched (key deleted), `0` if the key did not exist or the value did not match (no change).

DELIFEQ replaces the Lua script previously required for safe lock release: `EVAL "if server.call('get',KEYS[1]) == ARGV[1] then return server.call('del',KEYS[1]) else return 0 end" 1 lock:order token_abc`

**Required terms:** `DELIFEQ`
**Redis trap:** Redis does not have DELIFEQ. Every model would answer with the Lua EVAL script as the only way to do this. No model would produce DELIFEQ from Redis training data.

---

## Q7: RDB file format changes in Valkey 9.0
**Expected answer:** Valkey 9.0 uses RDB version 80. The magic string is `VALKEY` (replacing `REDIS` which was used for all RDB versions <= 11). The `rdbUseValkeyMagic()` function returns true for RDB versions > 79.

The "foreign version" range is RDB versions 12-79. This range is reserved to prevent loading RDB files from incompatible forks (specifically Redis CE 7.4+ which uses versions in this range). Under the default `rdb-version-check strict` mode, Valkey rejects RDB files in this range.

**Required terms:** (`80` or `version 80`) AND `VALKEY` (as magic string) AND (`12` or `foreign`)
**Redis trap:** A model would say RDB uses the `REDIS` magic string (wrong for 9.0) and would not know about RDB version 80 or the foreign version range. These are entirely Valkey-specific concepts.

---

## Q8: Numbered databases in cluster mode
**Expected answer:** Before Valkey 9.0, running SELECT in cluster mode returned an error - cluster mode was restricted to database 0 only.

The configuration directive is `cluster-databases` with a default value of `1` (meaning only database 0 is available). Setting `cluster-databases 16` enables databases 0 through 15.

**Required terms:** `cluster-databases` AND (`1` or `default 1` as the default value)
**Redis trap:** Redis does not support numbered databases in cluster mode at all. A model would definitively state "cluster mode only supports database 0, period" without knowing Valkey 9.0 changed this. No model would know the `cluster-databases` directive name.

---

## Q9: The deprecated io-threads companion directive
**Expected answer:** The deprecated directive is `io-threads-do-reads`. In current Valkey, when `io-threads` is set > 1, reads are always offloaded to I/O threads - there is no separate toggle. The directive is listed in the `deprecated_configs[]` array in src/config.c and is silently ignored if present.

The other deprecated directive is `dynamic-hz` - the behavior it controlled (automatically scaling the server timer frequency based on connected clients) is now always enabled.

**Required terms:** `io-threads-do-reads` AND `dynamic-hz`
**Redis trap:** Redis documentation and guides actively instruct users to set `io-threads-do-reads yes` as a companion to `io-threads`. A model would recommend this deprecated setting as current best practice. Models would also not know `dynamic-hz` is deprecated because it is still documented in Redis.

---

## Q10: HGETEX - get hash fields and set TTL atomically
**Expected answer:** `HGETEX session:abc EX 3600 FIELDS 2 user_id email`

HGETEX was introduced in Valkey 9.0. It reads hash field values and atomically sets or refreshes their TTL in a single command. The `FIELDS 2` argument specifies that 2 field names follow.

It differs from a pipeline of HMGET + HEXPIRE because it is a single atomic operation - there is no window between reading and setting the TTL where the field could be modified or expired by another client. It also supports PERSIST to remove TTL from fields in the same read operation.

**Required terms:** `HGETEX` AND `FIELDS 2` (or `FIELDS n`)
**Redis trap:** Redis has no HGETEX command and no per-field TTL. A model would say this is not possible in a single command and suggest a pipeline or Lua script. No model would produce HGETEX from Redis training data.

---

## Scoring Summary

| Question | Required Terms | Redis-Trained Model Would Say |
|----------|---------------|-------------------------------|
| Q1 | COMMANDLOG, GET, slow | SLOWLOG GET 10 (no type arg) |
| Q2 | IFEQ | Lua script or WATCH/MULTI |
| Q3 | commandlog-execution-slower-than, commandlog-request-larger-than, commandlog-reply-larger-than | slowlog-log-slower-than only |
| Q4 | HSETEX, FXX or FIELDS | HSET + EXPIRE (key-level) |
| Q5 | lazyfree-lazy-expire, yes | Defaults to no |
| Q6 | DELIFEQ | Lua EVAL script |
| Q7 | 80, VALKEY, 12/foreign | REDIS magic, no version 80 |
| Q8 | cluster-databases, 1 | "Not possible in cluster" |
| Q9 | io-threads-do-reads, dynamic-hz | Recommend enabling both |
| Q10 | HGETEX, FIELDS | "Not possible atomically" |

A model without the Valkey skills should score 0-2 out of 10. Key terms Q2, Q4, Q6, Q7, Q8, Q10 require Valkey-only command names or values that do not exist in Redis.
