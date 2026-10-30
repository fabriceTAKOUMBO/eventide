// What the system media card shows (lock screen, Always On Display, notification shade,
// docs/app/architecture.md « Carte de lecture »): pure rules, no Flutter, no plugin. The app
// controller computes a [MediaCardInfo] from the scene; the playback handler turns it into the
// MediaSession metadata and buttons.

import 'catalog.dart';
import 'format.dart';
import 'scene.dart';

/// Album line of the card.
const String mediaCardAlbum = 'Full Relax';

/// Subtitle when every sound and music of the mix is muted (`sourdine`).
const String mediaCardMutedSummary = 'Son en sourdine';

/// Everything the card shows about the current scene. The handler adds the timer (progress
/// bar and timer button) and the play/pause state.
class MediaCardInfo {
  const MediaCardInfo({
    required this.landscapeId,
    required this.title,
    this.artist,
    this.moment = Moment.jour,
    this.favorite = false,
    this.previousId,
    this.nextId,
    this.artUri,
  });

  /// Landscape shown: the scene's, or the one the sound is about to follow after a
  /// previous/next tap (debounced like a home swipe).
  final String landscapeId;

  /// Landscape name (« Cascade en forêt »).
  final String title;

  /// Audible mix (« Eau vive · Oiseaux · Piano doux »), [mediaCardMutedSummary], or null.
  final String? artist;
  final Moment moment;

  /// The mix is one of the favourites (heart filled).
  final bool favorite;

  /// Previous and next usable landscapes of the theme (null at the edges: button omitted).
  final String? previousId;
  final String? nextId;

  /// Picture of the landscape (`file://`), null until it is ready.
  final Uri? artUri;

  bool get hasPrevious => previousId != null;
  bool get hasNext => nextId != null;

  MediaCardInfo withArt(Uri? art) => MediaCardInfo(
    landscapeId: landscapeId,
    title: title,
    artist: artist,
    moment: moment,
    favorite: favorite,
    previousId: previousId,
    nextId: nextId,
    artUri: art,
  );

  @override
  bool operator ==(Object other) =>
      other is MediaCardInfo &&
      other.landscapeId == landscapeId &&
      other.title == title &&
      other.artist == artist &&
      other.moment == moment &&
      other.favorite == favorite &&
      other.previousId == previousId &&
      other.nextId == nextId &&
      other.artUri == artUri;

  @override
  int get hashCode => Object.hash(
    landscapeId,
    title,
    artist,
    moment,
    favorite,
    previousId,
    nextId,
    artUri,
  );

  @override
  String toString() =>
      'MediaCardInfo($landscapeId, $title, $artist, favorite: $favorite, '
      'previous: $previousId, next: $nextId, art: $artUri)';
}

/// Subtitle of the card: the names of what can be heard, sounds first then music, in mix
/// order. Muted categories, layers at level 0 and items the plan cannot play ([canUse], a
/// shared mix received by a free user) are left out. Null when the mix is empty;
/// [mediaCardMutedSummary] when it only has muted layers.
String? mixSummary(
  Scene scene,
  Catalog catalog, {
  bool Function(LayerKind kind, String id)? canUse,
}) {
  final names = <String>[];
  var muted = false;
  for (final kind in const [LayerKind.son, LayerKind.musique]) {
    for (final layer in scene.layers(kind)) {
      if (layer.level <= 0) continue;
      if (canUse != null && !canUse(kind, layer.id)) continue;
      final item = catalog.item(kind, layer.id);
      if (item == null) continue;
      if (scene.isMuted(kind)) {
        muted = true;
        continue;
      }
      names.add(item.name);
    }
  }
  if (names.isNotEmpty) return names.join(' · ');
  return muted ? mediaCardMutedSummary : null;
}

/// The landscape before ([direction] < 0) or after ([direction] > 0) [landscapeId] in its
/// theme, skipping those [usable] refuses (locked for the plan). No wrap: null at the edges.
String? neighbourLandscape(
  Catalog catalog,
  String landscapeId,
  int direction,
  bool Function(Landscape landscape) usable,
) {
  final landscape = catalog.landscape(landscapeId);
  if (landscape == null || direction == 0) return null;
  final list = catalog.landscapesOfTheme(landscape.themeId);
  final index = list.indexWhere((l) => l.id == landscapeId);
  if (index < 0) return null;
  final step = direction < 0 ? -1 : 1;
  for (var i = index + step; i >= 0 && i < list.length; i += step) {
    if (usable(list[i])) return list[i].id;
  }
  return null;
}

/// Cycle of the card's timer button: 15 min → 30 min → 1 h → 2 h → Toute la nuit → Sans
/// minuteur → 15 min.
const List<TimerSetting> mediaCardTimerCycle = [
  TimerDuration(15),
  TimerDuration(30),
  TimerDuration(60),
  TimerDuration(120),
  TimerNight(),
  TimerNone(),
];

/// Next timer of the cycle. A duration outside the cycle (45 min from a stored scene)
/// goes to the next longer step.
TimerSetting nextMediaCardTimer(TimerSetting current) => switch (current) {
  TimerNone() => const TimerDuration(15),
  TimerNight() => const TimerNone(),
  TimerDuration(:final minutes) =>
    minutes < 15
        ? const TimerDuration(15)
        : minutes < 30
        ? const TimerDuration(30)
        : minutes < 60
        ? const TimerDuration(60)
        : minutes < 120
        ? const TimerDuration(120)
        : const TimerNight(),
};

/// Content description of the timer button (TalkBack reads it; French):
/// « Minuteur 30 min. Toucher pour 1 h », « Minuteur toute la nuit. Toucher pour l’enlever »,
/// « Sans minuteur. Toucher pour 15 min ».
String mediaCardTimerLabel(TimerSetting timer) {
  final state = switch (timer) {
    TimerDuration(:final minutes) =>
      'Minuteur ${formatDuration(Duration(minutes: minutes))}',
    TimerNight() => 'Minuteur toute la nuit',
    TimerNone() => 'Sans minuteur',
  };
  final action = switch (nextMediaCardTimer(timer)) {
    TimerDuration(:final minutes) =>
      'Toucher pour ${formatDuration(Duration(minutes: minutes))}',
    TimerNight() => 'Toucher pour toute la nuit',
    TimerNone() => 'Toucher pour l’enlever',
  };
  return '$state. $action';
}
