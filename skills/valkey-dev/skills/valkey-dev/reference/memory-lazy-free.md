# Lazy Freeing

Use when you need to understand how Valkey avoids blocking the main thread when deleting large objects.

Standard lazy free via BIO thread - UNLINK removes key synchronously, queues value for background deallocation. Threshold is 64 elements (`LAZYFREE_THRESHOLD`). `lazyfreeGetFreeEffort()` estimates cost per object type.

## Valkey-Specific Changes

- **All lazyfree defaults are `yes`**: In Valkey, all five lazyfree configs default to `yes` (Redis defaults are `no`):
  - `lazyfree-lazy-eviction yes`
  - `lazyfree-lazy-expire yes`
  - `lazyfree-lazy-server-del yes`
  - `lazyfree-lazy-user-del yes`
  - `lazyfree-lazy-user-flush yes`

Source: `src/lazyfree.c`
