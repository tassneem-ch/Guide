"""API request/response schemas shared across routers."""
from __future__ import annotations

from datetime import date, datetime

from pydantic import BaseModel, Field

from ..domain.geo import GeoPoint
from ..domain.prayer import PrayerConfig


class PrayerTimesRequest(BaseModel):
    point: GeoPoint
    # Either a plain local date (used as-is) or a UTC instant, which the
    # server converts to the location's local calendar date via its IANA
    # zone — the phone's timezone is never trusted for another location.
    date: date | datetime
    config: PrayerConfig = Field(default_factory=PrayerConfig)


class MosqueSearchRequest(BaseModel):
    center: GeoPoint
    radius_m: int = Field(default=1500, ge=50, le=50_000)
    query: str | None = None
    # Optional corridor: sample these points too (route polyline positions).
    corridor_points: list[GeoPoint] = Field(default_factory=list)


class GeocodeRequest(BaseModel):
    query: str = Field(min_length=1, max_length=300)
    language: str = "en"
    limit: int = Field(default=5, ge=1, le=10)


class ReverseGeocodeRequest(BaseModel):
    point: GeoPoint
    language: str = "en"


class RegisterRequest(BaseModel):
    email: str = Field(pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    password: str = Field(min_length=8, max_length=128)
    display_name: str | None = None


class LoginRequest(BaseModel):
    email: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user_id: str


class PreferencesRequest(BaseModel):
    data: dict


class SaveItineraryRequest(BaseModel):
    title: str = Field(min_length=1, max_length=255)
    kind: str = Field(default="route", pattern="^(route|trip)$")
    data: dict


class ItinerarySummary(BaseModel):
    id: str
    title: str
    kind: str
    created_at: datetime
    updated_at: datetime


class CommunityMosqueSubmit(BaseModel):
    """Submission payload. There is deliberately NO status/verification
    field — the server always starts a submission as `unverified`."""

    name: str | None = Field(default=None, min_length=1, max_length=120)
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    address: str | None = Field(default=None, max_length=500)
    opening_hours: str | None = Field(default=None, max_length=120)


class CommunityMosqueOut(BaseModel):
    id: str
    name: str | None
    lat: float
    lon: float
    address: str | None
    opening_hours: str | None
    status: str  # unverified | verified
    created_at: datetime


class CommunityMosqueReport(BaseModel):
    reason: str | None = Field(default=None, max_length=300)


class CommunityMosqueReview(BaseModel):
    """Moderator action. `name` optionally corrects the record while
    reviewing it."""

    status: str = Field(pattern="^(verified|rejected)$")
    name: str | None = Field(default=None, min_length=1, max_length=120)
