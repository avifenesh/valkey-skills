# ioredis to GLIDE Migration

This application uses ioredis and needs to be migrated to Valkey GLIDE (`@valkey/valkey-glide`).

## Task

Migrate `app.js` from ioredis to GLIDE. The migrated code must:
1. Use `@valkey/valkey-glide` - not ioredis, not node-redis
2. Connect to a Valkey cluster (3 nodes) using GlideClusterClient
3. Preserve all functionality - cache, pub/sub, batch writes, streams
4. Run in Docker (GLIDE native deps require Linux)
5. Pass the same behavioral tests as the original

## Setup

```bash
docker compose up --build
```

The original ioredis version works. Your job is to make the GLIDE version work identically.

## Key Differences to Handle

The ioredis API and GLIDE API differ significantly. Some patterns that work in ioredis will silently fail or throw in GLIDE. You need to know the correct GLIDE equivalents.
