# Task: Investigate Valkey Hash Field TTL Bug

You are a Valkey server developer investigating a bug in a custom Valkey 9.0.3 build.

## Situation

An operator has reported anomalous behavior with hash field expiration. A Docker container running the buggy Valkey build is available at localhost:6379 (see docker-compose.yml). The workspace contains:

- `symptoms.md` - the operator's bug report describing observed symptoms
- `reproduce.sh` - a script that demonstrates the bug against the running instance

## What You Know

- This is a Valkey 9.0.3 build with a single bug introduced in the hash field TTL handling code
- The bug causes HEXPIRE to accept TTL settings on fields that no longer exist in the hash
- This leads to ghost TTL entries visible via HEXPIRETIME, incorrect return values, and a slow memory leak

## What You Do NOT Have

- No Valkey source code is provided
- No hints about which specific file or function contains the bug
- You must reason from Valkey's architecture and the observed symptoms to identify the root cause

## Deliverable

Write your analysis to `ANALYSIS.md` in the workspace directory. Your analysis must cover:

1. **Root cause** - identify the specific source file and the missing check
2. **Mechanism** - explain exactly how the bug manifests at the code level
3. **Impact** - describe all observable consequences (incorrect return values, ghost TTLs, memory leak)
4. **Fix** - propose a minimal, correct fix with enough detail to implement it
5. **Related commands** - identify other commands that may be affected by or expose this bug

Use the reproduce script and symptoms document to guide your investigation. Reason from your knowledge of Valkey server internals.
