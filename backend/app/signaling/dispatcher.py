"""Message dispatcher for ConnectCall signaling.

Handles all post-authentication WebSocket signaling messages:
- call.invite, call.accept, call.reject, call.end
- webrtc.offer, webrtc.answer, webrtc.ice

Architectural Rules:
1. The sender identity is ALWAYS the authenticated Firebase UID passed in from the
   WebSocket router. Client-supplied fromUserId / callerId / senderId are ignored.
2. The dispatcher does not hold WebSocket references. It uses ConnectionManager
   for message delivery and CallSessionManager for call state.
3. All errors are caught and translated into safe call.error responses.
   No Python exceptions, Firebase details, or stack traces are ever exposed.
"""

import json
import logging
from typing import Any, Dict, Optional

from pydantic import ValidationError

from app.calls.exceptions import (
    CallAlreadyExistsError,
    CallNotFoundError,
    CallSessionError,
    InvalidCallError,
    InvalidStateTransitionError,
    UserBusyError,
    UserNotParticipantError,
)
from app.calls.manager import CallSessionManager
from app.calls.models import CallState
from app.signaling.manager import ConnectionManager
from app.signaling.schemas import (
    CallInvitePayload,
    SignalingEnvelope,
    WebRTCIcePayload,
    WebRTCSdpPayload,
)

logger = logging.getLogger(__name__)

# Supported post-auth signaling message types
CALL_CONTROL_TYPES = {"call.invite", "call.accept", "call.reject", "call.end"}
WEBRTC_TYPES = {"webrtc.offer", "webrtc.answer", "webrtc.ice"}
ALL_SIGNALING_TYPES = CALL_CONTROL_TYPES | WEBRTC_TYPES

# Maximum permitted size for any signaling message (64 KB)
MAX_MESSAGE_SIZE_BYTES: int = 65536


def _build_error(call_id: str, code: str, message: str) -> Dict[str, Any]:
    """Build a standard call.error response dict."""
    return {
        "type": "call.error",
        "callId": call_id,
        "payload": {
            "code": code,
            "message": message,
        },
    }


def _build_outgoing(
    msg_type: str,
    call_id: str,
    from_uid: str,
    to_uid: str,
    payload: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Build an outgoing message envelope with server-stamped fromUserId."""
    out: Dict[str, Any] = {
        "type": msg_type,
        "callId": call_id,
        "fromUserId": from_uid,
        "toUserId": to_uid,
        "payload": payload if payload is not None else {},
    }
    return out


class MessageDispatcher:
    """Dispatches incoming WebSocket signaling messages.

    Handles message validation, call lifecycle orchestration (via CallSessionManager),
    WebRTC SDP/ICE relaying, error responses, and disconnect cleanup.
    """

    def __init__(
        self,
        connection_manager: ConnectionManager,
        call_session_manager: CallSessionManager,
    ) -> None:
        self._conn_mgr = connection_manager
        self._call_mgr = call_session_manager

    async def dispatch(
        self,
        sender_uid: str,
        raw_message: str,
    ) -> Optional[Dict[str, Any]]:
        """Parse, validate, and dispatch a signaling message.

        Args:
            sender_uid: Authenticated Firebase UID of the sending user.
            raw_message: Raw JSON string from the WebSocket.

        Returns:
            A dict to send back to the sender (error response), or None if
            the message was handled successfully and any responses were
            already routed to the appropriate recipients.
        """
        # 0. Enforce maximum message size (64 KB)
        if len(raw_message.encode("utf-8")) > MAX_MESSAGE_SIZE_BYTES:
            return _build_error(
                "",
                "INVALID_MESSAGE",
                f"Message exceeds maximum allowed size of {MAX_MESSAGE_SIZE_BYTES} bytes",
            )

        # 1. Parse JSON
        try:
            data = json.loads(raw_message)
            if not isinstance(data, dict):
                return _build_error("", "INVALID_MESSAGE", "Message must be a JSON object")
        except (json.JSONDecodeError, ValueError):
            return _build_error("", "INVALID_MESSAGE", "Invalid JSON")

        # 2. Extract type
        msg_type = data.get("type")
        if not msg_type or not isinstance(msg_type, str):
            return _build_error(
                data.get("callId", ""),
                "INVALID_MESSAGE",
                "Missing or invalid message type",
            )

        # 3. Check if supported
        if msg_type not in ALL_SIGNALING_TYPES:
            return _build_error(
                data.get("callId", ""),
                "UNSUPPORTED_MESSAGE",
                f"Unsupported message type: {msg_type}",
            )

        # 4. Validate envelope
        try:
            envelope = SignalingEnvelope(**data)
        except (ValidationError, Exception):
            return _build_error(
                data.get("callId", ""),
                "INVALID_MESSAGE",
                "Invalid message format: callId and toUserId are required",
            )

        # 5. Dispatch by type
        try:
            if msg_type == "call.invite":
                return await self._handle_call_invite(sender_uid, envelope)
            elif msg_type == "call.accept":
                return await self._handle_call_accept(sender_uid, envelope)
            elif msg_type == "call.reject":
                return await self._handle_call_reject(sender_uid, envelope)
            elif msg_type == "call.end":
                return await self._handle_call_end(sender_uid, envelope)
            elif msg_type in WEBRTC_TYPES:
                return await self._handle_webrtc_relay(sender_uid, envelope)
        except Exception:
            # Catch-all safety net — never expose internal errors
            logger.exception("Unexpected error dispatching message type=%s", msg_type)
            return _build_error(
                envelope.callId,
                "INVALID_MESSAGE",
                "An internal error occurred",
            )

        return None

    # ==========================================================================
    # Call Control Handlers
    # ==========================================================================

    async def _handle_call_invite(
        self,
        sender_uid: str,
        envelope: SignalingEnvelope,
    ) -> Optional[Dict[str, Any]]:
        """Handle call.invite: create session and route invite to receiver."""
        call_id = envelope.callId
        receiver_uid = envelope.toUserId

        # Validate payload — must contain valid callType
        try:
            invite_payload = CallInvitePayload(**envelope.payload)
        except (ValidationError, Exception):
            return _build_error(call_id, "INVALID_CALL_TYPE", "Invalid or missing callType")

        # Self-call check
        if sender_uid == receiver_uid:
            return _build_error(call_id, "INVALID_TARGET", "Cannot call yourself")

        # Check receiver is online
        if not self._conn_mgr.is_connected(receiver_uid):
            return _build_error(call_id, "USER_OFFLINE", "User is offline")

        # Create call session
        try:
            await self._call_mgr.create_call(
                call_id=call_id,
                caller_id=sender_uid,
                receiver_id=receiver_uid,
                call_type=invite_payload.callType,
            )
        except CallAlreadyExistsError:
            return _build_error(call_id, "INVALID_CALL_ID", "Call ID already exists")
        except UserBusyError as exc:
            # Determine which user is busy for the correct error code
            if exc.user_id == sender_uid:
                return _build_error(call_id, "USER_BUSY", "You are already in a call")
            return _build_error(call_id, "USER_BUSY", "User is busy")
        except InvalidCallError:
            return _build_error(call_id, "INVALID_MESSAGE", "Invalid call parameters")

        # Route invite to receiver
        outgoing = _build_outgoing(
            "call.invite",
            call_id,
            sender_uid,
            receiver_uid,
            {"callType": invite_payload.callType},
        )
        sent = await self._conn_mgr.send_to_user(receiver_uid, outgoing)

        if not sent:
            # Receiver went offline between our check and the send — clean up
            try:
                await self._call_mgr.transition(call_id, CallState.ENDED)
            except CallSessionError:
                pass
            return _build_error(call_id, "USER_OFFLINE", "User is offline")

        return None  # Success — no response back to sender

    async def _handle_call_accept(
        self,
        sender_uid: str,
        envelope: SignalingEnvelope,
    ) -> Optional[Dict[str, Any]]:
        """Handle call.accept: transition ringing→active and notify caller."""
        call_id = envelope.callId
        target_uid = envelope.toUserId

        # Look up call
        session = self._call_mgr.get_call(call_id)
        if session is None:
            return _build_error(call_id, "CALL_NOT_FOUND", "Call not found")

        # Only the receiver can accept
        if sender_uid != session.receiver_id:
            return _build_error(call_id, "NOT_PARTICIPANT", "Only the receiver can accept")

        # Target must be the caller
        if target_uid != session.caller_id:
            return _build_error(call_id, "INVALID_TARGET", "Invalid target user")

        # Transition state
        try:
            await self._call_mgr.transition(call_id, CallState.ACTIVE)
        except InvalidStateTransitionError:
            return _build_error(call_id, "INVALID_STATE", "Call is not in ringing state")
        except CallNotFoundError:
            return _build_error(call_id, "CALL_NOT_FOUND", "Call not found")

        # Route to caller
        outgoing = _build_outgoing("call.accept", call_id, sender_uid, target_uid)
        await self._conn_mgr.send_to_user(target_uid, outgoing)
        return None

    async def _handle_call_reject(
        self,
        sender_uid: str,
        envelope: SignalingEnvelope,
    ) -> Optional[Dict[str, Any]]:
        """Handle call.reject: transition ringing→rejected and notify caller."""
        call_id = envelope.callId
        target_uid = envelope.toUserId

        # Look up call
        session = self._call_mgr.get_call(call_id)
        if session is None:
            return _build_error(call_id, "CALL_NOT_FOUND", "Call not found")

        # Only the receiver can reject
        if sender_uid != session.receiver_id:
            return _build_error(call_id, "NOT_PARTICIPANT", "Only the receiver can reject")

        # Target must be the caller
        if target_uid != session.caller_id:
            return _build_error(call_id, "INVALID_TARGET", "Invalid target user")

        # Transition state
        try:
            await self._call_mgr.transition(call_id, CallState.REJECTED)
        except InvalidStateTransitionError:
            return _build_error(call_id, "INVALID_STATE", "Call is not in ringing state")
        except CallNotFoundError:
            return _build_error(call_id, "CALL_NOT_FOUND", "Call not found")

        # Route rejection to caller with optional reason
        payload = {}
        reason = envelope.payload.get("reason")
        if reason:
            payload["reason"] = reason

        outgoing = _build_outgoing("call.reject", call_id, sender_uid, target_uid, payload)
        await self._conn_mgr.send_to_user(target_uid, outgoing)
        return None

    async def _handle_call_end(
        self,
        sender_uid: str,
        envelope: SignalingEnvelope,
    ) -> Optional[Dict[str, Any]]:
        """Handle call.end: transition to ended and notify other participant."""
        call_id = envelope.callId
        target_uid = envelope.toUserId

        # Look up call
        session = self._call_mgr.get_call(call_id)
        if session is None:
            return _build_error(call_id, "CALL_NOT_FOUND", "Call not found")

        # Verify sender is a participant
        if not self._call_mgr.is_participant(call_id, sender_uid):
            return _build_error(call_id, "NOT_PARTICIPANT", "Not a participant in this call")

        # Verify target is the other participant
        try:
            expected_other = self._call_mgr.get_other_participant(call_id, sender_uid)
        except UserNotParticipantError:
            return _build_error(call_id, "NOT_PARTICIPANT", "Not a participant in this call")
        except CallNotFoundError:
            return _build_error(call_id, "CALL_NOT_FOUND", "Call not found")

        if target_uid != expected_other:
            return _build_error(call_id, "INVALID_TARGET", "Invalid target user")

        # Verify state allows ending (ringing or active)
        if session.state not in (CallState.RINGING, CallState.ACTIVE):
            return _build_error(call_id, "INVALID_STATE", "Call cannot be ended in current state")

        # Transition to ended
        try:
            await self._call_mgr.transition(call_id, CallState.ENDED)
        except InvalidStateTransitionError:
            return _build_error(call_id, "INVALID_STATE", "Call cannot be ended in current state")
        except CallNotFoundError:
            return _build_error(call_id, "CALL_NOT_FOUND", "Call not found")

        # Route to other participant
        outgoing = _build_outgoing("call.end", call_id, sender_uid, target_uid)
        await self._conn_mgr.send_to_user(target_uid, outgoing)
        return None

    # ==========================================================================
    # WebRTC Relay Handlers
    # ==========================================================================

    async def _handle_webrtc_relay(
        self,
        sender_uid: str,
        envelope: SignalingEnvelope,
    ) -> Optional[Dict[str, Any]]:
        """Handle webrtc.offer, webrtc.answer, webrtc.ice: validate and relay unchanged."""
        call_id = envelope.callId
        target_uid = envelope.toUserId
        msg_type = envelope.type

        # Validate payload for specific WebRTC types
        try:
            if msg_type in ("webrtc.offer", "webrtc.answer"):
                WebRTCSdpPayload(**envelope.payload)
            elif msg_type == "webrtc.ice":
                WebRTCIcePayload(**envelope.payload)
        except (ValidationError, Exception):
            return _build_error(call_id, "INVALID_MESSAGE", "Invalid WebRTC payload")

        # Look up call
        session = self._call_mgr.get_call(call_id)
        if session is None:
            return _build_error(call_id, "CALL_NOT_FOUND", "Call not found")

        # Verify sender is a participant
        if not self._call_mgr.is_participant(call_id, sender_uid):
            return _build_error(call_id, "NOT_PARTICIPANT", "Not a participant in this call")

        # Verify target is the other participant
        try:
            expected_other = self._call_mgr.get_other_participant(call_id, sender_uid)
        except UserNotParticipantError:
            return _build_error(call_id, "NOT_PARTICIPANT", "Not a participant in this call")
        except CallNotFoundError:
            return _build_error(call_id, "CALL_NOT_FOUND", "Call not found")

        if target_uid != expected_other:
            return _build_error(call_id, "INVALID_TARGET", "Invalid target user")

        # Verify call is active
        if session.state != CallState.ACTIVE:
            return _build_error(call_id, "INVALID_STATE", "Call is not active")

        # Relay unchanged payload to target
        outgoing = _build_outgoing(msg_type, call_id, sender_uid, target_uid, envelope.payload)
        await self._conn_mgr.send_to_user(target_uid, outgoing)
        return None

    # ==========================================================================
    # Disconnect Cleanup
    # ==========================================================================

    async def handle_disconnect(self, user_id: str) -> None:
        """Clean up any active/ringing calls when a user disconnects.

        This should ONLY be called when the disconnecting WebSocket is confirmed
        to be the currently registered connection for the user (stale-socket check
        is performed by the caller in the router).

        Actions:
        1. Find any active/ringing call for the disconnecting user.
        2. Transition it to ended.
        3. Send peer.disconnected to the other participant.
        """
        session = self._call_mgr.get_active_call_for_user(user_id)
        if session is None:
            return

        call_id = session.call_id

        # Transition to ended
        try:
            await self._call_mgr.transition(call_id, CallState.ENDED)
        except CallSessionError:
            # Already ended or removed — safe to ignore
            return

        # Determine the other participant
        try:
            other_uid = self._call_mgr.get_other_participant(call_id, user_id)
        except (CallNotFoundError, UserNotParticipantError):
            return

        # Send peer.disconnected notification
        notification = _build_outgoing(
            "peer.disconnected",
            call_id,
            user_id,
            other_uid,
        )
        await self._conn_mgr.send_to_user(other_uid, notification)
