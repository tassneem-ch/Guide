"""Community mosque submission tests (hermetic — fixture providers + SQLite).

Covers: payload validation, duplicate detection, unverified-by-default rules,
retrieval, reporting, minimal moderation, discovery integration, dedup
against external providers, provenance labels and graceful degradation.
"""
from __future__ import annotations

import pytest

from app.db.models import CommunityMosque
from app.db.session import SessionLocal
from app.domain.geo import GeoPoint
from app.providers.mosques_community import CommunityMosqueProvider
from app.providers.mosques_fixture import FixtureMosqueProvider


@pytest.fixture(autouse=True)
def _clean_community_rows():
    """Isolate: no community row leaks into another test's search."""

    def _wipe():
        db = SessionLocal()
        try:
            db.query(CommunityMosque).delete()
            db.commit()
        finally:
            db.close()

    _wipe()
    yield
    _wipe()


# ---------------------------------------------------------------------------
# Submission validation
# ---------------------------------------------------------------------------


def test_submit_valid_record_starts_unverified(client):
    response = client.post(
        "/v1/community/mosques",
        json={
            "name": "Masjid Al-Khair",
            "lat": 36.8405,
            "lon": 10.2350,
            "address": "Rue de la Paix, Manouba",
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "unverified"
    assert body["name"] == "Masjid Al-Khair"
    assert body["lat"] == 36.8405
    assert "id" in body


def test_submit_rejects_out_of_range_coordinates(client):
    for bad in ({"lat": 95.0, "lon": 10.0}, {"lat": 36.0, "lon": 181.0}):
        response = client.post(
            "/v1/community/mosques", json={**bad, "name": "X"}
        )
        assert response.status_code == 422


def test_submit_rejects_missing_coordinates(client):
    response = client.post("/v1/community/mosques", json={"name": "X"})
    assert response.status_code == 422


def test_submit_allows_unnamed_mosque(client):
    """Unnamed mosques are legitimate — coordinates are what matters."""
    response = client.post(
        "/v1/community/mosques", json={"lat": 36.8410, "lon": 10.2360}
    )
    assert response.status_code == 200
    assert response.json()["name"] is None


def test_submit_rejects_oversized_fields(client):
    response = client.post(
        "/v1/community/mosques",
        json={"name": "x" * 200, "lat": 36.8, "lon": 10.2},
    )
    assert response.status_code == 422


def test_client_cannot_set_verification_status(client):
    """The status field is absent from the schema — it can never be trusted."""
    response = client.post(
        "/v1/community/mosques",
        json={
            "name": "Spoofed",
            "lat": 36.8500,
            "lon": 10.2400,
            "status": "verified",  # ignored: not in CommunityMosqueSubmit
        },
    )
    assert response.status_code == 200
    assert response.json()["status"] == "unverified"


def test_duplicate_submission_conflict(client):
    payload = {"name": "Dup Mosque", "lat": 36.8600, "lon": 10.2500}
    assert client.post("/v1/community/mosques", json=payload).status_code == 200
    # Same name within 150 m → conflict
    again = client.post(
        "/v1/community/mosques", json={**payload, "lat": 36.8605}
    )
    assert again.status_code == 409
    # Different name at the same spot is a different mosque → allowed
    other = client.post(
        "/v1/community/mosques", json={**payload, "name": "Other Mosque"}
    )
    assert other.status_code == 200
    # Same name far away is a different mosque → allowed
    far = client.post(
        "/v1/community/mosques", json={**payload, "lat": 36.3600, "lon": 10.2500}
    )
    assert far.status_code == 200


# ---------------------------------------------------------------------------
# Retrieval, reporting, moderation
# ---------------------------------------------------------------------------


def test_lookup_by_ids_returns_status(client):
    created = client.post(
        "/v1/community/mosques", json={"name": "Look Me Up", "lat": 36.9, "lon": 10.3}
    ).json()
    found = client.get(f"/v1/community/mosques?ids={created['id']}")
    assert found.status_code == 200
    assert [r["id"] for r in found.json()] == [created["id"]]
    assert found.json()[0]["status"] == "unverified"
    # Unknown ids vanish silently; empty query returns nothing (no list-all).
    assert client.get("/v1/community/mosques?ids=deadbeef").json() == []
    assert client.get("/v1/community/mosques").json() == []


def test_report_increments_and_never_exposes_reporter(client):
    created = client.post(
        "/v1/community/mosques", json={"name": "Reported", "lat": 36.91, "lon": 10.31}
    ).json()
    response = client.post(
        f"/v1/community/mosques/{created['id']}/report",
        json={"reason": "wrong coordinates"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["id"] == created["id"]
    # No reporter data in the response schema at all.
    assert "reports" not in body and "report_count" not in body
    assert client.post(
        f"/v1/community/mosques/{created['id']}/report", json={}
    ).status_code == 200


def test_reports_demote_verified_record_to_unverified(client, monkeypatch):
    from app.config import get_settings

    db = SessionLocal()
    row = CommunityMosque(
        name="Demoted", lat=36.92, lon=10.32, status="verified"
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    db.close()

    monkeypatch.setattr(get_settings(), "community_report_threshold", 2)
    client.post(f"/v1/community/mosques/{row.id}/report", json={})
    second = client.post(f"/v1/community/mosques/{row.id}/report", json={})
    assert second.status_code == 200
    assert second.json()["status"] == "unverified"  # dropped out of routing


def test_review_requires_admin_token(client):
    created = client.post(
        "/v1/community/mosques", json={"name": "Review Me", "lat": 36.93, "lon": 10.33}
    ).json()
    # No ADMIN_TOKEN configured → endpoint reports 404 (route effectively off).
    no_token = client.patch(
        f"/v1/community/mosques/{created['id']}/review",
        json={"status": "verified"},
        headers={"X-Admin-Token": "anything"},
    )
    assert no_token.status_code == 404


def test_review_with_token_verifies_and_corrects(client, monkeypatch):
    from app.config import get_settings

    monkeypatch.setattr(get_settings(), "admin_token", "secret-token")
    created = client.post(
        "/v1/community/mosques", json={"name": "Confirm Me", "lat": 36.94, "lon": 10.34}
    ).json()

    wrong = client.patch(
        f"/v1/community/mosques/{created['id']}/review",
        json={"status": "verified"},
        headers={"X-Admin-Token": "nope"},
    )
    assert wrong.status_code == 403

    ok = client.patch(
        f"/v1/community/mosques/{created['id']}/review",
        json={"status": "verified", "name": "Confirmed Name"},
        headers={"X-Admin-Token": "secret-token"},
    )
    assert ok.status_code == 200
    body = ok.json()
    assert body["status"] == "verified"
    assert body["name"] == "Confirmed Name"

    # Verified records become visible to lookup…
    assert client.get(f"/v1/community/mosques?ids={created['id']}").json()[0][
        "status"
    ] == "verified"


def test_rejected_records_are_invisible(client, monkeypatch):
    from app.config import get_settings

    monkeypatch.setattr(get_settings(), "admin_token", "secret-token")
    created = client.post(
        "/v1/community/mosques", json={"name": "Bad Row", "lat": 36.95, "lon": 10.35}
    ).json()
    client.patch(
        f"/v1/community/mosques/{created['id']}/review",
        json={"status": "rejected"},
        headers={"X-Admin-Token": "secret-token"},
    )
    assert client.get(f"/v1/community/mosques?ids={created['id']}").json() == []


# ---------------------------------------------------------------------------
# Discovery integration (via the community provider decorator)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_verified_record_appears_in_discovery_with_provenance():
    db = SessionLocal()
    row = CommunityMosque(
        name="Community Gem", lat=48.8600, lon=2.3400, status="verified"
    )
    db.add(row)
    db.commit()
    db.close()

    provider = CommunityMosqueProvider(FixtureMosqueProvider())
    result = await provider.search_near(GeoPoint(lat=48.8566, lon=2.3522), 2000)

    community = [c for c in result.candidates if c.quality.provider == "community"]
    assert community, "verified community record must join discovery"
    cand = community[0]
    assert cand.id.startswith("community-")
    assert cand.name == "Community Gem"
    assert cand.quality.source == "live"
    assert any("Community-submitted" in n for n in cand.quality.notes)
    # Primary provider results still present — community augments, not replaces.
    assert any(c.quality.provider == "fixture" for c in result.candidates)
    # The merged result keeps the primary verdict (fixture stays fixture).
    assert result.status == "fixture"


@pytest.mark.asyncio
async def test_unverified_record_excluded_by_default():
    db = SessionLocal()
    db.add(CommunityMosque(name="Pending", lat=48.8610, lon=2.3410, status="unverified"))
    db.commit()
    db.close()

    provider = CommunityMosqueProvider(FixtureMosqueProvider())
    result = await provider.search_near(GeoPoint(lat=48.8566, lon=2.3522), 2000)
    assert all(c.quality.provider != "community" for c in result.candidates)


@pytest.mark.asyncio
async def test_unverified_included_with_operator_opt_in(monkeypatch):
    from app.config import get_settings

    db = SessionLocal()
    db.add(CommunityMosque(name="Opted In", lat=48.8620, lon=2.3420, status="unverified"))
    db.commit()
    db.close()

    monkeypatch.setattr(get_settings(), "community_include_unverified", True)
    provider = CommunityMosqueProvider(FixtureMosqueProvider())
    result = await provider.search_near(GeoPoint(lat=48.8566, lon=2.3522), 2000)
    community = [c for c in result.candidates if c.quality.provider == "community"]
    assert len(community) == 1
    # Still labelled unverified — opt-in never means "trustworthy".
    assert any("UNVERIFIED" in n for n in community[0].quality.notes)
    assert community[0].opening_hours is None


@pytest.mark.asyncio
async def test_community_hours_never_verified():
    db = SessionLocal()
    db.add(
        CommunityMosque(
            name="Hours Row",
            lat=48.8630,
            lon=2.3430,
            status="verified",
            opening_hours="Mo-Fr 08:00-20:00 (as submitted)",
        )
    )
    db.commit()
    db.close()

    provider = CommunityMosqueProvider(FixtureMosqueProvider())
    result = await provider.search_near(GeoPoint(lat=48.8566, lon=2.3522), 2000)
    cand = next(c for c in result.candidates if c.quality.provider == "community")
    assert cand.opening_hours is not None
    assert cand.opening_hours_verification == "unverified"


@pytest.mark.asyncio
async def test_dedup_drops_community_record_duplicate_of_fixture():
    """A community row on top of an external result must not double-count."""
    # Fixture mosque #1 sits at a deterministic offset from the centre; place
    # a community row 50 m away with a matching name → dropped.
    fixture = FixtureMosqueProvider()
    base = GeoPoint(lat=48.8566, lon=2.3522)
    fixture_result = await fixture.search_near(base, 2000)
    external = fixture_result.candidates[0]

    db = SessionLocal()
    db.add(
        CommunityMosque(
            # Fixture names end with " (fixture)" — match the base name.
            name=external.name,
            lat=external.location.lat,
            lon=external.location.lon,
            status="verified",
        )
    )
    db.commit()
    db.close()

    provider = CommunityMosqueProvider(fixture)
    result = await provider.search_near(base, 2000)
    community = [c for c in result.candidates if c.quality.provider == "community"]
    assert community == [], "duplicate community row must be dropped"
    assert any(c.quality.provider == "fixture" for c in result.candidates)


@pytest.mark.asyncio
async def test_unnamed_community_record_near_external_is_dropped():
    base = GeoPoint(lat=48.8566, lon=2.3522)
    fixture = FixtureMosqueProvider()
    external = (await fixture.search_near(base, 2000)).candidates[0]

    db = SessionLocal()
    db.add(
        CommunityMosque(
            name=None,
            lat=external.location.lat,
            lon=external.location.lon,
            status="verified",
        )
    )
    db.commit()
    db.close()

    result = await CommunityMosqueProvider(fixture).search_near(base, 2000)
    assert all(c.quality.provider != "community" for c in result.candidates)


@pytest.mark.asyncio
async def test_community_failure_never_corrupts_primary_result(monkeypatch):
    """DB blow-up inside the community layer → primary answer untouched."""
    provider = CommunityMosqueProvider(FixtureMosqueProvider())

    def _boom(*_args, **_kwargs):
        raise RuntimeError("database exploded")

    monkeypatch.setattr(provider, "_community_near", _boom)
    base = GeoPoint(lat=48.8566, lon=2.3522)
    result = await provider.search_near(base, 2000)
    assert result.candidates, "primary fixture candidates must survive"
    assert result.status == "fixture"
    assert all(c.quality.provider == "fixture" for c in result.candidates)


@pytest.mark.asyncio
async def test_disabled_community_skips_query(monkeypatch):
    from app.config import get_settings

    monkeypatch.setattr(get_settings(), "community_mosques_enabled", False)
    provider = CommunityMosqueProvider(FixtureMosqueProvider())
    result = await provider.search_near(GeoPoint(lat=48.8566, lon=2.3522), 2000)
    assert all(c.quality.provider != "community" for c in result.candidates)


def test_health_report_shows_community_layer(client):
    body = client.get("/v1/health").json()
    assert "+community" in body["providers"]["mosques"]
