import 'package:flutter_test/flutter_test.dart';
import 'package:guide/core/google_maps_export.dart';
import 'package:guide/domain/models.dart';

/// Build a minimal-but-real RoutePlan: origin → [intermediate...] →
/// destination, mirroring the backend's stop ordering.
RoutePlan planWith(List<ScheduledStop> stops) => RoutePlan(
      preference: RoutePreference.balanced,
      legs: const [],
      stops: stops,
      metrics: RouteMetrics(
        totalDistanceM: 1000,
        totalDurationS: 600,
        drivingDurationS: 500,
        waitingDurationS: 50,
        detourDurationS: 50,
        detourDistanceM: 100,
        arrivalUtc: DateTime.utc(2026, 10, 11, 12, 0),
        arrivalLocal: '12:00',
        arrivalTz: 'Africa/Tunis',
        mosqueStopCount: 0,
        prayersServed: const [],
        prayersMissed: const [],
      ),
      prayerEvents: const [],
      explanation: const [],
      uncertainties: const [],
      routeProvider: 'test',
      routeLive: true,
      geometry: const [],
      feasible: true,
    );

ScheduledStop stop(StopKind kind, double lat, double lon, {String? name}) =>
    ScheduledStop(
      kind: kind,
      name: name ?? kind.name,
      location: GeoPoint(lat: lat, lon: lon),
      arrivalUtc: DateTime.utc(2026, 10, 11, 11, 0),
      departureUtc: DateTime.utc(2026, 10, 11, 11, 15),
      locked: false,
    );

void main() {
  group('buildGoogleMapsExport', () {
    test('origin and destination are the plan endpoints', () {
      final plan = planWith([
        stop(StopKind.origin, 36.8065, 10.1815),
        stop(StopKind.destination, 36.7300, 10.2900),
      ]);
      final export = buildGoogleMapsExport(plan)!;
      expect(export.isSingle, isTrue);
      final leg = export.legs.single;
      expect(leg.origin.lat, closeTo(36.8065, 1e-9));
      expect(leg.origin.lon, closeTo(10.1815, 1e-9));
      expect(leg.destination.lat, closeTo(36.7300, 1e-9));
      expect(leg.destination.lon, closeTo(10.2900, 1e-9));
      expect(leg.waypoints, isEmpty);
    });

    test('a route with no mosque stops exports origin → destination', () {
      final plan = planWith([
        stop(StopKind.origin, 36.8065, 10.1815),
        stop(StopKind.waypoint, 36.7700, 10.2300),
        stop(StopKind.destination, 36.7300, 10.2900),
      ]);
      final export = buildGoogleMapsExport(plan)!;
      expect(export.legs.single.waypoints, hasLength(1));
      expect(export.legs.single.waypoints.single.lat, closeTo(36.7700, 1e-9));
    });

    test('multiple mosque stops keep the planned order as waypoints', () {
      final plan = planWith([
        stop(StopKind.origin, 36.8065, 10.1815),
        stop(StopKind.mosque, 36.7900, 10.2000, name: 'First'),
        stop(StopKind.prayerBreak, 36.7700, 10.2300, name: 'Second'),
        stop(StopKind.mosque, 36.7500, 10.2600, name: 'Third'),
        stop(StopKind.destination, 36.7300, 10.2900),
      ]);
      final export = buildGoogleMapsExport(plan)!;
      final leg = export.legs.single;
      expect(leg.waypoints, hasLength(3));
      // Order is exactly the plan's stop order — never reordered.
      expect(leg.waypoints[0].lat, closeTo(36.7900, 1e-9));
      expect(leg.waypoints[1].lat, closeTo(36.7700, 1e-9));
      expect(leg.waypoints[2].lat, closeTo(36.7500, 1e-9));
    });

    test('journeys beyond the waypoint cap split into legs without losing stops',
        () {
      // 12 intermediate stops, cap of 9 per request (or lower, to also
      // exercise the general path).
      final stops = [
        stop(StopKind.origin, 36.0000, 10.0000),
        for (var i = 0; i < 12; i++) stop(StopKind.mosque, 36.1 + i * 0.01, 10.1),
        stop(StopKind.destination, 36.9900, 10.9900),
      ];
      final export = buildGoogleMapsExport(planWith(stops),
          maxWaypointsPerLeg: 9)!;

      expect(export.isSingle, isFalse);
      expect(export.legs.length, 2);
      // Every intermediate stop survives, in order, across the legs
      // (as waypoints or as intermediate leg destinations).
      final all = export.allIntermediateStops;
      expect(all, hasLength(12));
      for (var i = 0; i < 12; i++) {
        expect(all[i].lat, closeTo(36.1 + i * 0.01, 1e-9),
            reason: 'stop $i must survive the split in order');
      }
      // The chain is continuous: each leg resumes where the previous ended.
      expect(export.legs[1].origin.lat, closeTo(export.legs[0].destination.lat, 1e-9));
      expect(export.legs[1].origin.lon, closeTo(export.legs[0].destination.lon, 1e-9));
      // First leg starts at the plan origin; last leg ends at the destination.
      expect(export.legs.first.origin.lat, closeTo(36.0000, 1e-9));
      expect(export.legs.last.destination.lat, closeTo(36.9900, 1e-9));
      // No leg exceeds the cap.
      for (final leg in export.legs) {
        expect(leg.waypoints.length, lessThanOrEqualTo(9));
      }
    });

    test('a tiny cap still preserves every stop (stress the splitter)', () {
      final stops = [
        stop(StopKind.origin, 0.0, 0.0),
        for (var i = 1; i <= 5; i++) stop(StopKind.mosque, i * 0.1, 0.0),
        stop(StopKind.destination, 1.0, 1.0),
      ];
      final export = buildGoogleMapsExport(planWith(stops), maxWaypointsPerLeg: 1)!;
      expect(export.allIntermediateStops, hasLength(5));
      for (var i = 0; i < 5; i++) {
        expect(export.allIntermediateStops[i].lat, closeTo((i + 1) * 0.1, 1e-9),
            reason: 'stop $i must survive with cap=1');
      }
      expect(export.legs.first.origin.lat, closeTo(0.0, 1e-9));
      expect(export.legs.last.destination.lat, closeTo(1.0, 1e-9));
      // Continuous chain across every leg.
      for (var i = 1; i < export.legs.length; i++) {
        expect(export.legs[i].origin.lat,
            closeTo(export.legs[i - 1].destination.lat, 1e-9));
      }
    });

    test('returns null when the plan has no coordinates at all', () {
      final plan = planWith(const []);
      expect(buildGoogleMapsExport(plan), isNull);
    });

    test('leg fallback: uses leg endpoints when stops are absent', () {
      final plan = RoutePlan(
        preference: RoutePreference.fastest,
        legs: [
          TravelLeg(
            from: const GeoPoint(lat: 48.8566, lon: 2.3522),
            to: const GeoPoint(lat: 45.7640, lon: 4.8357),
            departureUtc: DateTime.utc(2026, 10, 11, 10),
            arrivalUtc: DateTime.utc(2026, 10, 11, 12),
            distanceM: 460000,
            durationS: 25000,
            fromLabel: 'Paris',
            toLabel: 'Lyon',
          ),
        ],
        stops: const [],
        metrics: RouteMetrics(
          totalDistanceM: 460000,
          totalDurationS: 25000,
          drivingDurationS: 25000,
          waitingDurationS: 0,
          detourDurationS: 0,
          detourDistanceM: 0,
          arrivalUtc: DateTime.utc(2026, 10, 11, 12),
          arrivalLocal: '12:00',
          arrivalTz: 'Europe/Paris',
          mosqueStopCount: 0,
          prayersServed: const [],
          prayersMissed: const [],
        ),
        prayerEvents: const [],
        explanation: const [],
        uncertainties: const [],
        routeProvider: 'test',
        routeLive: true,
        geometry: const [],
        feasible: true,
      );
      final export = buildGoogleMapsExport(plan)!;
      expect(export.legs.single.origin.lat, closeTo(48.8566, 1e-9));
      expect(export.legs.single.destination.lat, closeTo(45.7640, 1e-9));
    });
  });

  group('GoogleMapsLeg.toUri', () {
    GoogleMapsLeg leg({List<GeoPoint> waypoints = const []}) => GoogleMapsLeg(
          origin: const GeoPoint(lat: 36.8065, lon: 10.1815),
          destination: const GeoPoint(lat: 36.7300, lon: 10.2900),
          waypoints: waypoints,
          index: 1,
          total: 1,
        );

    test('builds a canonical google.com maps dir URL', () {
      final uri = leg().toUri(TravelMode.driving);
      expect(uri.scheme, 'https');
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/maps/dir/');
      expect(uri.queryParameters['api'], '1');
      expect(uri.queryParameters['origin'], '36.806500,10.181500');
      expect(uri.queryParameters['destination'], '36.730000,10.290000');
      expect(uri.queryParameters['travelmode'], 'driving');
      expect(uri.queryParameters.containsKey('waypoints'), isFalse);
    });

    test('waypoints are pipe-separated, in order, and encoded', () {
      final uri = leg(waypoints: const [
        GeoPoint(lat: 36.7900, lon: 10.2000),
        GeoPoint(lat: 36.7500, lon: 10.2600),
      ]).toUri(TravelMode.driving);
      // Uri encodes the pipe; decoding recovers the documented format.
      expect(uri.queryParameters['waypoints'], '36.790000,10.200000|36.750000,10.260000');
      expect(uri.toString(), contains('%7C'));
    });

    test('travel modes map to Google\'s documented values', () {
      expect(leg().toUri(TravelMode.walking).queryParameters['travelmode'], 'walking');
      expect(leg().toUri(TravelMode.cycling).queryParameters['travelmode'], 'bicycling');
    });

    test('coordinates survive round-tripping (no precision loss at 6 dp)',
        () {
      const point = GeoPoint(lat: -33.8688197, lon: 151.2092955);
      final uri = GoogleMapsLeg(
        origin: point,
        destination: point,
        waypoints: const [],
        index: 1,
        total: 1,
      ).toUri(TravelMode.driving);
      final parsed = uri.queryParameters['origin']!.split(',');
      expect(double.parse(parsed[0]), closeTo(point.lat, 1e-6));
      expect(double.parse(parsed[1]), closeTo(point.lon, 1e-6));
    });
  });
}
