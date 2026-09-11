import asyncio
from typing import Any, Dict, Optional

from fastapi import WebSocket


class ConnectionManager:
    """Manages active authenticated signaling WebSocket connections.

    Key Architectural Rules:
    1. Canonical Key: Verified Firebase UID (never client-supplied userIds, emails, or names).
    2. One-User-One-Connection: Each user has at most ONE active signaling connection.
       Registering a new connection for an existing user cleanly supersedes and closes
       the prior connection.
    3. Stale Disconnect Safety: Disconnecting an older socket will not accidentally remove
       a newer active socket for the same user.
    """

    def __init__(self) -> None:
        self._connections: Dict[str, WebSocket] = {}
        self._lock: asyncio.Lock = asyncio.Lock()

    async def connect(self, user_id: str, websocket: WebSocket) -> None:
        """Register an active connection for an authenticated Firebase UID.

        If a previous connection already exists for this user, it is cleanly closed
        and replaced by the new connection.
        """
        async with self._lock:
            existing_ws = self._connections.get(user_id)
            if existing_ws is not None and existing_ws is not websocket:
                try:
                    await existing_ws.close(
                        code=4000,
                        reason="Superseded by new connection",
                    )
                except Exception:
                    # Ignore errors if the older socket was already closed or dead
                    pass

            self._connections[user_id] = websocket

    async def disconnect(self, user_id: str, websocket: Optional[WebSocket] = None) -> None:
        """Safely remove a user's connection.

        If a specific websocket instance is provided, it is only removed if it matches
        the currently registered socket for that user. This prevents a stale/older
        connection's disconnect event from removing a newer, active connection.

        This method is safe to call multiple times or on already disconnected users.
        """
        async with self._lock:
            current_ws = self._connections.get(user_id)
            if current_ws is not None:
                if websocket is None or current_ws is websocket:
                    del self._connections[user_id]

    def is_connected(self, user_id: str) -> bool:
        """Check whether an authenticated user is currently connected."""
        return user_id in self._connections

    def get_connection(self, user_id: str) -> Optional[WebSocket]:
        """Retrieve the active WebSocket for a user, or None if offline."""
        return self._connections.get(user_id)

    async def send_to_user(self, user_id: str, message: Dict[str, Any]) -> bool:
        """Send a JSON-serializable message dictionary to a specific connected user.

        Uses the WebSocket's native JSON serialization (send_json).

        Returns:
            bool: True if the message was sent successfully.
                  False if the user is offline or if sending failed.

        If sending fails because the socket is dead or disconnected, the stale
        connection is safely removed from the registry.
        """
        websocket = self.get_connection(user_id)
        if websocket is None:
            return False

        try:
            await websocket.send_json(message)
            return True
        except Exception:
            # Dead or disconnected socket: purge safely from registry
            await self.disconnect(user_id, websocket)
            return False

    def active_connections_count(self) -> int:
        """Return the number of currently active connections."""
        return len(self._connections)
