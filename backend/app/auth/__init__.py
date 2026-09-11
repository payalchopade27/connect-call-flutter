"""Authentication package for ConnectCall backend."""

from app.auth.firebase_auth import (
    AuthenticationError,
    FirebaseConfigError,
    initialize_firebase_admin,
    verify_firebase_token,
)

__all__ = [
    "AuthenticationError",
    "FirebaseConfigError",
    "initialize_firebase_admin",
    "verify_firebase_token",
]
