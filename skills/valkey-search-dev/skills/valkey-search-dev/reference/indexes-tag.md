# Tag index

Use when reasoning about tag filtering, `PatriciaTree` storage, separator handling, or prefix wildcard matching.

Source: `src/indexes/tag.{h,cc}`, `src/utils/patricia_tree.h`.

## Shape

```cpp
class Tag : public IndexBase {
  InternedStringHashMap<TagInfo> tracked_tags_by_keys_; // key -> {raw, parsed}
  InternedStringSet untracked_keys_;
  const char separator_;                                // default ','
  const bool case_sensitive_;
  PatriciaTreeIndex tree_;                              // tag -> set<key>
  mutable absl::Mutex index_mutex_;
};

struct TagInfo {
  InternedStringPtr raw_tag_string;
  absl::flat_hash_set<absl::string_view> tags;          // views into raw_tag_string
};
```

`SaveIndex()` is a no-op (rebuilt from hash keys on load). `GetMutationWeight()` -> `options::GetMutationWeightTag()`.

Constructor reads `separator()[0]` (first char) and `case_sensitive()` from `TagIndex` proto. Separator can be any single char.

## `PatriciaTree<InternedStringPtr>`

```cpp
template <typename T>
class PatriciaNode {
  absl::flat_hash_map<std::string, std::unique_ptr<PatriciaNode>> children;
  int64_t subtree_values_count = 0;
  std::optional<absl::flat_hash_set<T>> value;   // keys at this exact tag
};
```

Constructed with `case_sensitive_` - case-insensitive mode normalizes to lowercase internally.

- Path-compression: shared prefixes collapse into single edges.
- `subtree_values_count` per node - O(prefix length) size estimation for prefix queries.
- `ExactMatcher(tag)` -> node for exact tag.
- `PrefixMatcher(prefix)` -> `PrefixSubTreeIterator` over the subtree.
- `RootIterator()` -> iterator over the entire tree (used by negated queries).

Case sensitivity applies to both storage and search matching.

## Tag splitting

### `ParseRecordTags` (static)

```cpp
// Whitespace-stripped, empty-dropped
for (part : absl::StrSplit(data, separator))
    if (tag = StripAsciiWhitespace(part); !tag.empty()) insert;
```

### `ParseSearchTags` (static, `StatusOr`)

Extra rules over `ParseRecordTags`:

- Escape: `\<sep>` is a literal, not a delimiter.
- Trailing `*` -> prefix match (`elec*` matches `electronics`, `electrical`).
- Prefix length `<= options::GetTagMinPrefixLength()` -> `InvalidArgumentError`.
- `tag**` (double wildcard) -> error via `IsValidPrefix()`.

`UnescapeTag()` (static) converts escapes to literals at the predicate level.

## Search (`Tag::Search`)

```cpp
std::unique_ptr<EntriesFetcher> Tag::Search(const query::TagPredicate&, bool negate) const;
```

Non-negated: for each tag in the predicate:

- Trailing `*` -> `tree_.PrefixMatcher(prefix)` iterates the subtree; insert each non-null node.
- Exact -> `tree_.ExactMatcher(tag)`; insert if not null.

Entry set deduplicated via `flat_hash_set<PatriciaNodeIndex*>`. `size` accumulates from each freshly-inserted node's value set. Multiple tags -> union. Suffix/infix search not yet implemented.

## Pre-filter evaluation (`vector_base.cc`)

```cpp
EvaluationResult PrefilterEvaluator::EvaluateTags(const TagPredicate& predicate) {
  bool case_sensitive = true;
  auto tags = predicate.GetIndex()->GetValue(*key_, case_sensitive);
  return predicate.Evaluate(tags, case_sensitive);
}
```

`GetValue(key, &case_sensitive)` retrieves the parsed tag set and sets the out flag. Lock-free - safe during the time-sliced-mutex read phase. `GetRawValue()` returns the original `InternedStringPtr` for result responses.

## `EntriesFetcher` / iterator

Non-negated walk - outer over collected Patricia nodes, inner over each node's value set:

```cpp
void EntriesFetcherIterator::Next() {
  if (next_node_ && ++next_iter_ != next_node_->value->end()) return;
  while (!entries_.empty()) {
    next_node_ = *entries_.begin();  entries_.erase(entries_.begin());
    if (next_node_->value && !next_node_->value->empty()) {
      next_iter_ = next_node_->value->begin();  return;
    }
  }
  next_node_ = nullptr;
}
```

`Begin()` constructs and calls `Next()` once.

## Record lifecycle

- **Add**: intern data via `StringInternStore::Intern()`, `ParseRecordTags()`. No tags -> `untracked_keys_`. Existing tracked -> `AlreadyExistsError`. Else insert into `tracked_tags_by_keys_`, then `tree_.AddKeyValue(tag, key)` per tag.
- **Modify**: intern new data, parse. Empty result -> fall through to `Remove(DeletionType::kIdentifier)`. Else differential update:
  ```cpp
  for (tag : new_tags)   if (!old.contains(tag)) tree_.AddKeyValue(tag, key);
  for (tag : old_tags)   if (!new.contains(tag)) tree_.Remove(tag, key);
  ```
  Avoids full remove-then-add. Untracked key -> `NotFoundError`.
- **Remove**: remove each tag from the tree, erase from `tracked_tags_by_keys_`.

## Tracked vs untracked

Mutually exclusive - `CHECK` in `UnTrack()`. `AddRecord` removes from untracked on the success path.

| `DeletionType` | Effect |
|----------------|--------|
| `kRecord` | remove from untracked too |
| `kIdentifier` / `kNone` | add to untracked |

Relevant for negated queries - untracked keys must be included.

## Negated search

Walks entire tree via `tree_.RootIterator()`, skipping nodes in matched `entries_`:

```cpp
void EntriesFetcherIterator::NextNegate() {
  while (!tree_iter_.Done()) {
    next_node_ = tree_iter_.Value();
    if (next_node_ && !entries_.contains(next_node_) &&
        next_node_->value && !next_node_->value->empty()) {
      next_iter_ = next_node_->value->begin(); return;
    }
    tree_iter_.Next();
  }
  // ... then yield untracked keys
  next_node_ = nullptr;
}
```

Size estimate: `max(0, tracked_count - matched_size) + untracked_keys_.size()`.

## FT.INFO

`RespondWithInfo()` reports `type=TAG`, `SEPARATOR`, `CASESENSITIVE`, `size` (tracked count).
