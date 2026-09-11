"""Calls module for ConnectCall.

Provides CallSession models, CallType, CallState, CallSessionManager,
and call session domain exceptions.
"""

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
from app.calls.models import CallSession, CallState, CallType

__all__ = [
    "CallSession",
    "CallType",
    "CallState",
    "CallSessionManager",
    "CallSessionError",
    "CallNotFoundError",
    "CallAlreadyExistsError",
    "InvalidStateTransitionError",
    "InvalidCallError",
    "UserBusyError",
    "UserNotParticipantError",
]
