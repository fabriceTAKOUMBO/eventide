// Share links (contract §8): a server link `https://<domain>/m/<code>` and a
// self-contained offline fallback `https://<domain>/s#<base64url(scene)>`.
// A shared scene carries the landscape, the layers and the moment; never the
// timer, the sleep tracking, the mute state (`sourdine`: the recipient gets
// the mix as heard unmuted), schedules or personal data.

import 'dart:convert';

import 'catalog.dart';
import 'scene.dart';

/// Longest accepted link payload, in characters.
const int maxShareDataLength = 8192;

/// The shareable part of [scene] (no timer, no sleep tracking, no mute).
Map<String, dynamic> shareableSceneJson(Scene scene) => {
  'version': scene.version,
  'paysage': scene.landscapeId,
  'moment': scene.moment.name,
  'sons': [for (final l in scene.sounds) l.toJson()],
  'musique': [for (final l in scene.music) l.toJson()],
  'decor': [for (final l in scene.decor) l.toJson()],
};

/// Compact JSON of the shareable scene, base64url-encoded without padding.
String encodeSceneForLink(Scene scene) {
  final bytes = utf8.encode(jsonEncode(shareableSceneJson(scene)));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Decodes a link payload. Returns null when the payload is not a scene or
/// its landscape is unknown; a retired landscape opens on the default one
/// (contract § 12); unknown or duplicate items and decor that does not apply to
/// the landscape are dropped, levels clamped, and audio layers capped at
/// `couches_max`. Never throws.
///
/// The recipient gets the default timer, no sleep tracking and nothing muted.
Scene? decodeSceneFromLink(String data, Catalog catalog) {
  try {
    var s = data.trim();
    if (s.contains('%')) s = Uri.decodeComponent(s);
    if (s.isEmpty || s.length > maxShareDataLength) return null;
    s = s.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
    if (s.length % 4 == 1) return null;
    s = s.padRight(s.length + (4 - s.length % 4) % 4, '=');
    final decoded = jsonDecode(utf8.decode(base64Url.decode(s)));
    if (decoded is! Map) return null;
    return _sceneFromShared(decoded, catalog);
  } catch (_) {
    return null;
  }
}

/// Validates a shared scene object against the catalog (also used for
/// `GET /shares/{code}` responses). Never throws.
Scene? sceneFromSharedJson(Object? json, Catalog catalog) {
  try {
    return json is Map ? _sceneFromShared(json, catalog) : null;
  } catch (_) {
    return null;
  }
}

Scene? _sceneFromShared(Map<dynamic, dynamic> json, Catalog catalog) {
  final landscapeId = json['paysage'];
  // A retired landscape opens on the default one, sounds and music kept (contract § 12).
  final landscape = landscapeId is String ? catalog.landscapeFor(landscapeId) : null;
  if (landscape == null) return null;
  var audio = 0;
  List<Layer> layers(LayerKind kind) {
    final list = json[kind.sceneKey];
    if (list is! List) return const [];
    final seen = <String>{};
    final out = <Layer>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final id = entry['id'];
      final level = entry['niveau'];
      // Unknown, or withdrawn from the published catalog (contract § 13): dropped.
      if (id is! String || !catalog.listsItem(kind, id)) continue;
      // Decor only where it applies: a 3D scene that can show it (contract § 12).
      if (kind == LayerKind.decor && !landscape.allowsDecor(id)) continue;
      if (level is! num || !level.isFinite) continue;
      final clamped = level.round().clamp(0, 100);
      if (clamped == 0 || !seen.add(id)) continue;
      if (kind.isAudio) {
        if (audio >= catalog.limits.layersMax) continue;
        audio++;
      }
      out.add(Layer(id: id, level: clamped));
    }
    return out;
  }

  return Scene(
    landscapeId: landscape.id,
    moment: Moment.fromName(json['moment']) ?? Moment.jour,
    sounds: layers(LayerKind.son),
    music: layers(LayerKind.musique),
    decor: layers(LayerKind.decor),
  );
}

/// Builds the offline link `https://<host>/s#<data>`.
Uri shareLinkFor(Scene scene, String host) => Uri(
  scheme: 'https',
  host: host,
  path: '/s',
  fragment: encodeSceneForLink(scene),
);

/// Scene of an offline link `https://<host>/s#<data>`, or null.
Scene? sceneFromShareUri(Uri uri, Catalog catalog) {
  if (uri.scheme != 'https' && uri.scheme != 'http') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length != 1 || segments.single != 's') return null;
  if (!uri.hasFragment || uri.fragment.isEmpty) return null;
  return decodeSceneFromLink(uri.fragment, catalog);
}

final RegExp _shareCode = RegExp(r'^[0-9A-Za-z]{4,32}$');

/// Code of a server link `https://<host>/m/<code>` (8 base62 characters
/// today; 4–32 accepted), or null.
String? shareCodeFromUri(Uri uri) {
  if (uri.scheme != 'https' && uri.scheme != 'http') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length != 2 || segments.first != 'm') return null;
  return _shareCode.hasMatch(segments[1]) ? segments[1] : null;
}
