package com.example.demo.service;

import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.stereotype.Service;

import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;

@Service
public class SessionService {

    private static final String SESSION_PREFIX = "session:";
    private static final String ACTIVE_SESSIONS_KEY = "active_sessions";

    private final RedisTemplate<String, Object> redisTemplate;

    public SessionService(RedisTemplate<String, Object> redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    /**
     * Create a new session with the given data and TTL.
     */
    public void createSession(String sessionId, Map<String, Object> data, long ttlMinutes) {
        String key = SESSION_PREFIX + sessionId;
        redisTemplate.opsForHash().putAll(key, data);
        redisTemplate.expire(key, ttlMinutes, TimeUnit.MINUTES);
        redisTemplate.opsForSet().add(ACTIVE_SESSIONS_KEY, sessionId);
    }

    /**
     * Retrieve session data by ID.
     */
    public Map<Object, Object> getSession(String sessionId) {
        String key = SESSION_PREFIX + sessionId;
        return redisTemplate.opsForHash().entries(key);
    }

    /**
     * Update a single field in an existing session.
     */
    public void updateSessionField(String sessionId, String field, Object value) {
        String key = SESSION_PREFIX + sessionId;
        redisTemplate.opsForHash().put(key, field, value);
    }

    /**
     * Delete a session and remove it from the active sessions set.
     */
    public void deleteSession(String sessionId) {
        String key = SESSION_PREFIX + sessionId;
        redisTemplate.delete(key);
        redisTemplate.opsForSet().remove(ACTIVE_SESSIONS_KEY, sessionId);
    }

    /**
     * Get all active session IDs.
     */
    public Set<Object> getActiveSessions() {
        return redisTemplate.opsForSet().members(ACTIVE_SESSIONS_KEY);
    }

    /**
     * Check if a session exists.
     */
    public boolean sessionExists(String sessionId) {
        String key = SESSION_PREFIX + sessionId;
        return Boolean.TRUE.equals(redisTemplate.hasKey(key));
    }
}
