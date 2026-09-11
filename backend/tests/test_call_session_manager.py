import asyncio
import pytest

from app.calls.exceptions import (
    CallAlreadyExistsError,
    CallNotFoundError,
    InvalidCallError,
    InvalidStateTransitionError,
    UserBusyError,
    UserNotParticipantError,
)
from app.calls.manager import CallSessionManager
from app.calls.models import CallSession, CallState, CallType


# ==============================================================================
# 1, 2, 3: Creation and Initial State Tests
# ==============================================================================

def test_create_audio_call():
    """1: Create an audio call with valid parameters."""
    async def _test():
        manager = CallSessionManager()
        session = await manager.create_call(
            call_id="call_audio_1",
            caller_id="user_alice",
            receiver_id="user_bob",
            call_type="audio",
        )
        assert session.call_id == "call_audio_1"
        assert session.caller_id == "user_alice"
        assert session.receiver_id == "user_bob"
        assert session.call_type == CallType.AUDIO
        assert session.state == CallState.RINGING

    asyncio.run(_test())


def test_create_video_call():
    """2: Create a video call with valid parameters."""
    async def _test():
        manager = CallSessionManager()
        session = await manager.create_call(
            call_id="call_video_1",
            caller_id="user_carol",
            receiver_id="user_dave",
            call_type=CallType.VIDEO,
        )
        assert session.call_id == "call_video_1"
        assert session.caller_id == "user_carol"
        assert session.receiver_id == "user_dave"
        assert session.call_type == CallType.VIDEO
        assert session.state == CallState.RINGING

    asyncio.run(_test())


def test_initial_state_is_ringing():
    """3: Initial state of newly created call is always RINGING."""
    async def _test():
        manager = CallSessionManager()
        session = await manager.create_call(
            call_id="call_init_state",
            caller_id="user_1",
            receiver_id="user_2",
            call_type="audio",
        )
        assert session.state == CallState.RINGING

    asyncio.run(_test())


# ==============================================================================
# 4, 5, 6: Validation and Conflict Rejections
# ==============================================================================

def test_duplicate_call_id_rejected():
    """4: Duplicate callId creation must be rejected."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call(
            call_id="call_unique_1",
            caller_id="user_1",
            receiver_id="user_2",
            call_type="audio",
        )
        with pytest.raises(CallAlreadyExistsError) as exc_info:
            await manager.create_call(
                call_id="call_unique_1",
                caller_id="user_3",
                receiver_id="user_4",
                call_type="audio",
            )
        assert "call_unique_1" in str(exc_info.value)

    asyncio.run(_test())


def test_caller_and_receiver_cannot_be_identical():
    """5: Caller and receiver IDs must be different."""
    async def _test():
        manager = CallSessionManager()
        with pytest.raises(InvalidCallError):
            await manager.create_call(
                call_id="call_self_1",
                caller_id="user_same",
                receiver_id="user_same",
                call_type="audio",
            )

    asyncio.run(_test())


def test_invalid_call_type_rejected():
    """6: Invalid call type must be rejected."""
    async def _test():
        manager = CallSessionManager()
        with pytest.raises(InvalidCallError):
            await manager.create_call(
                call_id="call_bad_type",
                caller_id="user_1",
                receiver_id="user_2",
                call_type="hologram",
            )

    asyncio.run(_test())


# ==============================================================================
# 7, 8, 9: Call Lookup and Removal Tests
# ==============================================================================

def test_get_call():
    """7: get_call returns the session or None without crashing."""
    async def _test():
        manager = CallSessionManager()
        assert manager.get_call("nonexistent_call") is None

        session = await manager.create_call(
            call_id="call_lookup_1",
            caller_id="user_1",
            receiver_id="user_2",
            call_type="audio",
        )
        fetched = manager.get_call("call_lookup_1")
        assert fetched == session
        assert manager.get_call("nonexistent_call") is None

    asyncio.run(_test())


def test_has_call():
    """8: has_call returns True for existing call, False otherwise."""
    async def _test():
        manager = CallSessionManager()
        assert not manager.has_call("call_test_has")

        await manager.create_call(
            call_id="call_test_has",
            caller_id="user_1",
            receiver_id="user_2",
            call_type="video",
        )
        assert manager.has_call("call_test_has")
        assert not manager.has_call("other_call")

    asyncio.run(_test())


def test_remove_call():
    """9: remove_call safely deletes call and frees active participants."""
    async def _test():
        manager = CallSessionManager()
        assert await manager.remove_call("missing_call") is None

        session = await manager.create_call(
            call_id="call_to_remove",
            caller_id="user_1",
            receiver_id="user_2",
            call_type="audio",
        )
        assert manager.is_user_busy("user_1")
        assert manager.is_user_busy("user_2")

        removed = await manager.remove_call("call_to_remove")
        assert removed == session
        assert not manager.has_call("call_to_remove")
        assert not manager.is_user_busy("user_1")
        assert not manager.is_user_busy("user_2")

    asyncio.run(_test())


# ==============================================================================
# 10, 11, 12, 13: Valid State Transitions
# ==============================================================================

def test_transition_ringing_to_active():
    """10: Valid transition ringing -> active."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c10", "u1", "u2", "audio")
        session = await manager.transition("c10", "active")
        assert session.state == CallState.ACTIVE
        assert manager.is_user_busy("u1")
        assert manager.is_user_busy("u2")

    asyncio.run(_test())


def test_transition_ringing_to_rejected():
    """11: Valid transition ringing -> rejected (frees participants)."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c11", "u1", "u2", "audio")
        session = await manager.transition("c11", "rejected")
        assert session.state == CallState.REJECTED
        # Terminal state: users are no longer busy
        assert not manager.is_user_busy("u1")
        assert not manager.is_user_busy("u2")

    asyncio.run(_test())


def test_transition_ringing_to_ended():
    """12: Valid transition ringing -> ended (caller cancels call)."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c12", "u1", "u2", "video")
        session = await manager.transition("c12", CallState.ENDED)
        assert session.state == CallState.ENDED
        assert not manager.is_user_busy("u1")
        assert not manager.is_user_busy("u2")

    asyncio.run(_test())


def test_transition_active_to_ended():
    """13: Valid transition active -> ended."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c13", "u1", "u2", "video")
        await manager.transition("c13", "active")
        session = await manager.transition("c13", "ended")
        assert session.state == CallState.ENDED
        assert not manager.is_user_busy("u1")
        assert not manager.is_user_busy("u2")

    asyncio.run(_test())


# ==============================================================================
# 14, 15, 16: Invalid State Transitions
# ==============================================================================

def test_invalid_active_to_rejected():
    """14: Invalid transition active -> rejected."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c14", "u1", "u2", "audio")
        await manager.transition("c14", "active")
        with pytest.raises(InvalidStateTransitionError):
            await manager.transition("c14", "rejected")

    asyncio.run(_test())


def test_invalid_ended_to_active():
    """15: Invalid transition ended -> active."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c15", "u1", "u2", "audio")
        await manager.transition("c15", "ended")
        with pytest.raises(InvalidStateTransitionError):
            await manager.transition("c15", "active")

    asyncio.run(_test())


def test_invalid_ended_to_rejected():
    """16: Invalid transition ended -> rejected."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c16", "u1", "u2", "audio")
        await manager.transition("c16", "ended")
        with pytest.raises(InvalidStateTransitionError):
            await manager.transition("c16", "rejected")

    asyncio.run(_test())


def test_other_invalid_transitions():
    """Verify active->active, ended->ended, rejected->active are forbidden."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c_sub", "u1", "u2", "audio")
        await manager.transition("c_sub", "active")

        # active -> active rejected
        with pytest.raises(InvalidStateTransitionError):
            await manager.transition("c_sub", "active")

        await manager.transition("c_sub", "ended")

        # ended -> ended rejected
        with pytest.raises(InvalidStateTransitionError):
            await manager.transition("c_sub", "ended")

    asyncio.run(_test())


def test_transition_nonexistent_call():
    """Transitioning a non-existent call raises CallNotFoundError."""
    async def _test():
        manager = CallSessionManager()
        with pytest.raises(CallNotFoundError):
            await manager.transition("nonexistent_call", "active")

    asyncio.run(_test())


# ==============================================================================
# 17, 18, 19: Participant Validation Tests
# ==============================================================================

def test_participant_validation():
    """17: Caller and receiver are validated as participants."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c17", "alice", "bob", "audio")
        assert manager.is_participant("c17", "alice")
        assert manager.is_participant("c17", "bob")

    asyncio.run(_test())


def test_non_participant_rejected():
    """18: A third-party user is rejected as non-participant."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c18", "alice", "bob", "audio")
        assert not manager.is_participant("c18", "charlie")
        assert not manager.is_participant("nonexistent_call", "alice")

    asyncio.run(_test())


def test_get_other_participant():
    """19: get_other_participant returns the partner and rejects non-participants."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c19", "alice", "bob", "video")

        assert manager.get_other_participant("c19", "alice") == "bob"
        assert manager.get_other_participant("c19", "bob") == "alice"

        with pytest.raises(UserNotParticipantError):
            manager.get_other_participant("c19", "charlie")

        with pytest.raises(CallNotFoundError):
            manager.get_other_participant("nonexistent", "alice")

    asyncio.run(_test())


# ==============================================================================
# 20 & 21: One Active Call Per User Policy
# ==============================================================================

def test_one_active_or_ringing_call_per_user():
    """20: A user participating in a ringing/active call cannot join another call."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c20_1", "alice", "bob", "audio")

        # Alice is caller in ringing call; cannot call Charlie
        with pytest.raises(UserBusyError) as exc_info:
            await manager.create_call("c20_2", "alice", "charlie", "audio")
        assert "alice" in str(exc_info.value)

        # Bob is receiver in ringing call; cannot receive another call from Charlie
        with pytest.raises(UserBusyError) as exc_info:
            await manager.create_call("c20_3", "charlie", "bob", "audio")
        assert "bob" in str(exc_info.value)

        # Transition c20_1 to active
        await manager.transition("c20_1", "active")

        # Alice still active, cannot start new call
        with pytest.raises(UserBusyError):
            await manager.create_call("c20_4", "alice", "david", "audio")

        # Bob still active, cannot start new call
        with pytest.raises(UserBusyError):
            await manager.create_call("c20_5", "david", "bob", "audio")

    asyncio.run(_test())


def test_user_can_join_new_call_after_previous_call_ended_or_rejected():
    """21: Users can create/join a new call once their previous call ends or is rejected."""
    async def _test():
        manager = CallSessionManager()
        await manager.create_call("c21_1", "alice", "bob", "audio")
        assert manager.is_user_busy("alice")
        assert manager.is_user_busy("bob")

        # End the call
        await manager.transition("c21_1", "ended")
        assert not manager.is_user_busy("alice")
        assert not manager.is_user_busy("bob")

        # Alice can now call Charlie
        session2 = await manager.create_call("c21_2", "alice", "charlie", "video")
        assert session2.state == CallState.RINGING
        assert manager.is_user_busy("alice")
        assert manager.is_user_busy("charlie")

        # Reject call 2
        await manager.transition("c21_2", "rejected")
        assert not manager.is_user_busy("alice")
        assert not manager.is_user_busy("charlie")

        # Bob can now call Charlie
        session3 = await manager.create_call("c21_3", "bob", "charlie", "audio")
        assert session3.state == CallState.RINGING

    asyncio.run(_test())


# ==============================================================================
# 22: Concurrency Tests
# ==============================================================================

def test_concurrent_creation_cannot_create_conflicting_active_calls():
    """22: Concurrent creation attempts for the same busy user cannot both succeed."""
    async def _test():
        manager = CallSessionManager()
        results = []
        errors = []

        async def attempt_create(call_id: str, caller_id: str, receiver_id: str):
            try:
                session = await manager.create_call(
                    call_id=call_id,
                    caller_id=caller_id,
                    receiver_id=receiver_id,
                    call_type="audio",
                )
                results.append(session)
            except UserBusyError as exc:
                errors.append(exc)

        # 10 concurrent requests attempting to call or be called by 'alice'
        tasks = [
            attempt_create(
                f"race_call_{i}",
                "alice" if i % 2 == 0 else f"other_{i}",
                f"other_{i}" if i % 2 == 0 else "alice",
            )
            for i in range(10)
        ]

        await asyncio.gather(*tasks)

        # Exactly ONE creation must succeed; the other 9 must fail with UserBusyError
        assert len(results) == 1
        assert len(errors) == 9
        assert manager.active_calls_count() == 1
        assert manager.is_user_busy("alice")

    asyncio.run(_test())


def test_concurrent_creation_distinct_users_succeed():
    """Distinct pairs of users can create calls concurrently without conflict."""
    async def _test():
        manager = CallSessionManager()

        async def create_pair(idx: int):
            return await manager.create_call(
                call_id=f"pair_call_{idx}",
                caller_id=f"caller_{idx}",
                receiver_id=f"receiver_{idx}",
                call_type="video",
            )

        sessions = await asyncio.gather(*[create_pair(i) for i in range(10)])
        assert len(sessions) == 10
        assert manager.active_calls_count() == 10

    asyncio.run(_test())
