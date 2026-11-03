"""Route feasibility: plan structure, metrics consistency, waypoints."""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

import pytest

from app.domain.geo import GeoPoint
from app.domain.mosque import MosqueSearchResult
from app.domain.prayer import PrayerConfig
from app.domain.route import (
    PlanningOptions,
    Preference,
    RouteRequest,
    StopKind,
    TravelMode,
)

PARIS = GeoPoint(lat=48.8566, lon=2.3522, tz="Europe/Paris", name="Paris")
LYON = GeoPoint(lat=45.7640, lon=4.8357, tz="Europe/Paris", name="Lyon")
DIJON = GeoPoint(lat=47.3220, lon=5.0415, tz="Europe/Paris", name="Dijon")


def make_request(depart: datetime | None = None, **kwargs) -> RouteRequest:
    return RouteRequest(
        origin=kwargs.pop("origin", PARIS),
        destination=kwargs.pop("destination", LYON),
        depart_at=depart or datetime(2025, 6, 15, 11, 50,
                                     tzinfo=timezone(timedelta(hours=2))),
        mode=TravelMode.DRIVING,
        options=kwargs.pop("options", PlanningOptions()),
        prayer=kwargs.pop("prayer", PrayerConfig()),
        **kwargs,
    )


@pytest.mark.asyncio
async def test_three_named_alternatives_are_returned(planner):
    response = await planner.plan(make_request())
    kinds = {p.preference for p in response.alternatives}
    assert {Preference.FASTEST, Preference.PRAYER_FRIENDLY,
            Preference.BALANCED} <= kinds
    fastest = next(p for p in response.alternatives
                   if p.preference == Preference.FASTEST)
    assert fastest.metrics.mosque_stop_count == 0


@pytest.mark.asyncio
async def test_metrics_are_self_consistent(planner):
    response = await planner.plan(make_request())
    req_depart = response.alternatives[0].legs[0].departure_utc
    for plan in response.alternatives:
        m = plan.metrics
        assert m.total_duration_s >= 0
        arrival = req_depart + timedelta(seconds=m.total_duration_s)
        assert abs((arrival - m.arrival_utc).total_seconds()) <= 1
        assert m.total_distance_m >= 0
        assert m.arrival_local  # formatted local arrival present
        # legs form a coherent non-decreasing timeline
        for a, b in zip(plan.legs, plan.legs[1:]):
            assert b.departure_utc >= a.arrival_utc - timedelta(seconds=1)


@pytest.mark.asyncio
async def test_prayer_friendly_never_beats_fastest_on_time(planner):
    response = await planner.plan(make_request())
    fastest = next(p for p in response.alternatives
                   if p.preference == Preference.FASTEST)
    friendly = next(p for p in response.alternatives
                    if p.preference == Preference.PRAYER_FRIENDLY)
    assert friendly.metrics.arrival_utc >= fastest.metrics.arrival_utc
    assert friendly.metrics.detour_duration_s >= 0


@pytest.mark.asyncio
async def test_waypoints_are_mandatory_stops(planner):
    response = await planner.plan(make_request(waypoints=[DIJON]))
    for plan in response.alternatives:
        kinds = [s.kind for s in plan.stops]
        assert StopKind.ORIGIN in kinds
        assert StopKind.WAYPOINT in kinds
        assert StopKind.DESTINATION in kinds
        waypoint = next(s for s in plan.stops if s.kind == StopKind.WAYPOINT)
        assert waypoint.locked is True


@pytest.mark.asyncio
async def test_fixture_data_is_labelled_in_notes_and_flags(planner):
    response = await planner.plan(make_request())
    assert any("FIXTURE" in note for note in response.notes)
    assert all(plan.route_live is False for plan in response.alternatives)
    assert "FIXTURE" in response.providers["routing"]


@pytest.mark.asyncio
async def test_mosque_stops_carry_honesty_fields(planner):
    response = await planner.plan(make_request())
    friendly = next(p for p in response.alternatives
                    if p.preference == Preference.PRAYER_FRIENDLY)
    for stop in friendly.stops:
        if stop.kind != StopKind.MOSQUE:
            continue
        assert stop.mosque is not None
        assert stop.prayer is not None
        assert stop.rationale
        assert stop.uncertainties, "fixture stops must disclose their nature"
        assert any("FIXTURE" in u for u in stop.uncertainties)
        assert stop.detour_seconds >= 0
        # arrival must fit the prayer window (planning 30 / buffer 10 min)
        assert stop.arrival_utc <= stop.prayer.utc + timedelta(minutes=10)
        wait = (stop.prayer.utc - stop.arrival_utc).total_seconds()
        assert wait <= 30 * 60


@pytest.mark.asyncio
async def test_explanations_exist_for_each_plan(planner):
    response = await planner.plan(make_request())
    for plan in response.alternatives:
        assert plan.explanation, "every plan must explain its choices"


class _NoDataMosqueProvider:
    """Reachable provider with no mosque data (e.g. an Overpass outage)."""

    name = "stub"
    live = True

    async def search_near(self, center, radius_m, query=None):
        return MosqueSearchResult(
            candidates=[], status="no_data",
            message="Mosque data unavailable.",
        )

    async def close(self):
        return None


@pytest.mark.asyncio
async def test_mandatory_prayer_stops_mark_plan_infeasible_when_unmet(
    routing_provider, prayer_provider,
):
    """prayer_stops='mandatory' must reach the UI: feasible=False + reason."""
    from app.services.route_planner import RoutePlanner

    planner = RoutePlanner(
        routing_provider, prayer_provider, _NoDataMosqueProvider()
    )
    response = await planner.plan(
        make_request(options=PlanningOptions(prayer_stops="mandatory"))
    )
    assert response.alternatives[0].prayer_events, \
        "precondition: the journey must contain prayers"
    for plan in response.alternatives:
        assert plan.metrics.prayers_missed, plan.preference
        assert plan.feasible is False, plan.preference
        assert plan.infeasibility_reason, plan.preference
        assert "mandatory" in plan.infeasibility_reason.lower()
        # exactly one explicit mandatory explanation, not a wall of repeats
        mandatory_lines = [
            l for l in plan.explanation if "mandatory" in l.lower()
        ]
        assert len(mandatory_lines) == 1, plan.explanation
        # the outage message must appear at most once per plan, never
        # repeated once per searched anchor.
        joined = "\n".join(plan.explanation)
        assert joined.count("Mosque data unavailable.") <= 1, plan.explanation


@pytest.mark.asyncio
async def test_optional_prayer_stops_stay_feasible_despite_missed_prayers(
    planner,
):
    """Non-regression: only 'mandatory' turns missed prayers into
    infeasibility — 'optional' plans with misses remain selectable."""
    response = await planner.plan(
        make_request(options=PlanningOptions(prayer_stops="optional"))
    )
    assert response.alternatives[0].prayer_events, \
        "precondition: the journey must contain prayers"
    for plan in response.alternatives:
        assert plan.feasible is True, plan.preference
        assert plan.infeasibility_reason is None, plan.preference


@pytest.mark.asyncio
async def test_mandatory_prayer_stops_stay_feasible_when_every_prayer_served(
    prayer_provider, routing_provider, mosque_provider,
):
    """The enforcement rule only fires when a prayer is actually missed."""
    from app.providers.base import RouteResult
    from app.services.route_planner import RoutePlanner
    from app.services.scheduler import ScheduleResult

    planner = RoutePlanner(routing_provider, prayer_provider, mosque_provider)
    depart = datetime(2025, 6, 15, 11, 50, tzinfo=timezone(timedelta(hours=2)))
    day = await prayer_provider.day_prayers(
        PARIS, date(2025, 6, 15), PrayerConfig()
    )
    route = RouteResult(
        geometry=[PARIS, LYON], distance_m=400_000, duration_s=14_000,
        provider="stub", live=False,
    )
    plan = planner._build_plan(
        req=make_request(options=PlanningOptions(prayer_stops="mandatory")),
        route=route, depart=depart, events=list(day.events),
        schedule=ScheduleResult(missed=[]),   # solver served everything
        candidates=[], preference=Preference.PRAYER_FRIENDLY,
    )
    assert plan.feasible is True
    assert plan.infeasibility_reason is None
