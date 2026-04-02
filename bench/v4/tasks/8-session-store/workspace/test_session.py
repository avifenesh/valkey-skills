"""Tests for the SessionManager with per-field independent expiration."""

import time

import pytest
import valkey

from session_manager import SessionManager


@pytest.fixture
def manager():
    """Create a SessionManager with very short TTLs for testing expiry."""
    short_ttls = {
        "auth_token": 10,        # 10 seconds (long enough to survive non-expiry tests)
        "csrf_token": 3,         # 3 seconds (short enough to expire in test)
        "refresh_token": 10,     # 10 seconds
        "user_profile": None,    # No expiry
        "last_activity": 10,     # 10 seconds
    }
    mgr = SessionManager(host="localhost", port=6508, field_ttls=short_ttls)
    yield mgr
    # Cleanup: flush test data
    mgr.client.flushdb()


class TestCreateSession:
    def test_create_session(self, manager):
        """Creating a session should return a session_id and populate all fields."""
        session_id = manager.create_session("user_42")
        assert session_id is not None
        assert len(session_id) > 0

        key = manager._session_key(session_id)
        # All expected fields should exist
        for field in ["auth_token", "csrf_token", "refresh_token", "user_profile", "last_activity"]:
            val = manager.client.execute_command("HGET", key, field)
            assert val is not None, f"Field '{field}' should exist after create_session"


class TestFieldTTLIndependence:
    def test_field_ttl_independence(self, manager):
        """Different fields should have different TTLs."""
        session_id = manager.create_session("user_42")
        ttls = manager.get_field_ttls(session_id)

        # auth_token should have TTL around 10
        assert 1 <= ttls["auth_token"] <= 10, f"auth_token TTL should be ~10, got {ttls['auth_token']}"

        # csrf_token should have TTL around 3
        assert 1 <= ttls["csrf_token"] <= 3, f"csrf_token TTL should be ~3, got {ttls['csrf_token']}"

        # user_profile should have no TTL (-1)
        assert ttls["user_profile"] == -1, f"user_profile should have no TTL, got {ttls['user_profile']}"

        # auth_token TTL should be greater than csrf_token TTL
        assert ttls["auth_token"] > ttls["csrf_token"], "auth_token should have longer TTL than csrf_token"


class TestGetFieldWithRefresh:
    def test_get_field_with_refresh(self, manager):
        """Getting a field with refresh=True should reset its TTL."""
        session_id = manager.create_session("user_42")

        # Wait 2 seconds so TTL decreases
        time.sleep(2)

        # Get csrf_token (3s TTL) with refresh - should reset to 3s
        value = manager.get_field(session_id, "csrf_token", refresh=True)
        assert value is not None, "csrf_token should still exist after 2 seconds"

        # TTL should have been refreshed back to around 3s
        ttls = manager.get_field_ttls(session_id)
        assert ttls["csrf_token"] >= 2, f"csrf_token TTL should be refreshed, got {ttls['csrf_token']}"

    def test_get_field_without_refresh(self, manager):
        """Getting a field without refresh should not change its TTL."""
        session_id = manager.create_session("user_42")
        ttls_before = manager.get_field_ttls(session_id)

        time.sleep(1)

        # Get without refresh
        manager.get_field(session_id, "auth_token", refresh=False)
        ttls_after = manager.get_field_ttls(session_id)

        # TTL should have decreased, not reset
        assert ttls_after["auth_token"] < ttls_before["auth_token"], "TTL should decrease without refresh"


class TestFieldExpiry:
    def test_field_expiry(self, manager):
        """Fields with short TTL should expire independently while others survive."""
        session_id = manager.create_session("user_42")

        # Wait for csrf_token (3s) to expire
        time.sleep(4)

        # csrf_token should be gone
        csrf_val = manager.get_field(session_id, "csrf_token")
        assert csrf_val is None, "csrf_token should have expired after 4 seconds"

        # auth_token (10s) should still exist
        auth_val = manager.get_field(session_id, "auth_token")
        assert auth_val is not None, "auth_token should still exist after 4 seconds"

        # user_profile (no TTL) should still exist
        profile_val = manager.get_field(session_id, "user_profile")
        assert profile_val is not None, "user_profile should never expire"


class TestRotateToken:
    def test_rotate_token(self, manager):
        """rotate_token should update an existing field's value."""
        session_id = manager.create_session("user_42")

        old_val = manager.get_field(session_id, "auth_token")
        result = manager.rotate_token(session_id, "auth_token", "new_token_value")
        assert result is True, "rotate_token should return True for existing field"

        new_val = manager.get_field(session_id, "auth_token")
        assert new_val == "new_token_value", "Field value should be updated"
        assert new_val != old_val, "Value should have changed"

    def test_rotate_nonexistent(self, manager):
        """rotate_token should return False for a field that does not exist."""
        session_id = manager.create_session("user_42")

        result = manager.rotate_token(session_id, "nonexistent_field", "some_value")
        assert result is False, "rotate_token should return False for non-existent field"

        # The field should NOT have been created
        val = manager.get_field(session_id, "nonexistent_field")
        assert val is None, "Non-existent field should not be created by rotate_token"


class TestSessionHealth:
    def test_session_health(self, manager):
        """get_session_health should show active, expired, and permanent fields."""
        session_id = manager.create_session("user_42")

        # Wait for csrf_token (3s) to expire
        time.sleep(4)

        health = manager.get_session_health(session_id)

        assert health["csrf_token"] == "expired", f"csrf_token should be expired, got {health['csrf_token']}"
        assert health["auth_token"] == "active", f"auth_token should be active, got {health['auth_token']}"
        assert health["user_profile"] == "permanent", f"user_profile should be permanent, got {health['user_profile']}"


class TestDestroySession:
    def test_destroy_session(self, manager):
        """destroy_session should delete the entire session hash."""
        session_id = manager.create_session("user_42")

        # Verify session exists
        val = manager.get_field(session_id, "auth_token")
        assert val is not None

        result = manager.destroy_session(session_id)
        assert result is True, "destroy_session should return True for existing session"

        # All fields should be gone
        val = manager.get_field(session_id, "auth_token")
        assert val is None, "Fields should not exist after destroy"
        val = manager.get_field(session_id, "user_profile")
        assert val is None, "Even permanent fields should be gone after destroy"

    def test_destroy_nonexistent(self, manager):
        """destroy_session should return False for a non-existent session."""
        result = manager.destroy_session("nonexistent_session_id")
        assert result is False, "destroy_session should return False for non-existent session"
