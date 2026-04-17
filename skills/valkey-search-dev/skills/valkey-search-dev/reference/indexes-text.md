# Full-text search index

Use when reasoning about full-text search, prefix/suffix Rax trees, postings, stemming, proximity/phrase matching, tokenization, or fuzzy matching.

Source: `src/indexes/text.{h,cc}`, `src/indexes/text/` directory.

## Two-level architecture

- **`TextIndexSchema`** (`text_index.h`) - schema-level shared state, one per `FT.CREATE`. Owns Rax trees (prefix, suffix, stem), lexer, per-key text indexes, staging areas.
- **`Text`** (`text.h`) - per-field index. Field-specific settings (`weight`, `no_stem`, `with_suffix_trie`) plus `text_field_number_` (bit position in field masks). Delegates indexing to the shared schema.

Separation exists because full-text is inherently cross-field - a single Rax tree indexes words from all text fields; field masks distinguish which fields contain each word.

## `TextIndexSchema`

```cpp
class TextIndexSchema {
  std::shared_ptr<TextIndex> text_index_;             // prefix + optional suffix
  Rax stem_tree_;                                     // stem -> parent words
  Lexer lexer_;
  TextIndexMetadata metadata_;                        // FT.INFO counters + pools
  absl::node_hash_map<Key, TextIndex>       per_key_text_indexes_;
  absl::node_hash_map<Key, TokenPositions>  in_progress_key_updates_;
  absl::node_hash_map<Key, InProgressStemMap> in_progress_stem_mappings_;
  RaxTargetMutexPool rax_target_mutex_pool_;          // per-word bucket locks
  uint8_t  num_text_fields_ = 0;                      // MAX 64 (field mask is uint64_t)
  bool     with_offsets_;                             // store position offsets (phrase queries)
  uint32_t min_stem_size_;
  uint64_t stem_text_field_mask_ = 0;
};
```

`AllocateTextFieldNumber()` - each `Text` attribute registers for a unique bit position. `EnableSuffix()` recreates the shared `TextIndex` with a suffix tree if any field has `WITHSUFFIXTRIE`.

`FieldMask` (`posting.h`) is a 16-byte struct (enforced by `static_assert`):

```cpp
struct FieldMask {
  uint64_t mask_{0};
  uint8_t  num_fields_{0};
  void SetField(size_t field_index);
  uint64_t GetMask() const;
};
```

`FieldMaskPredicate` is a `uint64_t` alias used for field-level filtering.

Per-field config (on `Text`): `weight_` (default 1.0), `no_stem_`, `with_suffix_trie_`. `tracked_keys_` / `untracked_keys_` (`InternedStringSet`) mainly drive `FT.INFO` metrics.

## Rax prefix tree

```cpp
class TextIndex {
  Rax prefix_tree_;                       // word -> Postings (always present)
  std::unique_ptr<Rax> suffix_tree_;      // reversed_word -> Postings (optional)
};
```

`Rax` wrapper (`rax_wrapper.h`) encapsulates Valkey core's C `rax` library with C++ iterator APIs. Memory-efficient radix tree with path compression. `InvasivePtr<Postings>` for reference-counted targets.

Key APIs:

- `GetWordIterator(prefix)` - all words with prefix, lexical order, yields `Postings`. Used for prefix search (`hello*`) and exact term lookup.
- `MutateTarget(word, fn, op)` - applies mutation; optional `item_count_op` updates subtree counts.
- `GetSubtreeItemCount(prefix)` - O(prefix length) count under a prefix (query planning). Only tracked when `track_subtree_item_counts_` is enabled - happens when the schema has a HNSW field.

Words stored lowercase. `RadixTree<Target>` (`radix_tree.h`) is a pure-C++ alternative available, but production uses Rax for memory.

## Suffix tree

`TextIndex::TextIndex(bool suffix)`: both trees reference the same `Postings` objects. `MutateTarget()` updates both atomically:

```cpp
void TextIndex::MutateTarget(word, target, reverse_word, op) {
  auto target_set_fn = CreateTargetSetFn(target);
  prefix_tree_.MutateTarget(word, target_set_fn, op);
  if (suffix_tree_ && reverse_word) suffix_tree_->MutateTarget(*reverse_word, target_set_fn, op);
}
```

`SuffixPredicate::BuildTextIterator` reverses the query string and prefix-searches the suffix tree. E.g., `*tion` reverses to `noit` and prefix-matches.

## Stem tree

Rax: `stemmed_word -> StemParents (vector<string>)`. Example: `"happi" -> {"happy", "happiness", "happily"}`.

**Indexing** (`CommitKeyData`): `in_progress_stem_mappings_` (populated by lexer's `UpdateStemMap()`) is committed under `stem_tree_mutex_`.

**Search** (`GetAllStemVariants`): stem the query term, look up in stem tree, expand to all parents.

```cpp
lexer_.StemWordInPlace(stemmed, lexer_.GetStemmer(), min_stem_size_);
auto stem_iter = stem_tree_.GetWordIterator(stemmed);
if (!stem_iter.Done() && stem_iter.GetWord() == stemmed)
    for (const auto& parent : *parents_ptr) words_to_search.push_back(parent);
```

Expansion gated by `stem_text_field_mask_` - only fields with stemming enabled get expanded.

## Postings

```cpp
struct Postings {
  absl::btree_map<Key, FlatPositionMap*> key_to_positions_;
  void InsertKey(const Key&, FlatPositionMap*);
  void RemoveKey(const Key&, TextIndexMetadata*);
  size_t GetKeyCount() const;
  KeyIterator GetKeyIterator() const;
};
```

`FlatPositionMap` (`flat_position_map.h`) - compact positions + field masks per key. Positions stored when `with_offsets_ == true`.

`KeyIterator`:

```cpp
struct Postings::KeyIterator {
  bool IsValid(); void NextKey();
  bool SkipForwardKey(const Key&);           // merge-join seek
  const Key& GetKey();
  bool ContainsFields(uint64_t field_mask);
  PositionIterator GetPositionIterator();
};
```

`SkipForwardKey` drives multi-term merge-join. `PositionIterator` yields positions ascending with field masks for proximity.

## Proximity / phrase

```cpp
class ProximityIterator : public TextIterator {
  absl::InlinedVector<std::unique_ptr<TextIterator>, kProximityTermsInlineCapacity> iters_;
  std::optional<uint32_t> slop_;
  bool in_order_;
  bool skip_positional_checks_;   // AND without positional constraints
};
```

`TextIterator` (`text_iterator.h`) is a two-level contract: key (`NextKey`, `SeekForwardKey`, `DoneKeys`) and position (`NextPosition`, `SeekForwardPosition`, `DonePositions`, `CurrentFieldMask`).

Algorithm:

1. `FindCommonKey()` - merge-join all iterators via `SeekForwardKey`.
2. Per common key: collect positions, sort, verify `max - min - (num_terms - 1) <= slop`. If `in_order_`, verify monotonically increasing.
3. `FindViolatingIterator()` returns which iterator to advance and an optional seek target.

Exact phrase = `slop=0, in_order=true`. `skip_positional_checks_` = AND without positional constraints (key intersection only).

Nested `ProximityIterator`s supported (ProximityOR inside ProximityAND). `OrProximityIterator` (`orproximity.h`) handles OR.

## Lexer

```cpp
struct Lexer {
  data_model::Language language_;
  std::bitset<256> punct_bitmap_;
  absl::flat_hash_set<std::string> stop_words_set_;
};
```

`Tokenize()` pipeline:

1. **UTF-8 validation** - `IsValidUtf8()` rejects invalid (bumps `hash_indexing_failures`).
2. **Split on punctuation** - chars in `punct_bitmap_` are delimiters.
3. **Unicode lowercase** - `NormalizeLowerCaseInPlace()` (ICU-aware, `unicode_normalizer.h`).
4. **Stop words** - `IsStopWord()` filter.
5. **Stem** - if enabled and `length >= min_stem_size`, `StemWordInPlace(word, stemmer, min_stem_size)` via Snowball (`libstemmer`).

`GetStemmer()` picks stemmer from schema's `language`. `UpdateStemMap()` records original-to-stem into `InProgressStemMap` for later stem tree commit. Stop words configurable per schema (language-defaulted).

## Fuzzy

`FuzzySearch` (`fuzzy.h`) - Damerau-Levenshtein over the Rax prefix tree: `Search(tree, pattern, max_distance, max_words)`. Recursive traversal with DP over 4 ops (deletion, insertion, substitution, transposition). Prunes branches where min DP row exceeds `max_distance`. Bounded by `max_words` (default `options::GetMaxTermExpansions()`). `FuzzyPredicate::BuildTextIterator` wraps results in a `TermIterator`.

## Record lifecycle

- **Add**: `Text::AddRecord()` -> `TextIndexSchema::StageAttributeData()` tokenizes into `TokenPositions` (`token -> (PositionMap, suffix_eligible)`, `PositionMap = btree_map<Position, FieldMask>`). Each token at each position sets its field bit. Stages in `in_progress_key_updates_`.
- **Commit** (`CommitKeyData`): after all attributes have staged. Per token: look up / create `Postings`, insert key with `FlatPositionMap`, update per-key text index, commit stem mappings. Per-word bucket locks (`RaxTargetMutexPool`); `text_index_mutex_` for structural changes.
- **Modify**: `ModifyRecord()` - old data was already removed by `DeleteKeyData()`, so just stages new data.
- **Delete** (`DeleteKeyData`): iterate all words the key was under, remove from each word's postings, clean empty postings, remove stem entries when last word with a given stem is gone.

## Concurrency

| Lock | Type | Protects |
|------|------|----------|
| `text_index_mutex_` | `absl::Mutex` | Rax structural changes |
| `rax_target_mutex_pool_` | pool of `absl::Mutex` | per-word postings mutations (hashed bucket) |
| `stem_tree_mutex_` | `absl::Mutex` | stem tree structural changes |
| `per_key_text_indexes_mutex_` | `std::mutex` | per-key text index map |
| `in_progress_key_updates_mutex_` | `std::mutex` | staging for key updates |
| `in_progress_stem_mappings_mutex_` | `std::mutex` | staging for stem mappings |
| `Text::index_mutex_` | `absl::Mutex` | per-field `tracked_keys_` / `untracked_keys_` |

Structure locks are separate from target mutation locks. Search takes `text_index_mutex_` as reader; target mutations only need the per-word bucket lock. High concurrency across different words.

`Text::EntriesFetcher::Begin()` calls `predicate_->BuildTextIterator()` and wraps in `TextFetcher` (`text_fetcher.h`). `TextIteratorFetcher` bridges composed AND queries where a `TextIterator` is already built.
