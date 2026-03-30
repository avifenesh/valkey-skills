# TLS Subsystem

Use when understanding Valkey's TLS implementation - OpenSSL integration,
certificate management, connection type registration, mutual TLS authentication,
and background certificate reloading.

Source: `src/tls.c` (~2,000 lines). Configuration struct in `src/server.h`.
The entire file is conditionally compiled behind `USE_OPENSSL`.

---

## Build Modes

TLS can be compiled in two modes controlled by `USE_OPENSSL`:

- **Built-in** (`USE_OPENSSL=1`): TLS code is linked directly into the server
  binary. `RedisRegisterConnectionTypeTLS()` registers the connection type at
  startup.
- **Module** (`USE_OPENSSL=2`): TLS is loaded as a Valkey module via
  `ValkeyModule_OnLoad()`. The module must be built from the same source tree
  (verified by `REDIS_BUILD_ID_RAW` comparison). Can only be loaded at boot.

When TLS is not compiled in, `RedisRegisterConnectionTypeTLS()` logs a message
and returns `C_ERR`.

---

## Configuration Struct

```c
typedef struct serverTLSContextConfig {
    char *cert_file;            /* Server certificate (also used as client cert if no client_cert_file) */
    char *key_file;             /* Private key for cert_file */
    char *key_file_pass;        /* Optional password for key_file */
    char *client_cert_file;     /* Separate client-side certificate for outbound connections */
    char *client_key_file;      /* Private key for client_cert_file */
    char *client_key_file_pass; /* Optional password for client_key_file */
    int client_auth_user;       /* TLS_CLIENT_FIELD_OFF/CN/URI - cert-based ACL user mapping */
    char *dh_params_file;
    char *ca_cert_file;
    char *ca_cert_dir;
    char *protocols;
    char *ciphers;
    char *ciphersuites;         /* TLS 1.3 ciphersuites */
    int prefer_server_ciphers;
    int session_caching;
    int session_cache_size;
    int session_cache_timeout;
    int auto_reload_interval;   /* Interval for background cert reload checks */
} serverTLSContextConfig;
```

Related server fields:

```c
int tls_port;           /* TLS listening port */
int tls_auth_clients;   /* TLS_CLIENT_AUTH_NO/YES/OPTIONAL */
int tls_cluster;        /* Use TLS for cluster bus */
int tls_replication;    /* Use TLS for replication */
```

---

## SSL Context Architecture

Two global `SSL_CTX` objects:

```c
SSL_CTX *valkey_tls_ctx = NULL;        /* Server-side context (also default client context) */
SSL_CTX *valkey_tls_client_ctx = NULL; /* Explicit client context, if separate client certs configured */
```

`valkey_tls_ctx` is used for accepting inbound connections. If
`client_cert_file` and `client_key_file` are configured, a separate
`valkey_tls_client_ctx` is created for outbound connections (replication,
cluster bus). Otherwise, `valkey_tls_ctx` is used for both directions.

### Context Creation

`createSSLContext()` builds a base `SSL_CTX` with these steps:

1. Create context via `SSLv23_method()` (supports all protocol versions)
2. Disable SSLv2 and SSLv3 unconditionally
3. Disable specific TLS versions based on `tls-protocols` config
4. Disable compression (`SSL_OP_NO_COMPRESSION`)
5. Enable partial writes and moving write buffers
6. Set verify mode to `SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT`
7. Load certificate chain, validate it is not expired
8. Load private key (with optional password callback)
9. Load CA certificates from file and/or directory
10. Validate all CA certificates are not expired
11. Configure ciphers (TLS 1.2) and ciphersuites (TLS 1.3)

The server context (`tlsCreateContexts`) adds:
- Session caching configuration
- `SSL_OP_NO_CLIENT_RENEGOTIATION` (when available)
- Server cipher preference
- DH parameters (from file, or auto via `SSL_CTX_set_dh_auto`)

Default protocol: TLSv1.2 + TLSv1.3 (when available).

---

## Connection Type Registration

TLS registers as a `ConnectionType` via `connTypeRegister(&CT_TLS)`. The
`CT_TLS` struct provides callbacks for the full connection lifecycle: init/
cleanup/configure, listen/accept, create/shutdown/close, connect, read/write/
writev, sync I/O variants, pending data handling, and TLS-specific methods
(`get_peer_cert`, `get_peer_user`). This makes TLS transparent to the rest
of the server - all I/O goes through the same `connection` abstraction.

---

## TLS Connection Struct

```c
typedef struct tls_connection {
    connection c;                       /* Base connection (embedded, not pointer) */
    int flags;                          /* TLS_CONN_FLAG_* */
    SSL *ssl;                           /* OpenSSL session object */
    char *ssl_error;                    /* Last error string from OpenSSL */
    listNode *pending_list_node;        /* Position in pending_list */
    size_t last_failed_write_data_len;  /* Required by SSL_write retry semantics */
} tls_connection;
```

Connection flags:

| Flag | Meaning |
|------|---------|
| `TLS_CONN_FLAG_READ_WANT_WRITE` | SSL read needs socket to be writable |
| `TLS_CONN_FLAG_WRITE_WANT_READ` | SSL write needs socket to be readable |
| `TLS_CONN_FLAG_FD_SET` | File descriptor has been set on SSL object |
| `TLS_CONN_FLAG_POSTPONE_UPDATE_STATE` | Defer event loop updates |
| `TLS_CONN_FLAG_HAS_PENDING` | SSL has internally buffered data |
| `TLS_CONN_FLAG_ACCEPT_ERROR` | TLS accept failed |
| `TLS_CONN_FLAG_ACCEPT_SUCCESS` | TLS accept completed |

The WANT flags handle the fundamental TLS complexity: a logical read may
require a physical write (SSL renegotiation), and vice versa. When this
happens, the event handler must register for the opposite event and
remember which logical operation to resume.

---

## Client Certificate Authentication

Three levels controlled by `tls-auth-clients`:

| Value | Constant | Behavior |
|-------|----------|----------|
| `no` | `TLS_CLIENT_AUTH_NO` (0) | No client cert required |
| `yes` | `TLS_CLIENT_AUTH_YES` (1) | Client cert required, verified |
| `optional` | `TLS_CLIENT_AUTH_OPTIONAL` (2) | Client cert verified if presented |

Applied in `connCreateAcceptedTLS()` via `SSL_set_verify()`: `no` sets
`SSL_VERIFY_NONE`, `optional` sets `SSL_VERIFY_PEER`, `yes` sets
`SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT`.

### Certificate-Based ACL User Mapping

The `tls-auth-clients-user` config (stored as `client_auth_user`) controls
automatic user resolution from the client certificate:

| Value | Constant | Behavior |
|-------|----------|----------|
| `off` | `TLS_CLIENT_FIELD_OFF` (0) | No automatic user mapping |
| `CN` | `TLS_CLIENT_FIELD_CN` (1) | Extract CN from subject, look up ACL user |
| `URI` | `TLS_CLIENT_FIELD_URI` (2) | Extract SAN URI fields, look up ACL user |

`tlsGetPeerUser()` implements this:

1. Verify `SSL_get_verify_result()` returns `X509_V_OK`
2. Get peer certificate
3. Based on `client_auth_user`, extract CN or SAN URI
4. Look up the extracted name in the ACL user table via `ACLGetUserByName()`
5. Verify the user is enabled (`USER_FLAG_ENABLED`)

This integrates TLS with the ACL subsystem - a client presenting a certificate
with CN "appuser" is automatically authenticated as ACL user "appuser" without
needing AUTH.

---

## Replication and Cluster Bus

When `tls-replication` is enabled, replica-to-primary connections use TLS.
When `tls-cluster` is enabled, cluster bus gossip connections use TLS.

Both use `valkey_tls_client_ctx` (if configured with separate client certs)
or `valkey_tls_ctx` for outbound connections. CA certificate configuration is
mandatory when any of `tls-auth-clients`, `tls-cluster`, or `tls-replication`
are enabled.

---

## Background Certificate Reloading

TLS supports hot-reloading certificates without server restart. The system
uses a two-phase approach:

### Phase 1: Background thread (tlsConfigureAsync)

Called periodically based on `auto_reload_interval`. Runs in the BIO thread:

1. Capture current certificate metadata (SHA-256 fingerprints of cert files,
   inode/mtime of key files and CA directory)
2. Compare against active metadata - skip if unchanged
3. Parse certificates and create new SSL contexts (CPU-intensive work)
4. Store in `pending_reload` struct under mutex

### Phase 2: Main thread (tlsApplyPendingReload)

Called from the main event loop:

1. Lock mutex, check if pending reload exists
2. Swap `valkey_tls_ctx` and `valkey_tls_client_ctx` pointers
3. Update active metadata
4. Free old contexts
5. Refresh certificate info (expiry times, serial numbers)

This design keeps the main thread unblocked during the expensive certificate
parsing operations.

### Change Detection

The `tlsMaterialsMetadata` struct tracks SHA-256 fingerprints for cert files
(content-based) and inode+mtime for key files and CA directories (filesystem-
based). `metadataChanged()` compares old vs new metadata to skip unnecessary
reloads.

---

## Pending Data Handling

OpenSSL may buffer decrypted data internally after a read. Since the socket
has no new data, the event loop will not fire again. A global `pending_list`
tracks connections with buffered SSL data. `tlsProcessPendingData()` iterates
this list and calls read handlers, ensuring no decrypted data is lost.

---

## OpenSSL Version Handling

The code supports multiple OpenSSL versions with preprocessor conditionals:

- **< 1.0.2**: Legacy `OPENSSL_config()`, explicit crypto locks
- **1.0.2 - 1.1.0**: `ASN1_TIME_to_tm()` available
- **1.1.0+**: Auto-init, no manual locking needed
- **3.0.0+**: New decoder API for DH params, `SSL_get0_peer_certificate()`
  (does not increment refcount vs old `SSL_get_peer_certificate()`)
- **TLS 1.3**: Conditional ciphersuite configuration via `SSL_CTX_set_ciphersuites()`

The `USE_CRYPTO_LOCKS` path (OpenSSL < 1.1.0) sets up per-lock mutexes for
thread safety via `CRYPTO_set_locking_callback()`.

---

## Key Functions

| Function | Purpose |
|----------|---------|
| `tlsInit()` | OpenSSL library initialization |
| `createSSLContext()` | Build an SSL_CTX from config |
| `tlsCreateContexts()` | Create server + optional client contexts |
| `tlsConfigure()` | Orchestrate sync or async context (re)configuration |
| `connCreateAcceptedTLS()` | Create TLS connection for accepted socket |
| `connTLSAccept()` | Perform TLS handshake on accepted connection |
| `connTLSConnect()` | Initiate outbound TLS connection |
| `tlsGetPeerUser()` | Extract ACL user from client certificate |
| `connTLSGetPeerCert()` | Return PEM-encoded peer certificate |
| `tlsEventHandler()` | Main event loop handler for TLS connections |
| `updateStateAfterSSLIO()` | Process SSL_read/SSL_write return codes |
| `tlsConfigureAsync()` | Background certificate reload entry point |
| `tlsApplyPendingReload()` | Apply background-prepared SSL contexts |
| `RedisRegisterConnectionTypeTLS()` | Register TLS as a connection type |

---

## Certificate Monitoring

The server tracks `tls_server_cert_expire_time`, `tls_client_cert_expire_time`,
`tls_ca_cert_expire_time`, and corresponding serial numbers as SDS strings.
Exposed via INFO for monitoring. For CA certs loaded from a directory, the
earliest expiry across all certificates is reported.

---

## See Also

- [ACL Subsystem](../security/acl.md) - Certificate-based user mapping (`tls-auth-clients-user`) resolves a username from the client certificate and authenticates via `ACLGetUserByName()`. The `ACL_INVALID_TLS_CERT_AUTH` denial code is specific to TLS certificate auth failures.
- [Module API Overview](../modules/api-overview.md) - TLS can be compiled as a Valkey module (`USE_OPENSSL=2`). The module-mode TLS uses the standard module lifecycle (`ValkeyModule_OnLoad`) and must be loaded at boot time.
