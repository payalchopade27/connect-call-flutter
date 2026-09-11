from typing import Any, Dict

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import get_settings
from app.signaling.router import router as signaling_router

settings = get_settings()

app = FastAPI(
    title=settings.PROJECT_NAME,
    version="0.1.0",
    description="Signaling backend server for ConnectCall 1-to-1 WebRTC calling.",
)

# CORS configuration
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Register signaling WebSocket router
app.include_router(signaling_router)


@app.get("/health", summary="Health Check", tags=["System"])
def health_check() -> Dict[str, Any]:
    """Returns the operational status of the service."""
    return {"status": "ok"}
