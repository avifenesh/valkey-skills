# Task: Investigate and Fix Valkey Hash Field TTL Bug

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

- No Valkey source code is provided in the workspace
- No hints about which specific file or function contains the bug
- You must reason from Valkey's architecture and the observed symptoms to identify the root cause

## Deliverables

### 1. ANALYSIS.md

Write your analysis to `ANALYSIS.md` covering:

1. **Root cause** - identify the specific source file and the missing check
2. **Mechanism** - explain exactly how the bug manifests at the code level
3. **Impact** - describe all observable consequences
4. **Related commands** - identify other commands affected

### 2. fix.patch

Write a patch file to `fix.patch` that fixes the bug. The patch should:

- Be a valid unified diff format (applicable with `git apply` or `patch -p1`)
- Target the correct source file in the Valkey codebase
- Add the minimal check needed to prevent HEXPIRE on non-existent fields
- Not break any existing functionality

### 3. verify.sh

Write a verification script `verify.sh` that:

- Connects to the Valkey instance at localhost:6379
- Demonstrates the bug is present (before fix)
- Applies the fix (you may describe the expected post-fix behavior)
- Tests that HEXPIRE on a deleted field returns 0 (not 1)
- Tests that HEXPIRETIME on a deleted field returns -2 (field not found)
- Tests that normal HEXPIRE on existing fields still works correctly

Use the reproduce script and symptoms document to guide your investigation.
