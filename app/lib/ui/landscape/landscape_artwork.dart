// Square picture of a procedural landscape for the system media card (lock screen,
// notification shade), drawn offscreen: same composition, crop focus and moment-of-day
// light as the full-screen landscape. Used by MediaArtwork (lib/services/audio) when the
// landscape has no poster file; wired in lib/app/bootstrap.dart.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../core/scene.dart' show Moment;
import 'landscape_image.dart' show landscapeMatrix;
import 'landscape_painter.dart';

/// PNG bytes of the landscape [style] at [moment], [size] × [size] pixels, cropped like
/// `cover` around the style's focus.
Future<Uint8List> renderLandscapeArtwork({
  required String style,
  required Moment moment,
  required int size,
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
  paintLandscapeCover(canvas, bounds.size, style);
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
