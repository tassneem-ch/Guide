import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../application/settings.dart';
import '../../domain/models.dart';
import '../../domain/repositories.dart';
import '../../l10n/generated/app_localizations.dart';
import '../widgets/common.dart';
import '../widgets/place_field.dart';
import '../widgets/route_map.dart';

/// LocalStore key holding this device's submission ids (UUIDs handed out by
/// the server — they double as read capabilities, so no account is needed
/// to check one's own submission statuses).
const String kCommunitySubmissionIdsKey = 'community_submission_ids';

/// Screen: suggest a mosque that is missing from the map (secondary
/// utility — reachable from Settings, never part of the main flow).
///
/// Honesty rules:
/// - a submission starts `unverified` server-side and is useless for
///   route planning until a moderator confirms it — said up front and
///   again on success;
/// - the location must be real (device fix, map tap, or search) — the
///   form never invents coordinates;
/// - unnamed mosques are valid: the name is optional everywhere.
class CommunityMosqueScreen extends ConsumerStatefulWidget {
  const CommunityMosqueScreen({super.key});

  @override
  ConsumerState<CommunityMosqueScreen> createState() =>
      _CommunityMosqueScreenState();
}

class _CommunityMosqueScreenState
    extends ConsumerState<CommunityMosqueScreen> {
  GeoPoint? _location;
  String? _locationLabel;
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _hoursController = TextEditingController();

  bool _submitting = false;
  CommunityMosqueRecord? _lastSubmitted;
  String? _error;
  List<String> _myIds = const [];
  List<CommunityMosqueRecord>? _myStatuses;
  bool _statusesLoading = false;

  @override
  void initState() {
    super.initState();
    _loadMyIds();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _hoursController.dispose();
    super.dispose();
  }

  Future<void> _loadMyIds() async {
    final store = ref.read(localStoreProvider);
    final raw = await store.read(kCommunitySubmissionIdsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        setState(() => _myIds = decoded.cast<String>());
        _refreshStatuses();
      }
    } catch (_) {
      // Corrupt local value: ignore rather than guess.
    }
  }

  Future<void> _refreshStatuses() async {
    final repo = ref.read(repositoriesProvider).community;
    if (repo == null || _myIds.isEmpty) return;
    setState(() => _statusesLoading = true);
    try {
      final records = await repo.statuses(_myIds);
      if (mounted) setState(() => _myStatuses = records);
    } on Failure {
      if (mounted) setState(() => _myStatuses = null);
    } finally {
      if (mounted) setState(() => _statusesLoading = false);
    }
  }

  Future<void> _useMyLocation() async {
    final l10n = AppLocalizations.of(context);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.locationDeniedCommunity)));
        }
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (!mounted) return;
      setState(() {
        _location = GeoPoint(lat: position.latitude, lon: position.longitude);
        _locationLabel = l10n.useMyLocation;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.locationDeniedCommunity)));
      }
    }
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final repo = ref.read(repositoriesProvider).community;
    final location = _location;
    if (repo == null || location == null || _submitting) return;

    setState(() {
      _submitting = true;
      _error = null;
      _lastSubmitted = null;
    });
    try {
      final record = await repo.submit(
        location: location,
        name: _nameController.text.trim().isEmpty ? null : _nameController.text,
        address:
            _addressController.text.trim().isEmpty ? null : _addressController.text,
        openingHours:
            _hoursController.text.trim().isEmpty ? null : _hoursController.text,
      );
      // Remember the id locally so "My submissions" can show its status.
      final store = ref.read(localStoreProvider);
      final raw = await store.read(kCommunitySubmissionIdsKey);
      List<String> ids;
      try {
        ids = raw == null ? <String>[] : (jsonDecode(raw) as List).cast<String>();
      } catch (_) {
        ids = <String>[];
      }
      ids.add(record.id);
      await store.write(kCommunitySubmissionIdsKey, jsonEncode(ids));
      if (!mounted) return;
      setState(() {
        _myIds = ids;
        _lastSubmitted = record;
        _submitting = false;
      });
      _refreshStatuses();
    } on Failure catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.statusCode == 409 ? l10n.submissionDuplicate : e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = l10n.errorGeneric;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final repo = ref.watch(repositoriesProvider).community;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.suggestMosque)),
      body: repo == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.communityUnavailableDemo,
                    textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ---- location -------------------------------------------
                SectionHeader(l10n.mosqueLocation),
                PlaceField(
                  label: l10n.mosqueLocationSearch,
                  icon: Icons.search,
                  onSelected: (point) => setState(() {
                    _location = point;
                    _locationLabel = point.name;
                  }),
                  onCleared: () => setState(() => _location = null),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _useMyLocation,
                        icon: const Icon(Icons.my_location),
                        label: Text(l10n.useMyLocation),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(l10n.pickOnMapHint,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                AdaptiveMap(
                  points: _location == null ? const [] : [_location!],
                  height: 180,
                  onMapTap: (point) => setState(() {
                    _location = point;
                    _locationLabel = null;
                  }),
                ),
                const SizedBox(height: 8),
                if (_location != null)
                  Text(
                    _locationLabel ??
                        '${_location!.lat.toStringAsFixed(5)}, '
                            '${_location!.lon.toStringAsFixed(5)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                else
                  Text(l10n.submissionLocationRequired,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 16),

                // ---- optional details ----------------------------------
                TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: l10n.mosqueNameOptional,
                    hintText: l10n.mosqueNameHint,
                  ),
                  maxLength: 120,
                ),
                TextField(
                  controller: _addressController,
                  decoration:
                      InputDecoration(labelText: l10n.mosqueAddressOptional),
                  maxLines: 2,
                  maxLength: 500,
                ),
                TextField(
                  controller: _hoursController,
                  decoration: InputDecoration(
                    labelText: l10n.mosqueOpeningHoursOptional,
                    helperText: l10n.mosqueOpeningHoursNote,
                  ),
                  maxLength: 120,
                ),
                const SizedBox(height: 8),

                if (_error != null) ...[
                  ErrorCard(message: _error!),
                  const SizedBox(height: 8),
                ],
                if (_lastSubmitted != null) ...[
                  Card(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l10n.submissionSuccess,
                              style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(height: 8),
                          Text(_lastSubmitted!.label,
                              style: Theme.of(context).textTheme.titleSmall),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],

                FilledButton.icon(
                  onPressed: _location == null || _submitting
                      ? null
                      : _submit,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_location_alt_outlined),
                  label: Text(
                      _submitting ? l10n.submittingMosque : l10n.submitMosque),
                ),

                // ---- my submissions (status by id) ----------------------
                if (_myIds.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: SectionHeader(l10n.mySubmissions)),
                      IconButton(
                        tooltip: l10n.viewSubmissionStatuses,
                        icon: const Icon(Icons.refresh),
                        onPressed: _statusesLoading ? null : _refreshStatuses,
                      ),
                    ],
                  ),
                  if (_statusesLoading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_myStatuses == null || _myStatuses!.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(l10n.mySubmissionsEmpty,
                          style: Theme.of(context).textTheme.bodySmall),
                    )
                  else
                    for (final record in _myStatuses!)
                      Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          leading: Icon(
                            record.isVerified
                                ? Icons.verified_outlined
                                : Icons.hourglass_bottom_outlined,
                            color: record.isVerified
                                ? Colors.green.shade700
                                : Theme.of(context).colorScheme.outline,
                          ),
                          title: Text(record.label),
                          subtitle: Text(record.isVerified
                              ? l10n.statusVerified
                              : l10n.statusUnverified),
                        ),
                      ),
                ],
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
