# Deployment Research - New Findings for Enrichment

Research date: 2026-03-29
Sources: valkey.io official docs, Docker Hub API, GitHub releases API, Bitnami container README, valkey-container Dockerfile/entrypoint, Valkey 9.0 blog, Context7, cluster/sentinel/replication/TLS/ACL/persistence/latency topic pages.

This document contains NEW information not already in our reference docs, organized by topic. Each section notes what is new vs what we already cover.

---

## 1. Current Version Matrix (as of 2026-03-29)

Our docs use generic `valkey/valkey:9` tags. Here are the exact current versions.

| Branch | Latest Release | Release Date | Docker Tags |
|--------|---------------|--------------|-------------|
| 9.0.x (stable) | 9.0.3 | 2026-02-24 | `9`, `9.0`, `9.0.3`, `latest` |
| 9.1.x (RC) | 9.1.0-rc1 | 2026-03-17 | `9.1`, `9.1.0-rc1` |
| 8.1.x | 8.1.6 | 2026-02-24 | `8`, `8.1`, `8.1.6` |
| 8.0.x | 8.0.7 | 2026-03-09 | `8.0`, `8.0.7` |
| 7.2.x | 7.2.12 | 2026-03-09 | `7`, `7.2`, `7.2.12` |
| unstable | rolling | 2026-03-29 | `unstable` |

Binary artifacts are published for arm64 and x86_64 on Ubuntu Jammy and Noble.

**9.0.3 is a security release** with three CVEs:
- CVE-2025-67733: RESP protocol injection via Lua error_reply
- CVE-2026-21863: Remote DoS with malformed cluster bus message
- CVE-2026-27623: Reset request type after handling empty requests

### Enrichment target
- `install.md`: add version matrix and security update urgency
- `docker.md`: update tag examples to `9.0.3` instead of generic `9`
- `production-checklist.md`: add "subscribe to security advisories" item

---

## 2. Docker Image Details (Not in Our Docs)

### Official image (`valkey/valkey`)

Source: Docker Hub API, valkey-container repo Dockerfile template and entrypoint.sh.

**Base images** (new - we don't document this):
- Default variant: `debian:trixie-slim` (changed from bookworm)
- Alpine variant: `alpine:3.23`
- Previous versions used bookworm; trixie is now the base for all current tags

**Supported architectures**: `amd64`, `arm64`, `arm` (32-bit), `ppc64le`
- We only mention amd64/arm64. ppc64le and 32-bit arm are also supported.

**Tag naming convention** (new - not documented):
- `<version>` = Debian Trixie (default)
- `<version>-trixie` = explicit Debian Trixie
- `<version>-alpine` = Alpine (latest)
- `<version>-alpine3.23` = Alpine pinned version
- `latest` = latest stable Debian Trixie
- `alpine` = latest stable Alpine

**Protected mode disabled in Docker builds** (important gotcha - not in our docs):
The Dockerfile explicitly patches `config.c` to change `protected-mode` default from `1` to `0` before building. This is intentional because Docker already isolates ports (no ports exposed unless `-p` specified). The comment in the Dockerfile explains: "if you specify any argument to valkey-server, [it assumes] you are going to specify everything" - so the default `save` behavior on SIGTERM is preserved by modifying the source rather than passing a config flag.

**Entrypoint behavior** (new details):
- If first arg starts with `-` or ends with `.conf`, it prepends `valkey-server`
- When running as root (UID 0), the entrypoint `chown`s the working directory to `valkey` user then drops privileges via `setpriv --reuid=valkey --regid=valkey --clear-groups`
- If NOT root and the working directory is not writable, it emits a warning about persistence errors
- Sets umask to `0077` (from default `0022`) for security
- Appends `$VALKEY_EXTRA_FLAGS` env var to the command - useful for injecting flags without modifying the command

**User IDs differ between variants** (gotcha - not in our docs):
- Debian: UID 999, GID 999
- Alpine: UID 999, GID 1000 (because Alpine already has GID 999 in use)
- Our docs say "UID 999 = valkey user in official image" which is correct, but the GID difference matters for volume permissions when switching between variants.

**Build flags in Docker image** (new):
- TLS is always built-in (`BUILD_TLS=yes`)
- Systemd support enabled in Debian variant (`USE_SYSTEMD=yes`), not in Alpine
- `USE_FAST_FLOAT=yes` enabled for versions >= 8.1 and unstable
- jemalloc page size tuning: `--with-lg-page=12` for amd64/i386, `--with-lg-page=16` for arm/ppc64le; `--with-lg-hugepage=21` for all

### Enrichment target
- `docker.md`: add base image info, tag naming convention, UID/GID gotcha, protected-mode note, VALKEY_EXTRA_FLAGS env var, TLS built-in note
- `install.md`: note that Docker images have TLS pre-built

---

## 3. Bitnami Image Details (New Information)

Source: bitnami/containers GitHub README.

**Base OS changed**: Bitnami images are now based on **Photon Linux** (VMware's hardened OS), not Debian. Legacy Debian-based images moved to `bitnamilegacy/` Docker Hub namespace. This is a significant change from what our docs imply.

**Full environment variable catalog** (our docs list only 4; here are all):

Configuration variables:
| Variable | Default | Notes |
|----------|---------|-------|
| `VALKEY_DATA_DIR` | `${VALKEY_VOLUME_DIR}/data` | |
| `VALKEY_OVERRIDES_FILE` | `${VALKEY_MOUNTED_CONF_DIR}/overrides.conf` | Partial config override |
| `VALKEY_DISABLE_COMMANDS` | empty | Comma-separated list |
| `VALKEY_AOF_ENABLED` | `yes` | |
| `VALKEY_RDB_POLICY` | nil | Custom RDB save policy |
| `VALKEY_RDB_POLICY_DISABLED` | `no` | Set to `yes` to disable all RDB |
| `VALKEY_PRIMARY_HOST` | nil | For replicas |
| `VALKEY_PRIMARY_PORT_NUMBER` | `6379` | For replicas |
| `VALKEY_PORT_NUMBER` | `6379` | |
| `VALKEY_ALLOW_REMOTE_CONNECTIONS` | `yes` | |
| `VALKEY_REPLICATION_MODE` | nil | `primary` or `replica` |
| `VALKEY_REPLICA_IP` | nil | Announce IP |
| `VALKEY_REPLICA_PORT` | nil | Announce port |
| `VALKEY_EXTRA_FLAGS` | nil | Additional server args |
| `ALLOW_EMPTY_PASSWORD` | `no` | Required for passwordless |
| `VALKEY_PASSWORD` | nil | `@` not supported in password |
| `VALKEY_PRIMARY_PASSWORD` | nil | |
| `VALKEY_ACLFILE` | nil | Path to ACL file |
| `VALKEY_IO_THREADS_DO_READS` | nil | Enable multi-threaded reads |
| `VALKEY_IO_THREADS` | nil | Number of IO threads |
| `VALKEY_TLS_ENABLED` | `no` | |
| `VALKEY_TLS_PORT_NUMBER` | `6379` | |
| `VALKEY_TLS_CERT_FILE` | nil | |
| `VALKEY_TLS_KEY_FILE` | nil | |
| `VALKEY_TLS_KEY_FILE_PASS` | nil | |
| `VALKEY_TLS_CA_FILE` | nil | |
| `VALKEY_TLS_CA_DIR` | nil | |
| `VALKEY_TLS_DH_PARAMS_FILE` | nil | |
| `VALKEY_TLS_AUTH_CLIENTS` | `yes` | |
| `VALKEY_SENTINEL_PRIMARY_NAME` | nil | |
| `VALKEY_SENTINEL_HOST` | nil | |
| `VALKEY_SENTINEL_PORT_NUMBER` | `26379` | |
| `OPENSSL_FIPS` | `yes` (BSI only) | FIPS mode |

Read-only/internal paths:
| Variable | Value |
|----------|-------|
| `VALKEY_VOLUME_DIR` | `/bitnami/valkey` |
| `VALKEY_BASE_DIR` | `${BITNAMI_ROOT_DIR}/valkey` |
| `VALKEY_CONF_DIR` | `${VALKEY_BASE_DIR}/etc` |
| `VALKEY_MOUNTED_CONF_DIR` | `${VALKEY_BASE_DIR}/mounted-etc` |
| `VALKEY_CONF_FILE` | `${VALKEY_CONF_DIR}/valkey.conf` |
| `VALKEY_LOG_DIR` | `${VALKEY_BASE_DIR}/logs` |
| `VALKEY_BIN_DIR` | `${VALKEY_BASE_DIR}/bin` |
| `VALKEY_DAEMON_USER` | `valkey` |
| `VALKEY_DAEMON_GROUP` | `valkey` |
| `VALKEY_DEFAULT_PORT_NUMBER` | `6379` |

**Gotchas**:
- The `@` character is NOT supported in `VALKEY_PASSWORD` - this is a known limitation
- Remote connections enabled by default (`VALKEY_ALLOW_REMOTE_CONNECTIONS=yes`) - opposite of secure default
- `ALLOW_EMPTY_PASSWORD=yes` is required even for development without auth
- Config override file at `/opt/bitnami/valkey/mounted-etc/overrides.conf` is ignored if a full `valkey.conf` is provided
- Bitnami changed terminology from `master/slave` to `primary/replica` in October 2024 - old `VALKEY_MASTER_*` env vars are gone

**FIPS support**: BSI (Bitnami Secure Images, commercial) includes OpenSSL FIPS mode. Not available in free images.

### Enrichment target
- `docker.md`: update Bitnami section with Photon OS base, full env var table, password `@` gotcha, override file behavior, IO threads env vars

---

## 4. Valkey 9.0 New Features Affecting Operations

Source: valkey.io/blog/introducing-valkey-9/

These are deployment-relevant features new in 9.0 that our docs should reference.

**Atomic Slot Migrations** (major operational improvement):
- Pre-9.0: cluster resharding migrated keys one-by-one, which could cause mini-outages for multi-key operations and block on large keys that exceed the target node's input buffer
- 9.0: entire slots migrate atomically using AOF format. Large collections are streamed item-by-item (not whole-key), preventing buffer overflow. Original node retains all keys until slot migration completes - no redirects/retries during migration
- Operational impact: resharding is now much safer; removes the need to manually increase input buffer limits for large key migrations

**Hash Field Expiration** (new commands):
- `HEXPIRE`, `HEXPIREAT`, `HEXPIRETIME`, `HGETEX`, `HPERSIST`, `HPEXPIRE`, `HPEXPIREAT`, `HPEXPIRETIME`, `HPTTL`, `HSETEX`, `HTTL`
- Enables per-field TTL within hash keys
- ACL implications: these new commands need to be included in ACL rules if using fine-grained permissions

**Numbered Databases in Cluster Mode**:
- Before 9.0: cluster mode was restricted to db 0
- 9.0: full support for `SELECT` and numbered databases in cluster mode
- Migration consideration: existing cluster deployments using db 0 are unaffected; new deployments can now use multiple databases

**Pipeline Memory Prefetch**: up to 40% higher throughput with pipelining

**Cluster scaling to 2,000 nodes**: improved large-cluster resilience, validated at 1 billion requests/second

**Un-deprecation of features**: some previously deprecated features have been restored

### Enrichment target
- `cluster/resharding.md`: add atomic slot migration details for 9.0
- `cluster/setup.md`: add numbered databases support
- `production-checklist.md`: note 9.0 features that change operational behavior
- `upgrades/compatibility.md`: note 9.0 changes

---

## 5. TLS Configuration Details (New)

Source: valkey.io/topics/tls/

**Automatic TLS material reload** (not in our docs):
```
tls-auto-reload-interval 86400
```
- Reloads certs/keys in a background thread at specified interval (seconds)
- Default: 0 (disabled)
- Useful for cert-manager in Kubernetes or Let's Encrypt auto-renewal
- Does not block the main server thread

**TLS material validation** (not in our docs):
- Validates on every load/reload: files not empty/malformed, certs match keys, certs within valid time period
- If validation fails, load is rejected - server continues with previous certs

**Certificate-based user authentication** (not in our docs):
```
tls-auth-clients-user
```
- Extracts a field from client TLS certificate and maps to an ACL user
- If no match found, falls back to default user
- Recommended: configure matched users without passwords (auth exclusively via mTLS)
- Example: `ACL SETUSER client-user on allcommands allkeys`

**Mutual TLS (mTLS)** details:
```
tls-client-cert-file /path/to/client.crt
tls-client-key-file /path/to/client.key
```
- Server can present a client certificate to connecting peers (for replication, cluster bus)

**Sentinel TLS** behavior:
- Sentinel inherits TLS config from common Valkey config
- `tls-replication` directive determines BOTH replication TLS AND whether Sentinel's own port supports TLS
- Sentinel gets `tls-port` if and only if `tls-replication` is enabled

### Enrichment target
- `security/tls.md`: add auto-reload, material validation, cert-based auth, mTLS client config, Sentinel TLS behavior

---

## 6. Latency Diagnosis Details (New)

Source: valkey.io/topics/latency/

**Intrinsic latency measurement** (not in our docs):
```bash
valkey-cli --intrinsic-latency 100
```
- Must run ON THE SERVER, not from client
- Measures kernel/hypervisor scheduling latency baseline
- Argument is seconds to run (100 recommended)
- Saturates a single CPU core during test
- Physical machines: typically 0.1ms
- Virtualized/noisy neighbors: can reach 9-40ms
- This sets the floor for achievable Valkey latency

**Latency measurement from client**:
```bash
valkey-cli --latency -h host -p port
```

**Fork latency details** (enriches our existing fork section):
- Memory divided into 4 KB pages on Linux/AMD64
- A 24 GB Valkey instance requires a 48 MB page table (24 GB / 4 KB * 8 bytes)
- Fork must allocate and copy this page table
- Modern hardware + HW-assisted virtualization: fast
- Older virtualization without HW assist: can be very slow
- Measure via: `BGSAVE` then check `latest_fork_usec` in `INFO`

**Swap detection procedure** (new diagnostic):
```bash
# Get Valkey PID
valkey-cli info | grep process_id

# Check swap usage per memory region
cat /proc/<pid>/smaps | grep 'Swap:'

# Check swap with region sizes
cat /proc/<pid>/smaps | egrep '^(Swap|Size)'
```
- Sporadic 4 KB entries are normal
- Larger swap entries (100+ KB) indicate memory pressure

**Network latency guidelines** (not in our docs):
- 1 Gbit/s network: ~200 us typical latency
- Unix domain socket: ~30 us
- Prefer: physical machine > VM, keep connections long-lived, use Unix socket if co-located
- Prefer: MSET/MGET > pipelining > sequential roundtrips
- Prefer: Lua scripts for operations not suitable for pipelining
- Linux tuning: `taskset`, `cgroups`, `chrt` (real-time priority), `numactl` for latency-sensitive deployments
- Warning: do NOT bind Valkey to a single CPU core - it forks background tasks that are CPU-intensive

**Durability vs latency tradeoff table** (from official docs, useful reference):
1. AOF + fsync always - very slow, maximum durability
2. AOF + fsync every second - good compromise
3. AOF + fsync every second + `no-appendfsync-on-rewrite yes` - reduces disk pressure during rewrites
4. AOF + fsync never - kernel handles fsyncing, minimal disk pressure
5. RDB - wide spectrum depending on save triggers

### Enrichment target
- `performance/latency.md`: add intrinsic latency measurement, fork page table math, swap detection, network latency guidelines, NUMA/cgroup/taskset tips
- `troubleshooting/diagnostics.md`: add swap detection via /proc/smaps

---

## 7. Persistence Edge Cases (New)

Source: valkey.io/topics/persistence/

**Multi-part AOF mechanism** (not in our docs):
- AOF is no longer a single file; it is split into:
  - Base file (at most one) - RDB or AOF format snapshot
  - Incremental files (one or more) - changes since last base
  - Manifest file - tracks all parts
- All files in a directory determined by `appenddirname` config

**AOF backup procedure** (new, important for ops):
1. Disable auto-rewrite: `CONFIG SET auto-aof-rewrite-percentage 0`
2. Verify no rewrite in progress: `INFO persistence` -> `aof_rewrite_in_progress` = 0
3. Copy/tar the `appenddirname` directory
4. Re-enable: `CONFIG SET auto-aof-rewrite-percentage <prev-value>`
- Optimization: create hard links to files, re-enable rewrites immediately, then copy/tar the hard links (Valkey only appends to or atomically replaces files)
- If server restarts during backup: persist config via `CONFIG REWRITE` in step 1

**Live RDB-to-AOF migration** (new procedure):
1. Backup current `dump.rdb`
2. Enable AOF live: `valkey-cli config set appendonly yes`
3. Optionally disable RDB: `valkey-cli config set save ""`
4. CRITICAL: persist config via `CONFIG REWRITE` - forgetting this loses the change on restart
5. Before restart: wait for AOF rewrite to finish (`aof_rewrite_in_progress` = 0, `aof_rewrite_scheduled` = 0, `aof_last_bgrewrite_status` = ok)

**AOF rewrite limiting** (new):
- If AOF rewrite fails repeatedly, Valkey introduces rate-limiting - retries at progressively slower intervals
- Prevents CPU/disk thrashing from repeated failed rewrites

**RDB + AOF interaction** (clarification):
- Valkey prevents concurrent BGSAVE and BGREWRITEAOF - only one background persistence at a time
- If BGREWRITEAOF requested during BGSAVE, it is scheduled to run after BGSAVE completes
- When both enabled, AOF is used for recovery (always more complete)

### Enrichment target
- `persistence/aof.md`: add multi-part AOF structure, backup procedure, rewrite rate limiting
- `persistence/backup-recovery.md`: add AOF backup procedure, live migration steps

---

## 8. Replication Details (New)

Source: valkey.io/topics/replication/

**Diskless replication** (not well covered in our docs):
- `repl-diskless-sync` config parameter
- `repl-diskless-sync-delay` controls delay to batch multiple replica sync requests
- Recommended when: disks are slow but network is fast
- The primary streams RDB directly to replicas over the wire without touching disk

**Partial sync after restart** (important gotcha):
- Replicas store replication state in RDB file when shut down cleanly via `SHUTDOWN`
- This enables partial resync on restart instead of full resync
- NOT possible when using AOF-only persistence
- Workaround: switch to RDB before shutdown, restart, then re-enable AOF

**Replication ID explained** (useful for troubleshooting):
- Each primary has a main replication ID + secondary replication ID
- After failover, promoted replica sets its secondary ID to the old primary's ID
- This enables other replicas to partial-sync with the new primary using the old ID
- The promoted replica then generates a new main ID (new history begins)

**Primary without persistence is dangerous** (critical warning):
- If primary has persistence off + auto-restart enabled, it restarts with empty dataset
- All replicas will sync from the empty primary and destroy their data
- Sentinel does NOT protect against this if the primary restarts before Sentinel detects failure
- Rule: either enable persistence on primary, OR disable auto-restart

**`replica-ignore-maxmemory`** (default behavior not in our docs):
- By default, replicas ignore `maxmemory` - they rely on primary for eviction
- This means replicas can use MORE memory than `maxmemory` (buffers, data structure overhead)
- Can be changed: `replica-ignore-maxmemory no`
- Warning: if replica has writable mode + different maxmemory, ensure all writes are idempotent

**Docker/NAT replication announce** (not in our docs):
```
replica-announce-ip 5.5.5.5
replica-announce-port 1234
```
- Required when using port forwarding or NAT
- Without this, primary's INFO shows container-internal IPs for replicas

### Enrichment target
- `replication/setup.md`: add diskless replication config, partial sync after restart
- `replication/safety.md`: add primary-without-persistence danger, replica-ignore-maxmemory
- `replication/tuning.md`: add announce-ip/port for Docker/NAT

---

## 9. Sentinel Deployment Details (New)

Source: valkey.io/topics/sentinel/

**Never deploy exactly 2 Sentinels** (explicit warning from official docs):
- With 2 Sentinels, if the box running one Sentinel + the primary fails, the remaining single Sentinel cannot authorize failover (needs majority)
- With quorum=1 on 2 Sentinels: dangerous - can create permanent split-brain with two primaries

**Sentinel configuration is auto-rewritten** (important for automation):
- Sentinel modifies its own config file at runtime
- Config file path MUST be writable
- Sentinel refuses to start if config file path is not writable
- Config is rewritten: when replicas are discovered, when failover occurs, when new Sentinels are discovered

**Sentinel and Docker** (expanded from our docs):
- Port remapping breaks Sentinel auto-discovery AND replica discovery
- Sentinel announces its own IP:port via hello messages - remapped ports cause wrong announcements
- Replicas listed in primary's INFO output use container-internal addresses
- Fix: `sentinel announce-ip <ip>` and `sentinel announce-port <port>`
- Alternative: `--net=host` (our docs mention this but not the announce directives)

**DNS/hostname support** (new, not in our docs):
- Available since version 6.2, disabled by default
- Enable: `resolve-hostnames yes` (global config)
- Enable hostname announcements: `announce-hostnames yes`
- Caveats: DNS resolution must be fast and reliable; slow DNS impacts Sentinel
- Use hostnames everywhere or IP addresses everywhere - don't mix
- Useful for TLS where clients need hostname for certificate ASN matching
- Not all Sentinel client libraries support hostnames

**Sentinel runtime reconfiguration**:
- Per-primary: `SENTINEL SET <primary-name> <option> <value>`
- Global: `SENTINEL CONFIG SET <option> <value>`

**Sentinel example 3** (Sentinels on client boxes):
- When only 2 Valkey boxes available (primary + replica), place Sentinels on 3+ client application servers
- Advantage: failover reflects client-side network view
- Disadvantage: no `min-replicas-to-write` protection for split-brain

### Enrichment target
- `sentinel/architecture.md`: add 2-Sentinel anti-pattern, DNS/hostname support
- `sentinel/deployment-runbook.md`: add config file writability requirement, announce directives, Sentinel-on-client-boxes pattern

---

## 10. Cluster Specification Details (New)

Source: valkey.io/topics/cluster-tutorial/, valkey.io/topics/cluster-spec/

**Cluster bus port** (clarification):
- Default: data port + 10000 (e.g., 6379 -> 16379)
- Override with `cluster-port` config directive (not in our docs)
- Both ports must be open in firewall; cluster bus uses binary protocol

**cluster-replica-validity-factor** (not in our docs):
- Default: 0 (replica always considers itself valid for failover)
- If positive: `max_disconnect_time = node_timeout * factor`
- Replica won't failover if disconnected from primary longer than this
- Risk: non-zero value can make cluster unavailable if no valid replica exists after primary failure
- Cluster recovers only when original primary rejoins

**cluster-migration-barrier** (not in our docs):
- Minimum replicas a primary keeps before allowing replica migration to an orphaned primary
- Enables automatic replica rebalancing after failures

**Cluster max size**: specification says "up to 2000 nodes" (not "1000" as sometimes cited). The 16,384 hash slots set the theoretical maximum at 16,384 primary nodes, but the recommended operational limit is ~1,000 nodes.

**Cluster and Docker** (official docs are explicit):
- "Valkey Cluster does not support NATted environments" - must use host networking or announce directives
- `cluster-announce-ip`, `cluster-announce-port`, `cluster-announce-bus-port`

**Numbered databases in cluster** (9.0+):
- `SELECT` works in cluster mode starting with 9.0
- "Some additional restrictions" apply (not fully specified in current docs)

**1 Billion RPS benchmark config** (production-tuned cluster):
```
cluster-enabled yes
cluster-config-file nodes.conf
cluster-require-full-coverage no
cluster-allow-reads-when-down yes
save ""
io-threads 6
maxmemory 50gb
```

### Enrichment target
- `cluster/setup.md`: add cluster-port override, validity-factor, migration-barrier, numbered databases
- `cluster/operations.md`: add 1B RPS benchmark config as reference
- `cluster/resharding.md`: clarify 2000-node operational limit

---

## 11. ACL Details (New)

Source: valkey.io/topics/acl/

**Key permission types** (not in our docs):
- `%R~<pattern>` - read-only access to matching keys
- `%W~<pattern>` - write-only access to matching keys
- `%RW~<pattern>` - alias for `~<pattern>`
- Enables true least-privilege: a consumer can read but not write, a producer can write but not read

**Selector syntax** (not in our docs):
- `(<rule list>)` creates a selector - an alternative permission set
- Selectors evaluated after main user permissions, in order
- If command matches user permissions OR any selector, it is allowed
- `clearselectors` removes all selectors

**SHA-256 password hashes** in ACL files:
- `#<hash>` stores hashed passwords instead of cleartext
- `!<hash>` removes a hashed password
- Only SHA-256 (64 hex chars, lowercase)
- Useful for storing ACLs in version control without exposing passwords

**Channel restrictions**:
- `&<pattern>` for pub/sub channel access
- `allchannels` = `&*`
- `resetchannels` flushes allowed channels AND disconnects pub/sub clients that lose access
- `PSUBSCRIBE` requires literal match (not glob) between its patterns and allowed patterns

**TLS certificate-based user mapping**:
- `tls-auth-clients-user` maps cert fields to ACL users automatically
- No password needed for these users
- Strongest auth model: mTLS + ACL user per service

### Enrichment target
- `security/acl.md`: add key permission types (%R, %W), selectors, SHA-256 hashes, channel restrictions, cert-based auth

---

## 12. EC2/Cloud Deployment (New)

Source: valkey.io/topics/admin/

**EC2 specific advice**:
- Use HVM-based instances, NOT PV (paravirtual) - PV has poor fork() performance
- EBS volumes can have high latency characteristics affecting persistence
- Consider diskless replication (`repl-diskless-sync yes`) to avoid EBS I/O bottleneck
- Modern instances (m3.medium and newer) have adequate fork performance

**Memory sizing for write-heavy workloads** (from official docs, not in our checklist):
- During BGSAVE/BGREWRITEAOF, Valkey can use up to 2x normal memory due to copy-on-write
- The extra memory is proportional to pages modified by writes during the save
- Size memory for 2x peak if running write-heavy with persistence enabled
- When running as cache-only (`save ""`, `appendonly no`), this overhead does not apply

**Diskless replication for EC2**:
- When EBS I/O is slow, diskless replication avoids writing RDB to disk
- Primary streams RDB directly to replica over network
- Especially useful when primaries have persistence disabled

### Enrichment target
- `deployment/bare-metal.md`: add EC2/cloud section with HVM, EBS latency, diskless replication advice
- `production-checklist.md`: add memory 2x sizing rule for write-heavy persistent workloads

---

## 13. Kubernetes Operator (SAP Valkey Operator)

Source: Context7 - sap/valkey-operator.

**CRD example**:
```yaml
apiVersion: cache.cs.sap.com/v1alpha1
kind: Valkey
metadata:
  name: test
spec:
  replicas: 3
  sentinel:
    enabled: true
  metrics:
    enabled: true
  tls:
    enabled: true
```

**Topology spread constraints** (auto-populated):
```yaml
topologySpreadConstraints:
- maxSkew: 1
  nodeAffinityPolicy: Honor
  nodeTaintsPolicy: Honor
  topologyKey: kubernetes.io/hostname
  whenUnsatisfiable: ScheduleAnyway
  matchLabelKeys:
  - controller-revision-hash
```
- Operator auto-populates `labelSelector` if not provided
- Uses `matchLabelKeys: [controller-revision-hash]` for rolling update awareness

**Resource presets vs manual**:
- Operator has `resourcesPreset` for quick sizing
- Manual `resources` block takes precedence
- Separate resource controls for: Valkey, Sentinel, metrics exporter

### Enrichment target
- `kubernetes/operators.md`: add SAP Valkey Operator CRD examples, topology spread, resource config

---

## 14. Upgrade Procedure Without Downtime (New)

Source: valkey.io/topics/admin/

**Standalone upgrade via replication** (step-by-step not in our docs):
1. Start new version as replica of current primary (different port if same server)
2. Wait for initial sync to complete (check replica log)
3. Verify both have same key count via `INFO`
4. Allow writes on replica: `CONFIG SET replica-read-only no`
5. Redirect clients to new instance (use `CLIENT PAUSE` on old primary to prevent writes during switch)
6. Verify old primary has no queries (`MONITOR`)
7. Promote replica: `REPLICAOF NO ONE`
8. Shut down old primary

**Sentinel/Cluster upgrade** (simpler):
1. Upgrade replicas one by one
2. Manual failover to promote an upgraded replica to primary
3. Upgrade the last (demoted) node

**`CONFIG SET`/`CONFIG GET` for runtime changes**:
- Many parameters can be changed at runtime without restart
- Use `CONFIG GET *` to see all modifiable parameters

### Enrichment target
- `upgrades/rolling-upgrade.md`: add standalone replication-based upgrade procedure
- `upgrades/rolling-upgrade.md`: add CLIENT PAUSE during switchover

---

## 15. Kernel Tuning Additions

Source: valkey.io/topics/admin/, valkey.io/topics/latency/

**Additional Linux tuning for low-latency** (not in our docs):
- `taskset` - CPU pinning (but do NOT pin to single core - Valkey forks)
- `cgroups` - resource isolation
- `chrt` - real-time process priority
- `numactl` - NUMA-aware memory allocation
- Consider low-latency kernel for extreme requirements

**Memory sizing reminder from official docs**:
- If you think you have 10 GB free, set `maxmemory` to 8 or 9 GB
- Accounts for: Valkey overhead beyond data, fragmentation, fork COW, client buffers

**`MEMORY DOCTOR` and `LATENCY DOCTOR`**:
- Runtime diagnostic commands
- `LATENCY DOCTOR` requires `latency-monitor-threshold > 0`
- `MEMORY DOCTOR` available without special config

### Enrichment target
- `deployment/bare-metal.md`: add NUMA, cgroup, taskset, chrt tips
- `performance/latency.md`: add MEMORY DOCTOR reference
- `configuration/essentials.md`: add 80-90% maxmemory rule of thumb

---

## 16. Differences Between Valkey and Redis Deployment

Collected across all sources.

| Area | Redis | Valkey |
|------|-------|--------|
| License | SSPL (since Redis 7.4) | BSD 3-Clause |
| Latest stable | Redis 7.4.x | Valkey 9.0.3 |
| Cluster databases | db 0 only | Multiple databases (9.0+) |
| Slot migration | Key-by-key | Atomic slot migration (9.0+) |
| Hash field expiry | Not available | HEXPIRE et al. (9.0+) |
| Config directive | `slaveof` deprecated | `replicaof` (no slave terminology) |
| Auth directive | `masterauth` | `primaryauth` |
| Docker user | UID 999 redis:redis | UID 999 valkey:valkey |
| Docker working dir | `/data` | `/data` (same) |
| Systemd flag | `--supervised systemd` | `--supervised systemd` (same) |
| TLS auto-reload | Not available | `tls-auto-reload-interval` |
| TLS cert-based auth | Not available | `tls-auth-clients-user` |
| Pipeline prefetch | Not available | Built-in (9.0+), 40% throughput gain |
| Protected mode in Docker | Disabled via config | Disabled via source patch |
| Cluster max nodes | ~1000 recommended | ~2000 supported (9.0+) |
| RDMA transport | Not available | `BUILD_RDMA=yes/module` |
| Binary names | `redis-server`, `redis-cli` | `valkey-server`, `valkey-cli` (redis-* symlinks optional) |
| USE_FAST_FLOAT | Not available | Enabled >= 8.1 |

### Enrichment target
- `upgrades/migration.md`: comprehensive Redis-to-Valkey diff table

---

## Summary of Enrichment Priorities

High priority (significant new information):
1. Docker image details - base OS, tag convention, UID/GID, protected-mode patch, VALKEY_EXTRA_FLAGS
2. Bitnami full env var catalog and Photon OS base change
3. Valkey 9.0 operational features - atomic slot migration, hash field expiry, numbered databases in cluster
4. TLS auto-reload and cert-based auth
5. Version matrix with security CVE urgency

Medium priority (useful additions):
6. Latency diagnosis - intrinsic latency, swap detection, fork page table math
7. Multi-part AOF and backup procedure
8. Replication edge cases - diskless, partial sync after restart, announce-ip
9. Sentinel DNS/hostname support, 2-Sentinel anti-pattern
10. Cluster config parameters - cluster-port, validity-factor, migration-barrier

Lower priority (reference material):
11. ACL key permission types, selectors, SHA-256 hashes
12. EC2/cloud-specific advice
13. SAP Valkey Operator CRD
14. Standalone upgrade via replication
15. Redis vs Valkey deployment diff table
