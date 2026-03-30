# Background I/O (BIO) Threads

Use when you need to understand how Valkey offloads blocking operations
(file close, fsync, lazy free) to dedicated background threads.

Source: `src/bio.c`, `src/bio.h`

---

## Design

BIO provides a simple job-queue model with dedicated worker threads. Each job
type is assigned to a specific worker. Multiple job types can share a worker.
Jobs within the same worker are processed in FIFO order.

There is no completion notification mechanism - the submitting code does not
block waiting for the job to finish (with one exception: `bioDrainWorker`
spin-waits until a job type's queue is empty).

---

## Job Types

```c
enum {
    BIO_CLOSE_FILE = 0,  // Deferred close(2) syscall
    BIO_AOF_FSYNC,       // Deferred AOF fsync
    BIO_LAZY_FREE,       // Deferred objects freeing
    BIO_CLOSE_AOF,       // Deferred close for AOF files
    BIO_RDB_SAVE,        // Deferred save RDB to disk on replica
    BIO_TLS_RELOAD,      // Deferred TLS reload
    BIO_NUM_OPS          // = 6
};
```

### Worker Assignment

```c
static unsigned int bio_job_to_worker[] = {
    [BIO_CLOSE_FILE] = 0,
    [BIO_AOF_FSYNC]  = 1,
    [BIO_CLOSE_AOF]  = 1,  // shares worker with AOF_FSYNC
    [BIO_LAZY_FREE]  = 2,
    [BIO_RDB_SAVE]   = 3,
    [BIO_TLS_RELOAD] = 4,
};
```

Five worker threads total. `BIO_AOF_FSYNC` and `BIO_CLOSE_AOF` share worker 1,
ensuring AOF fsync and close operations are serialized (a close always fsyncs
first).

---

## Worker Data Structure

```c
typedef struct {
    const char *const bio_worker_title;
    pthread_t bio_thread_id;
    mutexQueue *bio_jobs;
} bio_worker_data;

static bio_worker_data bio_workers[] = {
    {"bio_close_file"},
    {"bio_aof"},
    {"bio_lazy_free"},
    {"bio_rdb_save"},
    {"bio_tls_reload"},
};
```

Each worker has a `mutexQueue` (a thread-safe queue with mutex+condvar) for
receiving jobs. The queue handles blocking waits when empty.

---

## Job Structure

```c
typedef union bio_job {
    struct { int type; } header;

    struct {
        int type;
        int fd;
        long long offset;
        unsigned need_fsync : 1;
        unsigned need_reclaim_cache : 1;
    } fd_args;

    struct {
        int type;
        lazy_free_fn *free_fn;
        void *free_args[];     // Flexible array member
    } free_args;

    struct {
        int type;
        connection *conn;
        int is_dual_channel;
    } save_to_disk_args;

    struct { int type; } tls_reload_args;
} bio_job;
```

The union allows different job types to carry different payloads while
sharing the type tag at offset 0. Lazy-free jobs use a flexible array member
to carry a variable number of argument pointers.

---

## Initialization

```c
void bioInit(void) {
    pthread_attr_t attr;
    // Ensure stack size >= 4MB
    while (stacksize < VALKEY_THREAD_STACK_SIZE) stacksize *= 2;

    for (bio_worker_data *bwd = bio_workers; bwd != bio_worker_end; ++bwd) {
        bwd->bio_jobs = mutexQueueCreate();
        pthread_create(&bwd->bio_thread_id, &attr,
                       bioProcessBackgroundJobs, bwd);
    }
}
```

Called once during server startup. Each worker thread:
1. Sets its thread title (visible in `ps` / `top`)
2. Applies CPU affinity from `server.bio_cpulist`
3. Blocks `SIGALRM` (watchdog signal is for the main thread only)
4. Enters the processing loop

---

## Job Processing Loop

```c
void *bioProcessBackgroundJobs(void *arg) {
    bio_worker_data *bwd = arg;
    // ...
    while (1) {
        bio_job *job = mutexQueuePop(bwd->bio_jobs, true);  // blocking pop
        int job_type = job->header.type;

        if (job_type == BIO_CLOSE_FILE) {
            if (job->fd_args.need_fsync) valkey_fsync(job->fd_args.fd);
            if (job->fd_args.need_reclaim_cache) reclaimFilePageCache(...);
            close(job->fd_args.fd);
        }
        else if (job_type == BIO_AOF_FSYNC || job_type == BIO_CLOSE_AOF) {
            valkey_fsync(job->fd_args.fd);
            // Update server.aof_bio_fsync_status atomically
            if (job_type == BIO_CLOSE_AOF) close(job->fd_args.fd);
        }
        else if (job_type == BIO_LAZY_FREE) {
            job->free_args.free_fn(job->free_args.free_args);
        }
        else if (job_type == BIO_RDB_SAVE) {
            replicaReceiveRDBFromPrimaryToDisk(...);
        }
        else if (job_type == BIO_TLS_RELOAD) {
            tlsConfigureAsync();
        }

        zfree(job);
        atomic_fetch_sub(&bio_jobs_counter[job_type], 1);
    }
}
```

---

## Job Creation Functions

### bioCreateLazyFreeJob

```c
void bioCreateLazyFreeJob(lazy_free_fn free_fn, int arg_count, ...);
```

Allocates a `bio_job` with extra space for `arg_count` void pointers. The
arguments are packed from the variadic parameter list. Used by `lazyfree.c`
for all async free operations.

### bioCreateCloseJob

```c
void bioCreateCloseJob(int fd, int need_fsync, int need_reclaim_cache);
```

Deferred file close. If `need_fsync` is set, fsyncs before closing. If
`need_reclaim_cache` is set, calls `reclaimFilePageCache()` to advise the OS
to drop the page cache for the file.

### bioCreateFsyncJob

```c
void bioCreateFsyncJob(int fd, long long offset, int need_reclaim_cache);
```

Deferred fsync for AOF. The `offset` is stored in `server.fsynced_reploff_pending`
on successful fsync, allowing the main thread to track fsync progress.

### bioCreateCloseAofJob

```c
void bioCreateCloseAofJob(int fd, long long offset, int need_reclaim_cache);
```

Combined fsync + close for AOF files. Routed to the same worker as
`BIO_AOF_FSYNC` to maintain ordering.

### bioCreateSaveRDBToDiskJob

```c
void bioCreateSaveRDBToDiskJob(connection *conn, int is_dual_channel);
```

Used during dual-channel replication. A dedicated BIO thread receives the
RDB data from the primary connection and writes it to disk.

### bioCreateTlsReloadJob

```c
void bioCreateTlsReloadJob(void);
```

Reloads TLS configuration asynchronously. Only available when built with
`BUILD_TLS=yes`.

---

## Monitoring and Control

### Pending Job Count

```c
unsigned long bioPendingJobsOfType(int type);
```

Returns the number of pending jobs for a given type. Used by `INFO` and
internally to decide when to wait.

### Drain Worker

```c
void bioDrainWorker(int type) {
    while (bioPendingJobsOfType(type) > 0) {
        usleep(100);
    }
}
```

Spin-waits (with 100us sleep) until all jobs of the given type are processed.
Used during shutdown and when synchronous completion is required.

### Kill Threads

```c
void bioKillThreads(void);
```

Cancels and joins all BIO threads. Used on crash (SIGSEGV handler) to stop
background threads before performing memory diagnostics.

### Thread Detection

```c
int inBioThread(void);
```

Returns nonzero if the calling thread is a BIO worker. Uses a thread-local
variable set during worker initialization.

---

## Key Differences from I/O Threads

| Aspect | BIO Threads | I/O Threads |
|--------|-------------|-------------|
| Purpose | OS-level blocking ops | Network read/write/parse |
| Queue type | mutexQueue (mutex+condvar) | Lock-free ring buffer |
| Count | 5 fixed workers | 1 to `IO_THREADS_MAX_NUM`, dynamic |
| Job routing | By job type | By client ID hash |
| When idle | Block on condvar | Spin then park on mutex |

---

## See Also

- [Lazy Freeing](../memory/lazy-free.md) - the primary consumer of the `BIO_LAZY_FREE` worker; submits jobs via `bioCreateLazyFreeJob()`
- [AOF Persistence](../persistence/aof.md) - uses `BIO_AOF_FSYNC` and `BIO_CLOSE_AOF` workers for deferred fsync and close
- [RDB Persistence](../persistence/rdb.md) - the `BIO_RDB_SAVE` worker handles disk I/O during dual-channel replication
- [I/O Threads](../threading/io-threads.md) - network I/O thread pool; contrast with BIO's blocking-operation design
- [TLS](../security/tls.md) - the `BIO_TLS_RELOAD` worker performs async TLS configuration reload
