# Contributing to valkey-search

Use when navigating the codebase, adding new index types, adding query features, understanding the code layout, or preparing a PR for valkey-search.

## Code Layout

```
src/
  module_loader.cc          # Entry point - ValkeyModule_OnLoad, command registration
  valkey_search.cc/h        # ValkeySearch singleton - startup, thread pools, cluster
  schema_manager.cc/h       # IndexSchema registry (db_num, name) -> IndexSchema
  index_schema.cc/h         # Core IndexSchema - attributes, mutations, backfill, RDB
  index_schema.proto        # Protobuf schema for index metadata
  rdb_section.proto         # Protobuf schema for RDB persistence
  rdb_serialization.cc/h    # Chunked RDB I/O for large indexes
  attribute.cc/h            # Attribute wrapper (name, alias, index pointer)
  attribute_data_type.cc/h  # Hash vs JSON field extraction
  keyspace_event_manager.cc/h  # Key notification routing to subscribed schemas
  server_events.cc/h        # Valkey server event handlers (cron, fork, load, flush)
  acl.cc/h                  # ACL permission checks for FT.* commands
  metrics.h                 # Metric counter definitions
  valkey_search_options.cc/h   # Module configuration options
  vector_externalizer.cc/h  # Vector data externalization to key content
  version.h                 # Module version, metadata versioning constants

  commands/
    commands.cc/h           # QueryCommand base, command name constants, ACL categories
    ft_create.cc            # FT.CREATE implementation
    ft_create_parser.cc/h   # FT.CREATE argument parsing
    ft_search.cc            # FT.SEARCH implementation
    ft_search_parser.cc/h   # FT.SEARCH argument parsing
    ft_aggregate.cc/h       # FT.AGGREGATE implementation
    ft_aggregate_parser.cc/h   # FT.AGGREGATE argument parsing
    ft_aggregate_exec.cc/h  # FT.AGGREGATE stage execution (records, groups, reducers)
    ft_info.cc              # FT.INFO implementation
    ft_info_parser.cc/h     # FT.INFO argument parsing
    ft_dropindex.cc         # FT.DROPINDEX implementation
    ft_list.cc              # FT._LIST implementation
    ft_debug.cc             # FT._DEBUG implementation
    ft_internal_update.cc   # Internal cluster replication command
    filter_parser.cc/h      # Query string -> predicate tree parser

  indexes/
    index_base.h            # IndexBase abstract class, IndexerType enum
    vector_base.cc/h        # VectorBase - common vector index logic, key tracking
    vector_hnsw.cc/h        # VectorHNSW<T> - HNSW algorithm wrapper
    vector_flat.cc/h        # VectorFlat<T> - brute-force search wrapper
    numeric.cc/h            # Numeric index (btree + segment tree)
    tag.cc/h                # Tag index (Patricia tree)
    text.cc/h               # Text attribute index adapter
    universal_set_fetcher.cc/h  # Yields all keys for negation queries
    text/
      text_index.cc/h       # TextIndex and TextIndexSchema - inverted index
      text_iterator.h       # TextIterator base interface for key+position iteration
      lexer.cc/h            # Text tokenizer (punctuation, stop words, unicode)
      posting.cc/h          # Posting lists (doc -> positions)
      term.cc/h             # Term management
      radix_tree.h          # Rax tree wrapper
      rax_wrapper.cc/h      # Rax C library wrapper with mutex
      rax_target_mutex_pool.h  # Sharded mutex pool for concurrent rax writes
      invasive_ptr.h        # Memory-efficient ref-counted smart pointer
      flat_position_map.cc/h   # Position storage for phrase queries
      proximity.cc/h        # Proximity/phrase matching (SLOP, INORDER)
      orproximity.cc/h      # OR-combined proximity matching
      fuzzy.h               # Fuzzy matching (Levenshtein)
      text_fetcher.cc/h     # Text content fetcher for results
      textinfocmd.cc        # FT._DEBUG TEXTINFO subcommand implementation
      unicode_normalizer.cc/h  # ICU-based unicode normalization

  query/
    search.cc/h             # Main search logic - sync and async
    planner.cc/h            # Pre-filter vs inline filter decision
    predicate.cc/h          # Predicate tree nodes (Tag, Numeric, Text, Composed, Negate)
    fanout.cc/h             # Distributed search fan-out
    fanout_operation_base.h # Template base for all fan-out operations
    cluster_info_fanout_operation.cc/h  # FT.INFO fan-out to all nodes
    primary_info_fanout_operation.cc/h  # FT.INFO fan-out to primaries only
    content_resolution.cc/h # Post-search content fetch and contention check
    response_generator.cc/h # Response formatting

  coordinator/
    server.cc/h             # gRPC server for cross-shard queries
    client.cc/h             # gRPC client for fan-out requests
    client_pool.h           # Lazy gRPC client pool by address
    metadata_manager.cc/h   # Global metadata consistency
    search_converter.cc/h   # Convert between SearchParameters and gRPC messages
    info_converter.cc/h     # Convert FT.INFO data for gRPC
    grpc_suspender.cc/h     # Suspend gRPC during RDB save
    util.h                  # Status conversion, coordinator port derivation
    coordinator.proto       # gRPC service and message definitions

  utils/
    allocator.cc/h          # Fixed-size allocator for vector data
    cancel.cc/h             # Cancellation token for search timeouts
    string_interning.cc/h   # Interned string pointers for memory efficiency
    patricia_tree.h         # Patricia trie (compressed radix tree)
    segment_tree.h          # Segment tree for range count queries
    lru.h                   # LRU cache
    intrusive_list.h        # Intrusive linked list
    intrusive_ref_count.h   # Intrusive reference counting
    inlined_priority_queue.h   # Priority queue with inline storage
    scanner.h               # String scanner utility

  expr/
    expr.cc/h               # Expression compiler and evaluator (for FT.AGGREGATE)
    value.cc/h              # Runtime value type (string, number, nil)
```

## Adding a New Index Type

1. **Define the index class** in `src/indexes/`. Inherit from `IndexBase`. Implement:
   - `AddRecord()`, `RemoveRecord()`, `ModifyRecord()` - CRUD
   - `RespondWithInfo()` - FT.INFO output
   - `SaveIndex()` - RDB persistence (or return OkStatus if rebuilt on load)
   - `ToProto()` - protobuf serialization
   - `GetTrackedKeyCount()`, `GetUnTrackedKeyCount()`, tracking methods
   - `GetMutationWeight()` - relative cost of mutations

2. **Add protobuf definition** in `src/index_schema.proto`. Add new index type to the `Index` message.

3. **Register in FT.CREATE parser** (`src/commands/ft_create_parser.cc`). Add parsing logic for the new field type keyword.

4. **Add to IndexerType enum** in `src/indexes/index_base.h` and the `kIndexerTypeByStr` map.

5. **Wire into IndexSchema** - `src/index_schema.cc` creates index instances during `AddIndex()`.

6. **Add predicate support** if the index supports filtering - add a new predicate class in `src/query/predicate.h`, wire into `FilterParser`.

7. **Write tests** - unit test in `testing/new_index_test.cc`, integration test in `integration/test_new_index.py`.

## Adding a Query Feature

1. **Parser changes** - extend `FilterParser` (`src/commands/filter_parser.cc`) or search parser (`src/commands/ft_search_parser.cc`).

2. **Predicate changes** - if new filter syntax, add/extend predicate in `src/query/predicate.h`.

3. **Evaluator changes** - update `PrefilterEvaluator` and any post-filter evaluators.

4. **gRPC changes** - if the feature affects distributed search, update `coordinator.proto` and the converters in `src/coordinator/`.

5. **FT.AGGREGATE support** - if applicable, add new `Stage` subclass in `src/commands/ft_aggregate_parser.h` and implement `Execute()`.

## Key Patterns

### Error Handling

Uses `absl::Status` and `absl::StatusOr<T>` throughout. Propagate errors with `RETURN_IF_ERROR` macro. Never throw exceptions.

### Thread Safety

- `absl::Mutex` with thread annotations (`ABSL_GUARDED_BY`, `ABSL_LOCKS_EXCLUDED`)
- `TimeSlicedMRMWMutex` for IndexSchema read/write phase separation
- `MainThreadAccessGuard<T>` for data that must only be accessed from main thread
- All search indexes must be safe for concurrent reads during search phase

### Memory Management

- `InternedStringPtr` for keys - pointer-based equality, shared ownership
- `FixedSizeAllocator` for vector data - reduces fragmentation
- `vmsdk::UniqueValkeyString` for Valkey-allocated strings
- `shared_ptr<IndexSchema>` for schema lifetime management

### Testing Pattern

Most tests use a mock `ValkeyModuleCtx` and test at the C++ level. See `testing/common.h` for the test fixture. Integration tests use real Valkey servers via `valkey_search_test_case.py`.

## PR Workflow

1. Fork and branch from `main`
2. Follow existing code style (clang-format enforced)
3. Add unit tests for new code
4. Run full test suite: `./build.sh --run-tests`
5. Run integration tests if touching commands or search paths
6. PR targets `main` branch
7. CI runs: unit tests, ASan, TSan, integration, formatting, spell check

## Documentation (`docs/`)

The `docs/` directory contains user-facing documentation:

- `docs/commands/` - per-command reference (ft.create, ft.search, ft.aggregate, ft.info, ft.dropindex, ft._list)
- `docs/topics/` - conceptual guides (search.md, query, configurables, observables, expressions, data-formats)
- `docs/full-text/` - full-text search documentation
- `docs/examples/` - usage examples
- `COMMANDS.md` (root) - command summary with syntax

## RFCs

Design proposals in `rfc/` directory. Existing RFCs:

- `ft-aggregate.md` - FT.AGGREGATE design
- `text-field.md` - Full-text search design
- `geospatial.md` - Geospatial index design (planned)
- `rdb-format.md` - RDB persistence format
- `TEMPLATE.md` - RFC template

New features should have an RFC before implementation.
