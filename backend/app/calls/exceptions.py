class CallSessionError(Exception):
    """Base exception for call session errors."""
    pass


class CallNotFoundError(CallSessionError):
    """Raised when a call session cannot be found by its ID."""

    def __init__(self, call_id: str) -> None:
        super().__init__(f"Call session with id '{call_id}' not found.")
        self.call_id = call_id


class CallAlreadyExistsError(CallSessionError):
    """Raised when attempting to create a call with an ID that already exists."""

    def __init__(self, call_id: str) -> None:
        super().__init__(f"Call session with id '{call_id}' already exists.")
        self.call_id = call_id


class InvalidStateTransitionError(CallSessionError):
    """Raised when an invalid state transition is requested."""

    def __init__(self, current_state: str, requested_state: str) -> None:
        super().__init__(
            f"Cannot transition call from state '{current_state}' to '{requested_state}'."
        )
        self.current_state = current_state
        self.requested_state = requested_state


class InvalidCallError(CallSessionError):
    """Raised when call parameters are invalid (e.g., caller equals receiver)."""
    pass


class UserBusyError(CallSessionError):
    """Raised when a participant is already engaged in an active or ringing call."""

    def __init__(self, user_id: str, active_call_id: str) -> None:
        super().__init__(
            f"User '{user_id}' is already participating in active/ringing call '{active_call_id}'."
        )
        self.user_id = user_id
        self.active_call_id = active_call_id


class UserNotParticipantError(CallSessionError):
    """Raised when an operation is attempted by a user who is not a participant."""

    def __init__(self, call_id: str, user_id: str) -> None:
        super().__init__(f"User '{user_id}' is not a participant in call '{call_id}'.")
        self.call_id = call_id
        self.user_id = user_id
