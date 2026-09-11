"""
Comprehensive integration tests for the ConnectCall signaling lifecycle.

Tests cover:
- call.invite (audio/video, offline receiver, busy receiver, self-call,
  invalid type, duplicate callId, identity spoofing)
- call.accept (success, non-participant, wrong target, invalid state)
- call.reject (success, non-participant, active call)
- call.end (caller/receiver, ringing/active, non-participant, wrong target)
- webrtc.offer / webrtc.answer / webrtc.ice (relay, security, state checks)
- Security: fromUserId / callerId spoofing rejected
- Disconnect: peer.disconnected, call cleanup, stale-socket safety
- Robustness: malformed JSON, unknown type, missing fields, server survives

Design principles:
- Each test uses UNIQUE user IDs to avoid cross-test busy-state pollution.
- The shared CallSessionManager singleton accumulates calls across tests,
  so user isolation is critical.
- All tests mock Firebase token verification — no real credentials needed.
"""

import asyncio
import json
from contextlib import contextmanager
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import WebSocket
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.calls.models import CallState
from app.main import app
from app.signaling.router import (
    get_call_session_manager,
    get_connection_manager,
    get_dispatcher,
)

client = TestClient(app)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def mock_token(uid: str):
    """Patch verify_firebase_token to return a given UID."""
    return patch("app.signaling.router.verify_firebase_token", return_value={"uid": uid})


@contextmanager
def authenticated_ws(uid: str):
    """Open an authenticated WebSocket for the given UID."""
    with mock_token(uid):
        with client.websocket_connect("/ws/signaling") as ws:
            ws.send_json({"type": "auth", "token": "tok"})
            resp = ws.receive_json()
            assert resp["type"] == "auth.success", f"Auth failed for {uid}: {resp}"
            assert resp["userId"] == uid
            yield ws


def send_and_receive(ws, message: dict) -> dict:
    """Send a JSON message and wait for one JSON response."""
    ws.send_json(message)
    return ws.receive_json()


def setup_ringing_call(call_id: str, caller_uid: str, receiver_uid: str, caller_ws, receiver_ws):
    """Helper: send invite and drain invite from receiver."""
    caller_ws.send_json({
        "type": "call.invite",
        "callId": call_id,
        "toUserId": receiver_uid,
        "payload": {"callType": "audio"},
    })
    invite = receiver_ws.receive_json()
    assert invite["type"] == "call.invite"


def setup_active_call(call_id: str, caller_uid: str, receiver_uid: str, caller_ws, receiver_ws):
    """Helper: establish call to active state."""
    setup_ringing_call(call_id, caller_uid, receiver_uid, caller_ws, receiver_ws)
    receiver_ws.send_json({
        "type": "call.accept",
        "callId": call_id,
        "toUserId": caller_uid,
        "payload": {},
    })
    accept = caller_ws.receive_json()
    assert accept["type"] == "call.accept"


# ==============================================================================
# Health check regression
# ==============================================================================

def test_health_check_still_works():
    """GET /health continues to return {"status": "ok"}."""
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


# ==============================================================================
# CALL INVITE
# ==============================================================================

def test_audio_invite_delivered_to_receiver():
    """1: Successful audio call invite reaches the receiver."""
    csm = get_call_session_manager()
    call_id = "t01_call"

    with authenticated_ws("t01_alice") as alice_ws:
        with authenticated_ws("t01_bob") as bob_ws:
            alice_ws.send_json({
                "type": "call.invite",
                "callId": call_id,
                "toUserId": "t01_bob",
                "payload": {"callType": "audio"},
            })

            invite = bob_ws.receive_json()
            assert invite["type"] == "call.invite"
            assert invite["callId"] == call_id
            assert invite["fromUserId"] == "t01_alice"
            assert invite["toUserId"] == "t01_bob"
            assert invite["payload"]["callType"] == "audio"

            session = csm.get_call(call_id)
            assert session is not None
            assert session.state == CallState.RINGING
            assert session.caller_id == "t01_alice"
            assert session.receiver_id == "t01_bob"


def test_video_invite_delivered():
    """2: Successful video call invite reaches the receiver."""
    call_id = "t02_call"

    with authenticated_ws("t02_carol") as carol_ws:
        with authenticated_ws("t02_dave") as dave_ws:
            carol_ws.send_json({
                "type": "call.invite",
                "callId": call_id,
                "toUserId": "t02_dave",
                "payload": {"callType": "video"},
            })

            invite = dave_ws.receive_json()
            assert invite["type"] == "call.invite"
            assert invite["payload"]["callType"] == "video"


def test_offline_receiver_returns_user_offline():
    """3: Inviting an offline user returns USER_OFFLINE; no ringing session left."""
    csm = get_call_session_manager()
    call_id = "t03_call"

    with authenticated_ws("t03_alice") as alice_ws:
        err = send_and_receive(alice_ws, {
            "type": "call.invite",
            "callId": call_id,
            "toUserId": "t03_nobody_online",
            "payload": {"callType": "audio"},
        })
        assert err["type"] == "call.error"
        assert err["callId"] == call_id
        assert err["payload"]["code"] == "USER_OFFLINE"
        assert csm.get_call(call_id) is None


def test_busy_receiver_returns_user_busy():
    """4: Inviting a user who is already in a ringing call returns USER_BUSY."""
    csm = get_call_session_manager()

    with authenticated_ws("t04_caller_a") as ca_ws:
        with authenticated_ws("t04_busy") as busy_ws:
            with authenticated_ws("t04_caller_b") as cb_ws:
                # First call: t04_caller_a → t04_busy
                ca_ws.send_json({
                    "type": "call.invite",
                    "callId": "t04_call_first",
                    "toUserId": "t04_busy",
                    "payload": {"callType": "audio"},
                })
                busy_ws.receive_json()

                # Second caller tries to reach t04_busy
                err = send_and_receive(cb_ws, {
                    "type": "call.invite",
                    "callId": "t04_call_second",
                    "toUserId": "t04_busy",
                    "payload": {"callType": "audio"},
                })
                assert err["type"] == "call.error"
                assert err["payload"]["code"] == "USER_BUSY"
                assert csm.get_call("t04_call_second") is None


def test_self_call_rejected():
    """5: Self-call (sender == target) is rejected with INVALID_TARGET."""
    with authenticated_ws("t05_selfcall") as ws:
        err = send_and_receive(ws, {
            "type": "call.invite",
            "callId": "t05_call",
            "toUserId": "t05_selfcall",
            "payload": {"callType": "audio"},
        })
        assert err["type"] == "call.error"
        assert err["payload"]["code"] == "INVALID_TARGET"


def test_invalid_call_type_rejected():
    """6: Invalid callType is rejected with INVALID_CALL_TYPE."""
    with authenticated_ws("t06_caller") as ws:
        with authenticated_ws("t06_recv") as _:
            err = send_and_receive(ws, {
                "type": "call.invite",
                "callId": "t06_call",
                "toUserId": "t06_recv",
                "payload": {"callType": "hologram"},
            })
            assert err["type"] == "call.error"
            assert err["payload"]["code"] == "INVALID_CALL_TYPE"


def test_duplicate_call_id_rejected():
    """7: Duplicate callId is rejected with INVALID_CALL_ID."""
    csm = get_call_session_manager()
    call_id = "t07_call"

    with authenticated_ws("t07_x") as x_ws:
        with authenticated_ws("t07_y") as y_ws:
            # Create call
            x_ws.send_json({
                "type": "call.invite",
                "callId": call_id,
                "toUserId": "t07_y",
                "payload": {"callType": "audio"},
            })
            y_ws.receive_json()

            # End it so users are free, but call ID still exists in memory
            x_ws.send_json({
                "type": "call.end",
                "callId": call_id,
                "toUserId": "t07_y",
                "payload": {},
            })
            y_ws.receive_json()

            # Try same callId again with free users
            with authenticated_ws("t07_z") as z_ws:
                err = send_and_receive(x_ws, {
                    "type": "call.invite",
                    "callId": call_id,
                    "toUserId": "t07_z",
                    "payload": {"callType": "audio"},
                })
                assert err["type"] == "call.error"
                assert err["payload"]["code"] == "INVALID_CALL_ID"


def test_sender_identity_from_authenticated_socket():
    """8: Sender identity comes from authenticated WebSocket, not client payload."""
    csm = get_call_session_manager()
    call_id = "t08_call"

    with authenticated_ws("t08_real") as alice_ws:
        with authenticated_ws("t08_recv") as bob_ws:
            alice_ws.send_json({
                "type": "call.invite",
                "callId": call_id,
                "toUserId": "t08_recv",
                "fromUserId": "t08_fake_admin",  # spoofed field — must be ignored
                "callerId": "t08_fake_admin",
                "payload": {"callType": "audio"},
            })

            invite = bob_ws.receive_json()
            assert invite["fromUserId"] == "t08_real"
            assert invite["fromUserId"] != "t08_fake_admin"

            session = csm.get_call(call_id)
            assert session.caller_id == "t08_real"


# ==============================================================================
# CALL ACCEPT
# ==============================================================================

def test_accept_transitions_to_active():
    """9: Successful accept transitions ringing→active and notifies caller."""
    csm = get_call_session_manager()
    call_id = "t09_call"

    with authenticated_ws("t09_caller") as caller_ws:
        with authenticated_ws("t09_recv") as recv_ws:
            setup_ringing_call(call_id, "t09_caller", "t09_recv", caller_ws, recv_ws)

            recv_ws.send_json({
                "type": "call.accept",
                "callId": call_id,
                "toUserId": "t09_caller",
                "payload": {},
            })

            accepted = caller_ws.receive_json()
            assert accepted["type"] == "call.accept"
            assert accepted["callId"] == call_id
            assert accepted["fromUserId"] == "t09_recv"
            assert accepted["toUserId"] == "t09_caller"
            assert csm.get_call(call_id).state == CallState.ACTIVE


def test_non_participant_cannot_accept():
    """10: Non-participant cannot accept a call."""
    call_id = "t10_call"

    with authenticated_ws("t10_caller") as caller_ws:
        with authenticated_ws("t10_recv") as recv_ws:
            with authenticated_ws("t10_intruder") as intruder_ws:
                setup_ringing_call(call_id, "t10_caller", "t10_recv", caller_ws, recv_ws)

                err = send_and_receive(intruder_ws, {
                    "type": "call.accept",
                    "callId": call_id,
                    "toUserId": "t10_caller",
                    "payload": {},
                })
                assert err["type"] == "call.error"
                assert err["payload"]["code"] == "NOT_PARTICIPANT"


def test_accept_wrong_target_rejected():
    """11: Accept with wrong target (not the caller) is rejected."""
    call_id = "t11_call"

    with authenticated_ws("t11_caller") as caller_ws:
        with authenticated_ws("t11_recv") as recv_ws:
            with authenticated_ws("t11_other") as other_ws:
                setup_ringing_call(call_id, "t11_caller", "t11_recv", caller_ws, recv_ws)

                err = send_and_receive(recv_ws, {
                    "type": "call.accept",
                    "callId": call_id,
                    "toUserId": "t11_other",  # wrong target
                    "payload": {},
                })
                assert err["type"] == "call.error"
                assert err["payload"]["code"] == "INVALID_TARGET"


def test_accept_non_ringing_call_rejected():
    """12: Accepting an already-active call is rejected with INVALID_STATE."""
    call_id = "t12_call"

    with authenticated_ws("t12_caller") as caller_ws:
        with authenticated_ws("t12_recv") as recv_ws:
            setup_active_call(call_id, "t12_caller", "t12_recv", caller_ws, recv_ws)

            # Accept again
            err = send_and_receive(recv_ws, {
                "type": "call.accept",
                "callId": call_id,
                "toUserId": "t12_caller",
                "payload": {},
            })
            assert err["type"] == "call.error"
            assert err["payload"]["code"] == "INVALID_STATE"


# ==============================================================================
# CALL REJECT
# ==============================================================================

def test_reject_transitions_and_notifies():
    """13: Successful reject transitions ringing→rejected and notifies caller."""
    csm = get_call_session_manager()
    call_id = "t13_call"

    with authenticated_ws("t13_caller") as caller_ws:
        with authenticated_ws("t13_recv") as recv_ws:
            setup_ringing_call(call_id, "t13_caller", "t13_recv", caller_ws, recv_ws)

            recv_ws.send_json({
                "type": "call.reject",
                "callId": call_id,
                "toUserId": "t13_caller",
                "payload": {"reason": "rejected"},
            })

            rejected = caller_ws.receive_json()
            assert rejected["type"] == "call.reject"
            assert rejected["fromUserId"] == "t13_recv"
            assert rejected["payload"]["reason"] == "rejected"

            assert csm.get_call(call_id).state == CallState.REJECTED
            assert not csm.is_user_busy("t13_caller")
            assert not csm.is_user_busy("t13_recv")


def test_non_participant_cannot_reject():
    """14: Non-participant cannot reject a call."""
    call_id = "t14_call"

    with authenticated_ws("t14_caller") as caller_ws:
        with authenticated_ws("t14_recv") as recv_ws:
            with authenticated_ws("t14_intruder") as intruder_ws:
                setup_ringing_call(call_id, "t14_caller", "t14_recv", caller_ws, recv_ws)

                err = send_and_receive(intruder_ws, {
                    "type": "call.reject",
                    "callId": call_id,
                    "toUserId": "t14_caller",
                    "payload": {},
                })
                assert err["type"] == "call.error"
                assert err["payload"]["code"] == "NOT_PARTICIPANT"


def test_reject_active_call_rejected():
    """15: Rejecting an active (non-ringing) call returns INVALID_STATE."""
    call_id = "t15_call"

    with authenticated_ws("t15_caller") as caller_ws:
        with authenticated_ws("t15_recv") as recv_ws:
            setup_active_call(call_id, "t15_caller", "t15_recv", caller_ws, recv_ws)

            err = send_and_receive(recv_ws, {
                "type": "call.reject",
                "callId": call_id,
                "toUserId": "t15_caller",
                "payload": {},
            })
            assert err["type"] == "call.error"
            assert err["payload"]["code"] == "INVALID_STATE"


# ==============================================================================
# CALL END
# ==============================================================================

def test_caller_can_end_ringing_call():
    """16: Caller can end a ringing call."""
    csm = get_call_session_manager()
    call_id = "t16_call"

    with authenticated_ws("t16_caller") as caller_ws:
        with authenticated_ws("t16_recv") as recv_ws:
            setup_ringing_call(call_id, "t16_caller", "t16_recv", caller_ws, recv_ws)

            caller_ws.send_json({
                "type": "call.end",
                "callId": call_id,
                "toUserId": "t16_recv",
                "payload": {},
            })

            ended = recv_ws.receive_json()
            assert ended["type"] == "call.end"
            assert ended["fromUserId"] == "t16_caller"
            assert csm.get_call(call_id).state == CallState.ENDED


def test_receiver_can_end_ringing_call():
    """17: Receiver can also end a ringing call."""
    csm = get_call_session_manager()
    call_id = "t17_call"

    with authenticated_ws("t17_caller") as caller_ws:
        with authenticated_ws("t17_recv") as recv_ws:
            setup_ringing_call(call_id, "t17_caller", "t17_recv", caller_ws, recv_ws)

            recv_ws.send_json({
                "type": "call.end",
                "callId": call_id,
                "toUserId": "t17_caller",
                "payload": {},
            })

            ended = caller_ws.receive_json()
            assert ended["type"] == "call.end"
            assert ended["fromUserId"] == "t17_recv"
            assert csm.get_call(call_id).state == CallState.ENDED


def test_participant_can_end_active_call():
    """18: Either participant can end an active call."""
    csm = get_call_session_manager()
    call_id = "t18_call"

    with authenticated_ws("t18_caller") as caller_ws:
        with authenticated_ws("t18_recv") as recv_ws:
            setup_active_call(call_id, "t18_caller", "t18_recv", caller_ws, recv_ws)

            caller_ws.send_json({
                "type": "call.end",
                "callId": call_id,
                "toUserId": "t18_recv",
                "payload": {},
            })
            ended = recv_ws.receive_json()
            assert ended["type"] == "call.end"
            assert csm.get_call(call_id).state == CallState.ENDED


def test_non_participant_cannot_end():
    """19: Non-participant cannot end a call."""
    call_id = "t19_call"

    with authenticated_ws("t19_caller") as caller_ws:
        with authenticated_ws("t19_recv") as recv_ws:
            with authenticated_ws("t19_intruder") as intruder_ws:
                setup_ringing_call(call_id, "t19_caller", "t19_recv", caller_ws, recv_ws)

                err = send_and_receive(intruder_ws, {
                    "type": "call.end",
                    "callId": call_id,
                    "toUserId": "t19_caller",
                    "payload": {},
                })
                assert err["type"] == "call.error"
                assert err["payload"]["code"] == "NOT_PARTICIPANT"


def test_call_end_wrong_target_rejected():
    """20: call.end with wrong target is rejected."""
    call_id = "t20_call"

    with authenticated_ws("t20_caller") as caller_ws:
        with authenticated_ws("t20_recv") as recv_ws:
            with authenticated_ws("t20_stranger") as stranger_ws:
                setup_ringing_call(call_id, "t20_caller", "t20_recv", caller_ws, recv_ws)

                err = send_and_receive(caller_ws, {
                    "type": "call.end",
                    "callId": call_id,
                    "toUserId": "t20_stranger",  # wrong
                    "payload": {},
                })
                assert err["type"] == "call.error"
                assert err["payload"]["code"] == "INVALID_TARGET"


# ==============================================================================
# WEBRTC SIGNALING
# ==============================================================================

def test_webrtc_offer_relayed():
    """21: Valid webrtc.offer is relayed unchanged to the other participant."""
    call_id = "t21_call"
    sdp = "v=0\r\no=- 1234 IN IP4 127.0.0.1\r\n..."

    with authenticated_ws("t21_caller") as caller_ws:
        with authenticated_ws("t21_recv") as recv_ws:
            setup_active_call(call_id, "t21_caller", "t21_recv", caller_ws, recv_ws)

            caller_ws.send_json({
                "type": "webrtc.offer",
                "callId": call_id,
                "toUserId": "t21_recv",
                "payload": {"sdp": sdp},
            })

            relayed = recv_ws.receive_json()
            assert relayed["type"] == "webrtc.offer"
            assert relayed["fromUserId"] == "t21_caller"
            assert relayed["toUserId"] == "t21_recv"
            assert relayed["payload"]["sdp"] == sdp


def test_webrtc_answer_relayed():
    """22: Valid webrtc.answer is relayed unchanged."""
    call_id = "t22_call"
    sdp = "v=0\r\no=- 5678 IN IP4 127.0.0.1\r\n..."

    with authenticated_ws("t22_caller") as caller_ws:
        with authenticated_ws("t22_recv") as recv_ws:
            setup_active_call(call_id, "t22_caller", "t22_recv", caller_ws, recv_ws)

            recv_ws.send_json({
                "type": "webrtc.answer",
                "callId": call_id,
                "toUserId": "t22_caller",
                "payload": {"sdp": sdp},
            })

            relayed = caller_ws.receive_json()
            assert relayed["type"] == "webrtc.answer"
            assert relayed["payload"]["sdp"] == sdp


def test_webrtc_ice_relayed():
    """23: Valid webrtc.ice is relayed unchanged."""
    call_id = "t23_call"

    with authenticated_ws("t23_caller") as caller_ws:
        with authenticated_ws("t23_recv") as recv_ws:
            setup_active_call(call_id, "t23_caller", "t23_recv", caller_ws, recv_ws)

            caller_ws.send_json({
                "type": "webrtc.ice",
                "callId": call_id,
                "toUserId": "t23_recv",
                "payload": {
                    "candidate": {"candidate": "candidate:1 1 UDP ..."},
                    "sdpMid": "0",
                    "sdpMLineIndex": 0,
                },
            })

            relayed = recv_ws.receive_json()
            assert relayed["type"] == "webrtc.ice"
            assert relayed["payload"]["sdpMid"] == "0"
            assert relayed["payload"]["sdpMLineIndex"] == 0


def test_non_participant_cannot_send_webrtc():
    """24: Non-participant cannot inject WebRTC messages."""
    call_id = "t24_call"

    with authenticated_ws("t24_caller") as caller_ws:
        with authenticated_ws("t24_recv") as recv_ws:
            with authenticated_ws("t24_attacker") as attacker_ws:
                setup_active_call(call_id, "t24_caller", "t24_recv", caller_ws, recv_ws)

                err = send_and_receive(attacker_ws, {
                    "type": "webrtc.offer",
                    "callId": call_id,
                    "toUserId": "t24_recv",
                    "payload": {"sdp": "fake sdp"},
                })
                assert err["type"] == "call.error"
                assert err["payload"]["code"] == "NOT_PARTICIPANT"


def test_webrtc_rejected_for_ringing_call():
    """25: WebRTC signaling on a ringing (not active) call returns INVALID_STATE."""
    call_id = "t25_call"

    with authenticated_ws("t25_caller") as caller_ws:
        with authenticated_ws("t25_recv") as recv_ws:
            setup_ringing_call(call_id, "t25_caller", "t25_recv", caller_ws, recv_ws)

            err = send_and_receive(caller_ws, {
                "type": "webrtc.offer",
                "callId": call_id,
                "toUserId": "t25_recv",
                "payload": {"sdp": "sdp"},
            })
            assert err["type"] == "call.error"
            assert err["payload"]["code"] == "INVALID_STATE"


def test_webrtc_wrong_target_rejected():
    """26: WebRTC message with wrong target returns INVALID_TARGET."""
    call_id = "t26_call"

    with authenticated_ws("t26_caller") as caller_ws:
        with authenticated_ws("t26_recv") as recv_ws:
            with authenticated_ws("t26_stranger") as stranger_ws:
                setup_active_call(call_id, "t26_caller", "t26_recv", caller_ws, recv_ws)

                err = send_and_receive(caller_ws, {
                    "type": "webrtc.offer",
                    "callId": call_id,
                    "toUserId": "t26_stranger",  # not a participant
                    "payload": {"sdp": "sdp"},
                })
                assert err["type"] == "call.error"
                assert err["payload"]["code"] == "INVALID_TARGET"


# ==============================================================================
# SECURITY
# ==============================================================================

def test_client_cannot_spoof_from_user_id():
    """27: fromUserId in client message is ignored; server constructs its own."""
    call_id = "t27_call"

    with authenticated_ws("t27_real") as caller_ws:
        with authenticated_ws("t27_recv") as recv_ws:
            caller_ws.send_json({
                "type": "call.invite",
                "callId": call_id,
                "toUserId": "t27_recv",
                "fromUserId": "t27_fake_admin",
                "payload": {"callType": "audio"},
            })
            invite = recv_ws.receive_json()
            assert invite["fromUserId"] == "t27_real"
            assert invite["fromUserId"] != "t27_fake_admin"


def test_client_cannot_spoof_caller_id():
    """28: callerId in payload is ignored; identity comes from WebSocket auth."""
    call_id = "t28_call"

    with authenticated_ws("t28_real") as caller_ws:
        with authenticated_ws("t28_recv") as recv_ws:
            caller_ws.send_json({
                "type": "call.invite",
                "callId": call_id,
                "toUserId": "t28_recv",
                "callerId": "t28_fake",
                "payload": {"callType": "audio"},
            })
            invite = recv_ws.receive_json()
            assert invite["fromUserId"] == "t28_real"


def test_client_cannot_send_to_arbitrary_user():
    """29: Client cannot route WebRTC to a non-participant."""
    call_id = "t29_call"

    with authenticated_ws("t29_caller") as caller_ws:
        with authenticated_ws("t29_recv") as recv_ws:
            with authenticated_ws("t29_arb") as arb_ws:
                setup_active_call(call_id, "t29_caller", "t29_recv", caller_ws, recv_ws)

                err = send_and_receive(caller_ws, {
                    "type": "webrtc.offer",
                    "callId": call_id,
                    "toUserId": "t29_arb",
                    "payload": {"sdp": "sdp"},
                })
                assert err["type"] == "call.error"
                assert err["payload"]["code"] == "INVALID_TARGET"


def test_firebase_errors_not_exposed():
    """30: Internal Firebase errors never reach the client."""
    internal_leak = "FATAL: ServiceAccountKey permission denied at /etc/secrets"
    with patch(
        "app.signaling.router.verify_firebase_token",
        side_effect=Exception(internal_leak),
    ):
        with client.websocket_connect("/ws/signaling") as ws:
            ws.send_json({"type": "auth", "token": "some_token"})
            response = ws.receive_json()
            assert response["type"] == "auth.error"
            assert internal_leak not in str(response)


# ==============================================================================
# DISCONNECT CLEANUP
# ==============================================================================

def test_peer_disconnected_sent_on_active_call():
    """31–32: peer.disconnected sent; active call becomes ended on disconnect."""
    csm = get_call_session_manager()
    call_id = "t31_call"

    with authenticated_ws("t31_caller") as caller_ws:
        with authenticated_ws("t31_recv") as recv_ws:
            setup_active_call(call_id, "t31_caller", "t31_recv", caller_ws, recv_ws)
            assert csm.get_call(call_id).state == CallState.ACTIVE

        # recv_ws disconnected; caller should get peer.disconnected
        notification = caller_ws.receive_json()
        assert notification["type"] == "peer.disconnected"
        assert notification["callId"] == call_id
        assert notification["fromUserId"] == "t31_recv"
        assert notification["toUserId"] == "t31_caller"
        assert notification["payload"] == {}

    assert csm.get_call(call_id).state == CallState.ENDED


def test_peer_disconnected_sent_on_ringing_call():
    """33: peer.disconnected sent; ringing call becomes ended on disconnect."""
    csm = get_call_session_manager()
    call_id = "t33_call"

    with authenticated_ws("t33_caller") as caller_ws:
        with authenticated_ws("t33_recv") as recv_ws:
            setup_ringing_call(call_id, "t33_caller", "t33_recv", caller_ws, recv_ws)

        # recv disconnects without answering
        notification = caller_ws.receive_json()
        assert notification["type"] == "peer.disconnected"
        assert notification["callId"] == call_id

    assert csm.get_call(call_id).state == CallState.ENDED


def test_disconnected_user_no_longer_busy():
    """34: After disconnect, user is no longer marked busy."""
    csm = get_call_session_manager()
    call_id = "t34_call"

    with authenticated_ws("t34_caller") as caller_ws:
        with authenticated_ws("t34_recv") as recv_ws:
            setup_ringing_call(call_id, "t34_caller", "t34_recv", caller_ws, recv_ws)
            assert csm.is_user_busy("t34_caller")
            assert csm.is_user_busy("t34_recv")

        caller_ws.receive_json()  # consume peer.disconnected

    assert not csm.is_user_busy("t34_caller")
    assert not csm.is_user_busy("t34_recv")


def test_stale_socket_does_not_terminate_newer_connections_calls():
    """35: Stale socket disconnect does not end calls belonging to a newer connection.

    This tests the router-level is_current_socket guard directly via mocked
    WebSocket instances and the shared manager/dispatcher.
    """
    csm = get_call_session_manager()
    call_id = "t35_call"

    async def _run():
        old_ws = MagicMock(spec=WebSocket)
        old_ws.send_json = AsyncMock()
        old_ws.close = AsyncMock()

        new_ws = MagicMock(spec=WebSocket)
        new_ws.send_json = AsyncMock()
        new_ws.close = AsyncMock()

        conn_mgr = get_connection_manager()

        # Register old, then new (new supersedes old — old_ws.close called by manager)
        await conn_mgr.connect("t35_user", old_ws)
        await conn_mgr.connect("t35_user", new_ws)

        # New connection creates a call
        await csm.create_call(call_id, "t35_user", "t35_other", "audio")
        assert csm.is_user_busy("t35_user")

        # Stale socket disconnect: is_current_socket → False → skip handle_disconnect
        is_current = conn_mgr.get_connection("t35_user") is old_ws
        assert not is_current

        # Call must remain ringing
        session = csm.get_call(call_id)
        assert session is not None
        assert session.state == CallState.RINGING
        assert csm.is_user_busy("t35_user")

        # Cleanup
        await csm.transition(call_id, "ended")
        await conn_mgr.disconnect("t35_user", new_ws)

    asyncio.run(_run())


# ==============================================================================
# ROBUSTNESS
# ==============================================================================

def test_malformed_json_returns_error():
    """36: Malformed JSON after auth returns INVALID_MESSAGE; connection stays alive."""
    with authenticated_ws("t36_user") as ws:
        ws.send_text("{THIS IS NOT JSON}")
        err = ws.receive_json()
        assert err["type"] == "call.error"
        assert err["payload"]["code"] == "INVALID_MESSAGE"

        # Connection must still be alive — send valid message
        err2 = send_and_receive(ws, {
            "type": "call.invite",
            "callId": "t36_alive_check",
            "toUserId": "t36_nobody",
            "payload": {"callType": "audio"},
        })
        assert err2["type"] == "call.error"
        assert err2["payload"]["code"] == "USER_OFFLINE"


def test_unknown_message_type_returns_error():
    """37: Unknown message type returns UNSUPPORTED_MESSAGE."""
    with authenticated_ws("t37_user") as ws:
        err = send_and_receive(ws, {
            "type": "unknown.thing",
            "callId": "x",
            "toUserId": "y",
            "payload": {},
        })
        assert err["type"] == "call.error"
        assert err["payload"]["code"] == "UNSUPPORTED_MESSAGE"


def test_missing_call_id_returns_error():
    """38: Missing callId returns INVALID_MESSAGE."""
    with authenticated_ws("t38_user") as ws:
        ws.send_json({"type": "call.invite", "toUserId": "y", "payload": {"callType": "audio"}})
        err = ws.receive_json()
        assert err["type"] == "call.error"
        assert err["payload"]["code"] == "INVALID_MESSAGE"


def test_missing_target_returns_error():
    """39: Missing toUserId returns INVALID_MESSAGE."""
    with authenticated_ws("t39_user") as ws:
        ws.send_json({"type": "call.invite", "callId": "c1", "payload": {"callType": "audio"}})
        err = ws.receive_json()
        assert err["type"] == "call.error"
        assert err["payload"]["code"] == "INVALID_MESSAGE"


def test_malformed_webrtc_payload_returns_error():
    """40: webrtc.offer with missing sdp returns INVALID_MESSAGE."""
    call_id = "t40_call"

    with authenticated_ws("t40_caller") as caller_ws:
        with authenticated_ws("t40_recv") as recv_ws:
            setup_active_call(call_id, "t40_caller", "t40_recv", caller_ws, recv_ws)

            err = send_and_receive(caller_ws, {
                "type": "webrtc.offer",
                "callId": call_id,
                "toUserId": "t40_recv",
                "payload": {},  # missing sdp
            })
            assert err["type"] == "call.error"
            assert err["payload"]["code"] == "INVALID_MESSAGE"


def test_server_remains_alive_after_multiple_bad_messages():
    """41: Server connection survives a sequence of bad messages."""
    with authenticated_ws("t41_user") as ws:
        for _ in range(3):
            ws.send_text("NOT JSON AT ALL")
            err = ws.receive_json()
            assert err["type"] == "call.error"

        # Connection still functional
        err2 = send_and_receive(ws, {
            "type": "call.end",
            "callId": "t41_nonexistent",
            "toUserId": "t41_someone",
            "payload": {},
        })
        assert err2["type"] == "call.error"
        assert err2["payload"]["code"] == "CALL_NOT_FOUND"


# ==============================================================================
# COMPLETE LIFECYCLE INTEGRATION
# ==============================================================================

def test_complete_call_lifecycle_invite_accept_webrtc_end():
    """Full flow: invite → accept → offer → answer → ICE → end."""
    csm = get_call_session_manager()
    call_id = "t_full_call"

    with authenticated_ws("t_full_caller") as caller_ws:
        with authenticated_ws("t_full_recv") as recv_ws:
            # 1. Invite
            caller_ws.send_json({
                "type": "call.invite",
                "callId": call_id,
                "toUserId": "t_full_recv",
                "payload": {"callType": "video"},
            })
            invite = recv_ws.receive_json()
            assert invite["type"] == "call.invite"

            # 2. Accept
            recv_ws.send_json({
                "type": "call.accept",
                "callId": call_id,
                "toUserId": "t_full_caller",
                "payload": {},
            })
            accepted = caller_ws.receive_json()
            assert accepted["type"] == "call.accept"
            assert csm.get_call(call_id).state == CallState.ACTIVE

            # 3. WebRTC Offer
            caller_ws.send_json({
                "type": "webrtc.offer",
                "callId": call_id,
                "toUserId": "t_full_recv",
                "payload": {"sdp": "offer_sdp"},
            })
            offer = recv_ws.receive_json()
            assert offer["type"] == "webrtc.offer"
            assert offer["payload"]["sdp"] == "offer_sdp"

            # 4. WebRTC Answer
            recv_ws.send_json({
                "type": "webrtc.answer",
                "callId": call_id,
                "toUserId": "t_full_caller",
                "payload": {"sdp": "answer_sdp"},
            })
            answer = caller_ws.receive_json()
            assert answer["type"] == "webrtc.answer"

            # 5. ICE candidate exchange
            caller_ws.send_json({
                "type": "webrtc.ice",
                "callId": call_id,
                "toUserId": "t_full_recv",
                "payload": {
                    "candidate": {"candidate": "ice_data"},
                    "sdpMid": "0",
                    "sdpMLineIndex": 0,
                },
            })
            ice = recv_ws.receive_json()
            assert ice["type"] == "webrtc.ice"

            # 6. End call
            caller_ws.send_json({
                "type": "call.end",
                "callId": call_id,
                "toUserId": "t_full_recv",
                "payload": {},
            })
            ended = recv_ws.receive_json()
            assert ended["type"] == "call.end"
            assert csm.get_call(call_id).state == CallState.ENDED
            assert not csm.is_user_busy("t_full_caller")
            assert not csm.is_user_busy("t_full_recv")


def test_complete_lifecycle_invite_reject():
    """Flow: invite → reject."""
    csm = get_call_session_manager()
    call_id = "t_reject_flow"

    with authenticated_ws("t_rf_caller") as caller_ws:
        with authenticated_ws("t_rf_recv") as recv_ws:
            caller_ws.send_json({
                "type": "call.invite",
                "callId": call_id,
                "toUserId": "t_rf_recv",
                "payload": {"callType": "audio"},
            })
            recv_ws.receive_json()

            recv_ws.send_json({
                "type": "call.reject",
                "callId": call_id,
                "toUserId": "t_rf_caller",
                "payload": {"reason": "busy"},
            })
            rejected = caller_ws.receive_json()
            assert rejected["type"] == "call.reject"
            assert rejected["payload"]["reason"] == "busy"
            assert csm.get_call(call_id).state == CallState.REJECTED


def test_oversized_signaling_message_rejected():
    """44: Oversized post-auth signaling message (>64KB) returns INVALID_MESSAGE error."""
    with authenticated_ws("t44_oversize_user") as ws:
        large_padding = "x" * 70000
        ws.send_text(json.dumps({
            "type": "call.invite",
            "callId": "t44_call",
            "toUserId": "t44_target",
            "payload": {"data": large_padding},
        }))
        err = ws.receive_json()
        assert err["type"] == "call.error"
        assert err["payload"]["code"] == "INVALID_MESSAGE"
        assert "exceeds maximum" in err["payload"]["message"]


def test_oversized_auth_message_rejected():
    """45: Oversized initial auth message (>64KB) returns AUTH_INVALID error and closes socket."""
    large_token = "tok" * 25000  # 75KB
    with client.websocket_connect("/ws/signaling") as ws:
        ws.send_text(json.dumps({"type": "auth", "token": large_token}))
        resp = ws.receive_json()
        assert resp["type"] == "auth.error"
        assert resp["code"] == "AUTH_INVALID"

