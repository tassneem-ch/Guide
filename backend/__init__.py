"""Marks ``backend`` as a regular package.

Locally the backend runs from inside ``backend/`` (``uvicorn app.main:app``)
so this file is never imported. On Vercel the entrypoint at the repository
root imports ``backend.app.main``, and an explicit package marker keeps that
import deterministic instead of relying on namespace-package fallback.
"""
