import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Key parity across locales: every key in the template (en) must exist in
/// ar and fr — a missing translation is a bug, not a fallback.
void main() {
  final l10nDir = Directory('lib/l10n');
  final locales = ['app_en.arb', 'app_ar.arb', 'app_fr.arb'];

  Map<String, Set<String>> keysByFile = {};

  setUpAll(() {
    for (final file in locales) {
      final content = File('${l10nDir.path}/$file').readAsStringSync();
      final json = jsonDecode(content) as Map<String, dynamic>;
      keysByFile[file] = {
        for (final key in json.keys)
          if (!key.startsWith('@')) key, // skip metadata entries
      };
    }
  });

  test('all locale ARB files exist', () {
    for (final file in locales) {
      expect(File('${l10nDir.path}/$file').existsSync(), isTrue,
          reason: '$file must exist');
    }
  });

  test('ar and fr have exactly the en key set', () {
    final en = keysByFile['app_en.arb']!;
    final ar = keysByFile['app_ar.arb']!;
    final fr = keysByFile['app_fr.arb']!;

    expect(ar.difference(en), isEmpty,
        reason: 'ar has keys missing from en');
    expect(en.difference(ar), isEmpty,
        reason: 'ar is missing keys present in en');
    expect(fr.difference(en), isEmpty,
        reason: 'fr has keys missing from en');
    expect(en.difference(fr), isEmpty,
        reason: 'fr is missing keys present in en');
  });

  test('new feature keys are present in all three locales', () {
    const requiredKeys = {
      // Feature B — Google Maps export
      'navigateGoogleMaps',
      'navigateGoogleMapsNote',
      'navigateLaunchFailed',
      'navigateMissingCoordinates',
      'navigateLegTitle',
      'navigateMultiLegNote',
      'navigateOpenLeg',
      'navigateLegOpened',
      // Feature A — community submissions
      'communitySection',
      'suggestMosque',
      'suggestMosqueSubtitle',
      'communityUnavailableDemo',
      'mosqueLocation',
      'mosqueLocationSearch',
      'pickOnMapHint',
      'mosqueNameOptional',
      'mosqueNameHint',
      'mosqueAddressOptional',
      'mosqueOpeningHoursOptional',
      'mosqueOpeningHoursNote',
      'submitMosque',
      'submittingMosque',
      'submissionSuccess',
      'submissionDuplicate',
      'submissionLocationRequired',
      'mySubmissions',
      'mySubmissionsEmpty',
      'statusUnverified',
      'statusVerified',
      'reportIncorrect',
      'reportReason',
      'reportSubmitted',
      'reportFailed',
      'locationDeniedCommunity',
    };
    for (final file in locales) {
      final keys = keysByFile[file]!;
      for (final key in requiredKeys) {
        expect(keys.contains(key), isTrue,
            reason: '$key missing from $file');
      }
    }
  });
}
