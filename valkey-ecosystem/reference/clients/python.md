# Python Client Libraries

Use when building Python applications with Valkey, choosing between valkey-py and GLIDE Python, migrating from redis-py, or integrating with Django and Celery.

---

> valkey-py, redis-py compatibility, GLIDE Python, and migration paths.

## valkey-py (Official Valkey Fork)

valkey-py is the official Python client for Valkey, forked from redis-py. It provides a familiar API for anyone who has used redis-py while adding Valkey-native awareness.

### Install

```bash
pip install valkey

# With hiredis C parser for better performance (recommended)
pip install valkey[hiredis]
```

### Version

- **Current**: 6.1.1 (check PyPI for latest)
- **Python**: 3.8+
- **Server**: Valkey 7.2+
- **Downloads**: ~1.14M/week on PyPI (~2.5% of redis-py's ~46M/week)

### Basic Usage

```python
from valkey import Valkey

client = Valkey(host="localhost", port=6379, decode_responses=True)
client.set("key", "value")
result = client.get("key")
```

### Key Features

- Cluster support built in (`valkey.cluster.ValkeyCluster`)
- Sentinel support (`valkey.sentinel.Sentinel`)
- Connection pooling
- Pub/Sub
- Streams
- Pipelines and transactions
- Lua scripting
- SSL/TLS support
- hiredis C parser for performance (optional dependency)
- `HSETEX` command support (Valkey 8+ hash field expiration)
- `max_tries` parameter on `transaction()` for retry control

### Upcoming in 6.2.0 (unreleased draft)

- Added `HSETEX` command support for hash field expiration (Valkey 8+)
- Added `max_tries` parameter to `transaction()` for retry control
- Dropped Python 3.9 and pypy-3.9; added Python 3.14 and pypy-3.11
- Migrated build system from setup.py to pyproject.toml
- Fixed async cluster reinitialization after explicit `aclose()`

### Cluster Mode

```python
from valkey.cluster import ValkeyCluster

cluster = ValkeyCluster(
    host="cluster-node-1",
    port=6379,
    decode_responses=True,
)
cluster.set("key", "value")
```

## redis-py Compatibility

redis-py works with Valkey by changing only the server endpoint. No code changes required.

```python
from redis import Redis

# Just point at Valkey instead of Redis
client = Redis(host="valkey-server", port=6379, decode_responses=True)
```

This works because Valkey speaks the same RESP protocol as Redis OSS. However, redis-py will not expose Valkey-specific features (multi-DB clustering, hash field expiration, `SETIFEQ`/`DELIFEQ`) and long-term compatibility is not guaranteed as the projects diverge. redis-py is tracking Redis 8+ features that diverge from Valkey's roadmap, and async cluster bugs that valkey-py has already fixed (RuntimeError in `NodesManager.initialize`) remain open in redis-py.

## Migration from redis-py to valkey-py

The migration is minimal - primarily an import change.

### Step 1: Install

```bash
pip install valkey[hiredis]
pip uninstall redis  # optional, can coexist
```

### Step 2: Change Imports

```python
# Before
from redis import Redis
from redis.cluster import RedisCluster
from redis.sentinel import Sentinel

# After
from valkey import Valkey
from valkey.cluster import ValkeyCluster
from valkey.sentinel import Sentinel
```

### Compatibility Alias

valkey-py provides a `Redis` class alias for convenience during migration:

```python
# This still works in valkey-py
from valkey import Redis  # alias for Valkey class
client = Redis(host="localhost", port=6379)
```

This means you can switch the package without changing any class names if needed, then rename at your own pace.

### Step 3: Update URL Schemes (if applicable)

```python
# Before
client = Redis.from_url("redis://localhost:6379/0")

# After
client = Valkey.from_url("valkey://localhost:6379/0")
```

### What Does Not Change

- Command names (`SET`, `GET`, `HSET`, etc.) are identical
- Pipeline API is identical
- Pub/Sub API is identical
- Lua scripting API is identical
- Connection pool configuration is identical

## Valkey GLIDE for Python

GLIDE is the official multi-language Valkey client with a Rust core and Python bindings. It provides production-hardened connection management, AZ-affinity routing, and automatic best practices.

```bash
pip install valkey-glide
```

```python
from glide import GlideClient, GlideClientConfiguration, NodeAddress

config = GlideClientConfiguration(
    [NodeAddress("localhost", 6379)]
)
client = await GlideClient.create(config)
await client.set("key", "value")
result = await client.get("key")
```

GLIDE Python is async-first. Version 2.3.0 added sync client support with `bytearray`/`memoryview` arguments, response buffers for reduced memory copies, and OpenTelemetry integration. GLIDE Python gets ~172K downloads/week on PyPI.

For detailed API coverage, connection management, AZ-affinity configuration, and advanced patterns, see the **valkey-glide** skill.

## Framework Integrations

### Django

**django-valkey** provides a cache and session backend for Django:

```bash
pip install django-valkey
```

```python
# settings.py
CACHES = {
    "default": {
        "BACKEND": "django_valkey.cache.ValkeyCache",
        "LOCATION": "valkey://127.0.0.1:6379",
    }
}
```

django-redis also works with Valkey by using a `redis://` URL pointed at the Valkey server.

### Celery

Celery works with Valkey using the `redis://` URL scheme:

```python
app = Celery("tasks", broker="redis://valkey-server:6379/0")
```

Note: switching the scheme to `valkey://` currently breaks celery-beat. Native `valkey://` transport support is not yet available in kombu. Use the `redis://` scheme pointed at your Valkey server.

## Decision Guide

| Scenario | Recommendation |
|----------|---------------|
| New project on Valkey | valkey-py |
| Existing redis-py project, minimal effort | Change endpoint only |
| Existing redis-py project, long-term | Migrate to valkey-py |
| Need AZ-affinity or managed service optimization | GLIDE Python |
| Django project | django-valkey |
| Celery project | redis-py with Valkey endpoint (for now) |

## Cross-References

- `clients/landscape.md` - overall client decision framework
- **valkey-glide** skill - GLIDE Python API details, async patterns, connection management
- `modules/overview.md` - module system; GLIDE Python provides `json` and `ft` classes for JSON and Search modules
- `modules/bloom.md` - Bloom filter commands via `custom_command` in valkey-py or GLIDE
