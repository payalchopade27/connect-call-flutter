from enum import Enum
from typing import Union
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class CallType(str, Enum):
    AUDIO = "audio"
    VIDEO = "video"


class CallState(str, Enum):
    RINGING = "ringing"
    ACTIVE = "active"
    REJECTED = "rejected"
    ENDED = "ended"


class CallSession(BaseModel):
    """Represents a 1-to-1 audio or video call session.
    
    Responsible solely for in-memory call metadata and lifecycle state.
    Does not know about WebSockets, WebRTC media, Firebase tokens, or Flutter.
    """

    call_id: str = Field(..., min_length=1, description="Unique call identifier")
    caller_id: str = Field(..., min_length=1, description="Firebase UID of the caller")
    receiver_id: str = Field(..., min_length=1, description="Firebase UID of the receiver")
    call_type: CallType = Field(..., description="Type of call: audio or video")
    state: CallState = Field(default=CallState.RINGING, description="Current lifecycle state")

    model_config = ConfigDict(validate_assignment=True)

    @field_validator("call_type", mode="before")
    @classmethod
    def validate_call_type(cls, v: Union[CallType, str]) -> CallType:
        if isinstance(v, CallType):
            return v
        if isinstance(v, str):
            try:
                return CallType(v.lower())
            except ValueError:
                raise ValueError(f"Invalid call_type '{v}'. Must be 'audio' or 'video'.")
        raise ValueError("call_type must be a string or CallType enum.")

    @field_validator("state", mode="before")
    @classmethod
    def validate_state(cls, v: Union[CallState, str]) -> CallState:
        if isinstance(v, CallState):
            return v
        if isinstance(v, str):
            try:
                return CallState(v.lower())
            except ValueError:
                raise ValueError(f"Invalid state '{v}'. Must be one of: {list(CallState)}.")
        raise ValueError("state must be a string or CallState enum.")

    @model_validator(mode="after")
    def validate_participants(self) -> "CallSession":
        if not self.call_id or not self.call_id.strip():
            raise ValueError("call_id cannot be empty or whitespace.")
        if not self.caller_id or not self.caller_id.strip():
            raise ValueError("caller_id cannot be empty or whitespace.")
        if not self.receiver_id or not self.receiver_id.strip():
            raise ValueError("receiver_id cannot be empty or whitespace.")
        if self.caller_id.strip() == self.receiver_id.strip():
            raise ValueError("caller_id and receiver_id cannot be identical.")
        return self
