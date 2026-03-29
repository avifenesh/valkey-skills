# Security

Use when evaluating Valkey's supply chain security, vulnerability disclosure process, enterprise authentication options, or container image provenance.

---

## Supply Chain Security

### verify-provenance GitHub Action

The `valkey-io/verify-provenance` action detects when pull requests contain content highly similar to a designated source repository. Valkey uses it to guard against unattributed code from post-fork Redis (where the license changed).

**How it works** - two-layer detection:

1. **Layer 1 (fast, local)**: SimHash64 fingerprinting plus git patch-id against pre-computed databases. Matches by file path and overall PR content.
2. **Layer 2 (precise, API-based)**: Fetches actual diffs from GitHub API for candidates. Token-based Jaccard and subset similarity filtering removes false positives.

Branding terms (e.g., `Redis` to `Valkey`) and code prefixes (e.g., `RM_` to `VM_`) are automatically normalized before comparison.

**Usage in a workflow**:

```yaml
name: Verify Provenance
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: valkey-io/verify-provenance@v1
        with:
          source_repo: "redis/redis"
          target_repo: "${{ github.repository }}"
          branding_pairs: "Redis:Valkey,KeyDB:Valkey"
          prefix_pairs: "RM_:VM_,REDISMODULE_:VALKEYMODULE_"
          github_token: "${{ secrets.GITHUB_TOKEN }}"
```

**Key inputs**:

| Input | Description | Default |
|-------|-------------|---------|
| `source_repo` | Upstream repo to compare against | Required |
| `target_repo` | Your repository | Required |
| `branding_pairs` | Brand name normalization pairs | - |
| `prefix_pairs` | Code prefix normalization pairs | - |
| `threshold` | Similarity threshold (0.0-1.0) | 0.85 |
| `mode` | `check` (PR analysis) or `refresh` (update DB) | `check` |

Fingerprint databases are stored on an orphan branch (`verify-provenance-db`). Run a weekly scheduled workflow in `mode: refresh` to keep the PR database current.

### OpenSSF Scorecard

Valkey runs the OpenSSF Scorecard analysis weekly and on pushes to `unstable`. Results are uploaded as SARIF to GitHub Code Scanning.

The Scorecard evaluates supply chain practices: branch protection, dependency pinning, signed releases, CI configuration, vulnerability scanning, and more. Valkey's workflow uses pinned action SHAs (not floating tags) throughout its CI - a practice scored favorably by Scorecard.

### CodeQL Analysis

Valkey runs GitHub CodeQL for static analysis, catching security bugs and vulnerabilities in the C codebase automatically on PRs and scheduled scans.

---

## Vulnerability Disclosure

### Process

Valkey follows responsible disclosure coordinated through the `valkey-io/valkey-security` repository.

1. **Report**: Email `security@lists.valkey.io` - do not create public issues
2. **Triage**: The security team creates a GitHub Security Advisory in the affected repository
3. **Embargo**: For High/Critical CVEs, an embargo notification goes to cloud providers and vendors (AWS, Google, Aiven, Tencent, Alibaba, Oracle, Percona, and others) with at least one month lead time
4. **Patch**: Fixes are developed in private repositories branched from the advisory
5. **Release**: Patches are merged and released when the embargo lifts
6. **Publish**: The security advisory is made public

**Vendor notification list** includes: AWS (ElastiCache, MemoryDB), Google (Memorystore), Aiven, Heroku, Tencent, Alibaba, Oracle, Percona, Momento, Ericsson, VMware/Broadcom, AlmaLinux, and Redis Inc.

### Reporting a Vulnerability

Send reports to `security@lists.valkey.io`. To be added to the vendor notification list, contact `maintainers@lists.valkey.io`.

---

## Enterprise Authentication

### valkey-ldap Module

The `valkey-ldap` module adds LDAP-based authentication to Valkey. It intercepts the `AUTH` command and validates credentials against an LDAP directory. Written in Rust.

**Authentication modes**:

| Mode | How It Works | When to Use |
|------|-------------|-------------|
| **bind** | Constructs DN from prefix + username + suffix, binds directly | Simple directory structure where username maps to DN |
| **search+bind** | Binds as service account, searches for user, re-binds as user | Flexible directory structure, Active Directory environments |

**Prerequisites**: Users must exist in Valkey's ACL database before LDAP authentication works. Create users with `resetpass` to prevent password-based login:

```
ACL SETUSER bob on resetpass +@hash
```

This ensures `bob` can only authenticate through LDAP.

**Key configuration**:

| Option | Description |
|--------|-------------|
| `ldap.servers` | Comma-separated LDAP URLs (`ldap[s]://host:port`) |
| `ldap.auth_mode` | `bind` or `search+bind` |
| `ldap.use_starttls` | Upgrade to TLS via StartTLS |
| `ldap.tls_ca_cert_path` | CA certificate for TLS validation |
| `ldap.bind_dn_prefix` / `ldap.bind_dn_suffix` | DN construction for bind mode |
| `ldap.search_base` / `ldap.search_filter` | Search parameters for search+bind mode |
| `ldap.connection_pool_size` | Connections per LDAP server (default: 2) |

Included in the `valkey/valkey-bundle` Docker image. See the [Docker](docker.md) reference for container setup.

---

## ACL and TLS

Valkey provides built-in ACL (Access Control Lists) and TLS support for authentication, authorization, and encrypted transport.

**ACL highlights**:
- Per-user command restrictions, key pattern limits, and channel permissions
- Password-based and passwordless authentication
- The `default` user can be restricted or disabled
- ACL rules persist via `aclfile` or inline configuration

**TLS highlights**:
- Mutual TLS (mTLS) for client and inter-node authentication
- Configurable via `tls-port`, `tls-cert-file`, `tls-key-file`, `tls-ca-cert-file`
- Valkey 9.1 adds automatic TLS certificate reload and SAN URI authentication
- Valkey 9.1 adds TLS certificate expiry tracking - server-side telemetry for
  cert expiry so monitoring systems can alert before certificates expire

For detailed ACL configuration, TLS setup, and hardening guides, see the **valkey-ops** skill (`security/acl.md`, `security/tls.md`, `security/hardening.md`).

---

## Protected Mode and Network Hardening

**Protected mode** (enabled by default) prevents connections from non-loopback interfaces when no password is set. In the Docker image, protected mode is disabled at build time since Docker's network isolation serves the same purpose.

**Network hardening basics**:
- `bind 127.0.0.1 -::1` - default, listens only on loopback
- `requirepass` or ACL users - always set for any exposed deployment
- `rename-command` - obscure dangerous commands (FLUSHALL, CONFIG, DEBUG)
- Firewall rules - restrict port 6379 to known application IPs

For production hardening checklists, see the **valkey-ops** skill (`security/hardening.md`, `production-checklist.md`).

---

## See Also

- [Docker](docker.md) - Container image provenance and hardening
- [Kubernetes](kubernetes.md) - TLS with cert-manager and service mesh mTLS
- [CI/CD](ci-cd.md) - Running provenance checks in CI pipelines
- [Testing Tools](testing.md) - TLS-enabled test containers
- **valkey-ops** skill - Detailed ACL, TLS, and hardening reference
