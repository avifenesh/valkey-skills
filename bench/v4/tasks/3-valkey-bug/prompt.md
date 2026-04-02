We built Valkey from the source in this directory and we're seeing issues in production.

After a server restart, `KEYS *` shows duplicate key names. Some keys ended up in wrong hash slots. Replicas fail with duplicate key errors. This happens with AOF in cluster mode when MULTI/EXEC transactions touch keys in different slots.

Separately, after a network partition heals, we get split-brain - two nodes claiming master on the same slots with the same configEpoch. It never resolves.

Stock Valkey 9.0.3 doesn't have these problems. Something is wrong in our source. Find and fix it, compile when done.
