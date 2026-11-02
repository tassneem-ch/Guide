"""Vercel entrypoint.

Vercel's Python runtime looks for a FastAPI instance named `app` in a
supported root filename (app.py, main.py, server.py, ...). The real
application lives in ``backend/app/main.py`` and runs locally as
``uvicorn app.main:app`` — this module only re-exports it so the backend
package stays untouched.

Static assets (the Flutter web build) are served from ``public/`` by
Vercel's CDN at matching root paths; every path that matches no file —
i.e. all ``/v1/...`` API calls — reaches this function.
"""
from __future__ import annotations

from backend.app.main import app

__all__ = ["app"]
