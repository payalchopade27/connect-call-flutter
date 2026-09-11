from typing import Any, Dict, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field


# ==============================================================================
# Authentication Schemas (Frozen — do not modify)
# ==============================================================================

class AuthMessage(BaseModel):
    """Initial client authentication message payload."""

    type: Literal["auth"]
    token: str = Field(..., min_length=1, description="Firebase ID token")

    model_config = ConfigDict(extra="ignore")


class AuthSuccessMessage(BaseModel):
    """Server authentication success response payload."""

    type: Literal["auth.success"] = "auth.success"
    userId: str = Field(..., min_length=1, description="Verified Firebase UID")

    model_config = ConfigDict(populate_by_name=True)


class AuthErrorMessage(BaseModel):
    """Server authentication error response payload."""

    type: Literal["auth.error"] = "auth.error"
    code: str = Field(..., description="Machine-readable error code")
    message: str = Field(..., description="Human-readable error description")

    model_config = ConfigDict(populate_by_name=True)


# ==============================================================================
# Signaling Message Schemas — Client → Backend
# ==============================================================================

class SignalingEnvelope(BaseModel):
    """Base envelope for all post-auth signaling messages from the client.

    Every signaling message must include:
    - type: the message type string
    - callId: unique call identifier (non-empty)
    - toUserId: target Firebase UID (non-empty)
    - payload: optional dict of message-specific data
    """

    type: str = Field(..., min_length=1, description="Message type identifier")
    callId: str = Field(..., min_length=1, description="Unique call identifier")
    toUserId: str = Field(..., min_length=1, description="Target Firebase UID")
    payload: Dict[str, Any] = Field(default_factory=dict, description="Message-specific payload")

    model_config = ConfigDict(extra="ignore")


class CallInvitePayload(BaseModel):
    """Payload for call.invite messages — specifies the call media type."""

    callType: Literal["audio", "video"] = Field(
        ..., description="Type of call: audio or video"
    )

    model_config = ConfigDict(extra="ignore")


class WebRTCSdpPayload(BaseModel):
    """Payload for webrtc.offer and webrtc.answer — contains SDP string."""

    sdp: str = Field(..., min_length=1, description="SDP offer or answer string")

    model_config = ConfigDict(extra="ignore")


class WebRTCIcePayload(BaseModel):
    """Payload for webrtc.ice — contains ICE candidate data.

    The backend does not inspect or modify ICE candidate internals.
    """

    candidate: Any = Field(..., description="ICE candidate object (opaque pass-through)")
    sdpMid: Optional[str] = Field(default=None, description="SDP media stream ID")
    sdpMLineIndex: Optional[int] = Field(default=None, description="SDP media line index")

    model_config = ConfigDict(extra="ignore")


# ==============================================================================
# Signaling Message Schemas — Backend → Client
# ==============================================================================

class OutgoingSignalingMessage(BaseModel):
    """Outgoing signaling message envelope from backend to client.

    The backend constructs `fromUserId` from the authenticated WebSocket UID.
    Never trust client-supplied fromUserId.
    """

    type: str = Field(..., description="Message type identifier")
    callId: str = Field(..., description="Unique call identifier")
    fromUserId: str = Field(..., description="Authenticated sender Firebase UID")
    toUserId: str = Field(..., description="Target Firebase UID")
    payload: Dict[str, Any] = Field(default_factory=dict, description="Message payload")

    model_config = ConfigDict(populate_by_name=True)


class CallErrorMessage(BaseModel):
    """Error response sent back to the sender when a signaling operation fails.

    Error codes:
    - CALL_NOT_FOUND: Call session does not exist
    - NOT_PARTICIPANT: Sender is not a participant in the call
    - INVALID_TARGET: toUserId does not match the expected participant
    - INVALID_STATE: Call is not in the required state for this operation
    - USER_OFFLINE: Target user is not connected
    - USER_BUSY: Target user is already in an active/ringing call
    - INVALID_MESSAGE: Malformed message structure
    - UNSUPPORTED_MESSAGE: Unknown message type
    - INVALID_CALL_TYPE: callType is not 'audio' or 'video'
    - INVALID_CALL_ID: callId conflict or invalid
    """

    type: Literal["call.error"] = "call.error"
    callId: str = Field(default="", description="Related call ID, or empty if unknown")
    payload: Dict[str, Any] = Field(..., description="Error details with 'code' and 'message'")

    model_config = ConfigDict(populate_by_name=True)
