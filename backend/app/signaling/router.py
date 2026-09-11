import asyncio
import json
import logging
from typing import Any, Dict

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, status

from app.auth.firebase_auth import AuthenticationError, verify_firebase_token
from app.calls.manager import CallSessionManager
from app.core.config import get_settings
from app.signaling.dispatcher import MAX_MESSAGE_SIZE_BYTES, MessageDispatcher
from app.signaling.manager import ConnectionManager
from app.signaling.schemas import AuthErrorMessage, AuthSuccessMessage

logger = logging.getLogger(__name__)

router = APIRouter()

# Singletons for connection management, call sessions, and message dispatching
_connection_manager = ConnectionManager()
_call_session_manager = CallSessionManager()
_dispatcher = MessageDispatcher(_connection_manager, _call_session_manager)


def get_connection_manager() -> ConnectionManager:
    """Return the singleton ConnectionManager instance."""
    return _connection_manager


def get_call_session_manager() -> CallSessionManager:
    """Return the singleton CallSessionManager instance."""
    return _call_session_manager


def get_dispatcher() -> MessageDispatcher:
    """Return the singleton MessageDispatcher instance."""
    return _dispatcher


async def _send_auth_error_and_close(
    websocket: WebSocket,
    code: str,
    message: str,
    close_code: int = status.WS_1008_POLICY_VIOLATION,
) -> None:
    """Send an auth.error payload and close the WebSocket."""
    error_payload = AuthErrorMessage(
        type="auth.error",
        code=code,
        message=message,
    ).model_dump()
    try:
        await websocket.send_json(error_payload)
    except Exception:
        pass
    try:
        await websocket.close(code=close_code)
    except Exception:
        pass


@router.websocket("/ws/signaling")
async def signaling_websocket_endpoint(websocket: WebSocket) -> None:
    """Authenticated WebSocket endpoint for 1-to-1 WebRTC signaling."""
    await websocket.accept()

    settings = get_settings()
    timeout = settings.AUTH_TIMEOUT_SECONDS

    # 1. Authentication Handshake Phase
    try:
        raw_auth_message = await asyncio.wait_for(
            websocket.receive_text(),
            timeout=timeout,
        )
    except asyncio.TimeoutError:
        await _send_auth_error_and_close(
            websocket,
            code="AUTH_TIMEOUT",
            message="Authentication timeout",
        )
        return
    except WebSocketDisconnect:
        return
    except Exception:
        await _send_auth_error_and_close(
            websocket,
            code="AUTH_INVALID",
            message="Authentication failed",
        )
        return

    # Check payload size (64 KB DoS protection)
    if len(raw_auth_message.encode("utf-8")) > MAX_MESSAGE_SIZE_BYTES:
        await _send_auth_error_and_close(
            websocket,
            code="AUTH_INVALID",
            message="Authentication failed",
        )
        return

    # Parse JSON
    try:
        auth_data = json.loads(raw_auth_message)
        if not isinstance(auth_data, dict):
            await _send_auth_error_and_close(
                websocket,
                code="AUTH_INVALID",
                message="Authentication failed",
            )
            return
    except Exception:
        await _send_auth_error_and_close(
            websocket,
            code="AUTH_INVALID",
            message="Authentication failed",
        )
        return

    # Check message type
    if auth_data.get("type") != "auth":
        await _send_auth_error_and_close(
            websocket,
            code="AUTH_INVALID",
            message="Authentication failed",
        )
        return

    # Extract token
    token = auth_data.get("token")
    if not token or not isinstance(token, str) or not token.strip():
        await _send_auth_error_and_close(
            websocket,
            code="AUTH_INVALID",
            message="Authentication failed",
        )
        return

    # Verify token with Firebase Admin
    try:
        decoded_token = verify_firebase_token(token)
        user_id = decoded_token.get("uid")
        if not user_id or not isinstance(user_id, str):
            await _send_auth_error_and_close(
                websocket,
                code="AUTH_INVALID",
                message="Authentication failed",
            )
            return
    except AuthenticationError:
        await _send_auth_error_and_close(
            websocket,
            code="AUTH_INVALID",
            message="Authentication failed",
        )
        return
    except Exception:
        # Never leak internal Firebase or server errors
        await _send_auth_error_and_close(
            websocket,
            code="AUTH_INVALID",
            message="Authentication failed",
        )
        return

    # Register authenticated connection
    await _connection_manager.connect(user_id, websocket)

    # Send auth.success response
    success_payload = AuthSuccessMessage(
        type="auth.success",
        userId=user_id,
    ).model_dump()
    try:
        await websocket.send_json(success_payload)
    except Exception:
        await _connection_manager.disconnect(user_id, websocket)
        return

    # 2. Post-Authentication Signaling Loop
    try:
        while True:
            raw_msg = await websocket.receive_text()
            response = await _dispatcher.dispatch(user_id, raw_msg)
            if response is not None:
                await websocket.send_json(response)
    except WebSocketDisconnect:
        pass
    except Exception:
        logger.exception("Unexpected error in signaling loop for user=%s", user_id)
    finally:
        # Clean up on disconnect:
        # Only clean up active calls and notify peer if this socket is still the active socket
        if _connection_manager.get_connection(user_id) is websocket:
            await _dispatcher.handle_disconnect(user_id)
            await _connection_manager.disconnect(user_id, websocket)
        else:
            await _connection_manager.disconnect(user_id, websocket)
