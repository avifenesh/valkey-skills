# Tag Index

Use when working on tag-based filtering, the PatriciaTree storage, tag separator handling, prefix wildcard matching, or tag predicate evaluation.

Source: `src/indexes/tag.h`, `src/indexes/tag.cc`, `src/utils/patricia_tree.h`

## Contents

- [Class Overview](#class-overview)
- [PatriciaTree Storage](#patriciatree-storage)
- [Separator and Case Sensitivity](#separator-and-case-sensitivity)
- [Tag Splitting](#tag-splitting)
- [Search and Wildcard Prefix Matching](#search-and-wildcard-prefix-matching)
- [Tag Predicate Evaluation](#tag-predicate-evaluation)
- [EntriesFetcher Iteration](#entriesfetcher-iteration)
- [Record Lifecycle](#record-lifecycle)
- [Tracked vs Untracked Keys](#tracked-vs-untracked-keys)
- [Negated Tag Queries](#negated-tag-queries)

## Class Overview

The `Tag` class implements `IndexBase` for categorical tag fields. Each key can have multiple tags (split on a configurable separator). Tags are stored in a Patricia tree for efficient exact and prefix matching.

```cpp
class Tag : public IndexBase {
  InternedStringHashMap<TagInfo> tracked_tags_by_keys_;  // key -> {raw_string, parsed_tags}
  InternedStringSet untracked_keys_;       // keys without valid tag data
  const char separator_;                   // tag delimiter (default comma)
  const bool case_sensitive_;              // case-sensitive matching
  PatriciaTreeIndex tree_;                 // Patricia tree: tag -> set<key>
  mutable absl::Mutex index_mutex_;
};
```

The `TagInfo` struct stored per key:
```cpp
struct TagInfo {
  InternedStringPtr raw_tag_string;            // original interned data
  absl::flat_hash_set<absl::string_view> tags; // parsed tag views into raw_tag_string
};
```

`SaveIndex()` is a no-op - tag data is reconstructed from hash keys on load. `GetMutationWeight()` returns `options::GetMutationWeightTag()`.

## PatriciaTree Storage

Tags are indexed in a `PatriciaTree<InternedStringPtr>` (`src/utils/patricia_tree.h`), aliased as `PatriciaTreeIndex`. Each node (aliased as `PatriciaNodeIndex`) can hold an optional `flat_hash_set<InternedStringPtr>` of keys that have that exact tag value.

```cpp
template <typename T>
class PatriciaNode {
  absl::flat_hash_map<std::string, std::unique_ptr<PatriciaNode>> children;
  int64_t subtree_values_count = 0;   // count of values in entire subtree
  std::optional<absl::flat_hash_set<T>> value;  // keys at this exact tag
};
```

The Patricia tree is constructed with the `case_sensitive_` flag. When case-insensitive, all lookups normalize to lowercase.

Key characteristics:
- **Path compression** - shared prefixes are collapsed into single edges, reducing memory for tags with common prefixes
- **subtree_values_count** - each node tracks the total number of values in its subtree, enabling O(prefix_length) size estimation for prefix queries
- **Exact and prefix search** - `ExactMatcher(tag)` returns the node for an exact tag; `PrefixMatcher(prefix)` returns a `PrefixSubTreeIterator` over all nodes in the prefix subtree
- **RootIterator** - `tree_.RootIterator()` returns a `PrefixSubTreeIterator` over the entire tree, used for negated queries

## Separator and Case Sensitivity

Both are configured at index creation from the `TagIndex` protobuf:

```cpp
Tag::Tag(const data_model::TagIndex& tag_index_proto)
    : IndexBase(IndexerType::kTag),
      separator_(tag_index_proto.separator()[0]),
      case_sensitive_(tag_index_proto.case_sensitive()),
      tree_(case_sensitive_) {}
```

The separator defaults to comma (`,`) but can be any single character. The `GetSeparator()` and `IsCaseSensitive()` accessors expose these for query evaluation.

Case sensitivity applies both to storage in the Patricia tree and to search matching. The tree itself handles case normalization internally when `case_sensitive_` is false.

`RespondWithInfo()` reports `type=TAG`, `SEPARATOR`, `CASESENSITIVE`, and `size` (tracked key count) for `FT.INFO`.

## Tag Splitting

Two parsing modes exist for different contexts:

**Record tags** (`ParseRecordTags`) - static method, splits data on separator via `absl::StrSplit`, strips whitespace:

```cpp
static absl::flat_hash_set<absl::string_view> ParseRecordTags(
    absl::string_view data, char separator) {
  absl::flat_hash_set<absl::string_view> parsed_tags;
  for (const auto& part : absl::StrSplit(data, separator)) {
    auto tag = absl::StripAsciiWhitespace(part);
    if (!tag.empty()) parsed_tags.insert(tag);
  }
  return parsed_tags;
}
```

**Search tags** (`ParseSearchTags`) - static method returning `StatusOr`, additionally handles:
- Escape sequences: `\<separator>` is a literal separator, not a delimiter
- Prefix wildcards: trailing `*` enables prefix matching (e.g., `elec*` matches `electronics`, `electrical`)
- Minimum prefix length: prefixes shorter than or equal to `options::GetTagMinPrefixLength()` are rejected with `InvalidArgumentError`
- Double wildcard rejection: `tag**` is an error (validated by `IsValidPrefix()`)

```cpp
// Escape-aware parsing loop
for (size_t i = 0; i < data.size(); ++i) {
  if (data[i] == '\\' && i + 1 < data.size()) {
    ++i;  // Skip escaped character
  } else if (data[i] == separator) {
    InsertTag(data.substr(tag_start, i - tag_start));
    tag_start = i + 1;
  }
}
```

`UnescapeTag()` (static method) converts escaped sequences to literal characters at the predicate level.

## Search and Wildcard Prefix Matching

`Tag::Search()` evaluates a `TagPredicate` against the Patricia tree:

```cpp
std::unique_ptr<Tag::EntriesFetcher> Tag::Search(
    const query::TagPredicate& predicate, bool negate) const {
  absl::flat_hash_set<PatriciaNodeIndex*> entries;
  size_t size = 0;
  for (const auto& tag : predicate.GetTags()) {
    if (tag.back() == '*') {
      // Prefix matching - iterate all nodes under the prefix
      auto prefix_tag = tag.substr(0, tag.length() - 1);
      for (auto it = tree_.PrefixMatcher(prefix_tag); !it.Done(); it.Next()) {
        PatriciaNodeIndex* node = it.Value();
        if (node != nullptr) {
          auto res = entries.insert(node);
          if (res.second && node->value.has_value()) {
            size += node->value.value().size();
          }
        }
      }
    } else {
      // Exact matching - direct Patricia tree lookup
      PatriciaNodeIndex* node = tree_.ExactMatcher(tag);
      if (node != nullptr) {
        auto res = entries.insert(node);
        if (res.second && node->value.has_value()) {
          size += node->value.value().size();
        }
      }
    }
  }
  // ...
}
```

Multiple tags in a single predicate produce a union - `entries` collects unique nodes from all tag lookups (deduplication via `flat_hash_set`). A source TODO notes suffix/infix search support is planned.

## Tag Predicate Evaluation

Tags also participate in vector pre-filtering via `PrefilterEvaluator::EvaluateTags()` (in `vector_base.cc`):

```cpp
query::EvaluationResult PrefilterEvaluator::EvaluateTags(
    const query::TagPredicate& predicate) {
  bool case_sensitive = true;
  auto tags = predicate.GetIndex()->GetValue(*key_, case_sensitive);
  return predicate.Evaluate(tags, case_sensitive);
}
```

`GetValue()` retrieves the parsed tag set for a key and sets the `case_sensitive` output parameter. It operates without locking (safe during read phase of the time-sliced mutex). The predicate's `Evaluate()` method checks whether any of the query tags match the key's stored tags.

`GetRawValue()` returns the original `InternedStringPtr` for a key, used when returning tag values in search results.

## EntriesFetcher Iteration

The `EntriesFetcher` / `EntriesFetcherIterator` pair provides the standard iteration interface (extending `EntriesFetcherBase` / `EntriesFetcherIteratorBase` from `index_base.h`):

```cpp
class EntriesFetcher : public EntriesFetcherBase {
  const PatriciaTreeIndex& tree_;
  absl::flat_hash_set<PatriciaNodeIndex*> entries_;  // matching Patricia nodes
  bool negate_;
  const InternedStringSet& untracked_keys_;
};
```

For non-negated queries, the iterator walks through the collected Patricia nodes, yielding each key from each node's value set:

```cpp
void Tag::EntriesFetcherIterator::Next() {
  if (next_node_) {
    ++next_iter_;
    if (next_iter_ != next_node_->value.value().end()) return;
  }
  while (!entries_.empty()) {
    auto itr = entries_.begin();
    next_node_ = *itr;
    entries_.erase(itr);
    if (next_node_->value.has_value() && !next_node_->value.value().empty()) {
      next_iter_ = next_node_->value.value().begin();
      return;
    }
  }
  next_node_ = nullptr;
}
```

`Begin()` returns a new `EntriesFetcherIterator` and calls `Next()` to advance to the first result.

## Record Lifecycle

**Add**: `AddRecord()` interns the data string via `StringInternStore::Intern()`, parses tags via `ParseRecordTags()`. If no tags are found, the key goes to `untracked_keys_`. If the key already exists, returns `AlreadyExistsError`. Otherwise, inserts into `tracked_tags_by_keys_` (with both raw string and parsed tags) and adds each tag to the Patricia tree:

```cpp
for (const auto& tag : parsed_tags) {
  tree_.AddKeyValue(tag, key);
}
```

**Modify**: `ModifyRecord()` interns the new data, parses new tags. If the new tag set is empty, falls through to `RemoveRecord` with `DeletionType::kIdentifier`. Otherwise, computes the diff between old and new tag sets, adding new tags and removing stale ones:

```cpp
// Insert new tags not in old set
for (const auto& tag : new_parsed_tags) {
  if (!tag_info.tags.contains(tag)) tree_.AddKeyValue(tag, key);
}
// Remove old tags not in new set
for (const auto& tag : tag_info.tags) {
  if (!new_parsed_tags.contains(tag)) tree_.Remove(tag, key);
}
```

This differential update avoids a full remove-then-add cycle, minimizing Patricia tree mutations. Returns `NotFoundError` if the key is not tracked.

**Remove**: Removes all of the key's tags from the Patricia tree, then erases from `tracked_tags_by_keys_`.

## Tracked vs Untracked Keys

Same pattern as the Numeric index:
- **Tracked** - keys with at least one parseable tag, stored in `tracked_tags_by_keys_`
- **Untracked** - keys that exist in the schema but whose tag field is empty or missing

These sets are mutually exclusive (enforced by `CHECK` in `UnTrack()`). On `AddRecord`, if the key was previously untracked, it is removed from `untracked_keys_`.

`DeletionType::kRecord` removes from untracked; `DeletionType::kIdentifier` (or `kNone`) adds to untracked. Important for negated queries where untracked keys must be included.

## Negated Tag Queries

For negated search (`negate=true`), the iterator walks the entire Patricia tree via `tree_.RootIterator()`, skipping nodes that are in the matched `entries_` set:

```cpp
void Tag::EntriesFetcherIterator::NextNegate() {
  while (!tree_iter_.Done()) {
    next_node_ = tree_iter_.Value();
    if (next_node_ && !entries_.contains(next_node_) &&
        next_node_->value.has_value() && !next_node_->value.value().empty()) {
      next_iter_ = next_node_->value.value().begin();
      return;
    }
    tree_iter_.Next();
  }
  // After tree exhaustion, yield untracked keys
  next_node_ = nullptr;
  // iterate untracked_keys_...
}
```

Size estimation for negated queries: `tracked_tags_by_keys_.size() - matched_size + untracked_keys_.size()` (clamped to avoid underflow when matched_size exceeds tracked count).

## See Also

- [numeric.md](numeric.md) - Numeric range index
- [text.md](text.md) - Full-text search index
- [Module overview](../architecture/module-overview.md) - Module architecture overview
- [Query execution](../query/execution.md) - Predicate evaluation and filter planning
- [Index schema](../architecture/index-schema.md) - Schema management and index creation
