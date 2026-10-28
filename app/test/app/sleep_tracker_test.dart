import 'package:eventide/app/sleep_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 10, 28, 23);

  test('a wake-up before 3 h keeps the night open, after 3 h ends it', () {
    final tracker = SleepTracker()..startNight(start);
    expect(tracker.onWake(start.add(const Duration(minutes: 40))), isNull);
    expect(tracker.isOpen, isTrue);
    final night = tracker.onWake(start.add(const Duration(hours: 7, minutes: 20)));
    expect(night?.duration, const Duration(hours: 7, minutes: 20));
    expect(tracker.isOpen, isFalse);
  });

  test('playback stopping after 3 h ends the night with the listened time', () {
    final tracker = SleepTracker()..startNight(start);
    expect(tracker.onPlaybackStopped(start.add(const Duration(hours: 1)), const Duration(minutes: 55)), isNull);
    final night = tracker.onPlaybackStopped(start.add(const Duration(hours: 10)), const Duration(hours: 9));
    expect(night?.listenedMinutes, 9 * 60 + 55);
  });

  test('a night forgotten for more than 16 h is dropped, not invented', () {
    final tracker = SleepTracker()..startNight(start);
    expect(tracker.onWake(start.add(const Duration(hours: 20))), isNull);
    expect(tracker.isOpen, isFalse);
  });

  test('starting twice keeps the first start; JSON round trip', () {
    final tracker = SleepTracker()..startNight(start);
    tracker.startNight(start.add(const Duration(minutes: 30)));
    expect(tracker.open?.start, start);
    final copy = OpenNight.fromJson(tracker.open!.withListened(const Duration(minutes: 5)).toJson());
    expect(copy?.start, start);
    expect(copy?.listened, const Duration(minutes: 5));
    expect(OpenNight.fromJson(null), isNull);
  });
}
