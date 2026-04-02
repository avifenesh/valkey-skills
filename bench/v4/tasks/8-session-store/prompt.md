I'm building a session management layer for our web app in Python and I need help getting it right. The tricky part is that different fields within a session need to expire at different times.

Here's the setup: each session is a single Valkey hash, and the fields inside it have their own independent TTLs:

- `auth_token`: expires in 3600 seconds (1 hour)
- `csrf_token`: expires in 900 seconds (15 minutes)
- `refresh_token`: expires in 86400 seconds (24 hours)
- `user_profile`: never expires (stays until explicit logout)
- `last_activity`: expires in 1800 seconds (30 minutes)

I also need to be able to:
- Optionally refresh a field's TTL when reading it (in the same operation)
- Check remaining TTL on individual fields
- Do conditional field updates - only set if the field already exists (for token rotation)
- Handle the case where some fields have expired while others haven't

I do NOT want to use separate keys for each field - that defeats the purpose of hash-based sessions. And I can't just EXPIRE the whole hash since each field needs its own TTL. We're running Valkey 9.0+ so per-field hash expiration is available.

Please build this as a `SessionManager` class in `session_manager.py` with this API:

- `create_session(user_id: str) -> str` - creates session, returns session_id
- `get_field(session_id: str, field: str, refresh: bool = False) -> Optional[str]` - get field value, optionally refreshing its TTL
- `get_field_ttls(session_id: str) -> dict[str, int]` - returns {field: remaining_seconds}
- `rotate_token(session_id: str, field: str, new_value: str) -> bool` - update only if field exists
- `get_session_health(session_id: str) -> dict[str, str]` - returns {field: "active"/"expired"/"permanent"}
- `destroy_session(session_id: str) -> bool` - delete the session

Also write tests in `test_session.py` using pytest.

Stack details:
- Use the `valkey` Python package (pip install valkey)
- Connect to Valkey on localhost:6508
- Use `execute_command()` for any commands not in the base client API
