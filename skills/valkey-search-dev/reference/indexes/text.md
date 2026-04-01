# Full-Text Search Index

Use when working on full-text search, the prefix/suffix Rax tree, postings lists, stemming, proximity/phrase matching, the tokenization pipeline, or fuzzy matching.

Source: `src/indexes/text.h`, `src/indexes/text.cc`, `src/indexes/text/` directory

## Contents

- [Architecture Overview](#architecture-overview)
- [TextIndexSchema and Per-Field Text](#textindexschema-and-per-field-text)
- [Rax Prefix Tree](#rax-prefix-tree)
- [Optional Suffix Tree](#optional-suffix-tree)
- [Stem Tree](#stem-tree)
- [Postings Lists with Position Maps](#postings-lists-with-position-maps)
- [Proximity and Phrase Matching](#proximity-and-phrase-matching)
- [Lexer Pipeline](#lexer-pipeline)
- [Fuzzy Matching](#fuzzy-matching)
- [Record Lifecycle](#record-lifecycle)
- [Concurrency Model](#concurrency-model)

## Architecture Overview

Full-text search has a two-level architecture:

1. **TextIndexSchema** (`text_index.h`) - schema-level shared state. One per `FT.CREATE` index. Owns the main Rax trees (prefix, suffix, stem), the lexer, per-key text indexes, and staging areas for in-progress mutations.

2. **Text** (`text.h`) - per-field index. One per TEXT attribute in the schema. Holds field-specific settings (`weight`, `no_stem`, `with_suffix_trie`) and a `text_field_number_` used as a bit position in field masks. Delegates indexing to the shared `TextIndexSchema`.

This separation exists because full-text search is inherently cross-field - a single Rax tree indexes words from all text fields, with field masks distinguishing which fields contain each word.

## TextIndexSchema and Per-Field Text

```cpp
class TextIndexSchema {
  std::shared_ptr<TextIndex> text_index_;    // main prefix + optional suffix tree
  Rax stem_tree_;                            // stem root -> parent words
  Lexer lexer_;                              // stateless tokenizer
  TextIndexMetadata metadata_;               // FT.INFO counters + memory pools
  absl::node_hash_map<Key, TextIndex> per_key_text_indexes_;  // per-key reverse index
  absl::node_hash_map<Key, TokenPositions> in_progress_key_updates_;  // staging
  absl::node_hash_map<Key, InProgressStemMap> in_progress_stem_mappings_;
  RaxTargetMutexPool rax_target_mutex_pool_; // per-word bucket locks
  uint8_t num_text_fields_ = 0;             // max 64 fields (field mask is uint64_t)
  bool with_offsets_;                        // store position offsets for phrase queries
  uint32_t min_stem_size_;                   // minimum word length for stemming
  uint64_t stem_text_field_mask_ = 0;        // bitmask of fields with stemming enabled
};
```

Each Text attribute registers itself via `AllocateTextFieldNumber()`, receiving a unique bit position. If the field has `with_suffix_trie_` enabled, it calls `TextIndexSchema::EnableSuffix()` which recreates the shared `TextIndex` with suffix support.

The `FieldMask` struct (`posting.h`) is a 16-byte struct (enforced by `static_assert`) that stores field presence as a 64-bit bitmask:

```cpp
struct FieldMask {
  uint64_t mask_{0};
  uint8_t num_fields_{0};
  void SetField(size_t field_index);
  uint64_t GetMask() const;
};
```

`FieldMaskPredicate` is a `uint64_t` type alias used for field-level filtering during queries.

Per-field configuration (stored in `Text` class):
- `weight_` - relevance weight for scoring (default 1.0)
- `no_stem_` - disables stemming for this field
- `with_suffix_trie_` - enables suffix/contains queries for this field

The `Text` class also maintains `tracked_keys_` and `untracked_keys_` (`InternedStringSet`) for per-field tracking - currently used mainly for `FT.INFO` metrics.

## Rax Prefix Tree

The primary data structure maps words to `Postings` objects. The `Rax` wrapper (`rax_wrapper.h`) encapsulates the C `rax` library from Valkey's core, providing C++ iterator APIs.

```cpp
class TextIndex {
  Rax prefix_tree_;                          // word -> Postings (always present)
  std::unique_ptr<Rax> suffix_tree_;         // reversed_word -> Postings (optional)
};
```

The prefix tree is a memory-efficient radix tree with path compression. Key APIs:

- `GetWordIterator(prefix)` - iterates all words with the given prefix in lexical order, returning `Postings` targets. Used for prefix search (`hello*`) and exact term lookup.
- `MutateTarget(word, fn, op)` - applies a mutation function to a word's target, with optional `item_count_op` for subtree count tracking
- `GetSubtreeItemCount(prefix)` - O(prefix_length) count of entries under a prefix, used for query planning (only tracked when `track_subtree_item_counts_` is enabled - happens when the schema has a HNSW field)

Words are stored lowercase. The Rax wraps the same `rax` C structure used in Valkey's core but with a C++ ownership model using `InvasivePtr<Postings>` for reference-counted targets.

The `RadixTree<Target>` template (`radix_tree.h`) is an alternative pure-C++ implementation available but the production code uses the Rax wrapper for its memory efficiency.

## Optional Suffix Tree

When any TEXT field has `WITHSUFFIXTRIE` enabled, `EnableSuffix()` recreates the `TextIndex` with a second Rax tree that stores reversed words:

```cpp
TextIndex::TextIndex(bool suffix)
    : prefix_tree_(FreePostingsCallback),
      suffix_tree_(suffix ? std::make_unique<Rax>(FreePostingsCallback)
                          : nullptr) {}
```

Both trees point to the same `Postings` objects - `TextIndex::MutateTarget()` updates both atomically:

```cpp
void TextIndex::MutateTarget(absl::string_view word,
                             const InvasivePtr<Postings>& target,
                             const std::optional<std::string>& reverse_word,
                             item_count_op op) {
  auto target_set_fn = CreateTargetSetFn(target);
  prefix_tree_.MutateTarget(word, target_set_fn, op);
  if (suffix_tree_ && reverse_word.has_value()) {
    suffix_tree_->MutateTarget(*reverse_word, target_set_fn, op);
  }
}
```

Suffix search (`SuffixPredicate::BuildTextIterator`) reverses the query string and does a prefix search on the suffix tree. For example, searching for `*tion` reverses to `noit` and prefix-matches in the suffix tree.

## Stem Tree

The stem tree maps stemmed forms to their original words, enabling stem-aware search:

```cpp
// Rax stem_tree_: stemmed_word -> StemParents (vector<string>)
// Example: "happi" -> {"happy", "happiness", "happily"}
```

During indexing (`CommitKeyData`), stem mappings collected in `in_progress_stem_mappings_` by the lexer's `UpdateStemMap()` are committed to the stem tree under `stem_tree_mutex_`.

During search (`GetAllStemVariants`), a query term is stemmed and the stem tree is consulted:

```cpp
std::string stemmed(search_term);
lexer_.StemWordInPlace(stemmed, lexer_.GetStemmer(), min_stem_size_);
auto stem_iter = stem_tree_.GetWordIterator(stemmed);
// If exact match found, collect all parent words
if (!stem_iter.Done() && stem_iter.GetWord() == stemmed) {
  for (const auto& parent : *parents_ptr) {
    words_to_search.push_back(parent);
  }
}
```

This enables queries for "happy" to also match documents containing "happiness" or "happily", since they all share the stem "happi". Stem expansion uses `stem_text_field_mask_` to only expand stems for fields that have stemming enabled.

## Postings Lists with Position Maps

`Postings` (`posting.h`) is the inverted index entry for a single word. It maps keys to their position/field information:

```cpp
struct Postings {
  absl::btree_map<Key, FlatPositionMap*> key_to_positions_;
  void InsertKey(const Key& key, FlatPositionMap* flat_map);
  void RemoveKey(const Key& key, TextIndexMetadata* metadata);
  size_t GetKeyCount() const;
  KeyIterator GetKeyIterator() const;
};
```

Each `FlatPositionMap` (`flat_position_map.h`) stores a compact representation of positions and their field masks for a single key. Positions are stored when `with_offsets_` is true, enabling phrase and proximity queries.

The `KeyIterator` provides ordered iteration over keys within a word's postings:

```cpp
struct Postings::KeyIterator {
  bool IsValid() const;
  void NextKey();
  bool SkipForwardKey(const Key& key);  // seek for merge joins
  const Key& GetKey() const;
  bool ContainsFields(uint64_t field_mask) const;  // field-level filtering
  PositionIterator GetPositionIterator() const;
};
```

`SkipForwardKey` enables efficient merge-join across multiple postings lists - critical for multi-term queries where the intersection of key sets must be found.

The `PositionIterator` (from `FlatPositionMap`) yields positions in ascending order with their field masks, enabling proximity checking.

## Proximity and Phrase Matching

`ProximityIterator` (`proximity.h`) coordinates multiple `TextIterator` instances to find documents where terms appear within a specified distance:

```cpp
class ProximityIterator : public TextIterator {
  absl::InlinedVector<std::unique_ptr<TextIterator>,
                      kProximityTermsInlineCapacity> iters_;
  std::optional<uint32_t> slop_;   // max word distance between terms
  bool in_order_;                  // require terms to appear in query order
  bool skip_positional_checks_;    // AND without positional constraints
};
```

The `TextIterator` interface (`text_iterator.h`) provides a two-level iteration contract: key-level (`NextKey`, `SeekForwardKey`, `DoneKeys`) and position-level (`NextPosition`, `SeekForwardPosition`, `DonePositions`, `CurrentFieldMask`).

The algorithm:
1. `FindCommonKey()` - advances all iterators to find a key present in all postings lists (merge-join using `SeekForwardKey`)
2. For each common key, check positional constraints:
   - Collect current positions from all iterators
   - Sort by position
   - Verify slop constraint: max(positions) - min(positions) - (num_terms - 1) <= slop
   - If `in_order_` is set, verify positions are monotonically increasing
3. `FindViolatingIterator()` returns a `ViolationInfo` struct identifying which iterator to advance and an optional seek target position

Exact phrase matching is a special case with `slop=0` and `in_order=true`.

`skip_positional_checks_` is set for AND operations without positional constraints - in this case only key intersection is verified, not positions.

`ProximityIterator` can contain nested `ProximityIterator` instances - this occurs when a ProximityOR term appears inside a ProximityAND term. The `OrProximityIterator` (`orproximity.h`) handles the OR case.

## Lexer Pipeline

The `Lexer` (`lexer.h`) is a stateless tokenizer configured per schema:

```cpp
struct Lexer {
  data_model::Language language_;          // for stemmer selection
  std::bitset<256> punct_bitmap_;          // fast punctuation check
  absl::flat_hash_set<std::string> stop_words_set_;
};
```

Tokenization pipeline (`Tokenize()`):

1. **UTF-8 validation** - `IsValidUtf8()` rejects invalid input (returns `kInvalidArgument` -> `hash_indexing_failures`)
2. **Split on punctuation** - characters in `punct_bitmap_` are treated as delimiters
3. **Unicode normalization** - `NormalizeLowerCaseInPlace()` lowercases using ICU-aware normalization (`unicode_normalizer.h`)
4. **Stop word removal** - tokens in `stop_words_set_` are filtered out (checked via `IsStopWord()`)
5. **Stemming** - if enabled and word length >= `min_stem_size`, apply Snowball stemmer via `StemWordInPlace()`

Stemming uses the `libstemmer` library (Snowball):

```cpp
void Lexer::StemWordInPlace(std::string& word, sb_stemmer* stemmer,
                            uint32_t min_stem_size) const;
```

The stemmer is obtained via `GetStemmer()` based on the schema's `language` field. `UpdateStemMap()` records the original-to-stem mapping into an `InProgressStemMap` for later stem tree updates.

Stop words are configurable per schema. The default set depends on the language.

## Fuzzy Matching

`FuzzySearch` (`fuzzy.h`) implements Damerau-Levenshtein distance matching on the Rax prefix tree via `Search(tree, pattern, max_distance, max_words)`. The algorithm uses recursive tree traversal with dynamic programming over four edit operations (deletion, insertion, substitution, transposition). Subtree pruning skips branches where the minimum DP row value exceeds `max_distance`. Each child branch saves and restores DP rows for independent evaluation. Results are bounded by `max_words` (from `options::GetMaxTermExpansions()`). `FuzzyPredicate::BuildTextIterator` wraps results in a `TermIterator`.

## Record Lifecycle

**Add**: `Text::AddRecord()` delegates to `TextIndexSchema::StageAttributeData()` which tokenizes the text and builds a `TokenPositions` map (`token -> (PositionMap, suffix_eligible)` where `PositionMap` is `absl::btree_map<Position, FieldMask>`). Each token at each position gets a field mask bit set for the current text field. This is staged in `in_progress_key_updates_`.

**Commit (CommitKeyData)**: Called after all attributes have staged their data. For each token: look up or create a `Postings` object in the prefix tree, insert the key with its `FlatPositionMap`, update the per-key text index, and commit stem mappings. Uses per-word bucket locks (`RaxTargetMutexPool`) for fine-grained concurrency, with `text_index_mutex_` for tree structural changes.

**Modify**: `Text::ModifyRecord()` - the old key value has already been removed via `TextIndexSchema::DeleteKeyData()`, so it simply stages new data via `StageAttributeData`.

**Delete (DeleteKeyData)**: Iterates all words the key was indexed under, removes the key from each word's postings, cleans up empty postings from the tree, and removes stem tree entries when the last word with a given stem is removed.

## Concurrency Model

Multiple locking levels:

| Lock | Type | Protects |
|------|------|----------|
| `text_index_mutex_` | absl::Mutex | Rax tree structural changes (node insert/delete) |
| `rax_target_mutex_pool_` | `RaxTargetMutexPool` (pool of absl::Mutex) | Per-word postings mutations (bucket hashed) |
| `stem_tree_mutex_` | absl::Mutex | Stem tree structural changes |
| `per_key_text_indexes_mutex_` | std::mutex | Per-key text index map |
| `in_progress_key_updates_mutex_` | std::mutex | Staging area for key updates |
| `in_progress_stem_mappings_mutex_` | std::mutex | Staging area for stem mappings |
| `index_mutex_` (Text class) | absl::Mutex | Per-field `tracked_keys_` / `untracked_keys_` |

The design separates tree structure locks from target mutation locks. Reading the Rax tree during search takes `text_index_mutex_` as a reader lock, while target mutations only need the per-word bucket lock. This allows high concurrency for queries that touch different words.

`Text::EntriesFetcher` bridges to the `TextIterator` hierarchy - `Begin()` calls `predicate_->BuildTextIterator()` and wraps it in a `TextFetcher` adapter (`text_fetcher.h`). `TextIteratorFetcher` (in `text.h`) provides the same bridge for composed AND queries where a `TextIterator` is already built.

## See Also

- [numeric.md](numeric.md) - Numeric range index
- [tag.md](tag.md) - Tag categorical index
- [Module overview](../architecture/module-overview.md) - Module architecture overview
- [Query execution](../query/execution.md) - Query execution and text predicate types
- [Query parsing](../query/parsing.md) - How text queries are parsed into predicate trees
- [Thread model](../architecture/thread-model.md) - Threading and concurrency architecture
