package com.example;

import glide.api.GlideClient;
import glide.api.models.configuration.GlideClientConfiguration;
import glide.api.models.configuration.NodeAddress;

import java.util.*;
import java.util.concurrent.*;
import java.util.stream.Collectors;

/**
 * Product cache service using Valkey GLIDE.
 *
 * This code works but has multiple anti-patterns. Review and improve it.
 * Focus on Valkey-specific best practices, performance, and production readiness.
 */
public class ProductCache {

    private GlideClient client;

    public ProductCache() throws Exception {
        // Anti-pattern 1: No connection error handling, no reconnect config
        client = GlideClient.createClient(
            GlideClientConfiguration.builder()
                .address(NodeAddress.builder().host("localhost").port(6379).build())
                .build()
        ).get();
    }

    // Anti-pattern 2: DEL instead of UNLINK (blocking delete)
    public void deleteProduct(String id) throws Exception {
        client.del(new String[]{"product:" + id}).get();
    }

    // Anti-pattern 3: Individual GETs instead of MGET
    public List<String> getProducts(List<String> ids) throws Exception {
        List<String> results = new ArrayList<>();
        for (String id : ids) {
            String value = client.get("product:" + id).get();
            if (value != null) {
                results.add(value);
            }
        }
        return results;
    }

    // Anti-pattern 4: No pipeline/batch for bulk writes
    public void saveProducts(Map<String, String> products) throws Exception {
        for (Map.Entry<String, String> entry : products.entrySet()) {
            client.set("product:" + entry.getKey(), entry.getValue()).get();
        }
    }

    // Anti-pattern 5: KEYS pattern in production
    public List<String> getAllProductKeys() throws Exception {
        Object result = client.customCommand(new String[]{"KEYS", "product:*"}).get();
        if (result instanceof Object[]) {
            return Arrays.stream((Object[]) result)
                .map(Object::toString)
                .collect(Collectors.toList());
        }
        return Collections.emptyList();
    }

    // Anti-pattern 6: SET without TTL for cache entries
    public void cacheProduct(String id, String json) throws Exception {
        client.set("cache:product:" + id, json).get();
    }

    // Anti-pattern 7: No expiry on session data
    public void saveSession(String sessionId, String data) throws Exception {
        client.set("session:" + sessionId, data).get();
    }

    // Anti-pattern 8: Blocking SORT on potentially large dataset
    public List<String> getLeaderboard() throws Exception {
        Object result = client.customCommand(new String[]{"SORT", "leaderboard", "DESC", "LIMIT", "0", "100"}).get();
        if (result instanceof Object[]) {
            return Arrays.stream((Object[]) result)
                .map(Object::toString)
                .collect(Collectors.toList());
        }
        return Collections.emptyList();
    }

    // Anti-pattern 9: Scanning all keys to count by pattern
    public long countProductsByCategory(String category) throws Exception {
        List<String> allKeys = getAllProductKeys();
        long count = 0;
        for (String key : allKeys) {
            String value = client.get(key).get();
            if (value != null && value.contains("\"category\":\"" + category + "\"")) {
                count++;
            }
        }
        return count;
    }

    public void close() throws Exception {
        client.close();
    }

    public static void main(String[] args) throws Exception {
        ProductCache cache = new ProductCache();

        // Demo usage
        cache.cacheProduct("1", "{\"name\":\"Widget\",\"price\":9.99,\"category\":\"tools\"}");
        cache.saveSession("abc123", "{\"user\":\"alice\"}");

        Map<String, String> bulk = new HashMap<>();
        for (int i = 1; i <= 100; i++) {
            bulk.put(String.valueOf(i), "{\"name\":\"Product " + i + "\",\"price\":" + (i * 1.5) + "}");
        }
        cache.saveProducts(bulk);

        List<String> ids = new ArrayList<>();
        for (int i = 1; i <= 20; i++) ids.add(String.valueOf(i));
        List<String> products = cache.getProducts(ids);
        System.out.println("Fetched " + products.size() + " products");

        List<String> keys = cache.getAllProductKeys();
        System.out.println("Total keys: " + keys.size());

        cache.close();
    }
}
