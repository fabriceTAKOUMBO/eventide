// Sleep tracking, method 1 of the dossier (screen 7): estimated from the use of the phone and the
// listening time. No sensor, no permission, nothing leaves the phone. Indicative only.
//
// A night starts with « Commencer la nuit » (or a « Pour dormir » schedule firing while
// tracking is on). It ends at the first wake of the standby screen or app resume at least
// [minNight] after its start, or when playback stops at least [minNight] after its start.
import '../core/sleep.dart';

class OpenNight {
  const OpenNight({required this.start, this.listened = Duration.zero});

  final DateTime start;
  final Duration listened;

  OpenNight withListened(Duration extra) => OpenNight(start: start, listened: listened + extra);

  Map<String, dynamic> toJson() => {'start': start.toIso8601String(), 'listened_seconds': listened.inSeconds};

  static OpenNight? fromJson(Object? json) {
    if (json is! Map) return null;
    final start = DateTime.tryParse('${json['start']}');
    if (start == null) return null;
    final listened = json['listened_seconds'];
    return OpenNight(start: start, listened: Duration(seconds: listened is num ? listened.toInt() : 0));
  }
}

class SleepTracker {
  SleepTracker({this.open});

  /// Shorter than this, a wake-up or a stop does not end the night (a short nap, a false start).
  static const Duration minNight = Duration(hours: 3);

  /// An open night older than this is dropped: the phone was not used, the figure would be invented.
  static const Duration maxNight = Duration(hours: 16);

  OpenNight? open;

  bool get isOpen => open != null;

  /// Starts a night unless one is already open.
  void startNight(DateTime now) {
    final current = open;
    if (current != null && now.difference(current.start) < maxNight) return;
    open = OpenNight(start: now);
  }

  /// Standby woken up or app resumed. Returns the finished night, if this ends it.
  Night? onWake(DateTime now) => _close(now);

  /// Playback stopped after [listened] of sound. Returns the finished night, if this ends it.
  Night? onPlaybackStopped(DateTime now, Duration listened) {
    final current = open;
    if (current == null) return null;
    open = current.withListened(listened);
    return _close(now);
  }

  Night? _close(DateTime now) {
    final current = open;
    if (current == null) return null;
    final elapsed = now.difference(current.start);
    if (elapsed > maxNight) {
      open = null;
      return null;
    }
    if (elapsed < minNight) return null;
    open = null;
    return Night(start: current.start, end: now, listenedMinutes: current.listened.inMinutes);
  }
}
