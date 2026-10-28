// Players of the living landscapes (looping, muted videos; docs/app/architecture.md § 14).
//
// The video must never look like a video: no controls, no spinner, never a black frame. A
// player only says when its first frames are on screen ([LandscapeVideoStatus.showing]); until
// then LandscapeBackground keeps the poster (the loop's own frame 0) and then fades the video in
// over it, pixel for pixel the same picture.
//
// Never tied to the sound: nothing here knows about playback of the sound. Play/pause, the
// media notification, voice, audio focus and the timer only change the sound; a landscape video
// plays whenever its landscape is on screen, the app in the foreground and animations allowed.
//
// At most [LandscapeVideoHub.maxLive] players exist at once (the landscape on screen, plus the
// neighbour sliding in during a swipe); a player is disposed as soon as nothing shows it.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../../core/landscape_media.dart';

enum LandscapeVideoStatus {
  /// Opening the file or waiting for the first frames: the poster is shown.
  starting,

  /// Frames are flowing on screen: the video can cover the poster.
  showing,

  /// The video cannot play (decoder error, missing file): the still picture stays.
  failed,
}

/// One looping, muted video. The real one wraps video_player (ExoPlayer on Android); tests use
/// a fake (no platform channel).
abstract class LandscapeVideoPlayer {
  ValueListenable<LandscapeVideoStatus> get status;

  /// Size of the video picture, in pixels (zero until known).
  Size get size;

  /// Opens the video, loops it, mutes it and starts playing (unless [pause] came first).
  Future<void> start();
  Future<void> play();
  Future<void> pause();
  Future<void> dispose();

  /// The picture only: no controls, nothing else.
  Widget view();
}

typedef LandscapeVideoPlayerFactory =
    LandscapeVideoPlayer Function(LandscapeVideoSource source);

/// video_player (ExoPlayer, texture view) behind [LandscapeVideoPlayer].
class VideoPlayerLandscapePlayer implements LandscapeVideoPlayer {
  VideoPlayerLandscapePlayer(LandscapeVideoSource source)
    : _controller = switch (source) {
        AssetLandscapeVideo(:final asset) => VideoPlayerController.asset(
          asset,
          videoPlayerOptions: _options,
        ),
        FileLandscapeVideo(:final path) => VideoPlayerController.file(
          File(path),
          videoPlayerOptions: _options,
        ),
      };

  /// mixWithOthers: the video never asks for audio focus (that would pause the app's own
  /// sound, see AudioSessionFocus). allowBackgroundPlayback: the lifecycle is handled by
  /// LandscapeBackground (players are released in background), not by video_player.
  static final VideoPlayerOptions _options = VideoPlayerOptions(
    mixWithOthers: true,
    allowBackgroundPlayback: true,
  );

  final VideoPlayerController _controller;
  final ValueNotifier<LandscapeVideoStatus> _status = ValueNotifier(
    LandscapeVideoStatus.starting,
  );
  bool _wantPlaying = true;
  bool _initialized = false;
  bool _disposed = false;

  @override
  ValueListenable<LandscapeVideoStatus> get status => _status;

  @override
  Size get size => _controller.value.size;

  @override
  Future<void> start() async {
    _controller.addListener(_onValue);
    try {
      await _controller.initialize();
      if (_disposed) return;
      await _controller.setVolume(0);
      await _controller.setLooping(true);
      _initialized = true;
      if (_wantPlaying && !_disposed) await _controller.play();
    } catch (e) {
      debugPrint('LandscapeVideo: cannot play ($e)');
      _fail();
    }
  }

  void _onValue() {
    if (_disposed) return;
    final v = _controller.value;
    if (v.hasError) {
      _fail();
    } else if (_status.value == LandscapeVideoStatus.starting &&
        v.isInitialized &&
        v.isPlaying &&
        v.position > Duration.zero) {
      // The position moves: frames are being rendered into the texture.
      _status.value = LandscapeVideoStatus.showing;
    }
  }

  void _fail() {
    if (!_disposed) _status.value = LandscapeVideoStatus.failed;
  }

  @override
  Future<void> play() async {
    _wantPlaying = true;
    if (_initialized && !_disposed) await _controller.play();
  }

  @override
  Future<void> pause() async {
    _wantPlaying = false;
    if (_initialized && !_disposed) await _controller.pause();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _controller.removeListener(_onValue);
    try {
      await _controller.dispose();
    } catch (_) {}
    _status.dispose();
  }

  @override
  Widget view() => VideoPlayer(_controller);
}

/// A widget's hold on a shared player. [playing] is what this holder wants; the player plays
/// when at least one holder wants it.
class LandscapeVideoLease {
  LandscapeVideoLease._(this._entry);

  final _HubEntry _entry;
  bool _playing = false;
  bool _released = false;

  LandscapeVideoPlayer get player => _entry.player;

  bool get playing => _playing;
  set playing(bool value) {
    if (_released || value == _playing) return;
    _playing = value;
    _entry.sync();
  }

  void release() {
    if (_released) return;
    _released = true;
    _entry.leases.remove(this);
    _entry.hub._onReleased(_entry);
  }
}

class _HubEntry {
  _HubEntry(this.hub, this.source, this.player);

  final LandscapeVideoHub hub;
  final LandscapeVideoSource source;
  final LandscapeVideoPlayer player;
  final List<LandscapeVideoLease> leases = [];
  bool _playing = false;

  void sync() {
    final want = leases.any((l) => l.playing);
    if (want == _playing) return;
    _playing = want;
    unawaited(want ? player.play() : player.pause());
  }
}

/// Owns the players: one per video source, shared by the widgets that show it, disposed when
/// the last one lets go, never more than [maxLive] at once.
class LandscapeVideoHub extends ChangeNotifier {
  LandscapeVideoHub({this.maxLive = 2, LandscapeVideoPlayerFactory? factory})
    : factory = factory ?? VideoPlayerLandscapePlayer.new;

  final int maxLive;
  LandscapeVideoPlayerFactory factory;
  final Map<LandscapeVideoSource, _HubEntry> _live = {};

  /// Players alive now (tests, logs).
  int get liveCount => _live.length;

  /// A hold on the player of [source], or null when [maxLive] players already exist (the
  /// caller keeps its still picture and retries when the hub notifies).
  LandscapeVideoLease? acquire(LandscapeVideoSource source) {
    var entry = _live[source];
    if (entry == null) {
      if (_live.length >= maxLive) return null;
      final player = factory(source);
      entry = _live[source] = _HubEntry(this, source, player);
      // Starts paused: a lease asks for playing explicitly.
      unawaited(player.pause());
      unawaited(player.start());
    }
    final lease = LandscapeVideoLease._(entry);
    entry.leases.add(lease);
    return lease;
  }

  void _onReleased(_HubEntry entry) {
    if (entry.leases.isNotEmpty) {
      entry.sync();
      return;
    }
    _live.remove(entry.source);
    unawaited(entry.player.dispose());
    // After the current frame: a widget waiting for a slot may take it.
    scheduleMicrotask(notifyListeners);
  }
}

/// The app's hub. Tests replace its factory with a fake (no platform channel).
abstract final class LandscapeVideos {
  static LandscapeVideoHub hub = LandscapeVideoHub();

  @visibleForTesting
  static void debugReset({LandscapeVideoPlayerFactory? factory}) {
    hub = LandscapeVideoHub(factory: factory);
  }
}
