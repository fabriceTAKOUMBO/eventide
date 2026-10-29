// Square picture of a procedural landscape for the system media card (lock screen,
// notification shade), drawn offscreen: same composition, crop focus and moment-of-day
// light as the full-screen landscape. Used by MediaArtwork (lib/services/audio) when the
// landscape has no poster file; wired in lib/app/bootstrap.dart through
// [renderGuardedLandscapeArtwork].
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../core/crash_guard.dart';
import '../../core/scene.dart' show Moment;
import 'landscape_image.dart' show landscapeMatrix;
import 'landscape_painter.dart';

/// PNG bytes of the landscape [style] at [moment], [size] × [size] pixels, cropped like
/// `cover` around the style's focus. [simplified]: the three-gradient picture of the crash
/// guard instead of the full composition.
Future<Uint8List> renderLandscapeArtwork({
  required String style,
  required Moment moment,
  required int size,
  bool simplified = false,
}) async {
  final side = size.toDouble();
  final bounds = Offset.zero & Size(side, side);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, bounds);
  final light = moment != Moment.jour;
  if (light) {
    canvas.saveLayer(
      bounds,
      Paint()..colorFilter = ColorFilter.matrix(landscapeMatrix(moment: moment)),
    );
  }
  if (simplified) {
    paintSimplifiedLandscape(canvas, bounds.size, style);
  } else {
    paintLandscapeCover(canvas, bounds.size, style);
  }
  if (light) canvas.restore();
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(size, size);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('PNG encoding failed');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

/// [renderLandscapeArtwork] behind the crash guard (docs/app/architecture.md § 19): the drawing
/// is marked, and noted in the problem report's log, before it starts; the mark is cleared once
/// the PNG is ready. A style whose drawing was interrupted by a crash gets the simplified
/// picture.
Future<Uint8List> renderGuardedLandscapeArtwork({
  required String style,
  required Moment moment,
  required int size,
}) async {
  final guard = CrashGuard.current;
  final simplified = guard.isDead(style);
  final token = guard.beginDrawing(
    'image de la carte',
    style,
    '$size×$size ${moment.name}${simplified ? ' simplifiée' : ''}',
  );
  try {
    return await renderLandscapeArtwork(
      style: style,
      moment: moment,
      size: size,
      simplified: simplified,
    );
  } finally {
    guard.endDrawing(token);
  }
}
