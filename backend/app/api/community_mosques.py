"""Community mosque submissions (secondary utility, never a data source of
record for planning unless reviewed).

Honesty/privacy rules:
* submissions are accepted anonymously or from an optional account — no
  other personal data is requested or stored;
* the client cannot set a verification status (absent from the schema);
* duplicates (same coordinates ±150 m with the same/absent name) are
  rejected with 409 so accidental double-taps don't pollute the table;
* `rejected` records are invisible on every read path;
* moderation is a minimal token-guarded endpoint (X-Admin-Token) — no
  admin UI exists yet; see docs/PROVIDERS.md for the follow-up.
"""
from __future__ import annotations

import math
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from sqlalchemy.orm import Session

from ..config import get_settings
from ..core.ratelimit import default_limit, limiter
from ..db.models import CommunityMosque
from ..db.session import get_db
from ..domain.geo import GeoPoint, haversine_m
from ..security import current_user_optional
from .schemas import (
    CommunityMosqueOut,
    CommunityMosqueReport,
    CommunityMosqueReview,
    CommunityMosqueSubmit,
)

router = APIRouter(prefix="/v1/community/mosques", tags=["community"])

DUPLICATE_RADIUS_M = 150.0


def _normalize_name(name: str | None) -> str:
    """Case/whitespace-insensitive comparison key; None stays empty."""
    return " ".join((name or "").casefold().split())


def _to_out(row: CommunityMosque) -> CommunityMosqueOut:
    return CommunityMosqueOut(
        id=row.id,
        name=row.name,
        lat=row.lat,
        lon=row.lon,
        address=row.address,
        opening_hours=row.opening_hours,
        status=row.status,
        created_at=row.created_at,
    )


@router.post("", response_model=CommunityMosqueOut)
@limiter.limit(default_limit())
async def submit_mosque(
    req: CommunityMosqueSubmit,
    request: Request,
    user_id: str | None = Depends(current_user_optional),
    db: Session = Depends(get_db),
) -> CommunityMosqueOut:
    settings = get_settings()
    if not settings.community_mosques_enabled:
        raise HTTPException(status_code=404, detail="Community submissions are disabled")

    # Duplicate detection: near-identical pending/confirmed record already
    # exists. Rejected records do not block a fresh submission. Bounding-box
    # prefilter keeps this off a full-table scan.
    point = GeoPoint(lat=req.lat, lon=req.lon)
    wanted = _normalize_name(req.name)
    cos_lat = max(abs(math.cos(math.radians(req.lat))), 1e-6)
    dlat = DUPLICATE_RADIUS_M / 111_320.0
    dlon = DUPLICATE_RADIUS_M / (111_320.0 * cos_lat)
    nearby = (
        db.query(CommunityMosque)
        .filter(CommunityMosque.status != "rejected")
        .filter(CommunityMosque.lat.between(req.lat - dlat, req.lat + dlat))
        .filter(CommunityMosque.lon.between(req.lon - dlon, req.lon + dlon))
        .all()
    )
    for row in nearby:
        dist = haversine_m(point, GeoPoint(lat=row.lat, lon=row.lon))
        if dist <= DUPLICATE_RADIUS_M and _normalize_name(row.name) == wanted:
            raise HTTPException(
                status_code=409,
                detail="A similar mosque was already submitted (pending review)",
            )

    row = CommunityMosque(
        name=req.name,
        lat=req.lat,
        lon=req.lon,
        address=req.address,
        opening_hours=req.opening_hours,
        status="unverified",  # always — never client-controlled
        submitted_by=user_id,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return _to_out(row)


@router.get("", response_model=list[CommunityMosqueOut])
@limiter.limit(default_limit())
async def my_submissions(
    request: Request,
    ids: str | None = None,
    db: Session = Depends(get_db),
) -> list[CommunityMosqueOut]:
    """Look up submission statuses by comma-separated ids (≤50).

    Ids are random UUIDs handed to the submitting client, so this is a
    capability-style read: no account needed, nothing else exposed, and
    no list-all endpoint exists.
    """
    id_list = [i.strip() for i in (ids or "").split(",") if i.strip()][:50]
    if not id_list:
        return []
    rows = (
        db.query(CommunityMosque)
        .filter(CommunityMosque.id.in_(id_list))
        .filter(CommunityMosque.status != "rejected")
        .all()
    )
    return [_to_out(r) for r in rows]


@router.post("/{mosque_id}/report", response_model=CommunityMosqueOut)
@limiter.limit(default_limit())
async def report_mosque(
    mosque_id: str,
    req: CommunityMosqueReport,
    request: Request,
    db: Session = Depends(get_db),
) -> CommunityMosqueOut:
    row = db.get(CommunityMosque, mosque_id)
    if row is None or row.status == "rejected":
        raise HTTPException(status_code=404, detail="Submission not found")

    reports = list(row.reports or [])
    reports.append(
        {
            "reason": req.reason,
            "at": datetime.now(timezone.utc).isoformat(),
        }
    )
    row.reports = reports
    row.report_count = (row.report_count or 0) + 1
    # Enough reports => back to unverified so it drops out of routing
    # until a moderator re-reviews it.
    if row.status == "verified" and row.report_count >= get_settings().community_report_threshold:
        row.status = "unverified"
    db.commit()
    db.refresh(row)
    return _to_out(row)


# ---------------------------------------------------------------------------
# Minimal moderation (no admin UI exists — token-guarded endpoint only).
# ---------------------------------------------------------------------------

def _require_admin(x_admin_token: str | None) -> None:
    token = get_settings().admin_token
    if not token:
        # Disabled when no token is configured: don't advertise the route.
        raise HTTPException(status_code=404, detail="Submission not found")
    if not x_admin_token or x_admin_token != token:
        raise HTTPException(status_code=403, detail="Invalid admin token")


@router.patch("/{mosque_id}/review", response_model=CommunityMosqueOut)
async def review_mosque(
    mosque_id: str,
    req: CommunityMosqueReview,
    x_admin_token: str | None = Header(default=None),
    db: Session = Depends(get_db),
) -> CommunityMosqueOut:
    _require_admin(x_admin_token)
    row = db.get(CommunityMosque, mosque_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Submission not found")
    row.status = req.status
    row.reviewed_at = datetime.now(timezone.utc)
    if req.name is not None:
        row.name = req.name
    db.commit()
    db.refresh(row)
    return _to_out(row)
