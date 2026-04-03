# Keyspace Notifications

Use when working on event-driven features that react to key changes, or when debugging why notifications are or are not firing.

Standard keyspace notifications, same as Redis. No Valkey-specific changes.

Source: `src/notify.c` (~160 lines). Publishes to `__keyspace@<db>__:<key>` and `__keyevent@<db>__:<event>` channels via global pub/sub. Controlled by `notify-keyspace-events` bitmask. Module notifications (`moduleNotifyKeyspaceEvent`) always fire regardless of config.
