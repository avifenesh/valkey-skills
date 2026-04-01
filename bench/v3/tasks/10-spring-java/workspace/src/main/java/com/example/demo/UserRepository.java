package com.example.demo;

import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

import org.springframework.stereotype.Repository;

/**
 * Simple in-memory user repository. The caching layer sits in front of this
 * via the UserController, so cache hit/miss behavior is testable by checking
 * whether this repository's methods are actually invoked.
 */
@Repository
public class UserRepository {

    private final Map<String, User> store = new ConcurrentHashMap<>();

    public UserRepository() {
        // Seed data
        store.put("1", new User("1", "Alice", "alice@example.com"));
        store.put("2", new User("2", "Bob", "bob@example.com"));
    }

    public Optional<User> findById(String id) {
        return Optional.ofNullable(store.get(id));
    }

    public User save(User user) {
        store.put(user.getId(), user);
        return user;
    }

    public void deleteById(String id) {
        store.remove(id);
    }

    public boolean existsById(String id) {
        return store.containsKey(id);
    }
}
