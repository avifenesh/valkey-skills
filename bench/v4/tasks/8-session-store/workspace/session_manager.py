"""Session management library with per-field independent expiration using Valkey 9.0+."""

import uuid
from typing import Optional

import valkey


# Default TTLs for session fields (in seconds)
FIELD_TTLS = {
    "auth_token": 3600,       # 1 hour
    "csrf_token": 900,        # 15 minutes
    "refresh_token": 86400,   # 24 hours
    "user_profile": None,     # No expiry (until explicit logout)
    "last_activity": 1800,    # 30 minutes
}


class SessionManager:
    """Manages user sessions stored as Valkey hashes with per-field TTLs."""

    def __init__(self, host: str = "localhost", port: int = 6508, field_ttls: dict | None = None):
        self.client = valkey.Valkey(host=host, port=port, decode_responses=True)
        self.field_ttls = field_ttls or FIELD_TTLS

    def _session_key(self, session_id: str) -> str:
        return f"session:{session_id}"

    def create_session(self, user_id: str) -> str:
        """Create a new session with all standard fields. Returns session_id."""
        raise NotImplementedError

    def get_field(self, session_id: str, field: str, refresh: bool = False) -> Optional[str]:
        """Get a single field value. If refresh=True, reset the field's TTL."""
        raise NotImplementedError

    def get_field_ttls(self, session_id: str) -> dict[str, int]:
        """Return {field_name: remaining_seconds} for all fields in the session.

        Returns -1 for fields with no TTL (permanent).
        Returns -2 for fields that do not exist (expired or never set).
        """
        raise NotImplementedError

    def rotate_token(self, session_id: str, field: str, new_value: str) -> bool:
        """Update a field only if it already exists (for token rotation).

        Returns True if the field was updated, False if it did not exist.
        """
        raise NotImplementedError

    def get_session_health(self, session_id: str) -> dict[str, str]:
        """Return {field_name: status} where status is 'active', 'expired', or 'permanent'.

        Checks all expected fields against their current state.
        """
        raise NotImplementedError

    def destroy_session(self, session_id: str) -> bool:
        """Delete the entire session. Returns True if it existed."""
        raise NotImplementedError
