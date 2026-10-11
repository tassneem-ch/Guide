"""Candidate discovery, detour evaluation and selection honesty."""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from app.domain.geo import GeoPoint
from app.domain.mosque import DataQuality, MosqueCandidate, MosqueSearchResult
from app.domain.prayer import (
    AsrSchool,
    PrayerConfig,
    PrayerEvent,
    PrayerMethod,
    PrayerName,
)
from app.domain.route import (
    PlanningOptions,
    Preference,
    RouteRequest,
    StopKind,
    TravelMode,
)
from app.services.candidate_eval import (
    RouteCandidate,
    discover_mosques_along_route,
    evaluate_detours,
)
from app.services.scheduler import WEIGHT_PROFILES, solve

PARIS = GeoPoint(lat=48.8566, lon=2.3522, tz="Europe/Paris", name="Paris")
LYON = GeoPoint(lat=45.7640, lon=4.8357, tz="Europe/Paris", name="Lyon")


class EmptyMosqueProvider:
    """Simulates a provider that was reachable but has no data (or failed)."""

    name = "stub"
    live = True

    def __init__(self, status: str = "no_data", message: str | None = None):
        self.status = status
        self.message = message

    async def search_near(self, center, radius_m, query=None):
        return MosqueSearchResult(
            candidates=[], status=self.status, message=self.message
        )

    async def close(self):
        return None


@pytest.mark.asyncio
async def test_discovery_returns_deduped_candidates_with_anchor(mosque_provider):
    geometry = [PARIS, LYON]
    result = await discover_mosques_along_route(mosque_provider, geometry, [0, 1])
    assert result.status in ("ok", "fixture")
    assert result.candidates
    ids = [c.id for c in result.candidates]
    assert len(ids) == len(set(ids)), "candidates must be de-duplicated"
    assert all(c.assigned_route_index in (0, 1) for c in result.candidates)
    assert all(c.quality.source == "fixture" for c in result.candidates)


@pytest.mark.asyncio
async def test_detours_are_non_negative_and_labelled(
    routing_provider, mosque_provider
):
    geometry = [PARIS, LYON]
    search = await discover_mosques_along_route(mosque_provider, geometry, [0, 1])
    cands, notes = await evaluate_detours(
        routing_provider,
        geometry,
        {0: 0, 1: 40_000},
        search.candidates,
        TravelMode.DRIVING,
        datetime(2025, 6, 15, 9, 50, tzinfo=timezone.utc),
    )
    assert cands
    for c in cands:
        assert c.detour_seconds >= 0
        assert c.detour_distance_m >= 0
        assert c.detour_method in ("routed", "great_circle_estimate")
        assert c.leg_seconds >= 0


@pytest.mark.asyncio
async def test_no_mosque_data_yields_explicit_no_data_plan(planner):
    """Provider reachable but empty => plans still return, clearly explained."""
    from app.services.route_planner import RoutePlanner

    planner_with_gaps = RoutePlanner(
        planner.routing, planner.prayer, EmptyMosqueProvider()
    )
    response = await planner_with_gaps.plan(
        RouteRequest(
            origin=PARIS,
            destination=LYON,
            depart_at=datetime(2025, 6, 15, 11, 50,
                               tzinfo=timezone(timedelta(hours=2))),
            options=PlanningOptions(),
            prayer=PrayerConfig(),
        )
    )
    friendly = next(
        p for p in response.alternatives
        if p.preference.value == "prayer_friendly"
    )
    assert friendly.metrics.mosque_stop_count == 0
    assert any("no mosques" in line.lower() or "no mosque data" in line.lower()
               for line in friendly.explanation)
    # never fabricate: no mosque stop may appear anywhere
    assert all(s.kind != StopKind.MOSQUE
               for p in response.alternatives for s in p.stops)


@pytest.mark.asyncio
async def test_provider_error_is_reported_not_masked():
    class FailingProvider(EmptyMosqueProvider):
        def __init__(self):
            super().__init__(status="provider_error",
                             message="Overpass unavailable: timeout")

    from app.services.route_planner import RoutePlanner
    from app.providers.prayer_fixture import FixturePrayerProvider
    from app.providers.routing_fixture import FixtureRoutingProvider

    broken = RoutePlanner(
        FixtureRoutingProvider(), FixturePrayerProvider(), FailingProvider()
    )
    response = await broken.plan(
        RouteRequest(
            origin=PARIS,
            destination=LYON,
            depart_at=datetime(2025, 6, 15, 11, 50,
                               tzinfo=timezone(timedelta(hours=2))),
        )
    )
    friendly = next(p for p in response.alternatives
                    if p.preference.value == "prayer_friendly")
    assert friendly.metrics.mosque_stop_count == 0
    assert any("error" in line.lower() for line in friendly.explanation)


# ---------------------------------------------------------------------------
# rejection explainability + prayer-window anchors
# ---------------------------------------------------------------------------

def _candidate(anchor_index=0, detour_s=60, eta0_s=0, leg_s=30) -> RouteCandidate:
    return RouteCandidate(
        mosque=MosqueCandidate(
            id=f"cand-{anchor_index}-{detour_s}-{eta0_s}",
            name="Test Mosque",
            location=GeoPoint(lat=48.80, lon=2.30, tz="Europe/Paris"),
            quality=DataQuality(
                provider="test", source="fixture",
                fetched_at=datetime.now(timezone.utc),
            ),
        ),
        anchor_index=anchor_index,
        detour_seconds=detour_s,
        detour_distance_m=detour_s * 10,
        detour_method="routed",
        eta_at_anchor_s=eta0_s,
        leg_seconds=leg_s,
    )


def _dhuhr(at_utc: datetime) -> PrayerEvent:
    local = at_utc.astimezone(ZoneInfo("Europe/Paris"))
    return PrayerEvent(
        name=PrayerName.DHUHR,
        utc=at_utc,
        local=local,
        tz="Europe/Paris",
        local_date=date(2025, 6, 15),
        location=LYON,
        method=PrayerMethod.MWL,
        school=AsrSchool.STANDARD,
        source="test",
        live=False,
    )


def test_optional_mode_explains_budget_rejections():
    """Skipping a prayer is legitimate — being silent about why is not."""
    depart = datetime(2025, 6, 15, 8, 0, tzinfo=timezone.utc)
    event = _dhuhr(depart + timedelta(minutes=60))
    over_budget = _candidate(detour_s=2000)  # 33 min > default 25 min budget

    result = solve(
        [event], [over_budget], depart,
        PlanningOptions(),  # prayer_stops defaults to "optional"
        WEIGHT_PROFILES["prayer_friendly"],
    )

    assert result.stops == []
    assert result.missed == [event]
    assert any(
        "Dhuhr" in note and "exceeded the 25 min detour limit" in note
        for note in result.notes
    ), f"expected a rejection explanation, got: {result.notes}"


def test_explanation_names_long_waiting_as_the_reason():
    depart = datetime(2025, 6, 15, 8, 0, tzinfo=timezone.utc)
    event = _dhuhr(depart + timedelta(minutes=60))
    # Reachable in time, but 55 min of waiting > the 30 min window.
    too_early = _candidate(detour_s=60, eta0_s=0, leg_s=300)

    result = solve(
        [event], [too_early], depart,
        PlanningOptions(),
        WEIGHT_PROFILES["prayer_friendly"],
    )

    assert result.stops == []
    assert any("more than 30 min of waiting" in note for note in result.notes)


def test_solution_still_silent_free_when_a_stop_is_chosen():
    """The explanation path must not fire when the prayer IS served."""
    depart = datetime(2025, 6, 15, 8, 0, tzinfo=timezone.utc)
    event = _dhuhr(depart + timedelta(minutes=60))
    good = _candidate(detour_s=120, eta0_s=3300, leg_s=60)

    result = solve(
        [event], [good], depart,
        PlanningOptions(),
        WEIGHT_PROFILES["prayer_friendly"],
    )

    assert len(result.stops) == 1
    assert result.missed == []
    assert not any("none were usable" in note for note in result.notes)


@pytest.mark.asyncio
async def test_discovery_preserves_fixture_status(mosque_provider):
    """A synthetic candidate must never read as live data downstream."""
    result = await discover_mosques_along_route(
        mosque_provider, [PARIS, LYON], [0, 1]
    )
    assert result.status == "fixture"
    assert result.candidates


@pytest.mark.asyncio
async def test_planner_places_stop_when_a_good_candidate_exists(
    routing_provider, prayer_provider
):
    """End-to-end: a routable mosque near the prayer must become a stop."""

    class AnchorMosqueProvider:
        """Returns a candidate exactly at each searched anchor — the best
        possible detour, isolating the planner's stop-placement behaviour."""

        name = "anchor"
        live = True

        async def search_near(self, center, radius_m, query=None):
            return MosqueSearchResult(
                candidates=[MosqueCandidate(
                    id=f"anchor-{center.lat:.4f}-{center.lon:.4f}",
                    name="Anchor Mosque",
                    location=center,
                    quality=DataQuality(
                        provider="anchor", source="live",
                        fetched_at=datetime.now(timezone.utc),
                    ),
                )],
                status="ok",
            )

        async def close(self):
            return None

    from app.services.route_planner import RoutePlanner

    planner = RoutePlanner(
        routing_provider, prayer_provider, AnchorMosqueProvider()
    )
    response = await planner.plan(
        RouteRequest(
            origin=PARIS,
            destination=LYON,
            depart_at=datetime(2025, 6, 15, 11, 50,
                               tzinfo=timezone(timedelta(hours=2))),
            options=PlanningOptions(preference=Preference.PRAYER_FRIENDLY),
            prayer=PrayerConfig(),
        )
    )
    friendly = next(p for p in response.alternatives
                    if p.preference.value == "prayer_friendly")
    fastest = next(p for p in response.alternatives
                   if p.preference.value == "fastest")

    prayer_stops = [s for s in friendly.stops if s.kind == StopKind.MOSQUE]
    assert prayer_stops, friendly.explanation
    assert all(s.prayer is not None for s in prayer_stops)
    assert friendly.metrics.prayers_served, friendly.metrics
    assert all(s.rationale for s in prayer_stops), \
        "every chosen stop must explain itself"
    # The comparison baseline stays stop-free.
    assert fastest.metrics.mosque_stop_count == 0


def test_anchors_near_events_bracket_the_prayer_position():
    from app.providers.base import RouteResult
    from app.services.prayer_sampling import anchors_near_events

    geometry = [GeoPoint(lat=48.0 + i * 0.01, lon=2.0) for i in range(101)]
    route = RouteResult(
        geometry=geometry, distance_m=100_000, duration_s=10_000,
        provider="stub", live=False,
    )
    depart = datetime(2025, 6, 15, 8, 0, tzinfo=timezone.utc)
    halfway = _dhuhr(depart + timedelta(seconds=5000))

    assert anchors_near_events(route, [halfway], depart) == [49, 50, 51]
    assert anchors_near_events(route, [], depart) == []
