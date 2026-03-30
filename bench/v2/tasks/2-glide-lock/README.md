# Order Processor - Distributed Lock Required

This is a multi-threaded order processor that needs a distributed lock to prevent double-processing.

## Task

Implement the `DistributedLock` class using Valkey GLIDE (io.valkey:valkey-glide). See `App.java` for requirements.

## Setup

```bash
docker compose up -d     # Start Valkey
./mvnw compile           # Build
./mvnw exec:java -Dexec.mainClass="com.example.App"  # Run
```

## Requirements

- Use GLIDE APIs only (not Jedis, not Lettuce)
- Lock must auto-expire (TTL)
- Only the lock owner can release (compare-and-delete)
- Retry with backoff on contention
- Must be safe in a cluster environment
