# Pub/Sub (PHP)

Use when implementing real-time message broadcasting in PHP - event distribution, notifications, or inter-process messaging. For durable message processing with consumer groups, use Streams instead.

GLIDE PHP supports PubSub with blocking subscribe, callback-based message delivery, and automatic reconnection with resubscription. The API is synchronous, matching PHP's execution model.

## Subscription Modes

| Mode | Subscribe | Unsubscribe | Cluster Only |
|------|-----------|-------------|--------------|
| Exact | `subscribe()` | `unsubscribe()` | No |
| Pattern | `psubscribe()` | `punsubscribe()` | No |

Sharded PubSub (`ssubscribe`/`sunsubscribe`) availability depends on cluster client implementation status.

## Subscribe and Receive

PHP's PubSub operates as a blocking loop. When a client subscribes, it enters subscriber mode and can only execute subscribe/unsubscribe commands until it unsubscribes from all channels.

```php
<?php
// Subscriber process
$subscriber = new ValkeyGlide();
$subscriber->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]]
);

// Subscribe - enters subscriber mode
$subscriber->subscribe('news', 'events');

// In subscriber mode, messages arrive via the callback mechanism
// The client processes messages until unsubscribed
$subscriber->unsubscribe('news', 'events');
$subscriber->close();
```

## Publishing

Use a separate client for publishing:

```php
$publisher = new ValkeyGlide();
$publisher->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]]
);

// Returns number of subscribers that received the message
$count = $publisher->publish('events', 'Hello subscribers!');
echo "Delivered to {$count} subscribers\n";

$publisher->close();
```

## Pattern Subscriptions

```php
$subscriber = new ValkeyGlide();
$subscriber->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]]
);

// Subscribe to patterns using glob syntax
$subscriber->psubscribe('news.*', 'events:*');

// Later, unsubscribe
$subscriber->punsubscribe('news.*', 'events:*');
$subscriber->close();
```

## PubSub Introspection

Query active channels and subscriber counts without entering subscriber mode:

```php
$client = new ValkeyGlide();
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]]
);

// List active channels
$channels = $client->pubsub('channels');
// => ["news", "events"]

// Filter by pattern
$channels = $client->pubsub('channels', 'news.*');

// Subscriber counts
$counts = $client->pubsub('numsub', 'news', 'events');
// => ["news", 5, "events", 3]

// Pattern count
$patCount = $client->pubsub('numpat');
// => 2
```

## Message Callback Structure

Messages arrive via a callback registered at the C extension level. Each message includes:

| Field | Type | Description |
|-------|------|-------------|
| `channel` | string | Channel the message was published to |
| `message` | string | The published payload |
| `pattern` | string/null | Matching pattern (pattern subscriptions only) |
| `kind` | int | Message kind (exact, pattern, sharded) |

## Multi-Process Pattern

PHP's synchronous nature means PubSub subscribers typically run in a dedicated process:

```php
<?php
// subscriber_worker.php - run as: php subscriber_worker.php

$client = new ValkeyGlide();
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]]
);

$client->subscribe('tasks', 'notifications');

// Process runs until killed or unsubscribed
// Messages are delivered via the extension's callback mechanism
```

```php
<?php
// publisher.php - your web application or CLI
$client = new ValkeyGlide();
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]]
);

$client->publish('tasks', json_encode(['action' => 'process', 'id' => 42]));
$client->close();
```

## Important Notes

1. **Separate clients for pub and sub.** A subscribing client enters a special mode where regular commands are unavailable.
2. **Blocking API.** PHP PubSub is synchronous - the subscriber process blocks while waiting for messages.
3. **Automatic reconnection.** On disconnect, GLIDE resubscribes to all channels automatically via the Rust core.
4. **Message loss during reconnect.** PubSub is at-most-once delivery. Use Streams for durability.
5. **Dedicated process.** Subscribers typically run as long-lived worker processes, not within web request handlers.
