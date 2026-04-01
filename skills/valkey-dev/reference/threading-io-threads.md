# I/O Threads

Use when you need to understand how Valkey parallelizes network I/O across
multiple threads while keeping command execution single-threaded, or when
tuning I/O thread count for throughput.

Source: `src/io_threads.c`, `src/io_threads.h`

## Contents

- Design Principle (line 23)
- Thread Pool Architecture (line 39)
- Thread Lifecycle (line 77)
- Dynamic Thread Adjustment (line 132)
- Job Dispatch (line 153)
- Synchronization (line 222)
- Configuration (line 252)
- Performance Characteristics (line 264)

---

## Design Principle

Command execution remains single-threaded in the main thread - no locks needed
around data structures. I/O threads handle only:

1. Reading and parsing commands from client sockets
2. Writing responses back to clients
3. Polling for I/O events (`epoll_wait`)
4. Freeing objects (argv arrays, sds strings)
5. Accepting TLS connections

The main thread dispatches I/O jobs to threads and processes the results. A
client's read and write are never handled by different threads simultaneously.

---

## Thread Pool Architecture

```c
static pthread_t io_threads[IO_THREADS_MAX_NUM] = {0};
static pthread_mutex_t io_threads_mutex[IO_THREADS_MAX_NUM];
```

Thread 0 is the main thread. Threads 1 through `io_threads_num - 1` are I/O
workers. Each thread has its own lock-free job queue.

### Job Queue: Lock-Free Ring Buffer

```c
typedef struct IOJobQueue {
    iojob *ring_buffer;
    size_t size;
    _Atomic size_t head __attribute__((aligned(CACHE_LINE_SIZE)));
    _Atomic size_t tail __attribute__((aligned(CACHE_LINE_SIZE)));
} IOJobQueue;
```

The queue is a single-producer (main thread) / single-consumer (I/O thread)
ring buffer. Head and tail are on separate cache lines to avoid false sharing.
Queue size is fixed at 2048 entries.

- **Push (main thread)**: writes data to `ring_buffer[head]`, advances head
  with `memory_order_release`
- **Peek + Remove (I/O thread)**: reads data from `ring_buffer[tail]`,
  processes it, advances tail. A single `memory_order_release` fence is issued
  after processing all available jobs in a batch
- **Empty check (main thread)**: uses `memory_order_relaxed` for both head and
  tail - in the worst case it wrongly sees a non-empty queue and waits

No mutex is needed for the queue itself. Mutexes are only used to park/unpark
threads.

---

## Thread Lifecycle

### Initialization

```c
void initIOThreads(void) {
    server.active_io_threads_num = 1;  // Start with only main thread
    if (server.io_threads_num == 1) return;
    prefetchCommandsBatchInit();
    for (int i = 1; i < server.io_threads_num; i++) {
        createIOThread(i);  // Creates thread in locked (parked) state
    }
}
```

All I/O threads start locked. They are only activated as load demands.

### Main Loop

```c
static void *IOThreadMain(void *myid) {
    // Set thread ID, CPU affinity, init shared query buffer
    while (1) {
        pthread_testcancel();  // Cancellation point
        jobs_to_process = IOJobQueue_availableJobs(jq);
        if (jobs_to_process == 0) {
            // Spin for up to 1M iterations waiting for work
            for (int j = 0; j < 1000000; j++) {
                jobs_to_process = IOJobQueue_availableJobs(jq);
                if (jobs_to_process) break;
            }
        }
        if (jobs_to_process == 0) {
            // Still nothing - park on the mutex
            pthread_mutex_lock(&io_threads_mutex[id]);
            pthread_mutex_unlock(&io_threads_mutex[id]);
            continue;
        }
        // Process all available jobs
        for (size_t j = 0; j < jobs_to_process; j++) {
            IOJobQueue_peek(jq, &handler, &data);
            handler(data);
            IOJobQueue_removeJob(jq);
        }
        atomic_thread_fence(memory_order_release);
    }
}
```

The spin loop before parking avoids the overhead of mutex lock/unlock for
bursty workloads. After spin-waiting fails, the thread parks on its mutex
until the main thread unlocks it.

---

## Dynamic Thread Adjustment

```c
void adjustIOThreadsByEventLoad(int numevents, int increase_only);
```

Called from the event loop to match active thread count to current load:

```c
int target_threads = numevents / server.events_per_io_thread;
target_threads = max(1, min(target_threads, server.io_threads_num));
```

When `events_per_io_thread == 0`, all events are offloaded (used for testing).

Activating a thread: unlock its mutex. Deactivating: lock its mutex (only if
its queue is empty). The `increase_only` flag prevents reducing threads during
a single event loop iteration.

---

## Job Dispatch

### Read Jobs

```c
int trySendReadToIOThreads(client *c);
```

Eligibility checks:
- Active I/O threads > 1
- Client is not a replica, not blocked, not in Lua debug mode
- Client doesn't have `close_asap` flag

Thread selection: `tid = (c->id % (active_io_threads - 1)) + 1`. This gives
deterministic affinity - the same client always maps to the same thread (for a
given thread count), improving cache locality.

If the client has a pending write on a different thread (due to thread count
change), the read is routed to the same thread to prevent concurrent access.

### Write Jobs

```c
int trySendWriteToIOThreads(client *c);
```

Similar eligibility checks. Before pushing the job, the main thread snapshots
`io_last_reply_block` and `io_last_bufpos` to cap how much data the I/O
thread will write. This prevents the I/O thread from reading data that was
appended after the job was dispatched.

### Object Free Jobs

```c
int tryOffloadFreeObjToIOThreads(robj *o);
int tryOffloadFreeArgvToIOThreads(client *c, int argc, robj **argv);
```

Simple string objects and command argv arrays can be freed by I/O threads.
For argv, the main thread decrements refcounts for shared objects and marks
the last object to free by setting its refcount to 0 as a sentinel.

### Poll Offloading

```c
void trySendPollJobToIOThreads(void);
```

When I/O threads have pending work, the `epoll_wait` call is offloaded to the
last active I/O thread. The main thread processes completed I/O jobs while
the poll runs concurrently:

```c
server.io_poll_state = AE_IO_STATE_POLL;
aeSetCustomPollProc(server.el, getIOThreadPollResults);
IOJobQueue_push(jq, IOThreadPoll, server.el);
```

### Accept Offloading (TLS)

```c
int trySendAcceptToIOThreads(connection *conn);
```

TLS handshakes are expensive. When `conn->flags & CONN_FLAG_ALLOW_ACCEPT_OFFLOAD`
is set, the accept operation is offloaded to an I/O thread.

---

## Synchronization

The main thread waits for a specific client's I/O to complete with:

```c
void waitForClientIO(client *c) {
    while (c->io_read_state == CLIENT_PENDING_IO) {
        atomic_thread_fence(memory_order_acquire);
    }
    while (c->io_write_state == CLIENT_PENDING_IO) {
        atomic_thread_fence(memory_order_acquire);
    }
    atomic_thread_fence(memory_order_acquire);
}
```

To drain all threads (e.g. before reconfiguration):

```c
void drainIOThreadsQueue(void) {
    for (int i = 1; i < IO_THREADS_MAX_NUM; i++) {
        while (!IOJobQueue_isEmpty(&io_jobs[i])) {
            atomic_thread_fence(memory_order_acquire);
        }
    }
}
```

---

## Configuration

| Config | Default | Description |
|--------|---------|-------------|
| `io-threads` | 1 | Total threads (including main). Set to N+1 for N I/O workers |
| `events-per-io-thread` | 2 | Events needed per active thread. 0 = always offload |

The old `io-threads-do-reads` config is gone in the current codebase - reads
are always offloaded when I/O threads are enabled.

---

## Performance Characteristics

From the research guide - benchmarked on AWS C7g.16xlarge with 650 clients:

- 8 I/O threads: 1.19M SET RPS (vs 360K single-threaded)
- 230% throughput improvement
- Average latency: 0.542ms (down from 1.792ms, -69.8%)

Key insight: the bottleneck is not CPU compute but memory access latency.
I/O threads parallelize the memory-intensive read/write/parse work, and the
prefetch optimization amortizes cache misses across batched commands.

---
