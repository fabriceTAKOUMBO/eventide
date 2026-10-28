// "Online" means a real request succeeded (dossier, screen 13: try first, show « Hors connexion »
// only after a real failure). Android's network state is only a hint.
import 'dart:async';

import 'package:http/http.dart' as http;

import 'native_bridge.dart';

abstract class ConnectivityChecker {
  /// Makes a real attempt; true when the internet answered.
  Future<bool> check();

  /// True when on Wi-Fi/Ethernet (« Téléchargements en Wi-Fi seulement »).
  Future<bool> isUnmetered();
}

class HttpConnectivityChecker implements ConnectivityChecker {
  HttpConnectivityChecker({
    required this._client,
    required String apiBaseUrl,
    required this._native,
    this.timeout = const Duration(seconds: 5),
  }) : _apiBaseUrl = apiBaseUrl.endsWith('/') ? apiBaseUrl.substring(0, apiBaseUrl.length - 1) : apiBaseUrl;

  final http.Client _client;
  final String _apiBaseUrl;
  final NativeBridge _native;
  final Duration timeout;

  static final Uri _generate204 = Uri.parse('https://connectivitycheck.gstatic.com/generate_204');

  Future<bool> _get(Uri uri) async {
    try {
      final response = await _client.get(uri).timeout(timeout);
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> check() async {
    // Our API first (it also proves the backend is reachable), then Google's 204 endpoint,
    // so that an API outage alone never locks a free user out.
    if (_apiBaseUrl.isNotEmpty && await _get(Uri.parse('$_apiBaseUrl/health'))) return true;
    return _get(_generate204);
  }

  @override
  Future<bool> isUnmetered() async => (await _native.networkStatus())?.unmetered ?? false;
}
