# Pub/Sub (PHP)

Use when wiring publish/subscribe in GLIDE PHP. Assumes familiarity with PHPRedis' `subscribe` / `psubscribe` callback-based model. This doc covers only what GLIDE PHP does differently.

## Divergence from PHPRedis

| | PHPRedis | GLIDE PHP |
|---|---|---|
| `subscribe` channels arg | varargs or array | **array required** |
| `subscribe` callback | `function($r, $ch, $msg)` | same shape |
| `psubscribe` callback | **4 args** `($r, $pat, $ch, $msg)` | **3 args** `($r, $ch, $msg)` - no pattern |
| `unsubscribe()` with no args | all channels | all channels (same) |
| Sharded PubSub (`ssubscribe`) | N/A | **NOT implemented in v1.0.0** |
| Introspection | `pubsub` subcommand | same (`pubsub($cmd, $arg)`) |

## Subscribe and loop - canonical shape

```php
<?php
$subscriber = new ValkeyGlide();
$subscriber->connect(addresses: [['host' => 'localhost', 'port' => 6379]]);

// Channels MUST be in an array. Callback is mandatory. Call blocks until unsubscribe.
$subscriber->subscribe(['news', 'events'], function ($client, $channel, $message) {
    echo "[$channel] $message\n";

    // Break the loop from inside the callback
    if ($message === 'quit') {
        $client->unsubscribe([$channel]);
    }
});

// After unsubscribe from all channels, control returns here
$subscriber->close();
```

The subscribe call is blocking. The callback fires for every message until all channels have been unsubscribed.

## Pattern subscriptions

```php
$subscriber = new ValkeyGlide();
$subscriber->connect(addresses: [['host' => 'localhost', 'port' => 6379]]);

// psubscribe callback gets 3 args - NOT 4 as in PHPRedis. Pattern is not passed.
$subscriber->psubscribe(['news.*', 'events:*'], function ($client, $channel, $message) {
    echo "[$channel] $message\n";
});

$subscriber->close();
```

**PHPRedis silent-bug**: PHPRedis pattern callback signature is `function($r, $pattern, $channel, $message)`. Copying that signature into GLIDE PHP means the third parameter gets `$message` instead of `$channel`, and the fourth is never invoked. Verify callback arity when migrating.

## Publishing

```php
$publisher = new ValkeyGlide();
$publisher->connect(addresses: [['host' => 'localhost', 'port' => 6379]]);

// Standard (channel, message) order. Matches PHPRedis - NOT reversed like Python/Node/Java GLIDE.
$count = $publisher->publish('events', 'Hello subscribers!');

$publisher->close();
```

Return value is the subscriber count that received the message.

## Unsubscribe shapes

```php
$client->unsubscribe(['news']);      // specific channel
$client->unsubscribe();              // null arg - all channels
$client->punsubscribe(['news.*']);   // specific pattern
$client->punsubscribe();             // null arg - all patterns
```

Signature: `unsubscribe(?array $channels = null): bool`. Inside a subscribe callback, calling `unsubscribe` from all channels returns control to the caller of `subscribe()`.

## Introspection (no subscriber mode)

```php
$client = new ValkeyGlide();
$client->connect(addresses: [['host' => 'localhost', 'port' => 6379]]);

// PUBSUB CHANNELS
$channels = $client->pubsub('channels');            // all
$filtered = $client->pubsub('channels', 'news.*');  // by pattern

// PUBSUB NUMSUB
$counts = $client->pubsub('numsub', ['news', 'events']);

// PUBSUB NUMPAT
$patCount = $client->pubsub('numpat');
```

Signature: `pubsub(string $command, mixed $arg = null): mixed`.

## Sharded PubSub - not available

The v1.0.0 stub has `ssubscribe` commented out with a TODO. `sunsubscribe` and `spublish` are also unavailable in this release. Do not design applications around sharded PubSub when using GLIDE PHP v1.0.0.

## Multi-process pattern

PHP's synchronous model means a subscriber process is dedicated to PubSub for its lifetime. Run the subscriber as a long-lived worker (systemd, supervisord, or a PHP CLI loop); keep publishers in short-lived request handlers.

```php
// subscriber_worker.php - run as: php subscriber_worker.php
$client = new ValkeyGlide();
$client->connect(addresses: [['host' => 'localhost', 'port' => 6379]]);
$client->subscribe(['tasks'], function ($c, $channel, $message) {
    // process $message
});
```

## Important notes

1. **Separate clients for pub and sub (occupancy).** A subscribing client is in subscriber mode for the duration of the subscribe call; it cannot issue normal commands from the outer scope. This is occupancy - the same reason blocking commands need dedicated clients - not connection-state leakage like WATCH/MULTI/EXEC.
2. **Automatic resubscribe on reconnect.** The Rust core restores subscriptions after a reconnect automatically.
3. **At-most-once delivery.** Messages published during a reconnect gap are lost. Use Streams for durable delivery.
4. **Callback exceptions** propagate out of `subscribe()` and leave the client in subscriber mode until you explicitly unsubscribe or close.
