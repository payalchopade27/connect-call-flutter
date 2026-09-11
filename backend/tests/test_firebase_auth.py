from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient
# pyrefly: ignore [missing-import]
from firebase_admin import auth

from app.auth.firebase_auth import (
    AuthenticationError,
    FirebaseConfigError,
    initialize_firebase_admin,
    verify_firebase_token,
)
from app.core.config import Settings
from app.main import app

client = TestClient(app)


# ==============================================================================
# 1. Health Endpoint Tests (Does NOT require Firebase configuration)
# ==============================================================================

def test_health_check_returns_ok():
    """Verify GET /health returns {"status": "ok"} without Firebase credentials."""
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


# ==============================================================================
# 2. Token Verification Unit Tests (Mocked Firebase Admin)
# ==============================================================================

def test_verify_token_success():
    """Valid token should return the decoded claims containing the verified UID."""
    fake_token = "valid_firebase_id_token"
    expected_claims = {
        "uid": "test_firebase_uid_12345",
        "email": "user@connectcall.io",
        "auth_time": 1700000000,
    }

    with patch("app.auth.firebase_auth.initialize_firebase_admin"), \
         patch("app.auth.firebase_auth.auth.verify_id_token", return_value=expected_claims) as mock_verify:
        claims = verify_firebase_token(fake_token)

        mock_verify.assert_called_once_with(fake_token)
        assert claims["uid"] == "test_firebase_uid_12345"
        assert claims["email"] == "user@connectcall.io"


def test_verify_token_empty_or_whitespace():
    """Empty or whitespace token must raise AuthenticationError."""
    with pytest.raises(AuthenticationError) as exc_info:
        verify_firebase_token("")
    assert exc_info.value.code == "AUTH_INVALID"

    with pytest.raises(AuthenticationError) as exc_info:
        verify_firebase_token("   ")
    assert exc_info.value.code == "AUTH_INVALID"


def test_verify_token_invalid():
    """Invalid token signature must raise AuthenticationError with code AUTH_INVALID."""
    with patch("app.auth.firebase_auth.initialize_firebase_admin"), \
         patch("app.auth.firebase_auth.auth.verify_id_token", side_effect=auth.InvalidIdTokenError("Invalid token")):
        with pytest.raises(AuthenticationError) as exc_info:
            verify_firebase_token("bad_token")
        assert exc_info.value.code == "AUTH_INVALID"


def test_verify_token_expired():
    """Expired token must raise AuthenticationError with code AUTH_EXPIRED."""
    with patch("app.auth.firebase_auth.initialize_firebase_admin"), \
         patch("app.auth.firebase_auth.auth.verify_id_token", side_effect=auth.ExpiredIdTokenError("Expired", "cause")):
        with pytest.raises(AuthenticationError) as exc_info:
            verify_firebase_token("expired_token")
        assert exc_info.value.code == "AUTH_EXPIRED"


def test_verify_token_revoked():
    """Revoked token must raise AuthenticationError with code AUTH_REVOKED."""
    with patch("app.auth.firebase_auth.initialize_firebase_admin"), \
         patch("app.auth.firebase_auth.auth.verify_id_token", side_effect=auth.RevokedIdTokenError("Revoked")):
        with pytest.raises(AuthenticationError) as exc_info:
            verify_firebase_token("revoked_token")
        assert exc_info.value.code == "AUTH_REVOKED"


def test_verify_token_missing_uid():
    """Token missing the 'uid' field must raise AuthenticationError."""
    with patch("app.auth.firebase_auth.initialize_firebase_admin"), \
         patch("app.auth.firebase_auth.auth.verify_id_token", return_value={"email": "no_uid@test.com"}):
        with pytest.raises(AuthenticationError) as exc_info:
            verify_firebase_token("token_without_uid")
        assert exc_info.value.code == "AUTH_INVALID"


# ==============================================================================
# 3. Firebase Initialization Unit Tests
# ==============================================================================

def test_initialize_firebase_admin_already_initialized():
    """If default app already exists in _apps, reuse it without re-initializing."""
    mock_app = MagicMock()
    with patch("app.auth.firebase_auth.firebase_admin._apps", {"[DEFAULT]": mock_app}), \
         patch("app.auth.firebase_auth.firebase_admin.get_app", return_value=mock_app), \
         patch("app.auth.firebase_auth.firebase_admin.initialize_app") as mock_init:
        app_instance = initialize_firebase_admin()
        assert app_instance == mock_app
        mock_init.assert_not_called()


def test_initialize_firebase_missing_path():
    """If FIREBASE_CREDENTIALS_PATH is empty, raise FirebaseConfigError."""
    dummy_settings = Settings(FIREBASE_CREDENTIALS_PATH="")
    with patch("app.auth.firebase_auth.firebase_admin._apps", {}), \
         patch("app.auth.firebase_auth.get_settings", return_value=dummy_settings):
        with pytest.raises(FirebaseConfigError) as exc_info:
            initialize_firebase_admin()
        assert "FIREBASE_CREDENTIALS_PATH is not set" in str(exc_info.value)


def test_initialize_firebase_file_not_found():
    """If credentials file does not exist, raise FirebaseConfigError."""
    dummy_settings = Settings(FIREBASE_CREDENTIALS_PATH="non_existent_service_account.json")
    with patch("app.auth.firebase_auth.firebase_admin._apps", {}), \
         patch("app.auth.firebase_auth.get_settings", return_value=dummy_settings):
        with pytest.raises(FirebaseConfigError) as exc_info:
            initialize_firebase_admin()
        assert "not found" in str(exc_info.value)
