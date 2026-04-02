package com.example.demo;

import com.example.demo.service.SessionService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.data.redis.core.RedisTemplate;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

@SpringBootTest
class SessionServiceTest {

    @Autowired
    private SessionService sessionService;

    @Autowired
    private RedisTemplate<String, Object> redisTemplate;

    @BeforeEach
    void setUp() {
        // Clean up test keys before each test
        redisTemplate.delete("session:test-session-1");
        redisTemplate.delete("session:test-session-2");
        redisTemplate.delete("active_sessions");
    }

    @Test
    void testCreateSession() {
        Map<String, Object> data = new HashMap<>();
        data.put("username", "alice");
        data.put("role", "admin");

        sessionService.createSession("test-session-1", data, 30);

        Map<Object, Object> session = sessionService.getSession("test-session-1");
        assertFalse(session.isEmpty());
        assertEquals("alice", session.get("username"));
        assertEquals("admin", session.get("role"));
    }

    @Test
    void testGetSessionReturnsEmptyForMissing() {
        Map<Object, Object> session = sessionService.getSession("nonexistent");
        assertTrue(session.isEmpty());
    }

    @Test
    void testUpdateSessionField() {
        Map<String, Object> data = new HashMap<>();
        data.put("username", "bob");

        sessionService.createSession("test-session-1", data, 30);
        sessionService.updateSessionField("test-session-1", "username", "bob-updated");

        Map<Object, Object> session = sessionService.getSession("test-session-1");
        assertEquals("bob-updated", session.get("username"));
    }

    @Test
    void testDeleteSession() {
        Map<String, Object> data = new HashMap<>();
        data.put("username", "charlie");

        sessionService.createSession("test-session-1", data, 30);
        assertTrue(sessionService.sessionExists("test-session-1"));

        sessionService.deleteSession("test-session-1");
        assertFalse(sessionService.sessionExists("test-session-1"));
    }

    @Test
    void testGetActiveSessions() {
        Map<String, Object> data1 = new HashMap<>();
        data1.put("username", "dave");
        Map<String, Object> data2 = new HashMap<>();
        data2.put("username", "eve");

        sessionService.createSession("test-session-1", data1, 30);
        sessionService.createSession("test-session-2", data2, 30);

        Set<Object> activeSessions = sessionService.getActiveSessions();
        assertNotNull(activeSessions);
        assertTrue(activeSessions.contains("test-session-1"));
        assertTrue(activeSessions.contains("test-session-2"));
    }

    @Test
    void testSessionExists() {
        assertFalse(sessionService.sessionExists("test-session-1"));

        Map<String, Object> data = new HashMap<>();
        data.put("username", "frank");
        sessionService.createSession("test-session-1", data, 30);

        assertTrue(sessionService.sessionExists("test-session-1"));
    }
}
