# Operational Questions

Answer each question with specific details, exact configuration directives, and concrete examples.

## Q1: Conditional Configuration

Valkey's config system supports an `include` directive for loading external config files. Some operators want environment-aware configuration where different settings apply based on the instance's role (primary vs replica). Explain how you would achieve conditional configuration in Valkey. Give a concrete example that sets different `maxmemory` values depending on whether the instance is a primary or a replica. Be precise about what Valkey's config system actually supports vs what it does not.

## Q2: COMMANDLOG vs SLOWLOG

Your team is migrating monitoring scripts from Redis to Valkey 9.0. The existing scripts use `SLOWLOG GET 25` and `slowlog-log-slower-than` in the config. Describe how COMMANDLOG differs from Redis's SLOWLOG. What are the 3 log types and how do you configure each? Show the exact config parameter names and their defaults. Explain what happens to existing scripts that still use SLOWLOG commands.

## Q3: Dual-Channel Replication

You are running a Valkey cluster where each primary node holds 100GB of data. When a replica needs to do a full resynchronization, it takes significant time and the replication backlog may overflow. Explain how dual-channel replication is intended to help with this scenario. What is the current status of this feature in Valkey 9.0? What configuration is needed, and what are the prerequisites? What should operators use today for improving full-sync performance?

## Q4: ACL-Based Command Restriction

Your current `valkey.conf` has these lines:
```
rename-command FLUSHALL ""
rename-command DEBUG ""
rename-command CONFIG ""
```
Design the ACL rules to replace these rename-command directives. The rules should allow admin users full access to all commands but restrict application users from running dangerous commands. Show the exact ACL SETUSER commands and explain why ACLs are preferred over rename-command, listing at least 4 specific limitations of rename-command.

## Q5: I/O Threads Troubleshooting

You have a Valkey instance with `io-threads 4` set on a 16-core machine, but performance benchmarks show no improvement over single-threaded mode. What are the 3 most likely reasons performance has not improved? For each reason, explain what config or operational change you would check, and what metrics or commands you would use to diagnose the issue. Also explain the `events-per-io-thread` hidden config parameter.
