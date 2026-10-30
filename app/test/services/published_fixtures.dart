// Answers of `GET /catalog` (contract § 13) built on the real bundled catalog: the base, plus a
// few items published from the dashboard.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A JSON answer in UTF-8, as the API sends it.
http.Response jsonResponse(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// The bundled `assets/catalog.json`, as JSON (a fresh copy each time).
Map<String, dynamic> bundledCatalogJson() =>
    jsonDecode(File('assets/catalog.json').readAsStringSync()) as Map<String, dynamic>;

/// The bundled `assets/landscapes/remote.json`, as JSON.
Map<String, dynamic> bundledRemoteJson() =>
    jsonDecode(File('assets/landscapes/remote.json').readAsStringSync()) as Map<String, dynamic>;

/// « Lac de brume »: a filmed landscape published in Nature, with its ambiance (contract § 11).
Map<String, dynamic> lacBrume({bool free = false, int rev = 2, String theme = 'nature', String? rendu}) => {
  'id': 'lac-brume',
  'theme': theme,
  'nom': 'Lac de brume',
  'gratuit': free,
  'rendu': ?rendu,
  'alias': ['lac de brume'],
  'media_rev': rev,
  'mix': {
    'sons': [
      {'id': 'ambiance-lac-brume', 'niveau': 60},
      {'id': 'vent', 'niveau': 20},
      {'id': 'inconnu', 'niveau': 20},
    ],
    'musique': [
      {'id': 'harpe-celeste', 'niveau': 20},
    ],
    'decor': [
      {'id': 'brume', 'niveau': 30},
    ],
  },
};

Map<String, dynamic> ambianceLacBrume({bool free = false, int rev = 2}) => {
  'id': 'ambiance-lac-brume',
  'nom': 'Ambiance du lac',
  'gratuit': free,
  'paysage': 'lac-brume',
  'alias': [],
  'media_rev': rev,
};

Map<String, dynamic> harpeCeleste({bool free = true, int rev = 1}) => {
  'id': 'harpe-celeste',
  'nom': 'Harpe céleste',
  'gratuit': free,
  'alias': ['harpe céleste'],
  'media_rev': rev,
};

/// A `GET /catalog` body: the bundled base plus [landscapes], [sounds] and [music] published,
/// and `distant` = the bundled remote.json plus the media of the published items.
Map<String, dynamic> catalogResponse({
  int revision = 7,
  List<Map<String, dynamic>>? landscapes,
  List<Map<String, dynamic>>? sounds,
  List<Map<String, dynamic>>? music,
  Map<String, dynamic>? catalog,
  bool withMedia = true,
}) {
  final base = catalog ?? bundledCatalogJson();
  final published = landscapes ?? [lacBrume()];
  final publishedSounds = sounds ?? [ambianceLacBrume()];
  final publishedMusic = music ?? [harpeCeleste()];
  (base['paysages'] as List).addAll(published);
  (base['sons'] as List).addAll(publishedSounds);
  (base['musiques'] as List).addAll(publishedMusic);
  final remote = bundledRemoteJson();
  List<Object?> plus(String key, Iterable<String> ids) => [...remote[key] as List, if (withMedia) ...ids];
  return {
    'revision': revision,
    'catalog': base,
    'distant': {
      'version': 1,
      'videos': plus('videos', published.map((l) => l['id'] as String)),
      'images': plus('images', published.map((l) => l['id'] as String)),
      'sons': plus('sons', publishedSounds.map((s) => s['id'] as String)),
      'musiques': plus('musiques', publishedMusic.map((m) => m['id'] as String)),
    },
  };
}
