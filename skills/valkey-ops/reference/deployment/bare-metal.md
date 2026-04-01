Use when deploying Valkey on physical servers or VMs without containers - systemd service, kernel tuning, directory structure, and permissions.

# Bare Metal Production Setup

## Contents

- Directory Structure (line 20)
- Systemd Service File (line 41)
- Kernel Tuning (line 84)
- File Descriptor Limits (line 157)
- Permissions and Security (line 181)
- Multiple Instances (line 221)
- EC2 and Cloud VM Considerations (line 267)
- Low-Latency Tuning (NUMA, cgroups) (line 275)
- Health Checks (line 289)
- See Also (line 307)

---

## Directory Structure

```
/etc/valkey/                  # Configuration
  valkey.conf                 # Main config file
/var/lib/valkey/              # Data (RDB, AOF)
/var/log/valkey/              # Logs
/var/run/valkey/              # PID file, unix socket
```

Create the valkey system user and directories:

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin valkey
sudo mkdir -p /etc/valkey /var/lib/valkey /var/log/valkey /var/run/valkey
sudo chown valkey:valkey /var/lib/valkey /var/log/valkey /var/run/valkey
sudo cp valkey.conf /etc/valkey/valkey.conf
sudo chown valkey:valkey /etc/valkey/valkey.conf
```


## Systemd Service File

Create `/etc/systemd/system/valkey.service`:

```ini
[Unit]
Description=Valkey In-Memory Data Store
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=valkey
Group=valkey
ExecStart=/usr/bin/valkey-server /etc/valkey/valkey.conf --supervised systemd
ExecStop=/usr/bin/valkey-cli -a $PASSWORD shutdown
Restart=always
RestartSec=3
LimitNOFILE=65535
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=full
ReadWriteDirectories=/var/lib/valkey /var/log/valkey /var/run/valkey

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now valkey
```

Notes on the service file:
- `Type=notify` requires systemd support in the build (auto-detected by default, or `USE_SYSTEMD=yes`)
- `--supervised systemd` tells Valkey to send readiness notification via sd_notify
- `LimitNOFILE=65535` raises the file descriptor limit for this process
- `ProtectSystem=full` makes `/usr`, `/boot`, `/efi` read-only
- `PrivateDevices=yes` creates a private `/dev` namespace


## Kernel Tuning

These settings are required for production. Without them, Valkey logs warnings on startup and may encounter issues under load.

### vm.overcommit_memory

Valkey forks for BGSAVE and BGREWRITEAOF. Without overcommit, the fork can fail when Valkey uses a significant fraction of RAM, even though copy-on-write means the child rarely needs all that memory.

```
vm.overcommit_memory = 1
```

- `0` (default): Kernel estimates available memory, may refuse fork
- `1`: Always allow overcommit - recommended for Valkey
- `2`: Never overcommit beyond swap + ratio of physical RAM

### net.core.somaxconn

The TCP listen backlog. Valkey's default `tcp-backlog` is 511, but the kernel caps it to `somaxconn`. Set higher than `tcp-backlog`:

```
net.core.somaxconn = 65535
```

### Apply sysctl Settings

Add to `/etc/sysctl.d/99-valkey.conf`:

```
vm.overcommit_memory = 1
net.core.somaxconn = 65535
```

Apply immediately:

```bash
sudo sysctl --system
```

### Transparent Huge Pages (THP)

THP causes latency spikes during fork operations. Valkey disables THP by default at startup (`disable-thp yes` in source, verified in config.c), but only for its own process. Disable system-wide for best results:

```bash
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
```

Make it persistent with a systemd unit:

Create `/etc/systemd/system/disable-thp.service`:

```ini
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=valkey.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now disable-thp
```


## File Descriptor Limits

Valkey needs one file descriptor per client connection, plus internal FDs for persistence, replication, and cluster bus. The default `maxclients` is 10000, so you need at least 10000 + 32 (internal reserve) FDs.

### Per-Service (recommended)

Already handled by `LimitNOFILE=65535` in the systemd unit file above.

### System-Wide Fallback

If not using systemd, edit `/etc/security/limits.conf`:

```
valkey  soft  nofile  65535
valkey  hard  nofile  65535
```

And ensure `/etc/pam.d/common-session` includes:

```
session required pam_limits.so
```


## Permissions and Security

### File Permissions

```bash
# Config file - readable by valkey only
sudo chmod 640 /etc/valkey/valkey.conf

# Data directory - writable by valkey only
sudo chmod 750 /var/lib/valkey

# Log directory
sudo chmod 750 /var/log/valkey
```

### Config File Settings

Essential security-related config for bare metal:

```
# Bind to specific interfaces (not 0.0.0.0)
bind 127.0.0.1 -::1

# Require authentication
requirepass your_strong_password_here

# Enable protected mode (blocks external access without auth)
protected-mode yes

# Set data directory
dir /var/lib/valkey

# Set log file
logfile /var/log/valkey/valkey.log

# Set PID file
pidfile /var/run/valkey/valkey.pid
```


## Multiple Instances

To run multiple Valkey instances on one server, create separate service files and directories per instance:

```bash
# Instance on port 6380
sudo mkdir -p /var/lib/valkey-6380 /var/log/valkey-6380 /var/run/valkey-6380
sudo chown valkey:valkey /var/lib/valkey-6380 /var/log/valkey-6380 /var/run/valkey-6380
sudo cp /etc/valkey/valkey.conf /etc/valkey/valkey-6380.conf
```

Edit `/etc/valkey/valkey-6380.conf`:

```
port 6380
pidfile /var/run/valkey-6380/valkey.pid
logfile /var/log/valkey-6380/valkey.log
dir /var/lib/valkey-6380
```

Create `/etc/systemd/system/valkey@.service` (template unit):

```ini
[Unit]
Description=Valkey Instance %i
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=valkey
Group=valkey
ExecStart=/usr/bin/valkey-server /etc/valkey/valkey-%i.conf --supervised systemd
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now valkey@6380
```


## EC2 and Cloud VM Considerations

- Use **HVM-based instances**, not PV (paravirtual) - PV has poor fork() performance
- EBS volumes can have high latency - consider `repl-diskless-sync yes` for replication
- Write-heavy workloads with persistence: fork COW can use up to 2x memory. Size `maxmemory` to at most 50% of available RAM. Cache-only deployments (`save ""`, `appendonly no`) skip this.
- Modern instances (m3.medium and newer) have adequate fork performance


## Low-Latency Tuning (NUMA, cgroups)

On dedicated hosts, use OS-level tools for latency isolation:

- `numactl --membind=0 --cpunodebind=0 valkey-server ...` - bind to a single NUMA node to avoid cross-node memory access
- `cgroups` - isolate Valkey from other processes for predictable CPU and memory
- `chrt -r 99 valkey-server ...` - set real-time process priority (use with caution)
- `taskset` - CPU pinning, but do NOT pin to a single core. Valkey forks background tasks (BGSAVE, AOF rewrite) that are CPU-intensive and need their own cores.

## Health Checks

```bash
# Basic connectivity
valkey-cli ping

# Memory info
valkey-cli INFO memory | grep used_memory_human

# Persistence status
valkey-cli INFO persistence | grep -E 'rdb_last_bgsave_status|aof_last_bgrewrite_status'

# Connected clients
valkey-cli INFO clients | grep connected_clients
```
