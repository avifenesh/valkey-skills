I need a `BF.DUMP` command added to valkey-bloom. It should serialize a bloom filter to raw bytes so we can back them up and migrate between instances.

`BF.DUMP key` should:
- Return the serialized bytes of the bloom filter at `key`
- Return nil when the key doesn't exist
- Return WRONGTYPE when the key isn't a bloom filter
- Be readonly

The valkey-bloom source is in `valkey-bloom/`. Look at existing commands to understand the patterns. Add command registration, metadata JSON, handler, and tests. Must compile with `cargo build --release`.
