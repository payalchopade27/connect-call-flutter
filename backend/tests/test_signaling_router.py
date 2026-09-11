from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.auth.firebase_auth import AuthenticationError
from app.core.config import Settings
from app.main import app
from app.signaling.router import get_connection_manager

client = TestClient(app)


# ==============================================================================
# Health Check Verification
# ==============================================================================

def test_health_check_still_works():
    """15: /health continues to return {"status": "ok"} with signaling router mounted."""
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


# ==============================================================================
# WebSocket Authentication Handshake Tests
# ==============================================================================

def test_valid_auth_message_succeeds_and_registers():
    """1, 2, 3, 10, 11: Valid auth message returns auth.success with verified UID,
    registers in ConnectionManager, and disconnect unregisters it.
    """
    user_id = "verified_firebase_user_100"
    manager = get_connection_manager()

    with patch("app.signaling.router.verify_firebase_token", return_value={"uid": user_id}):
        with client.websocket_connect("/ws/signaling") as ws:
            # Send valid auth message
            ws.send_json({"type": "auth", "token": "valid_mock_token"})

            # Verify response
            response = ws.receive_json()
            assert response == {
                "type": "auth.success",
                "userId": user_id,
            }

            # Verify user is registered in ConnectionManager
            assert manager.is_connected(user_id)
            assert manager.get_connection(user_id) is not None

        # After exiting context (disconnecting), user should be removed
        assert not manager.is_connected(user_id)


def test_cannot_establish_identity_with_client_supplied_user_id():
    """14: Client-supplied userId must be ignored; only server-verified UID is trusted."""
    hacker_supplied_id = "fake_admin_uid"
    real_verified_uid = "authentic_firebase_uid_999"
    manager = get_connection_manager()

    with patch("app.signaling.router.verify_firebase_token", return_value={"uid": real_verified_uid}):
        with client.websocket_connect("/ws/signaling") as ws:
            # Client maliciously attempts to inject its own userId
            ws.send_json({
                "type": "auth",
                "token": "valid_token",
                "userId": hacker_supplied_id,
                "fromUserId": hacker_supplied_id,
            })

            response = ws.receive_json()
            # Verified server UID must be returned
            assert response["type"] == "auth.success"
            assert response["userId"] == real_verified_uid

            # Real UID must be registered, hacker UID must NOT be registered
            assert manager.is_connected(real_verified_uid)
            assert not manager.is_connected(hacker_supplied_id)


def test_invalid_token_returns_auth_error_and_closes():
    """4: Invalid token returns generic auth.error and closes connection."""
    with patch(
        "app.signaling.router.verify_firebase_token",
        side_effect=AuthenticationError("Invalid signature", code="AUTH_INVALID"),
    ):
        with client.websocket_connect("/ws/signaling") as ws:
            ws.send_json({"type": "auth", "token": "bad_token"})

            response = ws.receive_json()
            assert response == {
                "type": "auth.error",
                "code": "AUTH_INVALID",
                "message": "Authentication failed",
            }

            with pytest.raises(WebSocketDisconnect):
                ws.receive_text()


def test_missing_token_returns_auth_error_and_closes():
    """5: Missing token in auth message returns auth.error and closes."""
    with client.websocket_connect("/ws/signaling") as ws:
        ws.send_json({"type": "auth"})

        response = ws.receive_json()
        assert response == {
            "type": "auth.error",
            "code": "AUTH_INVALID",
            "message": "Authentication failed",
        }

        with pytest.raises(WebSocketDisconnect):
            ws.receive_text()


def test_empty_token_returns_auth_error_and_closes():
    """6: Empty/whitespace token returns auth.error and closes."""
    with client.websocket_connect("/ws/signaling") as ws:
        ws.send_json({"type": "auth", "token": "   "})

        response = ws.receive_json()
        assert response == {
            "type": "auth.error",
            "code": "AUTH_INVALID",
            "message": "Authentication failed",
        }

        with pytest.raises(WebSocketDisconnect):
            ws.receive_text()


def test_malformed_json_returns_auth_error_and_closes():
    """7: Malformed non-JSON first message returns auth.error and closes."""
    with client.websocket_connect("/ws/signaling") as ws:
        ws.send_text("THIS_IS_NOT_VALID_JSON{")

        response = ws.receive_json()
        assert response == {
            "type": "auth.error",
            "code": "AUTH_INVALID",
            "message": "Authentication failed",
        }

        with pytest.raises(WebSocketDisconnect):
            ws.receive_text()


def test_first_message_not_auth_returns_auth_error_and_closes():
    """8: First message with type != 'auth' returns auth.error and closes."""
    with client.websocket_connect("/ws/signaling") as ws:
        ws.send_json({"type": "call.invite", "to": "user_b"})

        response = ws.receive_json()
        assert response == {
            "type": "auth.error",
            "code": "AUTH_INVALID",
            "message": "Authentication failed",
        }

        with pytest.raises(WebSocketDisconnect):
            ws.receive_text()


def test_internal_firebase_exception_details_not_exposed():
    """13: Raw internal exception messages or stack traces are never sent to client."""
    internal_leak = "FATAL: ServiceAccountKey permission denied at /etc/secrets"
    with patch(
        "app.signaling.router.verify_firebase_token",
        side_effect=Exception(internal_leak),
    ):
        with client.websocket_connect("/ws/signaling") as ws:
            ws.send_json({"type": "auth", "token": "some_token"})

            response = ws.receive_json()
            assert response == {
                "type": "auth.error",
                "code": "AUTH_INVALID",
                "message": "Authentication failed",
            }
            # Verify internal leak is nowhere in the client payload
            assert internal_leak not in str(response)


def test_authentication_timeout():
    """9: Server sends AUTH_TIMEOUT and closes socket if no auth message is sent within timeout."""
    fast_timeout_settings = Settings(AUTH_TIMEOUT_SECONDS=0.05)

    with patch("app.signaling.router.get_settings", return_value=fast_timeout_settings):
        with client.websocket_connect("/ws/signaling") as ws:
            # Client connects but stays silent without sending any message
            response = ws.receive_json()
            assert response == {
                "type": "auth.error",
                "code": "AUTH_TIMEOUT",
                "message": "Authentication timeout",
            }

            with pytest.raises(WebSocketDisconnect):
                ws.receive_text()


def test_stale_disconnect_cannot_remove_newer_connection():
    """12: Replacing a connection with a newer socket ensures stale disconnect of the older
    socket does not evict the newer socket from ConnectionManager.
    """
    user_id = "user_reconnecting_test"
    manager = get_connection_manager()

    with patch("app.signaling.router.verify_firebase_token", return_value={"uid": user_id}):
        # First connection establishes
        ws1 = client.websocket_connect("/ws/signaling")
        ws1.__enter__()
        ws1.send_json({"type": "auth", "token": "token1"})
        res1 = ws1.receive_json()
        assert res1["type"] == "auth.success"

        first_registered_socket = manager.get_connection(user_id)
        assert first_registered_socket is not None

        # Second connection establishes for the same user
        ws2 = client.websocket_connect("/ws/signaling")
        ws2.__enter__()
        ws2.send_json({"type": "auth", "token": "token2"})
        res2 = ws2.receive_json()
        assert res2["type"] == "auth.success"

        second_registered_socket = manager.get_connection(user_id)
        assert second_registered_socket is not None
        assert second_registered_socket is not first_registered_socket

        # Disconnect the first connection (simulate older socket terminating)
        ws1.__exit__(None, None, None)

        # The user MUST still be registered with the second socket!
        assert manager.is_connected(user_id)
        assert manager.get_connection(user_id) is second_registered_socket

        # Clean up second connection
        ws2.__exit__(None, None, None)
        assert not manager.is_connected(user_id)
