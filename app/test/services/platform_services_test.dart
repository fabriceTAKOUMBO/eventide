import 'package:eventide/services/ads_service.dart';
import 'package:eventide/services/connectivity.dart';
import 'package:eventide/services/native_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('connectivity is a real attempt', () {
    test('API health first, then Google 204', () async {
      final seen = <String>[];
      var apiUp = true;
      var internetUp = true;
      final checker = HttpConnectivityChecker(
        client: MockClient((request) async {
          seen.add(request.url.host);
          if (request.url.host == 'api.test') {
            return apiUp ? http.Response('{"status":"ok"}', 200) : http.Response('', 503);
          }
          if (!internetUp) throw http.ClientException('offline');
          return http.Response('', 204);
        }),
        apiBaseUrl: 'https://api.test/v1/',
        native: FakeNativeBridge(),
      );
      expect(await checker.check(), isTrue);
      expect(seen, ['api.test']);
      apiUp = false;
      expect(await checker.check(), isTrue, reason: 'an API outage alone never locks a free user out');
      internetUp = false;
      expect(await checker.check(), isFalse);
    });

    test('no backend: Google 204 only', () async {
      final checker = HttpConnectivityChecker(
        client: MockClient((request) async => http.Response('', 204)),
        apiBaseUrl: '',
        native: FakeNativeBridge(),
      );
      expect(await checker.check(), isTrue);
      expect(await checker.isUnmetered(), isTrue);
    });
  });

  group('ad policy', () {
    const policy = AdPolicy();
    final now = DateTime(2026, 10, 28, 20);

    test('free only, never during playback', () {
      expect(policy.canShow(showsAds: true, playing: false, lastShown: null, now: now), isTrue);
      expect(policy.canShow(showsAds: false, playing: false, lastShown: null, now: now), isFalse);
      expect(policy.canShow(showsAds: true, playing: true, lastShown: null, now: now), isFalse);
    });

    test('frequency cap of 4 h per placement', () {
      expect(
        policy.canShow(showsAds: true, playing: false, lastShown: now.subtract(const Duration(hours: 3)), now: now),
        isFalse,
      );
      expect(
        policy.canShow(showsAds: true, playing: false, lastShown: now.subtract(const Duration(hours: 4)), now: now),
        isTrue,
      );
    });
  });

  group('native bridge channel', () {
    const channel = MethodChannel('be.cinaf.eventide/native');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'syncSchedules':
            return {'mode': 'exact', 'next_at': DateTime(2026, 10, 28, 22).millisecondsSinceEpoch};
          case 'consumePendingStart':
            return 'sched-1';
          case 'networkStatus':
            return {'connected': true, 'unmetered': false};
          case 'requestIntegrityToken':
            return 'tok';
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('parses answers', () async {
      final bridge = MethodChannelNativeBridge();
      final sync = await bridge.syncSchedules('{"schedules":[]}');
      expect(sync.mode, AlarmMode.exact);
      expect(sync.nextAt, DateTime(2026, 10, 28, 22));
      expect(await bridge.consumePendingStart(), 'sched-1');
      final net = await bridge.networkStatus();
      expect(net?.connected, isTrue);
      expect(net?.unmetered, isFalse);
      expect(await bridge.requestIntegrityToken('n', cloudProjectNumber: '42'), 'tok');
      expect(calls.last.arguments, {'nonce': 'n', 'cloudProjectNumber': '42'});
    });

    test('missing answers fall back to safe defaults', () async {
      final bridge = MethodChannelNativeBridge();
      expect(await bridge.canScheduleExactAlarms(), isFalse);
      expect(await bridge.androidId(), '');
    });
  });
}
