package com.example.demo;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class DemoApplicationTests {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Autowired
    private SessionService sessionService;

    @Autowired
    private NotificationService notificationService;

    private String baseUrl;

    @BeforeEach
    void setUp() {
        baseUrl = "http://localhost:" + port;
        notificationService.clearMessages();
    }

    @Test
    void contextLoads() {
        // Verifies the application context starts successfully
    }

    @Test
    void cacheHitAndMiss() {
        // First call - cache miss, should return seeded user
        ResponseEntity<User> first = restTemplate.getForEntity(
                baseUrl + "/users/1", User.class);
        assertThat(first.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(first.getBody()).isNotNull();
        assertThat(first.getBody().getName()).isEqualTo("Alice");

        // Second call - should be cached (same result)
        ResponseEntity<User> second = restTemplate.getForEntity(
                baseUrl + "/users/1", User.class);
        assertThat(second.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(second.getBody()).isNotNull();
        assertThat(second.getBody().getName()).isEqualTo("Alice");
    }

    @Test
    void sessionReadWrite() {
        String sessionId = "test-session-001";
        String userData = "{\"username\":\"testuser\",\"role\":\"admin\"}";

        // Write session
        sessionService.createSession(sessionId, userData);

        // Read session back
        String retrieved = sessionService.getSession(sessionId);
        assertThat(retrieved).isEqualTo(userData);

        // Verify exists
        assertThat(sessionService.sessionExists(sessionId)).isTrue();

        // Delete and verify gone
        sessionService.deleteSession(sessionId);
        assertThat(sessionService.sessionExists(sessionId)).isFalse();
    }

    @Test
    void pubSubDelivery() throws InterruptedException {
        String channel = "notifications";
        String message = "Hello from test";

        // Publish
        notificationService.publish(channel, message);

        // Wait for async delivery
        Thread.sleep(Duration.ofSeconds(2));

        // Verify received
        assertThat(notificationService.getReceivedMessages()).contains(message);
    }

    @Test
    void crudCreateAndRead() {
        User newUser = new User("99", "Charlie", "charlie@example.com");

        // Create
        ResponseEntity<User> created = restTemplate.postForEntity(
                baseUrl + "/users", newUser, User.class);
        assertThat(created.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(created.getBody()).isNotNull();
        assertThat(created.getBody().getName()).isEqualTo("Charlie");

        // Read back
        ResponseEntity<User> fetched = restTemplate.getForEntity(
                baseUrl + "/users/99", User.class);
        assertThat(fetched.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(fetched.getBody()).isNotNull();
        assertThat(fetched.getBody().getEmail()).isEqualTo("charlie@example.com");
    }

    @Test
    void crudUpdateAndDelete() {
        // Update existing seeded user
        User updated = new User("2", "Bob Updated", "bob.updated@example.com");
        ResponseEntity<User> updateResp = restTemplate.exchange(
                baseUrl + "/users/2", HttpMethod.PUT,
                new HttpEntity<>(updated), User.class);
        assertThat(updateResp.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(updateResp.getBody()).isNotNull();
        assertThat(updateResp.getBody().getName()).isEqualTo("Bob Updated");

        // Delete
        ResponseEntity<Void> deleteResp = restTemplate.exchange(
                baseUrl + "/users/2", HttpMethod.DELETE,
                null, Void.class);
        assertThat(deleteResp.getStatusCode()).isEqualTo(HttpStatus.NO_CONTENT);

        // Verify gone
        ResponseEntity<User> gone = restTemplate.getForEntity(
                baseUrl + "/users/2", User.class);
        assertThat(gone.getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND);
    }
}
