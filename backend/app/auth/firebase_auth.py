from pathlib import Path
from typing import Any, Dict, Optional

import firebase_admin
from firebase_admin import auth, credentials

from app.core.config import get_settings


class FirebaseConfigError(Exception):
    """Raised when Firebase configuration or credentials file is invalid/missing."""

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class AuthenticationError(Exception):
    """Raised when token verification fails."""

    def __init__(self, message: str, code: str = "AUTH_INVALID") -> None:
        super().__init__(message)
        self.message = message
        self.code = code


def initialize_firebase_admin(credentials_path: Optional[str] = None) -> firebase_admin.App:
    """Initialize Firebase Admin SDK once using configured service account credentials.

    If Firebase Admin is already initialized, the existing default app is returned.
    If credentials are missing or invalid, a clear FirebaseConfigError is raised.
    """
    # Check if default app is already initialized
    if firebase_admin._apps:
        return firebase_admin.get_app()

    settings = get_settings()
    path_str = credentials_path or settings.FIREBASE_CREDENTIALS_PATH

    if not path_str or not path_str.strip():
        raise FirebaseConfigError(
            "FIREBASE_CREDENTIALS_PATH is not set in settings or environment variables. "
            "Please provide a valid path to your Firebase service-account JSON file."
        )

    cred_path = Path(path_str).resolve()
    if not cred_path.is_file():
        raise FirebaseConfigError(
            f"Firebase service-account credentials file was not found at: {cred_path}"
        )

    try:
        cred = credentials.Certificate(str(cred_path))
        return firebase_admin.initialize_app(cred)
    except Exception as exc:
        raise FirebaseConfigError(
            f"Failed to initialize Firebase Admin SDK with credentials at {cred_path}: {exc}"
        ) from exc


def verify_firebase_token(id_token: str) -> Dict[str, Any]:
    """Verify a Firebase Authentication ID token and return the decoded claims.

    Important Architecture Rule:
        The canonical identity of the user is ALWAYS decoded_token["uid"].
        Never trust a client-supplied userId.

    Returns:
        Dict[str, Any]: The decoded token payload containing the verified "uid".

    Raises:
        AuthenticationError: If the token is empty, invalid, expired, or revoked.
        FirebaseConfigError: If Firebase Admin SDK cannot be initialized.
    """
    if not id_token or not id_token.strip():
        raise AuthenticationError("Authentication token is missing or empty.", code="AUTH_INVALID")

    # Ensure Firebase Admin SDK is initialized
    initialize_firebase_admin()

    try:
        decoded_token: Dict[str, Any] = auth.verify_id_token(id_token)
        if "uid" not in decoded_token or not decoded_token["uid"]:
            raise AuthenticationError(
                "Verified token does not contain a valid UID.",
                code="AUTH_INVALID",
            )
        return decoded_token
    except auth.ExpiredIdTokenError as exc:
        raise AuthenticationError("Firebase ID token has expired.", code="AUTH_EXPIRED") from exc
    except auth.RevokedIdTokenError as exc:
        raise AuthenticationError("Firebase ID token has been revoked.", code="AUTH_REVOKED") from exc
    except auth.InvalidIdTokenError as exc:
        raise AuthenticationError(f"Firebase ID token is invalid: {exc}", code="AUTH_INVALID") from exc
    except auth.CertificateFetchError as exc:
        raise AuthenticationError(
            "Failed to fetch public certificates to verify token.",
            code="AUTH_SERVER_ERROR",
        ) from exc
    except AuthenticationError:
        raise
    except FirebaseConfigError:
        raise
    except Exception as exc:
        raise AuthenticationError(
            f"Token verification failed: {exc}",
            code="AUTH_INVALID",
        ) from exc
