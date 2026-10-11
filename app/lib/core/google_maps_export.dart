/// Export the *selected* plan to Google Maps for turn-by-turn navigation.
///
/// Guide remains the planner: this handoff only carries the ordered stops
/// the user already chose (origin → planned mosque/waypoint stops →
/// destination). Google Maps may recalculate a different route — we never
/// claim it reproduces Guide's geometry, durations or prayer schedule.
///
/// Waypoint limits: the Google Maps URLs `dir` action accepts a bounded
/// number of intermediate waypoints per request (platform-dependent, and
/// fewer for some launch paths). We use a deliberately conservative
/// constant and split longer journeys into *sequential legs* — every
/// planned stop is preserved, in order, across the legs. Stops are never
/// silently dropped; when a journey needs several legs the caller must
/// walk the user through them.
library;

import '../domain/models.dart';

/// Conservative per-request waypoint cap. Google's documented limit varies
/// by platform and launch method (up to 9 on modern clients, fewer on
/// some); staying at or below 9 keeps every target working, and the
/// leg-splitting below handles anything longer without losing stops.
const int kGoogleMapsMaxWaypointsPerLeg = 9;

/// One Google Maps directions request: origin, ordered waypoints,
/// destination.
class GoogleMapsLeg {
  const GoogleMapsLeg({
    required this.origin,
    required this.destination,
    required this.waypoints,
    required this.index,
    required this.total,
  });

  final GeoPoint origin;
  final GeoPoint destination;

  /// Intermediate stops in visit order (never reordered, never dropped).
  final List<GeoPoint> waypoints;

  /// 1-based leg position, for UI copy ("Leg 1 of 3").
  final int index;
  final int total;

  bool get isSingle => total == 1;

  /// Canonical Google Maps directions URL. Coordinates are formatted to 6
  /// decimals (~0.1 m — removes float noise without moving the point) and
  /// all parameters are encoded by [Uri].
  Uri toUri(TravelMode mode) {
    final query = <String, String>{
      'api': '1',
      'origin': _coord(origin),
      'destination': _coord(destination),
      'travelmode': switch (mode) {
        TravelMode.driving => 'driving',
        TravelMode.walking => 'walking',
        TravelMode.cycling => 'bicycling',
      },
      if (waypoints.isNotEmpty)
        'waypoints': waypoints.map(_coord).join('|'),
    };
    return Uri.https('www.google.com', '/maps/dir/', query);
  }

  static String _coord(GeoPoint p) =>
      '${p.lat.toStringAsFixed(6)},${p.lon.toStringAsFixed(6)}';
}

/// The full export for a plan: one or more sequential legs.
class GoogleMapsExport {
  const GoogleMapsExport({required this.legs});

  final List<GoogleMapsLeg> legs;

  bool get isSingle => legs.length == 1;

  /// Every planned intermediate stop, in the planned order, across all
  /// legs — whether carried as a waypoint or as an intermediate leg's
  /// destination. Used by tests and the confirmation UI to prove the
  /// split never dropped or reordered a stop.
  List<GeoPoint> get allIntermediateStops {
    final out = <GeoPoint>[];
    for (var i = 0; i < legs.length; i++) {
      out.addAll(legs[i].waypoints);
      // Every leg except the final one lands on a planned stop; the final
      // leg's destination is the journey's real destination, not a stop.
      if (i < legs.length - 1) out.add(legs[i].destination);
    }
    return out;
  }
}

/// Build the export for [plan].
///
/// Intermediate stops are taken from the plan's scheduled stops in order
/// (origin first, destination last, everything between as waypoints —
/// mosque stops, prayer breaks and user waypoints alike). Returns null
/// when the plan carries no usable origin/destination coordinates; never
/// invents points to make an export possible.
GoogleMapsExport? buildGoogleMapsExport(
  RoutePlan plan, {
  int maxWaypointsPerLeg = kGoogleMapsMaxWaypointsPerLeg,
}) {
  if (maxWaypointsPerLeg < 1) {
    throw ArgumentError.value(
        maxWaypointsPerLeg, 'maxWaypointsPerLeg', 'must be >= 1');
  }

  final stops = plan.stops;
  GeoPoint? origin;
  GeoPoint? destination;
  final intermediate = <GeoPoint>[];

  for (final stop in stops) {
    switch (stop.kind) {
      case StopKind.origin:
        // First origin wins; later ones are not expected but harmless.
        origin ??= stop.location;
      case StopKind.destination:
        destination = stop.location;
      default:
        intermediate.add(stop.location);
    }
  }

  // Fallback: some plans may lack explicit origin/destination stops but
  // still carry legs — use their endpoints rather than failing.
  origin ??= plan.legs.isNotEmpty ? plan.legs.first.from : null;
  destination ??= plan.legs.isNotEmpty ? plan.legs.last.to : null;

  if (origin == null || destination == null) return null;

  final legs = <GoogleMapsLeg>[];
  var currentOrigin = origin;
  var i = 0;
  // Full legs while more than [maxWaypointsPerLeg] stops remain: the
  // chunk's last stop becomes this leg's destination AND the next leg's
  // origin, so the user can resume navigation exactly where they are.
  while (intermediate.length - i > maxWaypointsPerLeg) {
    final chunk = intermediate.sublist(i, i + maxWaypointsPerLeg);
    legs.add(GoogleMapsLeg(
      origin: currentOrigin,
      destination: chunk.last,
      waypoints: chunk.sublist(0, chunk.length - 1),
      index: legs.length + 1,
      total: 0, // patched below
    ));
    currentOrigin = chunk.last;
    i += maxWaypointsPerLeg;
  }
  // Final leg: whatever remains (<= cap) plus the real destination.
  legs.add(GoogleMapsLeg(
    origin: currentOrigin,
    destination: destination,
    waypoints: intermediate.sublist(i),
    index: legs.length + 1,
    total: 0,
  ));

  return GoogleMapsExport(
    legs: [
      for (final leg in legs)
        GoogleMapsLeg(
          origin: leg.origin,
          destination: leg.destination,
          waypoints: leg.waypoints,
          index: leg.index,
          total: legs.length,
        ),
    ],
  );
}
