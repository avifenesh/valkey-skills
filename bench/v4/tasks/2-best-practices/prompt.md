# Valkey Best Practices Assessment

Answer each question with a detailed, specific response. Be precise about command names, configuration directives, and version-specific features.

Write your answers to `answers.md` with a section for each question.

## Q1: COMMANDLOG vs SLOWLOG
Valkey 8.1 introduced COMMANDLOG as a replacement for SLOWLOG. What three types of events does COMMANDLOG track, what are the default thresholds for each, and what is the exact syntax to retrieve the last 10 entries from each type? Also explain how the old SLOWLOG commands map to COMMANDLOG.

## Q2: Hash field TTL commands
Valkey 9.0 introduced per-field TTL on hashes. Name the command that sets hash fields with values and a TTL in a single atomic operation, and show its full syntax including conditional flags. What does the `FIELDS n` argument mean? What return values do the TTL inspection commands (HTTL) return for a field that exists without a TTL, and for a field that does not exist?

## Q3: Conditional operations - IFEQ and DELIFEQ
Explain the SET IFEQ and DELIFEQ commands introduced in Valkey 8.1 and 9.0 respectively. For DELIFEQ specifically, show how it replaces the Lua script previously required for safe distributed lock release in the Redlock algorithm. What return values does DELIFEQ produce?

## Q4: I/O threads - when NOT to enable
Valkey's io-threads config defaults to 1. What is the deprecated config directive that older Redis guides tell you to set alongside io-threads, and why is it no longer needed? On a 4-core system, what is the maximum safe io-threads value and what specific performance degradation was measured when over-subscribing? What does the `events-per-io-thread` hidden config control?

## Q5: Lazyfree defaults - Valkey vs Redis
List all five lazyfree configuration parameters in Valkey and their default values. How do Valkey's defaults differ from Redis 7.x defaults for these same parameters? What practical consequence does `lazyfree-lazy-user-del yes` have on the behavior of the DEL command?

## Q6: rename-command vs ACL for disabling dangerous commands
The rename-command directive has several serious limitations. Name at least four specific limitations, then explain the ACL-based alternative. What ACL category contains all dangerous commands, and what specific per-user advantages does ACL provide that rename-command cannot?

## Q7: Client-side caching protocol and invalidation
Describe how client-side caching works in Valkey using CLIENT TRACKING. What is the exact channel name used for invalidation messages in RESP2 redirect mode? What are the two tracking modes (key-based vs prefix-based), and what are the OPTIN and OPTOUT sub-modes? What server config parameter controls the maximum number of tracked keys?

## Q8: Cluster enhancements in Valkey 9.0
Valkey 9.0 introduced two major cluster enhancements. First, explain numbered databases in cluster mode - what was the restriction before 9.0, what config directive enables it, and what is its default value? Second, explain how atomic slot migration differs from traditional key-by-key migration and what redirect behavior clients see during each approach.

## Q9: AOF persistence defaults and hybrid mode
What is the default value of `aof-use-rdb-preamble` in Valkey, and what does it do? Explain the worst-case data loss scenario for `appendfsync everysec` - why is it 2 seconds rather than 1 second as commonly stated? What are the four possible values for `repl-diskless-load` on the replica side, and what does `swapdb` do differently from the others?

## Q10: GEOSEARCH BYPOLYGON and Valkey 9.0 performance features
Valkey 9.0 added BYPOLYGON to GEOSEARCH. Show the syntax including the num-vertices argument. Then separately, name at least three Valkey 9.0 server-side performance features that improve throughput without application code changes, and state the measured improvement for pipeline memory prefetch.
