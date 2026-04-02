# Session Management Library

Build a Python session management library for a web application with these requirements:

## Business Requirements

- Sessions are stored as hashes in Valkey (one hash per session)
- Different session fields must have DIFFERENT expiration times:
  - `auth_token`: expires in 3600 seconds (1 hour)
  - `csrf_token`: expires in 900 seconds (15 minutes)
  - `refresh_token`: expires in 86400 seconds (24 hours)
  - `user_profile`: never expires (until explicit logout)
  - `last_activity`: expires in 1800 seconds (30 minutes)
- Reading a field should optionally refresh its TTL in the same operation
- Must be able to check remaining TTL on individual fields
- Must support conditional field updates (only set if field already exists, for token rotation)
- Must handle the case where some fields have expired while others haven't

## Technical Requirements

- Use the `valkey` Python package (pip install valkey)
- Connect to Valkey on localhost:6508
- Use `execute_command()` for any commands not in the base client API
- Implement as a `SessionManager` class in `session_manager.py`
- Write tests in `test_session.py` using pytest

## API

- `create_session(user_id: str) -> str` - creates session, returns session_id
- `get_field(session_id: str, field: str, refresh: bool = False) -> Optional[str]` - get field value, optionally refreshing its TTL
- `get_field_ttls(session_id: str) -> dict[str, int]` - returns {field: remaining_seconds}
- `rotate_token(session_id: str, field: str, new_value: str) -> bool` - update only if field exists
- `get_session_health(session_id: str) -> dict[str, str]` - returns {field: "active"/"expired"/"permanent"}
- `destroy_session(session_id: str) -> bool` - delete the session

## Important

- Do NOT use separate keys for each field (defeats the purpose of hash-based sessions)
- Do NOT use EXPIRE on the whole hash (all fields must have independent TTLs)
- Valkey 9.0+ is running on the target server
