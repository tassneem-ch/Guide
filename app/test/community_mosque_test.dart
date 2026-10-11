import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guide/data/api_client.dart';
import 'package:guide/data/api_repositories.dart';
import 'package:guide/domain/models.dart';
import 'package:guide/domain/repositories.dart';

/// Fake HTTP adapter returning canned JSON (no network, follows the
/// aladhan_service_test transport-mocking convention).
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int statusCode = 200}) => ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  group('CommunityMosqueRecord.fromJson', () {
    test('parses a server submission response', () {
      final record = CommunityMosqueRecord.fromJson(const {
        'id': 'abc123',
        'name': 'Masjid Al-Khair',
        'lat': 36.8405,
        'lon': 10.2350,
        'address': 'Rue de la Paix',
        'opening_hours': 'Mo-Fr 08:00-20:00',
        'status': 'unverified',
        'created_at': '2026-10-11T10:00:00Z',
      });
      expect(record.id, 'abc123');
      expect(record.name, 'Masjid Al-Khair');
      expect(record.location.lat, closeTo(36.8405, 1e-9));
      expect(record.status, 'unverified');
      expect(record.isVerified, isFalse);
      expect(record.createdAt.isUtc, isTrue);
    });

    test('unnamed mosque keeps its coordinates as its label', () {
      final record = CommunityMosqueRecord.fromJson(const {
        'id': 'x',
        'name': null,
        'lat': 36.8410,
        'lon': 10.2360,
        'status': 'unverified',
        'created_at': '2026-10-11T10:00:00Z',
      });
      expect(record.name, isNull);
      expect(record.label, contains('36.841'));
    });
  });

  group('ApiCommunityMosqueRepository (mocked transport)', () {
    GuideApi apiWith(Future<ResponseBody> Function(RequestOptions) handler) =>
        GuideApi(baseUrl: 'http://test.local')
          ..dio.httpClientAdapter = _FakeAdapter(handler);

    test('submit sends coordinates and optional fields, no status claim',
        () async {
      late RequestOptions seen;
      final repo = ApiCommunityMosqueRepository(apiWith((options) async {
        seen = options;
        return _json(const {
          'id': 'new1',
          'name': 'Test Mosque',
          'lat': 36.84,
          'lon': 10.23,
          'address': null,
          'opening_hours': null,
          'status': 'unverified',
          'created_at': '2026-10-11T10:00:00Z',
        });
      }));

      final record = await repo.submit(
        location: const GeoPoint(lat: 36.84, lon: 10.23),
        name: 'Test Mosque',
      );

      expect(seen.path, '/v1/community/mosques');
      expect(seen.method, 'POST');
      final body = seen.data as Map<String, dynamic>;
      expect(body['lat'], 36.84);
      expect(body['lon'], 10.23);
      expect(body['name'], 'Test Mosque');
      // The client never sends a verification status.
      expect(body.containsKey('status'), isFalse);
      expect(record.status, 'unverified');
    });

    test('blank optional fields are omitted, not sent as empty strings',
        () async {
      late RequestOptions seen;
      final repo = ApiCommunityMosqueRepository(apiWith((options) async {
        seen = options;
        return _json(const {
          'id': 'new2',
          'name': null,
          'lat': 36.0,
          'lon': 10.0,
          'address': null,
          'opening_hours': null,
          'status': 'unverified',
          'created_at': '2026-10-11T10:00:00Z',
        });
      }));
      await repo.submit(
        location: const GeoPoint(lat: 36.0, lon: 10.0),
        name: '   ',
        address: '',
      );
      final body = seen.data as Map<String, dynamic>;
      expect(body.containsKey('name'), isFalse);
      expect(body.containsKey('address'), isFalse);
      expect(body.containsKey('opening_hours'), isFalse);
    });

    test('statuses strips the community- prefix and parses the list', () async {
      late RequestOptions seen;
      final repo = ApiCommunityMosqueRepository(apiWith((options) async {
        seen = options;
        return _json([
          {
            'id': 'abc',
            'name': 'A',
            'lat': 1.0,
            'lon': 2.0,
            'status': 'verified',
            'created_at': '2026-10-11T10:00:00Z',
          },
          {
            'id': 'def',
            'name': null,
            'lat': 3.0,
            'lon': 4.0,
            'status': 'unverified',
            'created_at': '2026-10-11T11:00:00Z',
          },
        ]);
      }));

      final records = await repo.statuses(['community-abc', 'def']);
      expect(seen.path, '/v1/community/mosques');
      expect(seen.queryParameters['ids'], 'abc,def'); // prefix stripped
      expect(records, hasLength(2));
      expect(records.first.isVerified, isTrue);
      expect(records.last.isVerified, isFalse);
    });

    test('empty id list is a no-op (no request)', () async {
      var called = false;
      final repo = ApiCommunityMosqueRepository(apiWith((options) async {
        called = true;
        return _json([]);
      }));
      expect(await repo.statuses(const []), isEmpty);
      expect(called, isFalse);
    });

    test('report strips the prefix and includes the reason', () async {
      late RequestOptions seen;
      final repo = ApiCommunityMosqueRepository(apiWith((options) async {
        seen = options;
        return _json(const {
          'id': 'abc',
          'name': null,
          'lat': 1.0,
          'lon': 2.0,
          'status': 'unverified',
          'created_at': '2026-10-11T10:00:00Z',
        });
      }));
      await repo.report('community-abc', reason: 'wrong coordinates');
      expect(seen.path, '/v1/community/mosques/abc/report');
      expect((seen.data as Map<String, dynamic>)['reason'], 'wrong coordinates');
    });

    test('server 409 surfaces as a typed Failure (duplicate detection)',
        () async {
      final repo = ApiCommunityMosqueRepository(apiWith((options) async {
        return _json({'detail': 'A similar mosque was already submitted'},
            statusCode: 409);
      }));
      expect(
        () => repo.submit(location: const GeoPoint(lat: 1, lon: 2)),
        throwsA(isA<Failure>().having(
            (f) => f.statusCode, 'statusCode', 409)),
      );
    });
  });
}
