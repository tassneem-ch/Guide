import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/planner.dart';
import '../../application/settings.dart';
import '../../core/format.dart';
import '../../core/google_maps_export.dart';
import '../../domain/models.dart';
import '../../l10n/generated/app_localizations.dart';
import '../widgets/common.dart';
import '../widgets/route_map.dart';

/// Screen 3: full itinerary for the selected alternative — timeline of stops
/// with honest labels for everything unverified.
class JourneyScreen extends ConsumerWidget {
  const JourneyScreen({super.key, required this.planIndex});

  final int planIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final response = ref.watch(routeProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.journeyTitle)),
      body: response.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: ErrorCard(
            message: l10n.errorGeneric,
            onRetry: () => context.pop(),
          ),
        ),
        data: (data) {
          if (data == null || planIndex >= data.alternatives.length) {
            return Center(child: Text(l10n.noResults));
          }
          final plan = data.alternatives[planIndex];
          final m = plan.metrics;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (data.stale) ...[
                StaleBanner(fetchedAt: data.staleAt ?? data.requestedAt),
                const SizedBox(height: 8),
              ],
              FixtureBanner(providers: data.providers),
              const SizedBox(height: 8),
              if (plan.geometry.length >= 2)
                AdaptiveMap(
                    points: plan.geometry, stops: plan.stops, height: 240),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              switch (plan.preference) {
                                RoutePreference.fastest => l10n.labelFastest,
                                RoutePreference.balanced => l10n.labelBalanced,
                                RoutePreference.prayerFriendly =>
                                  l10n.labelPrayerFriendly,
                              },
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          if (!plan.routeLive)
                            SourceBadge(live: false, label: l10n.fixtureData),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          MetricTile(
                            icon: Icons.straighten,
                            label: l10n.totalDistance,
                            value: formatDistance(context, m.totalDistanceM,
                                metric: settings.metric),
                          ),
                          const SizedBox(width: 8),
                          MetricTile(
                            icon: Icons.schedule,
                            label: l10n.totalDuration,
                            value: formatDuration(context, m.totalDurationS,
                                compact: true),
                          ),
                          const SizedBox(width: 8),
                          MetricTile(
                            icon: Icons.flag_outlined,
                            label: l10n.arrivalTime,
                            value: m.arrivalLocal.isEmpty
                                ? formatTime(context, m.arrivalUtc.toLocal(),
                                    use24h: settings.use24h)
                                : m.arrivalLocal,
                          ),
                        ],
                      ),
                      if (m.prayersServed.isNotEmpty || m.prayersMissed.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text('${l10n.servedPrayers}: '
                            '${m.prayersServed.map((p) => prayerName(context, p)).join(', ')}'),
                        if (m.prayersMissed.isNotEmpty)
                          Text(
                            '${l10n.missedPrayers}: '
                            '${m.prayersMissed.map((p) => prayerName(context, p)).join(', ')}',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error),
                          ),
                      ],
                    ],
                  ),
                ),
              ),

              const SectionHeader2(),
              for (var i = 0; i < plan.stops.length; i++)
                _StopTile(stop: plan.stops[i], use24h: settings.use24h),

              // ---- optional handoff to Google Maps -----------------------
              const SizedBox(height: 12),
              _NavigateWithGoogleMaps(plan: plan),

              if (plan.uncertainties.isNotEmpty) ...[
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.uncertainties,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer)),
                        const SizedBox(height: 8),
                        InfoList(items: plan.uncertainties, warning: true),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class SectionHeader2 extends StatelessWidget {
  const SectionHeader2({super.key});

  @override
  Widget build(BuildContext context) =>
      SectionHeader(AppLocalizations.of(context).stopsTimeline);
}

class _StopTile extends StatelessWidget {
  const _StopTile({required this.stop, required this.use24h});

  final ScheduledStop stop;
  final bool use24h;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final arrival = formatTime(context, stop.arrivalUtc.toLocal(),
        use24h: use24h);
    final departure = formatTime(context, stop.departureUtc.toLocal(),
        use24h: use24h);

    final (icon, title) = switch (stop.kind) {
      StopKind.origin => (Icons.trip_origin_outlined, l10n.origin),
      StopKind.destination => (Icons.place_outlined, l10n.destination),
      StopKind.mosque => (Icons.mosque, stop.name),
      StopKind.prayerBreak => (Icons.mosque, stop.name),
      _ => (Icons.circle_outlined, stop.name),
    };

    final canOpenMosque = stop.kind == StopKind.mosque && stop.mosque != null;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(stop.kind == StopKind.origin
                ? l10n.departAt(arrival)
                : l10n.arriveAt(arrival)),
            if (stop.kind != StopKind.origin && stop.kind != StopKind.destination)
              Text(l10n.departAt(departure)),
            if (stop.prayer != null)
              Text(l10n.prayerAt(
                prayerName(context, stop.prayer!.name.name),
                formatTime(context, stop.prayer!.local, use24h: use24h),
              )),
            if (stop.rationale != null) ...[
              const SizedBox(height: 4),
              Text(stop.rationale!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12)),
            ],
            if (stop.uncertainties.isNotEmpty) ...[
              const SizedBox(height: 4),
              InfoList(items: stop.uncertainties, warning: true),
            ],
          ],
        ),
        trailing: canOpenMosque ? const Icon(Icons.chevron_right) : null,
        onTap: canOpenMosque
            ? () => context.push('/mosque', extra: stop.mosque)
            : null,
      ),
    );
  }
}

/// Optional navigation handoff: open the *selected* plan in Google Maps.
///
/// Guide keeps planning and explaining; Google Maps only navigates. The
/// export carries the plan's own coordinates in the plan's stop order —
/// origin, every planned mosque/waypoint stop, destination. Longer journeys
/// are split into sequential legs (never dropping stops) and the user is
/// told to open each leg in turn. Nothing in Guide's state is mutated.
class _NavigateWithGoogleMaps extends ConsumerWidget {
  const _NavigateWithGoogleMaps({required this.plan});

  final RoutePlan plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final mode = ref.watch(plannerProvider).mode;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FilledButton.icon(
              onPressed: () => _navigate(context, ref, l10n, mode),
              icon: const Icon(Icons.navigation_outlined),
              label: Text(l10n.navigateGoogleMaps),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.navigateGoogleMapsNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _navigate(BuildContext context, WidgetRef ref,
      AppLocalizations l10n, TravelMode mode) async {
    final export = buildGoogleMapsExport(plan);
    if (export == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.navigateMissingCoordinates)),
      );
      return;
    }

    if (export.isSingle) {
      await _openLeg(context, l10n, export.legs.first, mode,
          announce: false);
      return;
    }

    // Multi-leg: explain the split and let the user open each leg in turn —
    // no stop is ever dropped, and the order is the planned order.
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                l10n.navigateMultiLegNote(export.legs.length),
                style: Theme.of(sheetContext).textTheme.bodyMedium,
              ),
            ),
            for (final leg in export.legs)
              ListTile(
                leading: const Icon(Icons.directions_outlined),
                title: Text(l10n.navigateLegTitle(leg.index, leg.total)),
                subtitle: Text(l10n.navigateOpenLeg(leg.index)),
                trailing: const Icon(Icons.open_in_new),
                onTap: () =>
                    _openLeg(context, l10n, leg, mode, announce: true),
              ),
          ],
        ),
      ),
    );
  }

  /// Launch one leg. Returns normally on success (launch actually
  /// happened); shows an honest failure message otherwise. Never claims
  /// navigation started when the launch did not.
  Future<void> _openLeg(
    BuildContext context,
    AppLocalizations l10n,
    GoogleMapsLeg leg,
    TravelMode mode, {
    required bool announce,
  }) async {
    final uri = leg.toUri(mode);
    bool launched = false;
    try {
      // externalApplication: prefer the Google Maps app, fall back to the
      // browser when the app is not installed (url_launcher behaviour).
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (!context.mounted) return;
    if (launched) {
      if (announce) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.navigateLegOpened(leg.index))),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.navigateLaunchFailed)),
      );
    }
  }
}
