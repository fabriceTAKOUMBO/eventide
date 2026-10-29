// A Canvas that records what a painter asks the GPU to do (test helper): draw count, mask-filter
// blurs (and on what), clip paths, device-space geometry and blur sizes, non-finite values.
// Used by landscape_budget_test.dart (docs/app/architecture.md § 19).
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

class CanvasAudit {
  int draws = 0;
  int clipPaths = 0;
  int saveLayers = 0;

  /// Mask-filter blurs by kind of draw (`path`, `circle`, `line`…): each one is an offscreen
  /// pass on the GPU (analytic for some shapes only, depending on the renderer).
  final Map<String, int> blurs = {};
  int blursUnderClipPath = 0;
  double maxBlurSigma = 0;

  /// Largest extent of any draw, in device pixels.
  double maxExtent = 0;
  final List<String> nonFinite = [];

  int get blurCount => blurs.values.fold(0, (a, b) => a + b);

  @override
  String toString() =>
      'draws=$draws clipPaths=$clipPaths blurs=$blurs underClip=$blursUnderClipPath '
      'maxSigma=${maxBlurSigma.toStringAsFixed(1)} nonFinite=$nonFinite';
}

/// Sigma of a blur mask filter (from its description: MaskFilter has no public getter).
double? maskSigma(Paint paint) {
  final filter = paint.maskFilter;
  if (filter == null) return null;
  final m = RegExp(r'MaskFilter\.blur\([^,]+, ([^)]+)\)').firstMatch(filter.toString());
  return m == null ? double.nan : double.tryParse(m.group(1)!.trim()) ?? double.nan;
}

class AuditCanvas implements Canvas {
  AuditCanvas(this.inner);

  final Canvas inner;
  final CanvasAudit audit = CanvasAudit();
  final List<Matrix4> _matrices = [Matrix4.identity()];
  final List<int> _clipDepth = [0];

  Matrix4 get _m => _matrices.last;

  double get _scale {
    final s = _m.storage;
    return math.max(
      math.sqrt(s[0] * s[0] + s[1] * s[1]),
      math.sqrt(s[4] * s[4] + s[5] * s[5]),
    );
  }

  void _finite(String what, Iterable<double> values) {
    if (values.any((v) => !v.isFinite)) audit.nonFinite.add(what);
  }

  void _draw(String kind, Rect local, Paint paint) {
    audit.draws++;
    _finite(kind, [local.left, local.top, local.right, local.bottom, paint.strokeWidth]);
    final device = MatrixUtils.transformRect(_m, local);
    if (device.width.isFinite && device.height.isFinite) {
      audit.maxExtent = math.max(audit.maxExtent, math.max(device.width, device.height));
    }
    final sigma = maskSigma(paint);
    if (sigma == null) return;
    final deviceSigma = sigma * _scale;
    _finite('$kind blur', [deviceSigma]);
    audit.blurs[kind] = (audit.blurs[kind] ?? 0) + 1;
    if (_clipDepth.last > 0) audit.blursUnderClipPath++;
    if (deviceSigma.isFinite) audit.maxBlurSigma = math.max(audit.maxBlurSigma, deviceSigma);
  }

  void _push() {
    _matrices.add(_m.clone());
    _clipDepth.add(_clipDepth.last);
  }

  @override
  void save() {
    _push();
    inner.save();
  }

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    audit.saveLayers++;
    _push();
    inner.saveLayer(bounds, paint);
  }

  @override
  void restore() {
    if (_matrices.length > 1) {
      _matrices.removeLast();
      _clipDepth.removeLast();
    }
    inner.restore();
  }

  @override
  int getSaveCount() => inner.getSaveCount();

  @override
  void translate(double dx, double dy) {
    _finite('translate', [dx, dy]);
    _m.translateByDouble(dx, dy, 0, 1);
    inner.translate(dx, dy);
  }

  @override
  void scale(double sx, [double? sy]) {
    _finite('scale', [sx, sy ?? sx]);
    _m.scaleByDouble(sx, sy ?? sx, 1, 1);
    inner.scale(sx, sy);
  }

  @override
  void rotate(double radians) {
    _finite('rotate', [radians]);
    _m.rotateZ(radians);
    inner.rotate(radians);
  }

  @override
  void clipRect(Rect rect, {ui.ClipOp clipOp = ui.ClipOp.intersect, bool doAntiAlias = true}) {
    _finite('clipRect', [rect.left, rect.top, rect.right, rect.bottom]);
    inner.clipRect(rect, clipOp: clipOp, doAntiAlias: doAntiAlias);
  }

  @override
  void clipPath(Path path, {bool doAntiAlias = true}) {
    audit.clipPaths++;
    _clipDepth[_clipDepth.length - 1]++;
    final b = path.getBounds();
    _finite('clipPath', [b.left, b.top, b.right, b.bottom]);
    inner.clipPath(path, doAntiAlias: doAntiAlias);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    _draw('line', Rect.fromPoints(p1, p2), paint);
    inner.drawLine(p1, p2, paint);
  }

  @override
  void drawRect(Rect rect, Paint paint) {
    _draw('rect', rect, paint);
    inner.drawRect(rect, paint);
  }

  @override
  void drawRRect(RRect rrect, Paint paint) {
    _draw('rrect', rrect.outerRect, paint);
    inner.drawRRect(rrect, paint);
  }

  @override
  void drawOval(Rect rect, Paint paint) {
    _draw('oval', rect, paint);
    inner.drawOval(rect, paint);
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    _draw('circle', Rect.fromCircle(center: c, radius: radius), paint);
    inner.drawCircle(c, radius, paint);
  }

  @override
  void drawArc(Rect rect, double startAngle, double sweepAngle, bool useCenter, Paint paint) {
    _draw('arc', rect, paint);
    inner.drawArc(rect, startAngle, sweepAngle, useCenter, paint);
  }

  @override
  void drawPath(Path path, Paint paint) {
    _draw('path', path.getBounds(), paint);
    inner.drawPath(path, paint);
  }

  @override
  void drawRawPoints(ui.PointMode pointMode, Float32List points, Paint paint) {
    audit.draws++;
    _finite('points', points);
    inner.drawRawPoints(pointMode, points, paint);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('AuditCanvas: ${invocation.memberName} is not audited');
}
