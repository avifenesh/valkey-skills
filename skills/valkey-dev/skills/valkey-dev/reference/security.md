# Security: ACL and TLS

Auth/authz. The two subsystems cross-reference - `tls-auth-clients-user` binds a TLS cert to an ACL user.

## ACL (`src/acl.c`)

Standard Redis 7.x selector model - users, selectors evaluated as OR, command bitmap, categories, `%R~` / `%W~` key-pattern read/write split, `&channel` pub/sub patterns, SHA-256 password storage, timing-safe compare, ACL file vs config file (mutually exclusive).

Valkey-specific:

- **Database-level selectors**: `alldbs`, `resetdbs`, and per-ID rules let you restrict a user to specific databases. Absent from Redis. Grep `alldbs` in `src/acl.c` to locate the implementation.
- **TLS-to-ACL binding**: config `tls-auth-clients-user` (`CN` | `URI` | `OFF`). A connecting TLS client with a matching cert subject field is auto-authenticated as the user named by that field. No explicit `AUTH` needed. Test coverage in `tests/unit/tls.tcl`.

## TLS (`src/tls.c`)

Compiled when `USE_OPENSSL` is set (`BUILD_TLS=yes|module` - see `devex.md`). Standard OpenSSL integration; agent-knowable from Redis. Valkey-specific:

- **`tls-auto-reload-interval`** (seconds, default 0 = off): when > 0, the server watches cert/key files and rebuilds the `SSL_CTX` in place without restart. Work is split - a BIO thread parses certs and constructs the new context (CPU-heavy), the main thread atomically swaps the context pointer. Change detection uses SHA-256 over cert content and inode/mtime on the key file.
- **`tls-auth-clients-user`** (`OFF` | `CN` | `URI`): cert-bound auto-auth. Cert subject CN or SAN URI is looked up as an ACL username.
- **INFO cert expiry fields**: `tls_server_cert_expire_time`, `tls_client_cert_expire_time`, `tls_ca_cert_expire_time` + serial numbers + `tls_*_expires_in_seconds` helpers. Populated by `tlsUpdateCertInfoFromCtx`.
- **TLS handshake I/O-thread offload**: expensive parts of `SSL_accept` run off the main thread via `trySendAcceptToIOThreads` (see `networking.md`). Relevant when you're touching the I/O-thread state machine in `event-loop.md`.
