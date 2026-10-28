// Assistant operations (contract §3): validation before applying, and the
// pure application of validated operations to the app state.
//
// Undo is the caller keeping the `before` snapshot: nothing here mutates it.

import 'catalog.dart';
import 'format.dart';
import 'plan.dart';
import 'scene.dart';
import 'schedule.dart';
import 'settings.dart';

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------
//
// Mirrors the API validator (`backend/apps/voice/validator.py`); both run the
// shared vectors of `shared/test-vectors/ops-validation.json`.

/// `{"op":"ouvrir","cible":"premium"}`.
Map<String, dynamic> openPremiumOp() => {'op': 'ouvrir', 'cible': 'premium'};

/// `{"op":"reformuler","raison":"incompris"}`.
Map<String, dynamic> rephraseOp([String reason = 'incompris']) => {
  'op': 'reformuler',
  'raison': reason,
};

/// `{"op":"refuser","raison":"interdit"}`.
Map<String, dynamic> forbiddenOp() => {'op': 'refuser', 'raison': 'interdit'};

/// Only the first operations of a list are read.
const int maxInputOps = 10;

/// Level given by `ajouter` without `niveau`.
const int defaultAddLevel = 50;

const Set<String> _momentValues = {'aube', 'jour', 'soir', 'nuit'};
const Set<String> _dayParts = {'matin', 'apres-midi', 'soir'};
const Set<String> _reminders = {'dormir', 'detente'};
const Set<String> _rephraseReasons = {'incompris', 'ambigu'};
const Set<String> _refuseReasons = {'hors_catalogue', 'interdit'};
const Set<String> _boolSettings = {
  'contraste_renforce',
  'ecran_noir_minuteur',
  'wifi_seulement',
};
const List<String> _selectorKeys = ['id', 'heure', 'rappel', 'moment_journee'];
const int _maxSelectorId = 64;

/// Purchases, subscriptions, cancellations and account deletion.
const Set<String> _forbiddenOps = {
  'acheter',
  'achat',
  'payer',
  'abonner',
  's_abonner',
  'souscrire',
  'resilier',
  'desabonner',
  'se_desabonner',
  'rembourser',
  'supprimer_compte',
};
const Set<String> _forbiddenTargets = {
  'compte',
  'abonnement',
  'achat',
  'paiement',
  'credits',
  'facturation',
};

final RegExp _hourPattern = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');

/// Validates assistant operations (contract §3) against the catalog and the
/// rights of [plan], exactly like the API:
///
/// 1. only the first [maxInputOps] items are read;
/// 2. a forbidden operation (purchase, subscription, cancellation, account
///    deletion, anything on `premium` but `ouvrir`) anywhere replaces the
///    whole list by `[{"op":"refuser","raison":"interdit"}]`;
/// 3. each item is checked; invalid items are dropped, unexpected fields are
///    dropped, defaults are filled (`niveau` 50 for `ajouter`;
///    `montee_minutes` 10 and `rappel` `dormir` for `creer`);
/// 4. on the free plan, an operation asking for a Premium element is replaced
///    in place by `{"op":"ouvrir","cible":"premium"}`;
/// 5. exact duplicates are removed (first kept), so one « ouvrir » at most;
/// 6. an empty result becomes `[{"op":"reformuler","raison":"incompris"}]`.
///
/// Numbers must be JSON integers (`70.0`, `true` or `"70"` are invalid).
List<Map<String, dynamic>> validateOps(
  List<dynamic> ops,
  Catalog catalog,
  Plan plan,
) {
  final items = ops.take(maxInputOps).toList();
  if (items.any(_isForbidden)) return [forbiddenOp()];
  final result = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final raw in items) {
    Map<String, dynamic> op;
    try {
      op = _one(raw, catalog, !plan.isPremium);
    } on _Premium {
      op = openPremiumOp();
    } on _Invalid {
      continue;
    }
    if (seen.add(_canonical(op))) result.add(op);
  }
  return result.isEmpty ? [rephraseOp()] : result;
}

/// [validateOps] for raw decoded JSON: anything but a list counts as an
/// empty list.
List<Map<String, dynamic>> validateOpsJson(
  Object? ops,
  Catalog catalog,
  Plan plan,
) => validateOps(ops is List ? ops : const [], catalog, plan);

class _Invalid implements Exception {
  const _Invalid();
}

class _Premium implements Exception {
  const _Premium();
}

const _invalid = _Invalid();

bool _isForbidden(Object? raw) {
  if (raw is! Map) return false;
  final op = raw['op'];
  final target = raw['cible'];
  if (op is String && _forbiddenOps.contains(op)) return true;
  if (target is String && _forbiddenTargets.contains(target)) return true;
  // Premium can only be opened (the screen), never activated or bought.
  return target == 'premium' && op is String && op != 'ouvrir';
}

/// Canonical JSON (sorted keys) used to find exact duplicates.
String _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return '{${keys.map((k) => '"$k":${_canonical(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  if (value is String) return '"${value.replaceAll('"', r'\"')}"';
  return '$value';
}

int _int(Object? value, int low, int high) {
  if (value is! int || value < low || value > high) throw _invalid;
  return value;
}

String _choice(Object? value, Set<String> choices) {
  if (value is! String || !choices.contains(value)) throw _invalid;
  return value;
}

bool _bool(Object? value) {
  if (value is! bool) throw _invalid;
  return value;
}

String _landscape(Object? value, Catalog catalog, bool free) {
  if (value is! String) throw _invalid;
  final landscape = catalog.landscape(value);
  if (landscape == null) throw _invalid;
  if (free && !landscape.free) throw const _Premium();
  return value;
}

Map<String, dynamic> _timer(Object? value) {
  if (value is! Map) throw _invalid;
  return switch (value['mode']) {
    'duree' => {'mode': 'duree', 'minutes': _int(value['minutes'], 1, 600)},
    'nuit' => {'mode': 'nuit'},
    'aucun' => {'mode': 'aucun'},
    _ => throw _invalid,
  };
}

List<int> _days(Object? value) {
  if (value is! List || value.isEmpty) throw _invalid;
  return ({for (final d in value) _int(d, 1, 7)}.toList()..sort());
}

Map<String, dynamic> _scheduleFields(
  Object? value,
  Catalog catalog,
  bool free, {
  required bool partial,
}) {
  if (value is! Map) throw _invalid;
  final out = <String, dynamic>{};
  var premium = false;
  if (value.containsKey('heure')) {
    final time = value['heure'];
    if (time is! String || !_hourPattern.hasMatch(time)) throw _invalid;
    out['heure'] = time;
  }
  if (value.containsKey('jours')) out['jours'] = _days(value['jours']);
  if (value.containsKey('montee_minutes')) {
    final ramp = value['montee_minutes'];
    if (ramp is! int || !Schedule.isValidRamp(ramp, catalog.limits)) {
      throw _invalid;
    }
    out['montee_minutes'] = ramp;
  }
  if (value.containsKey('paysage')) {
    try {
      out['paysage'] = _landscape(value['paysage'], catalog, free);
    } on _Premium {
      premium = true;
    }
  }
  if (value.containsKey('rappel')) {
    out['rappel'] = _choice(value['rappel'], _reminders);
  }
  if (!partial) {
    if (!out.containsKey('heure') || !out.containsKey('jours')) throw _invalid;
    out.putIfAbsent('montee_minutes', () => Schedule.defaultRampMinutes);
    out.putIfAbsent('rappel', () => 'dormir');
  } else if (out.isEmpty && !premium) {
    throw _invalid;
  }
  // Checked last: an invalid field wins over a Premium landscape.
  if (premium) throw const _Premium();
  return out;
}

Map<String, dynamic> _selector(Object? value) {
  if (value is! Map) throw _invalid;
  final keys = [
    for (final k in _selectorKeys)
      if (value.containsKey(k)) k,
  ];
  if (keys.length != 1) throw _invalid;
  final key = keys.single;
  final item = value[key];
  switch (key) {
    case 'id':
      if (item is! String || item.isEmpty || item.length > _maxSelectorId) {
        throw _invalid;
      }
    case 'heure':
      if (item is! String || !_hourPattern.hasMatch(item)) throw _invalid;
    case 'rappel':
      _choice(item, _reminders);
    default:
      _choice(item, _dayParts);
  }
  return {key: item};
}

Map<String, dynamic> _layerOp(
  String op,
  Map<dynamic, dynamic> raw,
  Catalog catalog,
  bool free,
) {
  final kind = LayerKind.fromCible(raw['cible']);
  if (kind == null) throw _invalid;
  final id = raw['id'];
  if (op == 'retirer') {
    // Removing is always allowed, even a locked element.
    if (id != '*' && (id is! String || catalog.item(kind, id) == null)) {
      throw _invalid;
    }
    return {'op': op, 'cible': kind.cible, 'id': id};
  }
  if (id is! String) throw _invalid;
  final item = catalog.item(kind, id);
  if (item == null) throw _invalid;
  final Map<String, dynamic> out = switch (op) {
    'ajouter' => {
      'op': op,
      'cible': kind.cible,
      'id': id,
      'niveau': raw.containsKey('niveau')
          ? _int(raw['niveau'], 0, 100)
          : defaultAddLevel,
    },
    'regler' => {
      'op': op,
      'cible': kind.cible,
      'id': id,
      'niveau': _int(raw['niveau'], 0, 100),
    },
    _ => {
      'op': op,
      'cible': kind.cible,
      'id': id,
      'delta': _int(raw['delta'], -100, 100),
    },
  };
  if (free && !item.free) throw const _Premium();
  return out;
}

/// `couper` / `remettre`: only sounds and music have a mute (`sourdine`).
Map<String, dynamic> _muteOp(String op, Map<dynamic, dynamic> raw) {
  final kind = LayerKind.fromCible(raw['cible']);
  if (kind == null || !kind.isAudio) throw _invalid;
  return {'op': op, 'cible': kind.cible};
}

Map<String, dynamic> _definir(
  Map<dynamic, dynamic> raw,
  Catalog catalog,
  bool free,
) {
  final target = raw['cible'];
  final value = raw['valeur'];
  switch (target) {
    case 'paysage':
      return {
        'op': 'definir',
        'cible': target,
        'valeur': _landscape(value, catalog, free),
      };
    case 'moment':
      return {
        'op': 'definir',
        'cible': target,
        'valeur': _choice(value, _momentValues),
      };
    case 'minuteur':
      return {'op': 'definir', 'cible': target, 'valeur': _timer(value)};
    case 'sommeil.suivi':
      return {'op': 'definir', 'cible': target, 'valeur': _bool(value)};
    case 'reglage':
      final key = raw['cle'];
      if (key == 'taille_texte') {
        return {
          'op': 'definir',
          'cible': target,
          'cle': key,
          'valeur': value == 'plus' || value == 'moins'
              ? value
              : _int(value, 0, AppSettings.maxTextSize),
        };
      }
      return {
        'op': 'definir',
        'cible': target,
        'cle': _choice(key, _boolSettings),
        'valeur': _bool(value),
      };
  }
  throw _invalid;
}

Map<String, dynamic> _scheduleOp(
  String op,
  Map<dynamic, dynamic> raw,
  Catalog catalog,
  bool free,
) {
  if (raw['cible'] != 'programmation') throw _invalid;
  if (op == 'creer') {
    return {
      'op': op,
      'cible': 'programmation',
      'valeur': _scheduleFields(raw['valeur'], catalog, free, partial: false),
    };
  }
  final selector = _selector(raw['selecteur']);
  if (op == 'modifier') {
    return {
      'op': op,
      'cible': 'programmation',
      'selecteur': selector,
      'valeur': _scheduleFields(raw['valeur'], catalog, free, partial: true),
    };
  }
  return {'op': op, 'cible': 'programmation', 'selecteur': selector};
}

Map<String, dynamic> _one(Object? raw, Catalog catalog, bool free) {
  if (raw is! Map) throw _invalid;
  final op = raw['op'];
  if (op is! String) throw _invalid;
  switch (op) {
    case 'ajouter':
    case 'retirer':
    case 'regler':
    case 'ajuster':
      return _layerOp(op, raw, catalog, free);
    case 'couper':
    case 'remettre':
      return _muteOp(op, raw);
    case 'definir':
      return _definir(raw, catalog, free);
    case 'changer':
      if (raw['cible'] != 'paysage') throw _invalid;
      return {
        'op': op,
        'cible': 'paysage',
        'valeur': _choice(raw['valeur'], const {'suivant', 'precedent'}),
      };
    case 'lecture':
      return {
        'op': op,
        'valeur': _choice(raw['valeur'], const {'pause', 'reprise'}),
      };
    case 'creer':
    case 'modifier':
    case 'activer':
    case 'desactiver':
    case 'supprimer':
      return _scheduleOp(op, raw, catalog, free);
    case 'commencer_nuit':
    case 'partager':
      return {'op': op};
    case 'ouvrir':
      if (raw['cible'] != 'premium') throw _invalid;
      return openPremiumOp();
    case 'reformuler':
      final reason = raw['raison'];
      return rephraseOp(
        _rephraseReasons.contains(reason) ? reason as String : 'incompris',
      );
    case 'refuser':
      final reason = raw['raison'];
      return {
        'op': op,
        'raison': _refuseReasons.contains(reason) ? reason : 'hors_catalogue',
      };
  }
  throw _invalid;
}

// ---------------------------------------------------------------------------
// Application
// ---------------------------------------------------------------------------

/// The state the assistant can change.
class AppSnapshot {
  AppSnapshot({
    required this.scene,
    List<Schedule> schedules = const [],
    this.settings = const AppSettings(),
    this.playing = false,
  }) : schedules = List.unmodifiable(schedules);

  final Scene scene;
  final List<Schedule> schedules;
  final AppSettings settings;
  final bool playing;

  AppSnapshot copyWith({
    Scene? scene,
    List<Schedule>? schedules,
    AppSettings? settings,
    bool? playing,
  }) {
    return AppSnapshot(
      scene: scene ?? this.scene,
      schedules: schedules ?? this.schedules,
      settings: settings ?? this.settings,
      playing: playing ?? this.playing,
    );
  }

  /// The `etat` object of `POST /voice` (contract §7).
  Map<String, dynamic> toVoiceState() => {
    'scene': scene.toJson(),
    'programmations': [for (final s in schedules) s.toJson()],
    'lecture': playing ? 'en_cours' : 'en_pause',
    'reglages': settings.toVoiceStateJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is AppSnapshot &&
      other.scene == scene &&
      other.settings == settings &&
      other.playing == playing &&
      other.schedules.length == schedules.length &&
      Iterable<int>.generate(schedules.length)
          .every((i) => other.schedules[i] == schedules[i]);

  @override
  int get hashCode =>
      Object.hash(scene, Object.hashAll(schedules), settings, playing);
}

/// Something the caller must do besides installing the new snapshot.
sealed class SideEffect {
  const SideEffect();
}

final class PauseEffect extends SideEffect {
  const PauseEffect();
  @override
  bool operator ==(Object other) => other is PauseEffect;
  @override
  int get hashCode => (PauseEffect).hashCode;
  @override
  String toString() => 'PauseEffect()';
}

final class ResumeEffect extends SideEffect {
  const ResumeEffect();
  @override
  bool operator ==(Object other) => other is ResumeEffect;
  @override
  int get hashCode => (ResumeEffect).hashCode;
  @override
  String toString() => 'ResumeEffect()';
}

/// « Commence la nuit »: start playback and open the black screen.
final class StartNightEffect extends SideEffect {
  const StartNightEffect();
  @override
  bool operator ==(Object other) => other is StartNightEffect;
  @override
  int get hashCode => (StartNightEffect).hashCode;
  @override
  String toString() => 'StartNightEffect()';
}

/// Open the Share screen for the current mix.
final class ShareEffect extends SideEffect {
  const ShareEffect();
  @override
  bool operator ==(Object other) => other is ShareEffect;
  @override
  int get hashCode => (ShareEffect).hashCode;
  @override
  String toString() => 'ShareEffect()';
}

/// Open the Premium screen (never buys anything).
final class OpenPremiumEffect extends SideEffect {
  const OpenPremiumEffect();
  @override
  bool operator ==(Object other) => other is OpenPremiumEffect;
  @override
  int get hashCode => (OpenPremiumEffect).hashCode;
  @override
  String toString() => 'OpenPremiumEffect()';
}

/// Ask the user to rephrase. Reasons: `incompris` (and the model's own),
/// `ambigu` (a selector matched several schedules), `introuvable` (no
/// schedule matched).
final class RephraseEffect extends SideEffect {
  const RephraseEffect(this.reason);
  final String reason;
  @override
  bool operator ==(Object other) =>
      other is RephraseEffect && other.reason == reason;
  @override
  int get hashCode => Object.hash(RephraseEffect, reason);
  @override
  String toString() => 'RephraseEffect($reason)';
}

/// Politely refuse. Reasons: `hors_catalogue`, `interdit`, and locally
/// `couches_max` (no room for another sound or music).
final class RefuseEffect extends SideEffect {
  const RefuseEffect(this.reason);
  final String reason;
  @override
  bool operator ==(Object other) =>
      other is RefuseEffect && other.reason == reason;
  @override
  int get hashCode => Object.hash(RefuseEffect, reason);
  @override
  String toString() => 'RefuseEffect($reason)';
}

/// One line of the « C’est fait » card, e.g. « Minuteur » — « Arrêt après 1 h ».
class ChangeLine {
  const ChangeLine(this.label, this.value);

  final String label;
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ChangeLine && other.label == label && other.value == value;

  @override
  int get hashCode => Object.hash(label, value);

  @override
  String toString() => '$label: $value';
}

class ApplyResult {
  ApplyResult({
    required this.snapshot,
    required List<SideEffect> effects,
    required List<ChangeLine> changes,
  }) : effects = List.unmodifiable(effects),
       changes = List.unmodifiable(changes);

  final AppSnapshot snapshot;
  final List<SideEffect> effects;
  final List<ChangeLine> changes;
}

/// Matches schedules against a contract `selecteur`.
List<Schedule> matchSchedules(
  Iterable<Schedule> schedules,
  Map<String, dynamic> selector,
) {
  bool matches(Schedule s) {
    if (selector.containsKey('id')) return s.id == selector['id'];
    if (selector.containsKey('heure')) {
      final t = Schedule.parseTime(selector['heure'], strict: false);
      return t != null && s.hour == t.hour && s.minute == t.minute;
    }
    if (selector.containsKey('rappel')) {
      return s.reminder.name == selector['rappel'];
    }
    if (selector.containsKey('moment_journee')) {
      return switch (selector['moment_journee']) {
        'matin' => s.hour < 12,
        'apres-midi' => s.hour >= 12 && s.hour < 18,
        'soir' => s.hour >= 18,
        _ => false,
      };
    }
    return false;
  }

  return [
    for (final s in schedules)
      if (matches(s)) s,
  ];
}

const String _outOfMix = 'Hors du mix';

String _onOff(bool v) => v ? 'Activé' : 'Désactivé';

/// Value of the « Sons » / « Musique » line after a mute change.
String muteSummary(LayerKind kind, bool muted) => muted
    ? 'En sourdine'
    : (kind == LayerKind.musique ? 'Rétablie' : 'Rétablis');

/// Applies validated operations to [before] and returns the new snapshot,
/// the side effects for the caller and the change lines for the result card.
///
/// - Operations are applied in order; malformed ones are skipped.
/// - `definir paysage` loads the landscape's default mix (keeping moment,
///   timer and sleep tracking); `changer paysage` moves within the current
///   theme, without wrapping.
/// - `ajouter` without `niveau` uses 50 and never lowers an element already
///   playing; `ajuster` on an absent element adds it at 50 when `delta` > 0.
///   Adding beyond `couches_max` emits `RefuseEffect('couches_max')`.
/// - `couper` / `remettre` mute or unmute sounds or music, keeping every
///   layer and its level. `ajouter`, `regler` and `ajuster` on a muted
///   category unmute it when the element stays in the mix (contract §1).
/// - `creer` without `jours` uses every day, without `paysage` the current
///   landscape (validated operations always carry `jours`).
/// - Schedule selectors: `activer`/`desactiver` apply to every match;
///   `modifier`/`supprimer` emit `RephraseEffect('ambigu')` on several
///   matches; no match emits `RephraseEffect('introuvable')`.
/// - When [plan] is given, the free-plan limits are enforced here too
///   (locked landscape reached by `changer`, schedule count): the change is
///   skipped and `OpenPremiumEffect` emitted.
///
/// [now] is the request time (kept for time-relative operations; the
/// current contract has none). [newId] gives ids to created schedules.
ApplyResult applyOps(
  AppSnapshot before,
  List<Map<String, dynamic>> validatedOps,
  Catalog catalog, {
  required String Function() newId,
  required DateTime now,
  Plan? plan,
}) {
  var scene = before.scene;
  final schedules = [...before.schedules];
  var settings = before.settings;
  var playing = before.playing;
  final effects = <SideEffect>[];
  final changes = <ChangeLine>[];
  final rules = ProductRules(catalog);
  final maxLayers = catalog.limits.layersMax;

  void effect(SideEffect e) {
    if (!effects.contains(e)) effects.add(e);
  }

  // Lines with the same label are merged (last value wins) unless [append].
  void change(String label, String value, {bool append = false}) {
    if (!append) {
      final index = changes.indexWhere((c) => c.label == label);
      if (index >= 0) {
        changes[index] = ChangeLine(label, value);
        return;
      }
    }
    changes.add(ChangeLine(label, value));
  }

  bool lockedLandscape(Landscape landscape) =>
      plan != null && !rules.canUseLandscape(plan, landscape);

  void setMuted(LayerKind kind, bool muted) {
    scene = scene.withMuted(kind, muted);
    change(kind.label, muteSummary(kind, muted));
  }

  // Touching the level of an element of a muted category makes it heard.
  void unmuteFor(LayerKind kind) {
    if (scene.isMuted(kind)) setMuted(kind, false);
  }

  // Sets a layer level; returns false when refused for lack of room.
  bool setLevel(LayerKind kind, CatalogItem item, int level) {
    final target = level.clamp(0, 100);
    final present = scene.hasLayer(kind, item.id);
    if (!present && target == 0) return true;
    if (!present && kind.isAudio && scene.audioLayerCount >= maxLayers) {
      effect(const RefuseEffect('couches_max'));
      return false;
    }
    scene = scene.withLevel(kind, item.id, target, maxAudioLayers: maxLayers);
    change(item.name, target == 0 ? _outOfMix : formatPercent(target));
    if (target > 0) unmuteFor(kind);
    return true;
  }

  for (final op in validatedOps) {
    final kind = LayerKind.fromCible(op['cible']);
    final id = op['id'];
    switch (op['op']) {
      case 'definir':
        switch (op['cible']) {
          case 'paysage':
            final landscape = catalog.landscape('${op['valeur']}');
            if (landscape == null) break;
            if (lockedLandscape(landscape)) {
              effect(const OpenPremiumEffect());
              break;
            }
            if (landscape.id != scene.landscapeId) {
              scene = scene.withLandscape(landscape);
            }
            change('Paysage', landscape.name);
          case 'moment':
            final moment = Moment.fromName(op['valeur']);
            if (moment == null) break;
            scene = scene.copyWith(moment: moment);
            change('Moment de la journée', moment.label);
          case 'minuteur':
            final timer = TimerSetting.tryParse(op['valeur']);
            if (timer == null) break;
            scene = scene.copyWith(timer: timer);
            change('Minuteur', timerSummary(timer));
          case 'sommeil.suivi':
            final v = op['valeur'];
            if (v is! bool) break;
            scene = scene.copyWith(sleepTracking: v);
            change('Suivi du sommeil', _onOff(v));
          case 'reglage':
            final v = op['valeur'];
            switch (op['cle']) {
              case 'taille_texte':
                final size = switch (v) {
                  'plus' => settings.textSize + 1,
                  'moins' => settings.textSize - 1,
                  int n => n,
                  _ => null,
                };
                if (size == null) break;
                settings = settings.copyWith(textSize: size);
                change('Taille du texte', settings.textSizeLabel);
              case 'contraste_renforce' when v is bool:
                settings = settings.copyWith(highContrast: v);
                change('Contraste renforcé', _onOff(v));
              case 'ecran_noir_minuteur' when v is bool:
                settings = settings.copyWith(blackScreenDuringTimer: v);
                change('Écran noir pendant le minuteur', _onOff(v));
              case 'wifi_seulement' when v is bool:
                settings = settings.copyWith(wifiOnly: v);
                change('Téléchargements en Wi-Fi seulement', _onOff(v));
            }
        }

      case 'changer':
        final current = catalog.landscape(scene.landscapeId);
        if (current == null) break;
        final theme = catalog.landscapesOfTheme(current.themeId);
        final index = theme.indexWhere((l) => l.id == current.id);
        final target = index + (op['valeur'] == 'precedent' ? -1 : 1);
        if (target < 0 || target >= theme.length) break; // no wrap
        final next = theme[target];
        if (lockedLandscape(next)) {
          effect(const OpenPremiumEffect());
          break;
        }
        scene = scene.withLandscape(next);
        change('Paysage', next.name);

      case 'ajouter' when kind != null && id is String:
        final item = catalog.item(kind, id);
        if (item == null) break;
        final level = op['niveau'] is int
            ? op['niveau'] as int
            : defaultAddLevel;
        final current = scene.levelOf(kind, id);
        if (current != null && current >= level) {
          // « Ajoute du vent » never lowers what is already playing.
          change(item.name, formatPercent(current));
          unmuteFor(kind);
          break;
        }
        setLevel(kind, item, level);

      case 'retirer' when kind != null && id is String:
        if (id == '*') {
          if (scene.layers(kind).isEmpty) break;
          scene = scene.withoutLayer(kind, '*');
          change(kind.label, kind == LayerKind.musique ? 'Aucune' : 'Aucun');
          break;
        }
        final item = catalog.item(kind, id);
        if (item == null || !scene.hasLayer(kind, id)) break;
        scene = scene.withoutLayer(kind, id);
        change(item.name, _outOfMix);

      case 'regler' when kind != null && id is String:
        final item = catalog.item(kind, id);
        final level = op['niveau'];
        if (item == null || level is! int) break;
        setLevel(kind, item, level);

      case 'ajuster' when kind != null && id is String:
        final item = catalog.item(kind, id);
        final delta = op['delta'];
        if (item == null || delta is! int) break;
        final current = scene.levelOf(kind, id);
        if (current == null) {
          if (delta > 0) setLevel(kind, item, Scene.defaultLevel);
          break;
        }
        setLevel(kind, item, current + delta);

      case 'couper' when kind != null && kind.isAudio:
        setMuted(kind, true);

      case 'remettre' when kind != null && kind.isAudio:
        setMuted(kind, false);

      case 'lecture':
        if (op['valeur'] == 'pause') {
          playing = false;
          effect(const PauseEffect());
          change('Lecture', 'En pause');
        } else if (op['valeur'] == 'reprise') {
          playing = true;
          effect(const ResumeEffect());
          change('Lecture', 'Reprise');
        }

      case 'creer':
        final v = op['valeur'];
        if (v is! Map) break;
        final time = Schedule.parseTime(v['heure'], strict: false);
        if (time == null) break;
        final max = plan == null ? null : rules.maxSchedules(plan);
        if (max != null && schedules.length >= max) {
          effect(const OpenPremiumEffect());
          break;
        }
        final landscapeId = v['paysage'] is String
            ? v['paysage'] as String
            : scene.landscapeId;
        final landscape = catalog.landscape(landscapeId);
        if (landscape != null && lockedLandscape(landscape)) {
          effect(const OpenPremiumEffect());
          break;
        }
        final days = v['jours'];
        final ramp = v['montee_minutes'];
        final created = Schedule(
          id: newId(),
          hour: time.hour,
          minute: time.minute,
          days: days is List && days.isNotEmpty
              ? days.whereType<int>().where((d) => d >= 1 && d <= 7).toSet()
              : Schedule.everyDay,
          rampMinutes: ramp is int ? ramp : Schedule.defaultRampMinutes,
          landscapeId: landscapeId,
          reminder: Reminder.fromName(v['rappel']) ?? Reminder.dormir,
          active: true,
        );
        schedules.add(created);
        change(
          'Programmation',
          scheduleSummary(created, catalog),
          append: true,
        );

      case 'modifier':
      case 'activer':
      case 'desactiver':
      case 'supprimer':
        final selector = op['selecteur'];
        if (selector is! Map) break;
        final matches = matchSchedules(
          schedules,
          Map<String, dynamic>.from(selector),
        );
        if (matches.isEmpty) {
          effect(const RephraseEffect('introuvable'));
          break;
        }
        final verb = op['op'];
        if ((verb == 'modifier' || verb == 'supprimer') && matches.length > 1) {
          effect(const RephraseEffect('ambigu'));
          break;
        }
        if (verb == 'supprimer') {
          schedules.removeWhere((s) => s.id == matches.single.id);
          change(
            'Programmation supprimée',
            scheduleSummary(matches.single, catalog),
            append: true,
          );
          break;
        }
        if (verb == 'modifier') {
          final v = op['valeur'];
          if (v is! Map) break;
          var s = matches.single;
          final time = Schedule.parseTime(v['heure'], strict: false);
          if (time != null) {
            s = s.copyWith(hour: time.hour, minute: time.minute);
          }
          final days = v['jours'];
          if (days is List && days.isNotEmpty) {
            s = s.copyWith(
              days: days
                  .whereType<int>()
                  .where((d) => d >= 1 && d <= 7)
                  .toSet(),
            );
          }
          final ramp = v['montee_minutes'];
          if (ramp is int) s = s.copyWith(rampMinutes: ramp);
          final landscapeId = v['paysage'];
          if (landscapeId is String) {
            final landscape = catalog.landscape(landscapeId);
            if (landscape != null && lockedLandscape(landscape)) {
              effect(const OpenPremiumEffect());
              break;
            }
            s = s.copyWith(landscapeId: landscapeId);
          }
          final reminder = Reminder.fromName(v['rappel']);
          if (reminder != null) s = s.copyWith(reminder: reminder);
          schedules[schedules.indexWhere((x) => x.id == s.id)] = s;
          change(
            'Programmation modifiée',
            scheduleSummary(s, catalog),
            append: true,
          );
          break;
        }
        final active = verb == 'activer';
        for (final m in matches) {
          final updated = m.copyWith(active: active);
          schedules[schedules.indexWhere((x) => x.id == m.id)] = updated;
          change(
            active ? 'Programmation activée' : 'Programmation désactivée',
            scheduleSummary(updated, catalog),
            append: true,
          );
        }

      case 'commencer_nuit':
        effect(const StartNightEffect());
        change('Mode nuit', 'Démarré');

      case 'partager':
        effect(const ShareEffect());

      case 'ouvrir':
        if (op['cible'] == 'premium') effect(const OpenPremiumEffect());

      case 'reformuler':
        final reason = op['raison'];
        effect(RephraseEffect(reason is String ? reason : 'incompris'));

      case 'refuser':
        final reason = op['raison'];
        effect(RefuseEffect(reason is String ? reason : 'interdit'));
    }
  }

  return ApplyResult(
    snapshot: AppSnapshot(
      scene: scene,
      schedules: schedules,
      settings: settings,
      playing: playing,
    ),
    effects: effects,
    changes: changes,
  );
}
