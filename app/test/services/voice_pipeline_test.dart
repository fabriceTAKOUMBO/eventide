import 'dart:async';
import 'dart:convert';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/ops.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/services/api_client.dart';
import 'package:eventide/services/storage.dart';
import 'package:eventide/services/voice/speech_recognizer.dart';
import 'package:eventide/services/voice/voice_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

void main() {
  late Catalog catalog;
  late AppSnapshot snapshot;
  late List<Map<String, dynamic>> sent;

  setUpAll(() => catalog = loadTestCatalog());

  VoicePipeline build(FutureOr<http.Response> Function(Map<String, dynamic> body) answer, {bool backend = true}) {
    sent = [];
    final store = MemoryStore()..files[StoreKeys.installation] = jsonEncode({'version': 1, 'data': {'token': 't'}});
    final api = ApiClient(
      baseUrl: backend ? 'https://api.test/v1' : '',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sent.add(body);
        return answer(body);
      }),
      store: store,
      native: FakeNativeBridge(),
      appVersion: '1',
      deviceSalt: 's',
    );
    return VoicePipeline(catalog: catalog, api: api);
  }

  http.Response json(int status, Object body) => http.Response(jsonEncode(body), status);

  setUp(() {
    snapshot = AppSnapshot(scene: Scene.fromLandscape(catalog.defaultLandscape), playing: true);
  });

  test('subscriber + rules hit: resolved on the phone, no server call', () async {
    final pipeline = build((_) => json(500, {}));
    final r = await pipeline.resolve(phrase: 'Pause', snapshot: snapshot, entitlements: entitlementsFor(Plan.annual));
    expect(r, isA<VoiceOpsResolution>().having((r) => r.source, 'source', VoiceSource.rules));
    expect(sent, isEmpty);
  });

  test('free + rules hit: sent with actions_locales so the trial is counted', () async {
    final pipeline = build((body) => json(200, {
          'actions': body['actions_locales'],
          'source': 'local',
          'voice': {'mode': 'trial', 'trial_remaining': 2},
        }));
    final r = await pipeline.resolve(phrase: 'pause', snapshot: snapshot, entitlements: entitlementsFor(Plan.free));
    expect(sent.single['actions_locales'], [
      {'op': 'lecture', 'valeur': 'pause'},
    ]);
    expect(sent.single['etat']['lecture'], 'en_cours');
    final ops = r as VoiceOpsResolution;
    expect(ops.source, VoiceSource.local);
    expect(ops.quota?.trialRemaining, 2);
  });

  test('lifetime + rules hit: counted too, 402 quota exhausted stops it', () async {
    final pipeline = build((_) => json(402, {'error': 'voice_quota_exhausted'}));
    final r = await pipeline.resolve(phrase: 'pause', snapshot: snapshot, entitlements: entitlementsFor(Plan.lifetime));
    expect(r, isA<VoiceQuotaExhaustedResolution>().having((r) => r.mode, 'mode', VoiceMode.credits));
  });

  test('rules miss goes to the model; result validated on the phone (premium item removed for free)', () async {
    final pipeline = build((body) => json(200, {
          'actions': [
            {'op': 'ajouter', 'cible': 'son', 'id': 'vagues', 'niveau': 40},
            {'op': 'definir', 'cible': 'moment', 'valeur': 'nuit'},
          ],
          'source': 'model',
          'voice': {'mode': 'trial', 'trial_remaining': 1},
        }));
    final r = await pipeline.resolve(
        phrase: 'raconte-moi une histoire', snapshot: snapshot, entitlements: entitlementsFor(Plan.free));
    expect(sent.single['actions_locales'], isNull);
    final ops = (r as VoiceOpsResolution).ops;
    expect(ops, contains({'op': 'ouvrir', 'cible': 'premium'}));
    expect(ops.any((o) => o['id'] == 'vagues'), isFalse);
    expect(r.source, VoiceSource.model);
  });

  test('monthly cap: rules only, never a hard cut', () async {
    final pipeline = build((_) => json(402, {'error': 'voice_monthly_cap'}));
    final r = await pipeline.resolve(
        phrase: 'raconte-moi une histoire', snapshot: snapshot, entitlements: entitlementsFor(Plan.monthly));
    expect(r, isA<VoiceFailureResolution>().having((r) => r.rephrase, 'rephrase', isTrue));
    expect((r as VoiceFailureResolution).quota?.monthlyCapReached, isTrue);
  });

  test('503 model unavailable → rephrase; 422 → not understood', () async {
    var status = 503;
    final pipeline = build((_) => json(status, {'error': 'model_unavailable'}));
    var r = await pipeline.resolve(
        phrase: 'raconte-moi une histoire', snapshot: snapshot, entitlements: entitlementsFor(Plan.annual));
    expect(r, isA<VoiceFailureResolution>().having((r) => r.rephrase, 'rephrase', isTrue));
    status = 422;
    r = await pipeline.resolve(
        phrase: 'raconte-moi une histoire', snapshot: snapshot, entitlements: entitlementsFor(Plan.annual));
    expect((r as VoiceFailureResolution).message, VoiceMessages.notUnderstood);
  });

  test('offline: a clear message when the model is needed, rules still work', () async {
    final pipeline = build((_) => throw http.ClientException('offline'));
    final miss = await pipeline.resolve(
        phrase: 'raconte-moi une histoire', snapshot: snapshot, entitlements: entitlementsFor(Plan.annual));
    expect(miss, isA<VoiceFailureResolution>().having((r) => r.offline, 'offline', isTrue));
    final hit = await pipeline.resolve(phrase: 'pause', snapshot: snapshot, entitlements: entitlementsFor(Plan.free));
    expect(hit, isA<VoiceOpsResolution>().having((r) => r.source, 'source', VoiceSource.rules));
  });

  test('no backend: rules only, rephrase otherwise', () async {
    final pipeline = build((_) => json(500, {}), backend: false);
    final hit = await pipeline.resolve(phrase: 'pause', snapshot: snapshot, entitlements: entitlementsFor(Plan.free));
    expect(hit, isA<VoiceOpsResolution>());
    final miss = await pipeline.resolve(
        phrase: 'raconte-moi une histoire', snapshot: snapshot, entitlements: entitlementsFor(Plan.free));
    expect(miss, isA<VoiceFailureResolution>().having((r) => r.rephrase, 'rephrase', isTrue));
    expect(sent, isEmpty);
  });

  test('free trial known as exhausted: Premium without calling the model', () async {
    final pipeline = build((_) => json(500, {}));
    final r = await pipeline.resolve(
      phrase: 'raconte-moi une histoire',
      snapshot: snapshot,
      entitlements: Entitlements.free(trialRemaining: 0),
    );
    expect(r, isA<VoiceQuotaExhaustedResolution>().having((r) => r.mode, 'mode', VoiceMode.trial));
    expect(sent, isEmpty);
  });

  test('quota labels', () {
    expect(quotaLabel(const VoiceQuota(mode: VoiceMode.trial, trialRemaining: 2)), 'Essai gratuit · 2 demandes restantes');
    expect(quotaLabel(const VoiceQuota(mode: VoiceMode.trial, trialRemaining: 1)), 'Essai gratuit · 1 demande restante');
    expect(quotaLabel(const VoiceQuota(mode: VoiceMode.credits, creditsRemaining: 48)), 'Crédits · 48 restants');
    expect(quotaLabel(const VoiceQuota(mode: VoiceMode.included)), isNull);
  });

  test('French locale preference: fr_BE, then fr_FR, then any fr', () {
    expect(pickFrenchLocale(['en_US', 'fr_FR', 'fr_BE']), 'fr_BE');
    expect(pickFrenchLocale(['en-US', 'fr-FR']), 'fr-FR');
    expect(pickFrenchLocale(['fr_CA', 'de_DE']), 'fr_CA');
    expect(pickFrenchLocale(['en_US']), isNull);
  });
}
