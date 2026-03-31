# Product Cache - Code Review

Java product cache service using Valkey GLIDE with multiple anti-patterns.

## Task

Review `src/main/java/com/example/ProductCache.java` and improve it. Focus on Valkey-specific best practices, performance patterns, and production readiness. Explain each change.

The improved code must compile and work.

## Setup

```bash
docker compose up -d
./mvnw compile exec:java -Dexec.mainClass="com.example.ProductCache"
```
