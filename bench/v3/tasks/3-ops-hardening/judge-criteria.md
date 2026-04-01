## Task-Specific Judging Criteria: Ops Production Hardening

### Security Awareness (30%)
- Did the agent add authentication (requirepass or ACL users)?
- Did the agent enable protected-mode or restrict bind address?
- Did the agent remove the legacy rename-command directives and replace them with ACL-based access control?
- Did the agent consider TLS or explicitly document why it was omitted?

### Persistence Configuration (25%)
- Did the agent enable AOF (appendonly yes) given the "must survive restart" requirement?
- Did the agent configure RDB snapshots as a backup mechanism?
- Are the persistence settings appropriate for the session workload?

### Performance Tuning (25%)
- Did the agent set maxmemory to an appropriate value for 32 GB RAM (typically 24-28 GB, leaving headroom for OS and fork)?
- Did the agent change maxmemory-policy to allkeys-lru or volatile-lru (matching "LRU eviction preferred")?
- Did the agent increase io-threads for the 16-core machine (typically 4-8)?
- Did the agent set a nonzero latency-monitor-threshold?
- Did the agent increase slowlog-max-len for meaningful diagnostics?

### Explanation Quality (20%)
- Does AUDIT.md list all 12 issues?
- Is each fix explained with workload-specific rationale (not generic advice)?
- Does the agent demonstrate understanding of Valkey-specific behavior (not just Redis assumptions)?
