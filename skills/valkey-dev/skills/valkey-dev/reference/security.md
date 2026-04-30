# Security: ACL and TLS

## ACL (`src/acl.c`)

- Database-level selectors: `alldbs`, `resetdbs`, and per-ID rules restrict a user to specific databases. Absent from Redis. Grep `alldbs` in `src/acl.c`.
- `tls-auth-clients-user` (`CN` | `URI` | `OFF`): a connecting TLS client with a matching cert subject field is auto-authenticated as the ACL user named by that field. No explicit `AUTH` needed.

## TLS (`src/tls.c`)

- `tls-auto-reload-interval` (seconds, default 0 = off): when > 0, the server watches cert/key files and rebuilds `SSL_CTX` in place without restart. A BIO thread parses certs and constructs the new context; the main thread atomically swaps the context pointer. Change detection = SHA-256 over cert content + inode/mtime on the key file.
- `tls-auth-clients-user` (`OFF` | `CN` | `URI`): cert-bound auto-auth. Cert subject CN or SAN URI is looked up as an ACL username.
- INFO cert expiry fields: `tls_server_cert_expire_time`, `tls_client_cert_expire_time`, `tls_ca_cert_expire_time` plus serial numbers and `tls_*_expires_in_seconds` helpers. Populated by `tlsUpdateCertInfoFromCtx`.
- TLS handshake I/O-thread offload: expensive parts of `SSL_accept` run off the main thread via `trySendAcceptToIOThreads`.
