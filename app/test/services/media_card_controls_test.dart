// Buttons of the system media card (lib/services/audio/media_card_controls.dart): order,
// compact indices, icons and French content descriptions; never a seek.
import 'package:audio_service/audio_service.dart';
import 'package:eventide/core/media_card.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/services/audio/media_card_controls.dart';
import 'package:flutter_test/flutter_test.dart';

MediaCardInfo _card({String? previous, String? next, bool favorite = false}) => MediaCardInfo(
  landscapeId: 'sous-bois',
  title: 'Sous-bois ensoleillé',
  artist: 'Vent · Oiseaux',
  previousId: previous,
  nextId: next,
  favorite: favorite,
);

List<MediaAction> _actions(MediaCardControls c) => [for (final control in c.controls) control.action];

void main() {
  test('expanded card: previous, pause, next, heart, timer; compact: pause and next', () {
    final c = mediaCardControls(
      playing: true,
      card: _card(previous: 'cascade-foret', next: 'berge-mousseuse', favorite: true),
      timer: const TimerDuration(30),
    );
    expect(_actions(c), [
      MediaAction.skipToPrevious,
      MediaAction.pause,
      MediaAction.skipToNext,
      MediaAction.custom,
      MediaAction.custom,
    ]);
    expect(c.compactIndices, [1, 2]);
    expect([for (final x in c.controls) x.label], [
      'Paysage précédent',
      'Pause',
      'Paysage suivant',
      'Retirer des favoris',
      'Minuteur 30 min. Toucher pour 1 h',
    ]);
    expect(c.controls[3].customAction?.name, MediaCardActions.favorite);
    expect(c.controls[3].androidIcon, 'drawable/ic_media_favorite');
    expect(c.controls[4].customAction?.name, MediaCardActions.timer);
    expect(c.controls[4].androidIcon, 'drawable/ic_media_timer_30');
  });

  test('first landscape of the theme: no previous button, play while paused', () {
    final c = mediaCardControls(playing: false, card: _card(next: 'sous-bois'), timer: const TimerNone());
    expect(_actions(c), [MediaAction.play, MediaAction.skipToNext, MediaAction.custom, MediaAction.custom]);
    expect(c.controls.first.label, 'Lecture');
    expect(c.compactIndices, [0, 1]);
    expect(c.controls[2].androidIcon, 'drawable/ic_media_favorite_border');
    expect(c.controls[2].label, 'Ajouter aux favoris');
    expect(c.controls[3].androidIcon, 'drawable/ic_media_timer_off');
  });

  test('last landscape of the theme: no next button, compact is play/pause only', () {
    final c = mediaCardControls(playing: true, card: _card(previous: 'cascade-foret'), timer: const TimerNight());
    expect(_actions(c), [MediaAction.skipToPrevious, MediaAction.pause, MediaAction.custom, MediaAction.custom]);
    expect(c.compactIndices, [1]);
    expect(c.controls[3].androidIcon, 'drawable/ic_media_timer_night');
  });

  test('alone in its theme for the plan: play/pause, heart and timer', () {
    final c = mediaCardControls(playing: true, card: _card(), timer: const TimerDuration(60));
    expect(_actions(c), [MediaAction.pause, MediaAction.custom, MediaAction.custom]);
    expect(c.compactIndices, [0]);
  });

  test('loading (no session yet): play/pause only', () {
    final c = mediaCardControls(playing: true);
    expect(_actions(c), [MediaAction.pause]);
    expect(c.compactIndices, [0]);
  });

  test('custom actions last: compact indices point at standard actions only', () {
    for (final previous in [null, 'a']) {
      for (final next in [null, 'b']) {
        final c = mediaCardControls(
          playing: false,
          card: _card(previous: previous, next: next),
          timer: const TimerDuration(15),
        );
        final standard = [
          for (final x in c.controls)
            if (x.customAction == null) x,
        ];
        expect(c.controls.sublist(0, standard.length), standard);
        expect(c.compactIndices.length, lessThanOrEqualTo(3));
        for (final i in c.compactIndices) {
          expect(i, lessThan(standard.length));
          expect(standard[i].action, isNot(MediaAction.skipToPrevious));
        }
      }
    }
  });

  test('never a seek control: the progress bar is the timer', () {
    final c = mediaCardControls(
      playing: true,
      card: _card(previous: 'a', next: 'b'),
      timer: const TimerDuration(15),
    );
    expect(_actions(c), isNot(contains(MediaAction.seek)));
  });

  test('timer icons: one per step of the cycle, a stopwatch for other durations', () {
    expect(MediaCardIcons.forTimer(const TimerDuration(15)), 'drawable/ic_media_timer_15');
    expect(MediaCardIcons.forTimer(const TimerDuration(30)), 'drawable/ic_media_timer_30');
    expect(MediaCardIcons.forTimer(const TimerDuration(60)), 'drawable/ic_media_timer_60');
    expect(MediaCardIcons.forTimer(const TimerDuration(120)), 'drawable/ic_media_timer_120');
    expect(MediaCardIcons.forTimer(const TimerDuration(45)), 'drawable/ic_media_timer');
    expect(MediaCardIcons.forTimer(const TimerNight()), 'drawable/ic_media_timer_night');
    expect(MediaCardIcons.forTimer(const TimerNone()), 'drawable/ic_media_timer_off');
  });
}
