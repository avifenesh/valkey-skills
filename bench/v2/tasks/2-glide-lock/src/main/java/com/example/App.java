package com.example;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Multi-threaded order processor.
 *
 * Problem: Multiple threads (and potentially multiple instances) process
 * orders from a shared queue. Without distributed locking, the same order
 * can be processed by two threads simultaneously, causing double-charges,
 * duplicate shipments, or inventory inconsistencies.
 *
 * Your task: Implement the DistributedLock class using Valkey GLIDE.
 *
 * Requirements:
 * - Use Valkey GLIDE (io.valkey:valkey-glide), NOT Jedis or Lettuce
 * - TTL-based expiration (lock auto-releases if holder crashes)
 * - Owner identification (only the lock owner can release it)
 * - Retry with exponential backoff
 * - Safe release: compare-and-delete (don't release someone else's lock)
 * - Must work in a Valkey cluster environment
 *
 * A Valkey instance is available at localhost:6379 (via docker-compose.yml).
 */
public class App {

    private static final int THREAD_COUNT = 8;
    private static final int ORDER_COUNT = 50;
    private static final AtomicInteger processedCount = new AtomicInteger(0);
    private static final AtomicInteger duplicateCount = new AtomicInteger(0);

    public static void main(String[] args) throws Exception {
        System.out.println("Starting order processor with " + THREAD_COUNT + " threads");

        ExecutorService executor = Executors.newFixedThreadPool(THREAD_COUNT);

        for (int orderId = 1; orderId <= ORDER_COUNT; orderId++) {
            final int id = orderId;
            executor.submit(() -> processOrder(id));
        }

        executor.shutdown();
        executor.awaitTermination(60, TimeUnit.SECONDS);

        System.out.println("\nResults:");
        System.out.println("  Orders processed: " + processedCount.get());
        System.out.println("  Duplicates prevented: " + duplicateCount.get());
        System.out.println("  Expected: " + ORDER_COUNT + " processed, 0 duplicates");
    }

    private static void processOrder(int orderId) {
        String lockKey = "lock:order:" + orderId;

        // TODO: Acquire distributed lock using Valkey GLIDE
        // DistributedLock lock = new DistributedLock(client, lockKey, 10000);
        // if (lock.acquire()) {
        //     try {
        //         doProcessOrder(orderId);
        //     } finally {
        //         lock.release();
        //     }
        // } else {
        //     duplicateCount.incrementAndGet();
        // }

        // TEMPORARY: process without lock (will cause duplicates)
        doProcessOrder(orderId);
    }

    private static void doProcessOrder(int orderId) {
        try {
            // Simulate work
            Thread.sleep(50 + (long)(Math.random() * 100));
            processedCount.incrementAndGet();
            System.out.println("  [Thread " + Thread.currentThread().getName() + "] Processed order #" + orderId);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
