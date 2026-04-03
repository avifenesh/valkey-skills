# TLS Subsystem

Use when understanding Valkey's TLS implementation - OpenSSL integration, certificate management, connection type registration, mutual TLS authentication, and background certificate reloading.

Source: `src/tls.c` (~2,000 lines). Conditionally compiled behind `USE_OPENSSL`.

Standard TLS implementation with these Valkey-specific features:

## Build Modes

- `BUILD_TLS=yes` - linked into binary
- `BUILD_TLS=module` - loaded as Valkey module (verified by `REDIS_BUILD_ID_RAW`; can only load at boot)

## Background Certificate Reloading

`tls-auto-reload-interval` enables periodic background cert reloading without restart. Two-phase: BIO thread parses certs and creates new SSL contexts (CPU-intensive), main thread atomically swaps context pointers. Change detection uses SHA-256 fingerprints for cert content and inode/mtime for key files.

## Certificate-Based ACL User Mapping

`tls-auth-clients-user` (`off`/`CN`/`URI`) maps client certificate fields to ACL users automatically - no AUTH needed. Extracts CN from subject or SAN URI, looks up in ACL user table.

## Certificate Monitoring

Server tracks `tls_server_cert_expire_time`, `tls_client_cert_expire_time`, `tls_ca_cert_expire_time` and serial numbers, exposed via INFO.
