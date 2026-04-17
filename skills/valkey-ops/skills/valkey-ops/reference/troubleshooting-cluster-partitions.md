# Cluster Partition Incidents

Use when `cluster_state:fail`, slots are uncovered, or clients get `CLUSTERDOWN`. Redis-baseline runbook (`CLUSTER INFO` fields, `CLUSTER NODES` flags, majority-vote mechanics, odd-number-of-primaries rule, network connectivity checks) applies here; what follows is the Valkey-specific delta.

## Bus port reminder

Cluster gossip runs on `port + 10000`. Both client port (`6379`) **and** bus port (`16379`) must be open between every pair of cluster nodes. A firewall that allows the client port but blocks the bus port produces a failure mode that looks like total partition even though every node is individually healthy - check both:

```sh
for n in node1 node2 node3 node4 node5 node6; do
  echo "=== $n ==="
  nc -zv $n 6379
  nc -zv $n 16379
done
```

## CLUSTER FAILOVER escape hatches

| Mode | Catch-up | Majority vote needed | Use when |
|------|---------|---------------------|----------|
| (default) | yes | yes | Planned - zero data loss |
| `FORCE` | no | yes | Primary unreachable, but the voting majority is alive |
| `TAKEOVER` | no | **no** - replica bumps configEpoch unilaterally | Majority unreachable (e.g., DC with most primaries down) |

`TAKEOVER` is the escape valve during partition incidents. Two sides that later re-merge with overlapping slot ownership is the consequence - only use if a real election is impossible.

## `--cluster fix` and `CLUSTER FORGET`

`valkey-cli --cluster fix <host>:<port>` reassigns uncovered slots, clears orphan `MIGRATING`/`IMPORTING` state left from interrupted migrations, resolves ownership conflicts. Review the proposed plan before confirming.

`CLUSTER FORGET <node-id>` must be sent to **every remaining node within 60 seconds**, or gossip re-adds the forgotten node. Scripting it in a tight loop is the normal pattern:

```sh
for n in node1:6379 node2:6379 node3:6379; do
  valkey-cli -h ${n%:*} -p ${n#*:} CLUSTER FORGET $NODE_ID
done
```

## `cluster-allow-pubsubshard-when-down` default differs

Valkey defaults `cluster-allow-pubsubshard-when-down yes` - shard pub/sub keeps working when the cluster is in FAIL state. Redis-trained operators expect all operations to reject. Disable explicitly if your use case requires fail-closed pub/sub.

## Large-key migration no longer blocks (Valkey 9.0 ASM)

**Pre-9.0 symptom**: a sorted set or hash with millions of members causes slot migration to hang because key-by-key `MIGRATE` exceeds the target's `proto-max-bulk-len` or `client-query-buffer-limit`. Slot stays in `MIGRATING`/`IMPORTING` indefinitely; multi-key commands on that slot fail.

**Pre-9.0 fix**: raise `proto-max-bulk-len` on the target, or delete-and-recreate the key, or force `CLUSTER SETSLOT <slot> NODE <node-id>` with accepted data loss.

**Valkey 9.0+**: atomic slot migration bypasses the problem. Entire slots transfer as a forked RDB stream rather than key-by-key, so a single oversized key no longer blocks the whole migration. See `cluster-resharding.md` for the ASM flow.

## Ranked failover elections (8.1+)

Replicas are ranked by replication offset; the most up-to-date tries first, others delay in proportion to rank. In a multi-primary failure scenario (say, a rack lost) the cluster doesn't collide on simultaneous elections - shards converge in rank order. Logged as `IO threads: vote rank X` in the primary logs during election.

## Reconnection throttling (9.0+)

Before 9.0, a node that lost a peer reconnected every 100 ms until the peer came back - a flapping network link produced reconnect storms that looked like the partition was worse than it was. Valkey 9.0 throttles reconnects within `cluster-node-timeout`. If logs are quieter than pre-9.0 under the same flap, that's expected.

## Post-incident hygiene

- `CLUSTER INFO` → verify `cluster_stats_bytes_*` counters stopped climbing abnormally.
- `CLUSTER SHARDS` → confirm `availability-zone` field is populated if you configured it (otherwise AZ-aware replica placement was silently off during the incident).
- Re-check `cluster-slot-stats-enabled`; it's default-off, and if you were relying on per-slot CPU accounting to root-cause, enable it before the next incident.
