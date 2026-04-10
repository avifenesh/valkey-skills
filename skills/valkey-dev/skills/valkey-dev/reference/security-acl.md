# ACL Subsystem

Use when understanding Valkey's access control internals - user management, permission checking, command categories, key/channel patterns, selectors, persistence, and audit logging.

Standard ACL implementation (same as Redis 7.x selector model). Valkey-specific additions:

- **`+failover` ACL requirement**: Valkey 9.0 requires explicit `+failover` permission for users executing the FAILOVER command (coordinated failover). The `default` user has it via `+@all`, but restricted users need it explicitly.
- **Database selectors**: `db=N` and `alldbs`/`resetdbs` rules restrict users to specific databases (Valkey addition, not in Redis)
- **`tls-auth-clients-user`**: Certificate-based ACL user mapping via CN or SAN URI fields (integrates TLS with ACL)

Source: `src/acl.c` (~3,500 lines). Users stored in rax tree. Selectors evaluated as OR (any match grants access). Command bitmap: 1024 bits. 21 built-in categories. Passwords stored as SHA-256 hex with timing-safe comparison. Two persistence modes: ACL file or config file (mutually exclusive).
