# BullMQ to glide-mq Migration

Migrate this BullMQ-based job processing application to glide-mq.

## Background

glide-mq is the successor to BullMQ, built for Valkey. It provides the same queue/worker/flow abstractions but with a different connection format, scheduling API, and several breaking changes in options and method signatures.

## What to do

1. Replace `bullmq` with `glide-mq` in package.json (remove `bullmq` and `ioredis` dependencies)
2. Update all imports from `'bullmq'` to `'glide-mq'`
3. Convert the ioredis connection (`new IORedis({ host, port })`) to the glide-mq addresses format (`{ addresses: [{ host, port }] }`)
4. Replace `opts.repeat` with `queue.upsertJobScheduler()` for repeatable jobs
5. Remove `defaultJobOptions` from the Queue constructor - use a wrapper function instead
6. Replace `settings.backoffStrategy` with `backoffStrategies` map on the Worker
7. Update `job.waitUntilFinished(queueEvents, ttl)` to `job.waitUntilFinished(pollMs, timeoutMs)`
8. All tests must pass after migration
9. No BullMQ or ioredis imports should remain in the source

## Documentation

For the most up-to-date glide-mq API documentation, check the repository: https://github.com/avifenesh/glide-mq

The glide-mq npm package also ships embedded skills at `node_modules/glide-mq/skills/` and the online migration guide is at https://avifenesh.github.io/glide-mq.dev/migration/from-bullmq

## Valkey Server

A Valkey server is available on `localhost:6507`.
