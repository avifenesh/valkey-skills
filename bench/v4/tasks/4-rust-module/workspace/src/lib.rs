use std::collections::HashMap;
use valkey_module::*;
use valkey_module::alloc::ValkeyAlloc;

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------

/// A single entry in the top-K tracker.
#[derive(Debug, Clone)]
struct TopKEntry {
    item: String,
    count: u64,
}

/// HashMap-based store that tracks item frequencies.
#[derive(Debug)]
struct TopKStore {
    items: HashMap<String, u64>,
}

impl TopKStore {
    fn new() -> Self {
        TopKStore {
            items: HashMap::new(),
        }
    }

    /// Increment the count for `item` by `increment` and return the new count.
    fn add(&mut self, item: &str, increment: u64) -> u64 {
        let count = self.items.entry(item.to_string()).or_insert(0);
        *count += increment;
        *count
    }

    /// Return the top `n` entries sorted by count descending.
    /// If `n` is 0, return all entries.
    fn top(&self, n: usize) -> Vec<TopKEntry> {
        let mut entries: Vec<TopKEntry> = self
            .items
            .iter()
            .map(|(item, &count)| TopKEntry {
                item: item.clone(),
                count,
            })
            .collect();
        entries.sort_by(|a, b| b.count.cmp(&a.count));
        if n > 0 && n < entries.len() {
            entries.truncate(n);
        }
        entries
    }

    /// Return the count for a specific item, or 0 if not tracked.
    fn count(&self, item: &str) -> u64 {
        self.items.get(item).copied().unwrap_or(0)
    }

    /// Clear all tracked items.
    fn reset(&mut self) {
        self.items.clear();
    }
}

// ---------------------------------------------------------------------------
// ValkeyType definition for custom data type persistence
// ---------------------------------------------------------------------------

// TODO: Define the static ValkeyType for TopKStore.
//
// The type name must be exactly 9 characters (Valkey requirement).
// Use ValkeyType::new() with the appropriate name, RDB version,
// and provide SaveRdbFunc / LoadRdbFunc callbacks so data survives
// BGSAVE and server restart.
//
// Example pattern:
//   static MY_TYPE: ValkeyType = ValkeyType::new(
//       "mytype-ab",
//       0,
//       raw::ValkeyModuleTypeMethods { ... }
//   );

// TODO: Implement RDB save callback.
// Save the number of entries first, then each item string and its count.
// Use rdb.save_string_buffer() for strings and rdb.save_unsigned() for counts.

// TODO: Implement RDB load callback.
// Load the entry count, then loop to load each item string and count.
// Reconstruct a TopKStore from the loaded data.

// TODO: Implement free callback.
// Drop the boxed TopKStore value.

// ---------------------------------------------------------------------------
// Command handlers
// ---------------------------------------------------------------------------

// TODO: Implement topk_add_cmd handler.
// Usage: TOPK.ADD key item [increment]
// Open the key writable, get or create a TopKStore, call store.add(),
// return the new count as an integer.
// Must call ctx.replicate_verbatim() for replication/AOF.

// TODO: Implement topk_list_cmd handler.
// Usage: TOPK.LIST key [count]
// Open the key read-only, get the TopKStore, call store.top(),
// return an array of alternating item-name, count pairs.

// TODO: Implement topk_count_cmd handler.
// Usage: TOPK.COUNT key item
// Open the key read-only, get the TopKStore, call store.count(),
// return the count as an integer (0 if not found or key missing).

// TODO: Implement topk_reset_cmd handler.
// Usage: TOPK.RESET key
// Open the key writable, get the TopKStore, call store.reset(),
// return OK.
// Must call ctx.replicate_verbatim() for replication/AOF.

// ---------------------------------------------------------------------------
// Module registration
// ---------------------------------------------------------------------------

valkey_module! {
    name: "topk",
    version: 1,
    allocator: (ValkeyAlloc, ValkeyAlloc),
    data_types: [],
    commands: [],
}
