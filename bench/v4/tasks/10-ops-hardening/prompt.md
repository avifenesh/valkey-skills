# Ops Hardening: Valkey Production Config Audit

You are a Valkey operations engineer reviewing a configuration file for a high-throughput session store deployment. The target machine has 16 CPU cores and 64GB RAM.

## Task 1: Fix the Configuration

Review `valkey.conf` in the workspace directory. This config was migrated from a Redis 7.2 deployment and has approximately 15 problems ranging from deprecated patterns, wrong parameter names, missing features, security holes, and suboptimal settings for a session store workload.

Write the corrected configuration to `valkey-fixed.conf` in the workspace directory. The fixed config must:

- Be a complete, valid valkey.conf that can start a Valkey 9.0 server
- Use Valkey-native parameter names instead of Redis legacy names
- Be properly tuned for a high-throughput session store on a 16-core / 64GB machine
- Follow security best practices (ACLs over rename-command, authentication required)
- Enable appropriate persistence for session data (sessions should survive restarts)
- Enable performance features appropriate for the hardware (I/O threads, defrag)
- Use proper lazyfree defaults for Valkey
- Enable all monitoring and diagnostic features (commandlog, latency monitoring)
- Enable dual-channel replication
- Address any missing configurations that a production deployment needs

## Task 2: Answer Operational Questions

Read `questions.md` in the workspace directory. Answer all 5 questions with detailed, specific responses. Write your answers to `answers.md` in the workspace directory.

Be precise about:
- Exact command names and syntax
- Configuration parameter names and their defaults
- What features actually exist in Valkey 9.0 vs what does not
- Version-specific behavior differences between Valkey and Redis

## Task 3: Write an Audit Report

Write `AUDIT.md` in the workspace directory explaining each change you made to the configuration and why. For each problem found, describe:
- What was wrong
- What you changed it to
- Why the change is necessary for this workload
