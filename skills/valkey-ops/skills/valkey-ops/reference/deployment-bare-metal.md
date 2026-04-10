# Bare Metal Production Setup

Use when deploying Valkey on physical servers or VMs - systemd service, kernel tuning, directory structure.

Standard Redis bare-metal setup applies. Valkey-specific names:

## Binary and Path Names

| Redis | Valkey |
|-------|--------|
| `redis-server` | `valkey-server` |
| `redis-cli` | `valkey-cli` |
| `/etc/redis/` | `/etc/valkey/` |
| `/var/lib/redis/` | `/var/lib/valkey/` |
| `redis` system user | `valkey` system user |

## Systemd Service (Valkey-specific)

```ini
[Unit]
Description=Valkey In-Memory Data Store
After=network-online.target

[Service]
Type=notify
User=valkey
Group=valkey
ExecStart=/usr/bin/valkey-server /etc/valkey/valkey.conf --supervised systemd
ExecStop=/usr/bin/valkey-cli -a $PASSWORD shutdown
Restart=always
LimitNOFILE=65535
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=full
ReadWriteDirectories=/var/lib/valkey /var/log/valkey /var/run/valkey
```

## Kernel Tuning

Standard settings - same as Redis:
- `vm.overcommit_memory = 1` (required for fork/BGSAVE)
- `net.core.somaxconn = 65535`
- Disable THP: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`

Valkey disables THP for its own process by default (`disable-thp yes`) but system-wide is still recommended.

## Multiple Instances

Use systemd template unit `valkey@.service` with per-instance configs at `/etc/valkey/valkey-<port>.conf`.

For EC2: use `repl-diskless-sync yes` with EBS volumes to avoid disk-write latency during replication.
