# Numeric Index

Use when working on numeric range queries, the BTree+SegmentTree dual data structure, adding numeric filter operations, or understanding how numeric predicates are evaluated.

Source: `src/indexes/numeric.h`, `src/indexes/numeric.cc`, `src/utils/segment_tree.h`

## Contents

- [Class Overview](#class-overview)
- [BTreeNumeric Data Structure](#btreenumeric-data-structure)
- [SegmentTree Overlay](#segmenttree-overlay)
- [Range Queries](#range-queries)
- [EntriesFetcher for Result Iteration](#entriesfetcher-for-result-iteration)
- [Record Lifecycle](#record-lifecycle)
- [Tracked vs Untracked Keys](#tracked-vs-untracked-keys)
- [Negated Range Queries](#negated-range-queries)
- [Memory Overhead](#memory-overhead)

## Class Overview

The `Numeric` class implements `IndexBase` for numeric field indexing. It maps string keys to double values and supports efficient range queries with both forward and negated filters.

```cpp
class Numeric : public IndexBase {
  InternedStringHashMap<double> tracked_keys_;    // key -> numeric value
  InternedStringSet untracked_keys_;              // keys without valid numeric data
  std::unique_ptr<BTreeNumericIndex> index_;      // sorted index + range counts
  mutable absl::Mutex index_mutex_;
};
```

Additional public APIs not present on vector indexes: `GetValue()` returns a pointer to the stored double for a key (used lock-free during the read phase of the time-sliced mutex), `GetMutationWeight()` returns `options::GetMutationWeightNumeric()`, and `SaveIndex()` is a no-op (numeric data is reconstructed from hash keys on load).

## BTreeNumeric Data Structure

`BTreeNumeric<T>` is a template wrapping an `absl::btree_map` that maps doubles to sets of keys:

```cpp
template <typename T, typename Hasher = absl::Hash<T>,
          typename Equalizer = std::equal_to<T>>
class BTreeNumeric {
  absl::btree_map<double, SetType> btree_;   // double -> flat_hash_set<T>
  utils::SegmentTree segment_tree_;           // for O(log n) range counting
};
```

The template defaults `Hasher` to `absl::Hash<T>` and `Equalizer` to `std::equal_to<T>`. The concrete instantiation is `BTreeNumeric<InternedStringPtr>` (aliased as `BTreeNumericIndex`).

The BTree maps each distinct numeric value to the set of `InternedStringPtr` keys that have that value. This enables:

- **Ordered iteration** - `absl::btree_map` keeps values sorted, enabling `lower_bound`/`upper_bound` for range queries
- **Multi-key support** - multiple keys can share the same numeric value

Operations:

```cpp
void Add(const T& value, double key) {
  btree_[key].insert(value);
  segment_tree_.Add(key);
}

void Remove(const T& value, double key) {
  btree_[key].erase(value);
  if (btree_[key].empty()) btree_.erase(key);
  segment_tree_.Remove(key);
}

void Modify(const T& value, double old_key, double new_key) {
  Remove(value, old_key);
  Add(value, new_key);
}
```

Both the BTree and SegmentTree are updated in tandem for every mutation. `GetBtree()` exposes a const reference for iteration in `Search()`.

## SegmentTree Overlay

The `SegmentTree` (`src/utils/segment_tree.h`) provides O(log n) range counting. It is a self-balancing binary tree (AVL-based) where each node tracks:

```cpp
struct SegmentTreeNode {
  uint64_t count;                           // entries in this subtree
  uint32_t height;                          // for AVL balancing
  double min_value, max_value;              // range covered
  std::unique_ptr<SegmentTreeNode> left_node, right_node;
};
```

The key API used by `BTreeNumeric::GetCount()`:

```cpp
// SegmentTree::Count() - called internally by BTreeNumeric::GetCount()
uint64_t Count(double start, double end,
               bool inclusive_start, bool inclusive_end) {
  uint64_t count_greater_than_start = CountGreaterThan(start, inclusive_start);
  uint64_t count_greater_than_end = CountGreaterThan(end, !inclusive_end);
  return count_greater_than_start - count_greater_than_end;
}
```

Range counting uses two `CountGreaterThan` calls with clever inclusive flag inversion to compute the count of entries in `[start, end]` with configurable boundary inclusivity.

The tree self-balances via AVL rotations (`RotateLeft`, `RotateRight`) triggered after every `Add` or `Remove`. New values are inserted at leaf positions; removal of a leaf with count 0 collapses it and promotes the remaining child.

Memory overhead is approximately 80 bytes per entry (40 bytes per node, roughly 2 nodes per entry in a balanced tree). The TODO in the source notes the possibility of a unified data structure to eliminate this overhead.

## Range Queries

`Numeric::Search()` returns an `EntriesFetcher` for the matching range:

```cpp
std::unique_ptr<EntriesFetcher> Numeric::Search(
    const query::NumericPredicate& predicate, bool negate) const;
```

For a non-negated query, the method computes iterator bounds using BTree operations:

```cpp
// Lower bound
entries_range.first = predicate.IsStartInclusive()
    ? btree.lower_bound(predicate.GetStart())
    : btree.upper_bound(predicate.GetStart());

// Upper bound
entries_range.second = predicate.IsEndInclusive()
    ? btree.upper_bound(predicate.GetEnd())
    : btree.lower_bound(predicate.GetEnd());

// Size via SegmentTree (O(log n) instead of iterating)
size_t size = index_->GetCount(start, end, start_inclusive, end_inclusive);
```

The BTree iterators define the range of matching values, and the SegmentTree provides the count without traversal. The `EntriesFetcher` wraps this range for the query engine to iterate.

## EntriesFetcher for Result Iteration

The `EntriesFetcher` / `EntriesFetcherIterator` pair provides the query engine's standard iteration interface (extending `EntriesFetcherBase` / `EntriesFetcherIteratorBase` from `index_base.h`):

```cpp
class EntriesFetcher : public EntriesFetcherBase {
  EntriesRange entries_range_;                        // primary range
  std::optional<EntriesRange> additional_entries_range_; // for negation
  const InternedStringSet* untracked_keys_;           // for negation
  size_t Size() const override;
  std::unique_ptr<EntriesFetcherIteratorBase> Begin() override;
};
```

The iterator walks a two-level structure - the outer level iterates BTree entries (sorted by numeric value), and the inner level iterates the `flat_hash_set` of keys at each value:

```cpp
static bool NextKeys(const EntriesRange& range,
    BTreeNumericIndex::ConstIterator& iter,
    std::optional<InternedStringSet::const_iterator>& keys_iter) {
  while (iter != range.second) {
    if (!keys_iter.has_value()) {
      keys_iter = iter->second.begin();
    } else {
      ++keys_iter.value();
    }
    if (keys_iter.value() != iter->second.end()) return true;
    ++iter;
    keys_iter = std::nullopt;
  }
  return false;
}
```

`Begin()` returns a new `EntriesFetcherIterator` and calls `Next()` to advance to the first result. For negated ranges, the iterator chains: primary range -> additional range -> untracked keys.

## Record Lifecycle

**Add**: `AddRecord()` parses the string value to double via `ParseNumber()` (a local function using `absl::SimpleAtod`, rejecting "nan"). If parsing fails, the key goes to `untracked_keys_` and returns false. If the key already exists, returns `AlreadyExistsError`. Otherwise, inserts into `tracked_keys_` map and calls `index_->Add(key, value)`.

```cpp
auto value = ParseNumber(data);
if (!value.has_value()) {
  untracked_keys_.insert(key);
  return false;
}
tracked_keys_.insert({key, *value});
index_->Add(key, *value);
```

**Modify**: Looks up the existing value in `tracked_keys_`, calls `index_->Modify(key, old_value, new_value)` and updates the tracked value. If the new value is unparseable, falls through to `RemoveRecord` with `DeletionType::kIdentifier`. Returns `NotFoundError` if the key is not tracked.

**Remove**: Calls `index_->Remove(key, value)` and erases from `tracked_keys_`. Deletion type determines untracked key handling.

All mutations hold `index_mutex_`.

## Tracked vs Untracked Keys

The numeric index distinguishes two key categories:

- **Tracked keys** (`tracked_keys_`) - keys with valid numeric values, indexed in the BTree
- **Untracked keys** (`untracked_keys_`) - keys that exist in the schema but have no parseable numeric value (e.g., the field contains a non-numeric string, or NaN)

These sets are mutually exclusive. On `AddRecord`, if the key was previously untracked, it is removed from `untracked_keys_`. Untracked keys are important for negated queries - a query like `NOT [10 20]` must include keys that have no numeric value at all, since they do not fall within the excluded range.

`DeletionType` controls the transition:
- `kRecord` - key is fully deleted from the store, remove from untracked
- `kIdentifier` (or `kNone`) - field removed but key exists, add to untracked

## Negated Range Queries

For negated searches (`negate=true`), the method constructs two BTree ranges representing everything outside the predicate range:

```cpp
// Range 1: (-inf, start) with inverted inclusivity
entries_range.first = btree.begin();
entries_range.second = predicate.IsStartInclusive()
    ? btree.lower_bound(predicate.GetStart())
    : btree.upper_bound(predicate.GetStart());

// Range 2: (end, +inf) with inverted inclusivity
additional_entries_range.first = predicate.IsEndInclusive()
    ? btree.upper_bound(predicate.GetEnd())
    : btree.lower_bound(predicate.GetEnd());
additional_entries_range.second = btree.end();
```

Size is computed as the sum of two SegmentTree range counts (using `numeric_limits<double>::lowest()` and `numeric_limits<double>::max()` as boundaries) plus `untracked_keys_.size()`. The `EntriesFetcherIterator` chains all three sources in sequence.

## Memory Overhead

Per indexed key, the numeric index stores:
- `tracked_keys_`: one `InternedStringHashMap` entry (~48 bytes)
- `BTree`: one entry in the `flat_hash_set` at the value's slot (~40 bytes amortized)
- `SegmentTree`: ~80 bytes per entry (40 bytes/node, ~2 nodes/entry)

Total: approximately 170 bytes per tracked key. The `index_mutex_` is a single `absl::Mutex` protecting all mutations, info queries, and key enumeration (`ForEachTrackedKey`, `ForEachUnTrackedKey`).

`RespondWithInfo()` reports `type=NUMERIC` and `size` (tracked key count) for `FT.INFO`.
