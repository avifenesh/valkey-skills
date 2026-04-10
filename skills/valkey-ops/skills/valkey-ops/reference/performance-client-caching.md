# Client-Side Caching

Use when reducing read latency with server-assisted client-side cache invalidation via CLIENT TRACKING.

Standard Redis CLIENT TRACKING behavior applies - default mode (key-based), broadcasting mode (prefix-based), OPTIN/OPTOUT, RESP3 push notifications or RESP2 redirect. See Redis docs for full protocol details.

## Valkey Default Value

| Parameter | Default |
|-----------|---------|
| `tracking-table-max-keys` | `1000000` |

The invalidation channel name is `__redis__:invalidate` (legacy prefix retained in Valkey source).

## Valkey-Specific: Cluster Mode

In cluster mode, tracking works per-node - each node tracks only its own keys. Broadcasting mode with empty prefix sends invalidation for every write on that node.

## Key Commands

```bash
CLIENT TRACKING ON                         # default mode
CLIENT TRACKING ON BCAST PREFIX user:      # broadcasting mode
CLIENT TRACKING ON OPTIN                   # explicit opt-in per read
CLIENT TRACKING ON NOLOOP                  # skip self-modification invalidations
CONFIG GET tracking-table-max-keys
valkey-cli INFO stats | grep tracking
```

## When Tracking Table Fills

When `tracking_total_keys` approaches `tracking-table-max-keys`, the server evicts entries and sends phantom invalidation messages. Increase the limit or switch hot-path clients to broadcasting mode.
