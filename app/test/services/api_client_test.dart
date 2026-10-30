import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:eventide/services/api_client.dart';
import 'package:eventide/services/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

void main() {
  late MemoryStore store;
  late FakeNativeBridge native;
  late List<http.Request> requests;

  ApiClient build(Future<http.Response> Function(http.Request) handler, {String base = 'https://api.test/v1'}) {
    requests = [];
    return ApiClient(
      baseUrl: base,
      client: MockClient((request) {
        requests.add(request);
        return handler(request);
      }),
      store: store,
      native: native,
      appVersion: '1.0.0',
      deviceSalt: 'salt',
      timeout: const Duration(milliseconds: 200),
    );
  }

  http.Response json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  setUp(() {
    store = MemoryStore();
    native = FakeNativeBridge();
  });

  test('registers the installation once, then sends the bearer token', () async {
    var installs = 0;
    final api = build((request) async {
      if (request.url.path == '/v1/installations') {
        installs++;
        return json(201, {'installation_id': 'i1', 'token': 'tok-1'});
      }
      return json(200, {'plan': 'free', 'premium': false});
    });
    await api.entitlements();
    await api.entitlements();
    expect(installs, 1);
    final install = jsonDecode(requests.first.body) as Map<String, dynamic>;
    expect(install['device_hash'], sha256.convert(utf8.encode('android-id-1salt')).toString());
    expect(install['integrity_token'], 'integrity-token');
    expect(install['app_version'], '1.0.0');
    // The Play Integrity nonce is the request hash itself.
    expect(native.lastNonce, install['request_hash']);
    expect(install['request_hash'], isNot(contains('=')));
    expect(requests[1].headers['Authorization'], 'Bearer tok-1');
    expect(requests.first.headers.containsKey('Authorization'), isFalse);
    expect((await store.readMap(StoreKeys.installation))?['token'], 'tok-1');
  });

  test('a 401 re-registers and retries once', () async {
    await store.write(StoreKeys.installation, {'token': 'old'});
    var calls = 0;
    final api = build((request) async {
      if (request.url.path == '/v1/installations') return json(201, {'installation_id': 'i2', 'token': 'new'});
      calls++;
      if (request.headers['Authorization'] == 'Bearer old') return json(401, {'error': 'unauthorized'});
      return json(200, {'plan': 'annual', 'premium': true});
    });
    final body = await api.entitlements();
    expect(body['plan'], 'annual');
    expect(calls, 2);
    expect((await store.readMap(StoreKeys.installation))?['token'], 'new');
  });

  test('Play Integrity unavailable: registration still sent (server decides)', () async {
    native.integrityFails = true;
    final api = build((request) async {
      if (request.url.path == '/v1/installations') return json(201, {'installation_id': 'i', 'token': 't'});
      return json(200, {});
    });
    await api.entitlements();
    expect((jsonDecode(requests.first.body) as Map)['integrity_token'], '');
  });

  test('error envelopes become ApiException with the contract code', () async {
    await store.write(StoreKeys.installation, {'token': 't'});
    final api = build((request) async => json(402, {'error': 'purchase_invalid', 'detail': 'x'}));
    await expectLater(
      api.postPurchase(productId: 'eventide_lifetime', purchaseToken: 'p'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'purchase_invalid').having((e) => e.status, 'status', 402)),
    );
  });

  test('timeouts and missing backend are ApiUnavailableException', () async {
    await store.write(StoreKeys.installation, {'token': 't'});
    final slow = build((request) => Completer<http.Response>().future);
    await expectLater(
      slow.entitlements(),
      throwsA(isA<ApiUnavailableException>().having((e) => e.timeout, 'timeout', isTrue)),
    );
    final none = build((request) async => json(200, {}), base: '');
    expect(none.enabled, isFalse);
    await expectLater(none.entitlements(), throwsA(isA<ApiUnavailableException>()));
    expect(await none.health(), isFalse);
  });

  test('shares and content urls', () async {
    await store.write(StoreKeys.installation, {'token': 't'});
    final api = build((request) async {
      switch (request.url.path) {
        case '/v1/shares':
          return json(201, {'code': 'k7Fq2xPa', 'url': 'https://eventide.app/m/k7Fq2xPa'});
        case '/v1/shares/k7Fq2xPa':
          return json(200, {
            'scene': {'paysage': 'cascade-foret'},
          });
        case '/v1/content/urls':
          return json(200, {
            'urls': {'audio/sons/vagues.ogg': 'https://cdn.test/signed'},
            'expires_at': 'x',
          });
      }
      return json(404, {'error': 'not_found'});
    });
    expect((await api.createShare({'paysage': 'cascade-foret'})).toString(), 'https://eventide.app/m/k7Fq2xPa');
    expect((await api.getShare('k7Fq2xPa'))['paysage'], 'cascade-foret');
    expect(await api.contentUrls(['audio/sons/vagues.ogg']), {'audio/sons/vagues.ogg': 'https://cdn.test/signed'});
    await expectLater(api.getShare('nope1234'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)));
  });

  group('GET /catalog (contract § 13)', () {
    test('200: the body; the revision held goes in If-None-Match', () async {
      await store.write(StoreKeys.installation, {'token': 't'});
      final api = build((request) async => json(200, {'revision': 7, 'catalog': {}, 'distant': {}}));
      final answer = await api.fetchCatalog();
      expect(answer, isA<CatalogFetched>().having((a) => a.body['revision'], 'revision', 7));
      expect(requests.single.method, 'GET');
      expect(requests.single.url.toString(), 'https://api.test/v1/catalog');
      expect(requests.single.headers['Authorization'], 'Bearer t');
      expect(requests.single.headers.containsKey('If-None-Match'), isFalse);
      await api.fetchCatalog(etag: '"7"');
      expect(requests.last.headers['If-None-Match'], '"7"');
    });

    test('304: unchanged, without a body', () async {
      await store.write(StoreKeys.installation, {'token': 't'});
      final api = build((request) async => http.Response('', 304));
      expect(await api.fetchCatalog(etag: '"7"'), isA<CatalogNotModified>());
    });

    test('304 after a revoked token: registered again, still unchanged', () async {
      await store.write(StoreKeys.installation, {'token': 'old'});
      final api = build((request) async {
        if (request.url.path == '/v1/installations') return json(201, {'installation_id': 'i', 'token': 'new'});
        if (request.headers['Authorization'] == 'Bearer old') return json(401, {'error': 'unauthorized'});
        return http.Response('', 304);
      });
      expect(await api.fetchCatalog(etag: '"3"'), isA<CatalogNotModified>());
      expect(requests.last.headers['If-None-Match'], '"3"');
    });

    test('errors are exceptions; other routes never accept a 304', () async {
      await store.write(StoreKeys.installation, {'token': 't'});
      final failing = build((request) async => json(429, {'error': 'rate_limited'}));
      await expectLater(failing.fetchCatalog(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 429)));
      final notModified = build((request) async => http.Response('', 304));
      await expectLater(notModified.entitlements(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 304)));
      final none = build((request) async => json(200, {}), base: '');
      await expectLater(none.fetchCatalog(), throwsA(isA<ApiUnavailableException>()));
      expect(requests, isEmpty);
    });
  });
}
