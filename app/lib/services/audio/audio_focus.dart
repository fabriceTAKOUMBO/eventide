// Android audio focus and "becoming noisy" (headphones unplugged), through audio_session.
import 'dart:async';

import 'package:audio_session/audio_session.dart';

enum FocusChange {
  /// Another app needs the output briefly (navigation, notification): lower the volume.
  duckBegin,
  duckEnd,

  /// Incoming call, another player: pause, and resume afterwards if it was transient.
  pauseBegin,

  /// The transient interruption is over.
  pauseEnd,

  /// Focus lost for good (another media app started): pause and stay paused.
  lost,
}

abstract class AudioFocus {
  /// Requests focus before playing. False when refused (for example during a call).
  Future<bool> activate();

  Future<void> deactivate();

  Stream<FocusChange> get changes;

  /// Headphones unplugged / Bluetooth disconnected.
  Stream<void> get becomingNoisy;
}

class AudioSessionFocus implements AudioFocus {
  AudioSession? _session;
  final _changes = StreamController<FocusChange>.broadcast();
  final _noisy = StreamController<void>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];

  Future<AudioSession> _ensure() async {
    final existing = _session;
    if (existing != null) return existing;
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    _subscriptions.add(session.interruptionEventStream.listen((event) {
      if (event.begin) {
        _changes.add(switch (event.type) {
          AudioInterruptionType.duck => FocusChange.duckBegin,
          AudioInterruptionType.pause => FocusChange.pauseBegin,
          AudioInterruptionType.unknown => FocusChange.lost,
        });
      } else {
        _changes.add(switch (event.type) {
          AudioInterruptionType.duck => FocusChange.duckEnd,
          AudioInterruptionType.pause => FocusChange.pauseEnd,
          AudioInterruptionType.unknown => FocusChange.lost,
        });
      }
    }));
    _subscriptions.add(session.becomingNoisyEventStream.listen((_) => _noisy.add(null)));
    _session = session;
    return session;
  }

  @override
  Future<bool> activate() async {
    try {
      return await (await _ensure()).setActive(true);
    } catch (_) {
      // Never block playback on a focus error.
      return true;
    }
  }

  @override
  Future<void> deactivate() async {
    try {
      await _session?.setActive(false);
    } catch (_) {}
  }

  @override
  Stream<FocusChange> get changes => _changes.stream;

  @override
  Stream<void> get becomingNoisy => _noisy.stream;
}
