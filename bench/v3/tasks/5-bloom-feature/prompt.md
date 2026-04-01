You have been given the valkey-bloom source code in workspace/valkey-bloom/. This is a Rust module for the Valkey in-memory data store that implements scalable bloom filters.

Your task: Add a new BF.COUNT command that returns the approximate number of items that have been added to a bloom filter. This is the sum of num_items across all sub-filters in the BloomObject.

Note: BF.COUNT is different from BF.CARD. Read the existing source code carefully to understand what BF.CARD returns and how it works before implementing BF.COUNT.

Requirements:

1. Register BF.COUNT as a new command with "readonly fast" flags
2. BF.COUNT takes exactly one argument: the key name (arity 2, same as BF.CARD)
3. Return an integer - the sum of num_items across all sub-filters in the bloom object
4. Return 0 for non-existent keys (key not found)
5. Return WRONGTYPE error for keys that hold a value of the wrong type (e.g., a string key)
6. Add the command to the "bloom" ACL category with "fast read bloom" command tips
7. Write a Rust unit test or integration test for BF.COUNT covering: basic count after adds, count on non-existent key, and count after scaling (adding enough items to trigger a new sub-filter)
8. Create a command metadata file at src/commands/bf.count.json following the same format as the existing command JSON files (e.g., bf.card.json)

Build with: cargo build --release

Work entirely within the workspace/valkey-bloom/ directory. Do not modify Cargo.toml dependencies.
