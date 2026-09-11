import asyncio
from typing import Dict, Optional, Set, Union

from app.calls.exceptions import (
    CallAlreadyExistsError,
    CallNotFoundError,
    InvalidCallError,
    InvalidStateTransitionError,
    UserBusyError,
    UserNotParticipantError,
)
from app.calls.models import CallSession, CallState, CallType


class CallSessionManager:
    """Manages in-memory 1-to-1 audio and video call sessions and lifecycles.
    
    Architectural Boundaries:
    - Pure call state management.
    - No direct knowledge of WebSockets, Firebase Admin, Flutter, or WebRTC media.
    - Concurrency-safe: uses asyncio.Lock for atomic checks and state transitions.
    - Enforces the 1-active-call-per-user MVP policy.
    """

    VALID_TRANSITIONS: Dict[CallState, Set[CallState]] = {
        CallState.RINGING: {CallState.ACTIVE, CallState.REJECTED, CallState.ENDED},
        CallState.ACTIVE: {CallState.ENDED},
        CallState.REJECTED: set(),
        CallState.ENDED: set(),
    }

    TERMINAL_STATES: Set[CallState] = {CallState.REJECTED, CallState.ENDED}

    def __init__(self) -> None:
        self._calls: Dict[str, CallSession] = {}
        # Maps user_id -> call_id for users currently participating in ringing/active calls
        self._user_active_calls: Dict[str, str] = {}
        self._lock: asyncio.Lock = asyncio.Lock()

    async def create_call(
        self,
        call_id: str,
        caller_id: str,
        receiver_id: str,
        call_type: Union[CallType, str],
    ) -> CallSession:
        """Create a new 1-to-1 call session in the 'ringing' state.
        
        Requirements:
        - caller_id and receiver_id must be distinct and non-empty.
        - call_id must be unique across existing calls.
        - call_type must be 'audio' or 'video'.
        - Neither caller nor receiver may be engaged in another active/ringing call.
        """
        # Validate call_type
        if isinstance(call_type, str):
            try:
                parsed_type = CallType(call_type.lower())
            except ValueError:
                raise InvalidCallError(f"Invalid call_type '{call_type}'. Must be 'audio' or 'video'.")
        elif isinstance(call_type, CallType):
            parsed_type = call_type
        else:
            raise InvalidCallError("call_type must be a string or CallType enum.")

        # Construct and validate model (checks participant identity & empty strings)
        try:
            session = CallSession(
                call_id=call_id,
                caller_id=caller_id,
                receiver_id=receiver_id,
                call_type=parsed_type,
                state=CallState.RINGING,
            )
        except Exception as exc:
            raise InvalidCallError(str(exc)) from exc

        async with self._lock:
            # Check unique call_id
            if call_id in self._calls:
                raise CallAlreadyExistsError(call_id)

            # Check if caller is already in an active/ringing call
            if caller_id in self._user_active_calls:
                active_call_id = self._user_active_calls[caller_id]
                raise UserBusyError(caller_id, active_call_id)

            # Check if receiver is already in an active/ringing call
            if receiver_id in self._user_active_calls:
                active_call_id = self._user_active_calls[receiver_id]
                raise UserBusyError(receiver_id, active_call_id)

            # Register session and mark participants as busy
            self._calls[call_id] = session
            self._user_active_calls[caller_id] = call_id
            self._user_active_calls[receiver_id] = call_id

        return session

    def get_call(self, call_id: str) -> Optional[CallSession]:
        """Retrieve a call session by its ID, or None if it does not exist."""
        return self._calls.get(call_id)

    def has_call(self, call_id: str) -> bool:
        """Return True if a call with the given ID exists in the registry."""
        return call_id in self._calls

    async def remove_call(self, call_id: str) -> Optional[CallSession]:
        """Safely remove a call session from the manager.
        
        Also cleans up active user indices if the call was still active/ringing.
        """
        async with self._lock:
            session = self._calls.pop(call_id, None)
            if session is not None:
                self._release_user_lock_if_matching(session.caller_id, call_id)
                self._release_user_lock_if_matching(session.receiver_id, call_id)
            return session

    async def transition(
        self,
        call_id: str,
        new_state: Union[CallState, str],
    ) -> CallSession:
        """Transition a call to a new state if the transition is valid.
        
        Permitted transitions:
        - ringing -> active
        - ringing -> rejected
        - ringing -> ended
        - active -> ended
        
        All other transitions are rejected cleanly with InvalidStateTransitionError.
        """
        # Parse new_state
        if isinstance(new_state, str):
            try:
                target_state = CallState(new_state.lower())
            except ValueError:
                raise InvalidStateTransitionError("unknown", new_state)
        elif isinstance(new_state, CallState):
            target_state = new_state
        else:
            raise InvalidStateTransitionError("unknown", str(new_state))

        async with self._lock:
            session = self._calls.get(call_id)
            if session is None:
                raise CallNotFoundError(call_id)

            current_state = session.state
            allowed_next = self.VALID_TRANSITIONS.get(current_state, set())

            if target_state not in allowed_next:
                raise InvalidStateTransitionError(
                    current_state=current_state.value,
                    requested_state=target_state.value,
                )

            # Apply state update
            session.state = target_state

            # If entering a terminal state, release the users from the active registry
            if target_state in self.TERMINAL_STATES:
                self._release_user_lock_if_matching(session.caller_id, call_id)
                self._release_user_lock_if_matching(session.receiver_id, call_id)

            return session

    def is_participant(self, call_id: str, user_id: str) -> bool:
        """Return True if user_id is caller or receiver of the given call."""
        session = self._calls.get(call_id)
        if session is None:
            return False
        return user_id in (session.caller_id, session.receiver_id)

    def get_other_participant(self, call_id: str, user_id: str) -> str:
        """Return the other participant's user_id in the call.
        
        Raises:
            CallNotFoundError: If the call does not exist.
            UserNotParticipantError: If the specified user is not in the call.
        """
        session = self._calls.get(call_id)
        if session is None:
            raise CallNotFoundError(call_id)

        if user_id == session.caller_id:
            return session.receiver_id
        if user_id == session.receiver_id:
            return session.caller_id

        raise UserNotParticipantError(call_id=call_id, user_id=user_id)

    def is_user_busy(self, user_id: str) -> bool:
        """Return True if the user is currently in a ringing or active call."""
        return user_id in self._user_active_calls

    def get_active_call_for_user(self, user_id: str) -> Optional[CallSession]:
        """Return the active or ringing CallSession for the user, if one exists."""
        call_id = self._user_active_calls.get(user_id)
        if call_id is not None:
            return self._calls.get(call_id)
        return None

    def active_calls_count(self) -> int:
        """Return the number of calls currently in ringing or active state."""
        return sum(
            1 for c in self._calls.values() if c.state not in self.TERMINAL_STATES
        )

    def total_calls_count(self) -> int:
        """Return the total number of calls currently tracked in memory."""
        return len(self._calls)

    def _release_user_lock_if_matching(self, user_id: str, call_id: str) -> None:
        """Internal helper: clear user's busy state only if currently tied to call_id."""
        if self._user_active_calls.get(user_id) == call_id:
            del self._user_active_calls[user_id]
