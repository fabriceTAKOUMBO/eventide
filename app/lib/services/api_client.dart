// HTTP client for the Eventide API (docs/api/contrat-v1.md). No API key in the app: requests are
// authenticated by an installation token obtained after a Play Integrity check.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'native_bridge.dart';
import 'storage.dart';

/// The server answered with an error envelope `{"error": code, "detail": ...}`.
class ApiException implements Exception {
  const ApiException(this.status, this.code, [this.detail]);

  final int status;
  final String code;
  final String? detail;

  @override
  String toString() => 'ApiException($status, $code)';
}

/// Answer of `GET /catalog` (contract § 13).
sealed class CatalogFetch {
  const CatalogFetch();
}

/// `304`: the revision held is still the current one.
final class CatalogNotModified extends CatalogFetch {
  const CatalogNotModified();
}

/// `200`: the published catalog (`{"revision", "catalog", "distant"}`), not yet checked.
final class CatalogFetched extends CatalogFetch {
  const CatalogFetched(this.body);

  final Map<String, dynamic> body;
}

/// No answer: no backend configured, no network, timeout or unreadable response.
class ApiUnavailableException implements Exception {
  const ApiUnavailableException(this.reason, {this.timeout = false});

  final String reason;
  final bool timeout;

  @override
  String toString() => 'ApiUnavailableException($reason)';
}

class ApiClient {
  ApiClient({
    required String baseUrl,
    required this._client,
    required this._store,
    required this._native,
    required this._appVersion,
    required this._deviceSalt,
    this._cloudProjectNumber,
    this.timeout = const Duration(seconds: 10),
    Random? random,
  })  : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _random = random ?? Random.secure();

  final String _baseUrl;
  final http.Client _client;
  final LocalStore _store;
  final NativeBridge _native;
  final String _appVersion;
  final String _deviceSalt;
  final String? _cloudProjectNumber;
  final Random _random;
  final Duration timeout;

  String? _token;
  Future<String>? _registering;

  bool get enabled => _baseUrl.isNotEmpty;

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  // ---- Installation

  /// `device_hash` = hex SHA-256(ANDROID_ID + app salt).
  static String deviceHash(String androidId, String salt) =>
      sha256.convert(utf8.encode(androidId + salt)).toString();

  /// base64url (no padding, 43 characters) of SHA-256(nonce). It is also what the token is bound
  /// to (standard request `requestHash`, or classic `nonce`), so the server can match the token's
  /// `requestDetails` with `request_hash`.
  static String requestHash(String nonce) =>
      base64Url.encode(sha256.convert(utf8.encode(nonce)).bytes).replaceAll('=', '');

  Future<String> _ensureToken() async {
    final cached = _token;
    if (cached != null) return cached;
    final stored = await _store.readMap(StoreKeys.installation);
    final storedToken = stored?['token'];
    if (storedToken is String && storedToken.isNotEmpty) {
      _token = storedToken;
      return storedToken;
    }
    return _register();
  }

  Future<String> _register() {
    return _registering ??= _doRegister().whenComplete(() => _registering = null);
  }

  Future<String> _doRegister() async {
    final nonceBytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final nonce = base64Url.encode(nonceBytes).replaceAll('=', '');
    final hash = requestHash(nonce);
    String integrityToken = '';
    try {
      integrityToken = await _native.requestIntegrityToken(hash, cloudProjectNumber: _cloudProjectNumber);
    } catch (e) {
      // Debug builds and sideloaded APKs: the server accepts it only when
      // PLAY_INTEGRITY_ENFORCED=false (development).
      debugPrint('ApiClient: Play Integrity unavailable ($e)');
    }
    final androidId = await _native.androidId();
    final body = await _send(
      'POST',
      '/installations',
      body: {
        'integrity_token': integrityToken,
        'request_hash': hash,
        'device_hash': deviceHash(androidId, _deviceSalt),
        'app_version': _appVersion,
      },
      auth: false,
    );
    final token = body is Map ? body['token'] : null;
    if (token is! String || token.isEmpty) {
      throw const ApiUnavailableException('invalid installation response');
    }
    _token = token;
    await _store.write(StoreKeys.installation, {
      'installation_id': body is Map ? body['installation_id'] : null,
      'token': token,
    });
    return token;
  }

  /// Forgets the local installation token (after DELETE /account).
  Future<void> forgetInstallation() async {
    _token = null;
    await _store.delete(StoreKeys.installation);
  }

  // ---- Transport

  /// Returned by [_send] for a `304 Not Modified` when the caller accepts one.
  static const Object _notModified = _NotModified();

  Future<Object?> _send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    Duration? timeout,
    bool retried = false,
    Map<String, String> extraHeaders = const {},
    bool acceptNotModified = false,
  }) async {
    if (!enabled) throw const ApiUnavailableException('no backend');
    final headers = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json; charset=utf-8',
      ...extraHeaders,
    };
    if (auth) headers['Authorization'] = 'Bearer ${await _ensureToken()}';
    final request = http.Request(method, _uri(path))..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    http.Response response;
    try {
      final streamed = await _client.send(request).timeout(timeout ?? this.timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout ?? this.timeout);
    } on TimeoutException {
      throw const ApiUnavailableException('timeout', timeout: true);
    } on SocketException catch (e) {
      throw ApiUnavailableException('network: ${e.message}');
    } on http.ClientException catch (e) {
      throw ApiUnavailableException('network: ${e.message}');
    } on HandshakeException catch (e) {
      throw ApiUnavailableException('tls: ${e.message}');
    }

    if (response.statusCode == 401 && auth && !retried) {
      // Token revoked (re-registration elsewhere, data deletion): register again, retry once.
      _token = null;
      await _store.delete(StoreKeys.installation);
      await _register();
      return _send(
        method,
        path,
        body: body,
        auth: auth,
        timeout: timeout,
        retried: true,
        extraHeaders: extraHeaders,
        acceptNotModified: acceptNotModified,
      );
    }
    if (response.statusCode == 304 && acceptNotModified) return _notModified;

    Object? decoded;
    if (response.bodyBytes.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        decoded = null;
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return decoded;
    final code = decoded is Map && decoded['error'] is String ? decoded['error'] as String : 'http_${response.statusCode}';
    final detail = decoded is Map && decoded['detail'] is String ? decoded['detail'] as String : null;
    throw ApiException(response.statusCode, code, detail);
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const ApiUnavailableException('unexpected response');
  }

  // ---- Endpoints

  /// `GET /health` (no token). True on 200.
  Future<bool> health({Duration timeout = const Duration(seconds: 4)}) async {
    try {
      await _send('GET', '/health', auth: false, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> entitlements() async => _asMap(await _send('GET', '/entitlements'));

  Future<Map<String, dynamic>> postPurchase({
    required String productId,
    required String purchaseToken,
    String? basePlanId,
  }) async =>
      _asMap(await _send('POST', '/purchases', body: {
        'product_id': productId,
        'purchase_token': purchaseToken,
        'base_plan_id': basePlanId,
      }));

  /// `POST /shares` → short link.
  Future<Uri> createShare(Map<String, dynamic> scene) async {
    final body = _asMap(await _send('POST', '/shares', body: {'scene': scene}));
    final url = body['url'];
    if (url is! String) throw const ApiUnavailableException('invalid share response');
    return Uri.parse(url);
  }

  /// `GET /shares/{code}` → scene document.
  Future<Map<String, dynamic>> getShare(String code) async {
    final body = _asMap(await _send('GET', '/shares/${Uri.encodeComponent(code)}'));
    return _asMap(body['scene']);
  }

  /// `POST /content/urls` → signed URLs by key.
  Future<Map<String, String>> contentUrls(List<String> keys) async {
    final body = _asMap(await _send('POST', '/content/urls', body: {'keys': keys}));
    final urls = body['urls'];
    if (urls is! Map) return const {};
    return {
      for (final entry in urls.entries)
        if (entry.value is String) '${entry.key}': entry.value as String,
    };
  }

  /// `GET /catalog` (contract § 13). [etag]: the revision held, sent as `If-None-Match`
  /// (`"7"`); the server then answers `304` when it is still the current one.
  Future<CatalogFetch> fetchCatalog({String? etag}) async {
    final body = await _send(
      'GET',
      '/catalog',
      extraHeaders: {'If-None-Match': ?etag},
      acceptNotModified: true,
    );
    if (identical(body, _notModified)) return const CatalogNotModified();
    return CatalogFetched(_asMap(body));
  }

  Future<Map<String, dynamic>> linkGoogle(String idToken) async =>
      _asMap(await _send('POST', '/account/google', body: {'id_token': idToken}));

  Future<Map<String, dynamic>> exportAccount() async => _asMap(await _send('GET', '/account/export'));

  Future<void> deleteAccount() async {
    await _send('DELETE', '/account');
  }
}

class _NotModified {
  const _NotModified();
}
