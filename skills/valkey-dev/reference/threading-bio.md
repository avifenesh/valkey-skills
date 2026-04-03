# Background I/O (BIO) Threads

Use when you need to understand how Valkey offloads blocking operations to dedicated background threads.

Standard BIO job-queue model with 5 worker threads. Job types: `BIO_CLOSE_FILE` (worker 0), `BIO_AOF_FSYNC` + `BIO_CLOSE_AOF` (worker 1, serialized), `BIO_LAZY_FREE` (worker 2), `BIO_RDB_SAVE` (worker 3), `BIO_TLS_RELOAD` (worker 4). Jobs use `mutexQueue` (mutex+condvar), processed FIFO. `bioDrainWorker()` spin-waits for completion.

Source: `src/bio.c`, `src/bio.h`
