# Numeric index

Use when reasoning about numeric range queries, the BTree+SegmentTree combo, or numeric predicate evaluation.

Source: `src/indexes/numeric.{h,cc}`, `src/utils/segment_tree.h`.

## Shape

```cpp
class Numeric : public IndexBase {
  InternedStringHashMap<double> tracked_keys_;         // key -> value
  InternedStringSet             untracked_keys_;       // keys with no valid numeric data
  std::unique_ptr<BTreeNumericIndex> index_;           // sorted + range counts
  mutable absl::Mutex index_mutex_;
};
```

APIs beyond `IndexBase`: `GetValue(key)` returns a pointer to the stored double (lock-free during read phase of the time-sliced mutex); `GetMutationWeight()` -> `options::GetMutationWeightNumeric()`; `SaveIndex()` is a no-op (rebuilt from hash keys on load).

## `BTreeNumeric<T>`

```cpp
template <typename T, typename Hasher = absl::Hash<T>, typename Equalizer = std::equal_to<T>>
class BTreeNumeric {
  absl::btree_map<double, SetType> btree_;   // value -> flat_hash_set<T>
  utils::SegmentTree               segment_tree_;
};
using BTreeNumericIndex = BTreeNumeric<InternedStringPtr>;
```

BTree maps each distinct value to the set of keys with that value (multi-key support). `absl::btree_map` is ordered -> `lower_bound` / `upper_bound` for range queries.

Both structures updated in tandem per mutation:

```cpp
Add   (v, k) -> btree_[k].insert(v); segment_tree_.Add(k);
Remove(v, k) -> btree_[k].erase (v); if empty erase slot; segment_tree_.Remove(k);
Modify(v, old, new) -> Remove(v, old); Add(v, new);
```

`GetBtree()` exposes const reference for range iteration.

## `SegmentTree` overlay

`src/utils/segment_tree.h`. Self-balancing AVL-style tree, O(log n) range counting.

```cpp
struct SegmentTreeNode {
  uint64_t count;
  uint32_t height;
  double   min_value, max_value;
  std::unique_ptr<SegmentTreeNode> left_node, right_node;
};
```

`Count(start, end, inclusive_start, inclusive_end)` = two `CountGreaterThan` calls with inverted inclusivity flags.

AVL rotations (`RotateLeft` / `RotateRight`) fire after every `Add` / `Remove`. Leaves with count 0 collapse; remaining child promotes.

Memory: ~80 bytes/entry (40 bytes/node, ~2 nodes/entry balanced). A unified structure could eliminate this overhead (not yet implemented).

## Range search

```cpp
std::unique_ptr<EntriesFetcher> Numeric::Search(const query::NumericPredicate&, bool negate) const;
```

Non-negated:

```cpp
entries_range.first  = start_inclusive ? btree.lower_bound(start) : btree.upper_bound(start);
entries_range.second = end_inclusive   ? btree.upper_bound(end)   : btree.lower_bound(end);
size_t size = index_->GetCount(start, end, start_inclusive, end_inclusive);
```

BTree iterators delimit the matching-value range; SegmentTree yields size without traversal. `EntriesFetcher` wraps the range for the query engine.

## Negated range search

Two ranges covering everything outside the predicate, plus untracked keys:

```cpp
// Range 1: (-inf, start) with inverted inclusivity
entries_range.first  = btree.begin();
entries_range.second = start_inclusive ? btree.lower_bound(start) : btree.upper_bound(start);

// Range 2: (end, +inf) with inverted inclusivity
additional_entries_range.first  = end_inclusive ? btree.upper_bound(end) : btree.lower_bound(end);
additional_entries_range.second = btree.end();
```

Size = two SegmentTree range counts (`numeric_limits<double>::lowest()` / `::max()` as boundaries) + `untracked_keys_.size()`. Iterator chains: primary range -> additional range -> untracked keys.

## `EntriesFetcher` / `EntriesFetcherIterator`

Extends `EntriesFetcherBase` from `index_base.h`. Holds primary range, optional additional range (for negation), optional `untracked_keys_` pointer.

Two-level iteration - outer by BTree value, inner by `flat_hash_set` of keys at that value:

```cpp
static bool NextKeys(const EntriesRange& range,
    BTreeNumericIndex::ConstIterator& iter,
    std::optional<InternedStringSet::const_iterator>& keys_iter) {
  while (iter != range.second) {
    keys_iter = keys_iter ? ++*keys_iter : iter->second.begin();
    if (*keys_iter != iter->second.end()) return true;
    ++iter; keys_iter.reset();
  }
  return false;
}
```

`Begin()` returns a fresh iterator and advances to the first result. Negated variant chains the three sources in sequence.

## Record lifecycle

- **Add**: `ParseNumber(data)` via `absl::SimpleAtod`, rejects "nan". Parse fail -> key into `untracked_keys_`, return false. Key already tracked -> `AlreadyExistsError`. Else insert `{key, value}` + `index_->Add(key, value)`.
- **Modify**: lookup existing value in `tracked_keys_`, `index_->Modify(key, old, new)`, update tracked value. Unparseable new -> falls through to `RemoveRecord(DeletionType::kIdentifier)`. Missing tracked key -> `NotFoundError`.
- **Remove**: `index_->Remove(key, value)` + erase from `tracked_keys_`. `DeletionType` controls untracked transition.

All mutations take `index_mutex_`.

## Tracked vs untracked

Mutually exclusive.

- **Tracked**: `tracked_keys_`, indexed in BTree.
- **Untracked**: exists in schema but no parseable numeric (non-numeric string, NaN). Matters for negated queries - `NOT [10 20]` must include keys with no numeric value at all.

`DeletionType` on remove:

- `kRecord` - key fully deleted; remove from untracked too.
- `kIdentifier` / `kNone` - field removed but key exists; add to untracked.

`AddRecord` removes the key from `untracked_keys_` if it was there.

## Memory per key

| Structure | Bytes |
|-----------|-------|
| `tracked_keys_` entry | ~48 |
| BTree entry (in `flat_hash_set`) | ~40 amortized |
| SegmentTree | ~80 |
| **Total** | ~170 |

Single `index_mutex_` protects all mutations, info, and enumeration (`ForEachTrackedKey`, `ForEachUnTrackedKey`). `RespondWithInfo()` reports `type=NUMERIC`, `size = tracked_keys_.size()`.
