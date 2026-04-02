We need a JSON.MERGE command added to valkey-json. It should merge a JSON patch into an existing document following RFC 7386 (JSON Merge Patch) semantics.

`JSON.MERGE key path json_patch`

Behavior:
- If the target is an object and the patch is an object, merge recursively
- New fields in the patch get added
- Existing fields get updated
- Fields set to null in the patch get deleted from the target
- If the target or patch is not an object, the patch replaces the target
- Returns OK on success
- Returns error if key doesn't exist or path is invalid

The valkey-json source is in `valkey-json/`. Look at how existing commands are implemented. Must compile cleanly - check `build.sh` for the build process.
