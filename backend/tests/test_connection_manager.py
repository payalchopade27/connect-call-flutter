import asyncio
from unittest.mock import AsyncMock, MagicMock

from fastapi import WebSocket

from app.signaling.manager import ConnectionManager


def create_mock_websocket() -> WebSocket:
    """Helper to create a mock WebSocket with async send_json and close methods."""
    ws = MagicMock(spec=WebSocket)
    ws.send_json = AsyncMock()
    ws.close = AsyncMock()
    return ws


# ==============================================================================
# ConnectionManager Unit Tests
# ==============================================================================

def test_register_and_discover_connection():
    """1 & 2: Register a connection and verify it is discoverable by userId."""
    async def _test():
        manager = ConnectionManager()
        ws = create_mock_websocket()
        user_id = "firebase_user_abc"

        assert not manager.is_connected(user_id)
        assert manager.active_connections_count() == 0

        await manager.connect(user_id, ws)

        assert manager.is_connected(user_id)
        assert manager.active_connections_count() == 1

    asyncio.run(_test())


def test_is_connected_and_get_connection():
    """3 & 4: Verify is_connected() and get_connection() return expected states."""
    async def _test():
        manager = ConnectionManager()
        ws = create_mock_websocket()
        user_id = "firebase_user_123"

        assert manager.get_connection(user_id) is None
        assert not manager.is_connected(user_id)

        await manager.connect(user_id, ws)

        assert manager.is_connected(user_id)
        assert manager.get_connection(user_id) is ws
        assert manager.get_connection("non_existent_user") is None

    asyncio.run(_test())


def test_send_to_user_success():
    """5: send_to_user sends JSON payload via websocket.send_json and returns True."""
    async def _test():
        manager = ConnectionManager()
        ws = create_mock_websocket()
        user_id = "firebase_user_recipient"
        message = {"type": "ping", "data": {"timestamp": 12345}}

        await manager.connect(user_id, ws)
        result = await manager.send_to_user(user_id, message)

        assert result is True
        ws.send_json.assert_awaited_once_with(message)

    asyncio.run(_test())


def test_disconnect_removes_connection():
    """6: disconnect() removes connection from registry."""
    async def _test():
        manager = ConnectionManager()
        ws = create_mock_websocket()
        user_id = "user_to_disconnect"

        await manager.connect(user_id, ws)
        assert manager.is_connected(user_id)

        await manager.disconnect(user_id, ws)
        assert not manager.is_connected(user_id)
        assert manager.get_connection(user_id) is None
        assert manager.active_connections_count() == 0

    asyncio.run(_test())


def test_disconnect_already_disconnected_user():
    """7: Disconnecting an already disconnected user must not crash or raise exceptions."""
    async def _test():
        manager = ConnectionManager()
        user_id = "already_offline_user"

        # Should safely no-op
        await manager.disconnect(user_id)
        await manager.disconnect(user_id, create_mock_websocket())
        assert not manager.is_connected(user_id)

    asyncio.run(_test())


def test_replace_existing_connection_closes_older_socket():
    """8: Replacing an existing connection closes older socket with code 4000."""
    async def _test():
        manager = ConnectionManager()
        old_ws = create_mock_websocket()
        new_ws = create_mock_websocket()
        user_id = "user_reconnecting"

        # Connect initial socket
        await manager.connect(user_id, old_ws)
        assert manager.get_connection(user_id) is old_ws

        # Connect newer socket for same user
        await manager.connect(user_id, new_ws)

        # Verify older socket was closed with code 4000
        old_ws.close.assert_awaited_once_with(
            code=4000,
            reason="Superseded by new connection",
        )
        # Verify manager now references new socket
        assert manager.get_connection(user_id) is new_ws
        assert manager.active_connections_count() == 1

    asyncio.run(_test())


def test_stale_old_connection_cannot_remove_newer_connection():
    """9: Stale disconnect of an older socket must NOT remove the newer registered socket."""
    async def _test():
        manager = ConnectionManager()
        old_ws = create_mock_websocket()
        new_ws = create_mock_websocket()
        user_id = "user_with_race_condition"

        # Socket 1 connects
        await manager.connect(user_id, old_ws)
        # Socket 2 replaces Socket 1
        await manager.connect(user_id, new_ws)

        # Socket 1 disconnect event fires later
        await manager.disconnect(user_id, websocket=old_ws)

        # Socket 2 must still remain active!
        assert manager.is_connected(user_id)
        assert manager.get_connection(user_id) is new_ws
        assert manager.active_connections_count() == 1

        # Only disconnecting the matching new_ws should remove it
        await manager.disconnect(user_id, websocket=new_ws)
        assert not manager.is_connected(user_id)
        assert manager.active_connections_count() == 0

    asyncio.run(_test())


def test_send_to_offline_user_does_not_crash():
    """10: Sending to an offline user returns False without crashing."""
    async def _test():
        manager = ConnectionManager()
        result = await manager.send_to_user("non_existent_uid", {"type": "test"})
        assert result is False

    asyncio.run(_test())


def test_failed_send_removes_stale_connection_safely():
    """11: If websocket.send_json fails (dead connection), purge stale entry safely."""
    async def _test():
        manager = ConnectionManager()
        dead_ws = create_mock_websocket()
        dead_ws.send_json.side_effect = RuntimeError("WebSocket connection is closed")
        user_id = "user_with_dead_socket"

        await manager.connect(user_id, dead_ws)
        assert manager.is_connected(user_id)

        result = await manager.send_to_user(user_id, {"type": "msg"})

        assert result is False
        # Verify the dead connection was purged
        assert not manager.is_connected(user_id)
        assert manager.get_connection(user_id) is None
        assert manager.active_connections_count() == 0

    asyncio.run(_test())
