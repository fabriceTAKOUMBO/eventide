// Buttons of the system media card (MediaSession playback state), built from the card info
// and the playback state. Android 13+ (Galaxy S24, One UI 6–8) draws them from the session:
// play/pause, then previous/next when the session allows them, then the custom actions
// (favourite, timer) in order. Android 12 and older draw the notification's own actions
// (custom actions are not shown there by audio_service).
//
// Seeking is never offered: the progress bar is the timer, for information only.
import 'package:audio_service/audio_service.dart';

import '../../core/media_card.dart';
import '../../core/scene.dart';

/// Names of the card's custom actions (AudioHandler.customAction).
abstract final class MediaCardActions {
  static const String favorite = 'eventide.favorite';
  static const String timer = 'eventide.timer';
}

/// Android drawables of the custom actions (res/drawable/ic_media_*.xml, white 24 dp, kept
/// from resource shrinking by res/raw/keep.xml).
abstract final class MediaCardIcons {
  static const String favorite = 'drawable/ic_media_favorite';
  static const String favoriteBorder = 'drawable/ic_media_favorite_border';
  static const String timer = 'drawable/ic_media_timer';
  static const String timer15 = 'drawable/ic_media_timer_15';
  static const String timer30 = 'drawable/ic_media_timer_30';
  static const String timer60 = 'drawable/ic_media_timer_60';
  static const String timer120 = 'drawable/ic_media_timer_120';
  static const String timerNight = 'drawable/ic_media_timer_night';
  static const String timerOff = 'drawable/ic_media_timer_off';

  static String forTimer(TimerSetting setting) => switch (setting) {
    TimerDuration(minutes: 15) => timer15,
    TimerDuration(minutes: 30) => timer30,
    TimerDuration(minutes: 60) => timer60,
    TimerDuration(minutes: 120) => timer120,
    TimerDuration() => timer,
    TimerNight() => timerNight,
    TimerNone() => timerOff,
  };
}

/// Content descriptions (French) of the card's buttons.
abstract final class MediaCardLabels {
  static const String previous = 'Paysage précédent';
  static const String next = 'Paysage suivant';
  static const String play = 'Lecture';
  static const String pause = 'Pause';
  static const String addFavorite = 'Ajouter aux favoris';
  static const String removeFavorite = 'Retirer des favoris';
}

/// The buttons of the card and the ones kept in the compact (collapsed) view.
class MediaCardControls {
  const MediaCardControls(this.controls, this.compactIndices);

  final List<MediaControl> controls;

  /// Indices in [controls] of play/pause and next (Android 12 and older; Android 13+ picks
  /// the compact buttons itself from the session).
  final List<int> compactIndices;
}

/// Up to five buttons: previous landscape, play/pause (sound only), next landscape, heart,
/// timer. Previous and next are left out at the edges of the theme (no wrap); the heart and
/// the timer need a loaded session ([card] and [timer] non-null). The custom actions come
/// last, so that each index is the same in the full list and in audio_service's list of
/// standard notification actions (which leaves custom actions out).
MediaCardControls mediaCardControls({
  required bool playing,
  MediaCardInfo? card,
  TimerSetting? timer,
}) {
  final controls = <MediaControl>[
    if (card != null && card.hasPrevious)
      MediaControl.skipToPrevious.copyWith(label: MediaCardLabels.previous),
    if (playing)
      MediaControl.pause.copyWith(label: MediaCardLabels.pause)
    else
      MediaControl.play.copyWith(label: MediaCardLabels.play),
    if (card != null && card.hasNext)
      MediaControl.skipToNext.copyWith(label: MediaCardLabels.next),
  ];
  final playIndex = card != null && card.hasPrevious ? 1 : 0;
  final compact = [playIndex, if (card != null && card.hasNext) playIndex + 1];
  if (card != null) {
    controls.add(
      MediaControl.custom(
        androidIcon: card.favorite
            ? MediaCardIcons.favorite
            : MediaCardIcons.favoriteBorder,
        label: card.favorite
            ? MediaCardLabels.removeFavorite
            : MediaCardLabels.addFavorite,
        name: MediaCardActions.favorite,
      ),
    );
    if (timer != null) {
      controls.add(
        MediaControl.custom(
          androidIcon: MediaCardIcons.forTimer(timer),
          label: mediaCardTimerLabel(timer),
          name: MediaCardActions.timer,
        ),
      );
    }
  }
  return MediaCardControls(List.unmodifiable(controls), List.unmodifiable(compact));
}
