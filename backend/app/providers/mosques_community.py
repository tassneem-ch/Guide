"""Community-submitted mosques merged into the configured mosque provider.

This is a *decorator* around whichever provider the environment selects
(OSM, Google, fixture) — community data augments discovery, it never
replaces the primary source, and a community failure can never corrupt
the primary provider's result.

Honesty rules:
* only `verified` records join results by default; `unverified` records
  are included only when COMMUNITY_INCLUDE_UNVERIFIED=true (an operator
  opt-in — they stay labelled unverified either way);
* provenance is always `provider="community"` with an explicit note —
  community records are never presented as Google/OSM data;
* a community record that duplicates a primary provider result (within
  150 m with a matching name) is dropped — the external record wins, and
  proximity alone NEVER marks anything verified;
* user-supplied opening hours carry Verification.UNVERIFIED always.
"""
from __future__ import annotations

import asyncio
import math
from datetime import datetime, timezone

from ..config import get_settings
from ..db.models import CommunityMosque
from ..db.session import SessionLocal
from ..domain.geo import GeoPoint, haversine_m
from ..domain.mosque import (
    DataQuality,
    MosqueCandidate,
    MosqueSearchResult,
    Verification,
)
from .base import MosqueProvider

DEDUP_RADIUS_M = 150.0


def _normalize_name(name: str | None) -> str:
    return " ".join((name or "").casefold().split())


class CommunityMosqueProvider:
    """Wraps the primary provider and merges eligible community records."""

    def __init__(self, primary: MosqueProvider) -> None:
        self._primary = primary
        # Report honestly in /v1/health: the primary slot is still visible.
        self.name = f"{primary.name}+community"
        self.live = primary.live

    async def search_near(
        self, center: GeoPoint, radius_m: int, query: str | None = None
    ) -> MosqueSearchResult:
        primary = await self._primary.search_near(center, radius_m, query)

        try:
            extra = await asyncio.to_thread(
                self._community_near, center, radius_m
            )
        except Exception:
            # A community-source failure must never fabricate or corrupt
            # primary results — degrade to the primary answer only.
            return primary

        if not extra:
            return primary

        # Drop community duplicates of primary results (external wins).
        kept: list[MosqueCandidate] = []
        for cand in extra:
            duplicate = any(
                haversine_m(cand.location, ext.location) <= DEDUP_RADIUS_M
                and (
                    _normalize_name(cand.name) == _normalize_name(ext.name)
                    # An unnamed community record near a named external one
                    # is likely the same mosque — the external record has
                    # richer provenance, so let it stand.
                    or not cand.name
                )
                for ext in primary.candidates
            )
            if not duplicate:
                kept.append(cand)

        if not kept:
            return primary

        return MosqueSearchResult(
            candidates=[*primary.candidates, *kept],
            queried_bbox=primary.queried_bbox,
            # Keep the primary verdict; community records carry their own
            # provenance and must not launder a fixture label (or vice
            # versa — the merged list is not "live" just because the
            # community rows are real).
            status=primary.status,
            message=primary.message,
        )

    # ------------------------------------------------------------------
    def _community_near(
        self, center: GeoPoint, radius_m: int
    ) -> list[MosqueCandidate]:
        settings = get_settings()
        if not settings.community_mosques_enabled:
            return []

        statuses = ["verified"]
        if settings.community_include_unverified:
            statuses.append("unverified")

        # Bounding-box prefilter (no PostGIS requirement), then exact
        # haversine filter in Python.
        dlat = radius_m / 111_320.0
        cos_lat = max(abs(math.cos(math.radians(center.lat))), 1e-6)
        dlon = radius_m / (111_320.0 * cos_lat)

        db = SessionLocal()
        try:
            rows = (
                db.query(CommunityMosque)
                .filter(CommunityMosque.status.in_(statuses))
                .filter(CommunityMosque.lat.between(center.lat - dlat, center.lat + dlat))
                .filter(CommunityMosque.lon.between(center.lon - dlon, center.lon + dlon))
                .all()
            )
        finally:
            db.close()

        fetched_at = datetime.now(timezone.utc)
        out: list[MosqueCandidate] = []
        for row in rows:
            loc = GeoPoint(lat=row.lat, lon=row.lon, tz=center.tz)
            if haversine_m(center, loc) > radius_m:
                continue
            notes = [
                "Community-submitted record — not from Google or OpenStreetMap."
            ]
            if row.status == "verified":
                notes.append("Confirmed by a Guide moderator.")
            else:
                notes.append(
                    "UNVERIFIED community submission — included only because "
                    "the operator enabled COMMUNITY_INCLUDE_UNVERIFIED."
                )
            out.append(
                MosqueCandidate(
                    # Namespaced id: a community id can never collide with a
                    # Google/OSM id in the discovery merge.
                    id=f"community-{row.id}",
                    name=row.name,  # None stays None — unnamed, never invented
                    location=loc,
                    quality=DataQuality(
                        provider="community",
                        source="live",  # real rows from the live local DB
                        fetched_at=fetched_at,
                        notes=notes,
                    ),
                    opening_hours=row.opening_hours or None,
                    # Community hours are user-supplied: never "verified".
                    opening_hours_verification=(
                        Verification.UNVERIFIED
                        if row.opening_hours
                        else Verification.UNKNOWN
                    ),
                )
            )
        return out

    async def close(self) -> None:
        await self._primary.close()
