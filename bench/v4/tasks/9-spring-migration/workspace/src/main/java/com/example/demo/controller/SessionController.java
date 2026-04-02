package com.example.demo.controller;

import com.example.demo.service.SessionService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.Set;

@RestController
@RequestMapping("/api/sessions")
public class SessionController {

    private final SessionService sessionService;

    public SessionController(SessionService sessionService) {
        this.sessionService = sessionService;
    }

    @PostMapping("/{sessionId}")
    public ResponseEntity<String> createSession(
            @PathVariable String sessionId,
            @RequestBody Map<String, Object> data) {
        sessionService.createSession(sessionId, data, 30);
        return ResponseEntity.ok("Session created");
    }

    @GetMapping("/{sessionId}")
    public ResponseEntity<Map<Object, Object>> getSession(@PathVariable String sessionId) {
        Map<Object, Object> session = sessionService.getSession(sessionId);
        if (session.isEmpty()) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.ok(session);
    }

    @PutMapping("/{sessionId}")
    public ResponseEntity<String> updateSession(
            @PathVariable String sessionId,
            @RequestBody Map<String, Object> data) {
        data.forEach((field, value) ->
                sessionService.updateSessionField(sessionId, field, value));
        return ResponseEntity.ok("Session updated");
    }

    @DeleteMapping("/{sessionId}")
    public ResponseEntity<String> deleteSession(@PathVariable String sessionId) {
        sessionService.deleteSession(sessionId);
        return ResponseEntity.ok("Session deleted");
    }

    @GetMapping
    public ResponseEntity<Set<Object>> getActiveSessions() {
        return ResponseEntity.ok(sessionService.getActiveSessions());
    }
}
