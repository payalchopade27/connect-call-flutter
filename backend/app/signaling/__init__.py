"""Signaling package for ConnectCall backend."""

from app.signaling.dispatcher import MessageDispatcher
from app.signaling.manager import ConnectionManager
from app.signaling.router import get_call_session_manager, get_connection_manager, get_dispatcher, router
from app.signaling.schemas import (
    AuthErrorMessage,
    AuthMessage,
    AuthSuccessMessage,
    CallErrorMessage,
    CallInvitePayload,
    OutgoingSignalingMessage,
    SignalingEnvelope,
    WebRTCIcePayload,
    WebRTCSdpPayload,
)

__all__ = [
    "ConnectionManager",
    "MessageDispatcher",
    "get_connection_manager",
    "get_call_session_manager",
    "get_dispatcher",
    "router",
    "AuthMessage",
    "AuthSuccessMessage",
    "AuthErrorMessage",
    "SignalingEnvelope",
    "CallInvitePayload",
    "WebRTCSdpPayload",
    "WebRTCIcePayload",
    "OutgoingSignalingMessage",
    "CallErrorMessage",
]
