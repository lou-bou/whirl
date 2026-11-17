import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:kit/kit.dart';
import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// How the mark is drawn at one moment of the splash. At rest everything is in place.
class MarkPose {
  const MarkPose({
    this.slices = const [1, 1, 1, 1, 1, 1],
    this.hub = 1,
    this.pointerDy = 0,
    this.pointerScaleX = 1,
    this.pointerScaleY = 1,
    this.pointerOpacity = 1,
    this.whirl = 0,
    this.flick = 0,
  });

  /// Each slice's scale from the hub (0 = not there yet).
  final List<double> slices;
  final double hub;
  final double pointerDy, pointerScaleX, pointerScaleY, pointerOpacity;

  /// Rotation of the slices and of the pointer's tip, in degrees.
  final double whirl, flick;

  static const rest = MarkPose();
}

/// The logo mark (public/logo/whirl-mark.svg, viewBox 160): six slices in amber, coral, teal
/// around a hub, and the pointer on top, in the theme's pointer colour.
class MarkPainter extends CustomPainter {
  MarkPainter(this.pointer, [this.pose = MarkPose.rest]);
  final Color pointer;
  final MarkPose pose;

  static const _colors = [Brand.amber, Brand.coral, Brand.teal, Brand.amber, Brand.coral, Brand.teal];
  static const _hub = Offset(80, 86);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 160, size.height / 160);

    canvas.save();
    _rotate(canvas, _hub, pose.whirl);
    for (var i = 0; i < 6; i++) {
      final s = pose.slices[i];
      if (s <= 0) continue;
      canvas.save();
      canvas.translate(_hub.dx, _hub.dy);
      canvas.scale(s);
      final start = (-90 + i * 60) * math.pi / 180;
      final path = Path()
        ..moveTo(0, 0)
        ..arcTo(Rect.fromCircle(center: Offset.zero, radius: 62), start, math.pi / 3, false)
        ..close();
      canvas.drawPath(path, Paint()..color = _colors[i].withValues(alpha: s.clamp(0.0, 1.0)));
      canvas.restore();
    }
    canvas.restore();

    if (pose.hub > 0) {
      canvas.drawCircle(_hub, 12 * pose.hub, Paint()..color = pointer.withValues(alpha: pose.hub.clamp(0.0, 1.0)));
    }

    if (pose.pointerOpacity > 0) {
      canvas.save();
      canvas.translate(0, pose.pointerDy);
      canvas.translate(80, 30);
      canvas.scale(pose.pointerScaleX, pose.pointerScaleY);
      canvas.translate(-80, -30);
      _rotate(canvas, const Offset(80, 8), pose.flick);
      canvas.drawPath(
        Path()
          ..moveTo(70, 8)
          ..lineTo(90, 8)
          ..lineTo(80, 30)
          ..close(),
        Paint()..color = pointer.withValues(alpha: pointer.a * pose.pointerOpacity.clamp(0.0, 1.0)),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  static void _rotate(Canvas canvas, Offset about, double degrees) {
    if (degrees == 0) return;
    canvas.translate(about.dx, about.dy);
    canvas.rotate(degrees * math.pi / 180);
    canvas.translate(-about.dx, -about.dy);
  }

  @override
  bool shouldRepaint(MarkPainter old) => old.pose != pose || old.pointer != pointer;
}

/// The mark at rest.
class Mark extends StatelessWidget {
  const Mark({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: MarkPainter(context.whirl.pointer)),
  );
}

/// Mark + "Whirl" in the display font (DESIGN.md §2: mark height 1.2× cap height).
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.markKey, this.size = 20});
  final Key? markKey;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Mark(key: markKey, size: size * 1.4),
      const SizedBox(width: Space.s2),
      Text('Whirl', style: context.display(size)),
    ],
  );
}

// ---------- keyframes ----------

const _cssEase = Cubic(0.25, 0.1, 0.25, 1);

/// A CSS @keyframes track: [frames] are (offset 0–1, value), each segment eased by [curve].
double _track(double p, List<(double, double)> frames, [Curve curve = _cssEase, List<Curve>? curves]) {
  if (p <= frames.first.$1) return frames.first.$2;
  for (var i = 0; i < frames.length - 1; i++) {
    final (a, va) = frames[i];
    final (b, vb) = frames[i + 1];
    if (p <= b) {
      final c = curves?[i] ?? curve;
      return va + (vb - va) * c.transform((p - a) / (b - a));
    }
  }
  return frames.last.$2;
}

/// The pose [ms] after the splash started (src/app.css "Loading splash").
MarkPose splashPose(double ms) {
  double pop(double delay) {
    final p = ((ms - delay) / 320).clamp(0.0, 1.0);
    return _track(p, const [(0, 0), (0.6, 1.16), (0.8, 0.96), (1, 1)], Motion.easeOut);
  }

  final drop = ((ms - 300) / 400).clamp(0.0, 1.0);
  const dropCurves = [Cubic(0.5, 0, 0.9, 0.5), Curves.easeOut, Curves.easeInOut];
  final whirlP = ms < 700 ? 0.0 : ((ms - 700) % 720) / 720;
  return MarkPose(
    slices: [for (var i = 0; i < 6; i++) pop(i * 50.0)],
    hub: pop(200),
    pointerDy: _track(drop, const [(0, -110), (0.55, 0), (0.78, -5), (1, 0)], Curves.linear, dropCurves),
    pointerScaleX: _track(drop, const [(0, 0.96), (0.55, 1.2), (0.78, 0.95), (1, 1)], Curves.linear, dropCurves),
    pointerScaleY: _track(drop, const [(0, 1.06), (0.55, 0.72), (0.78, 1.08), (1, 1)], Curves.linear, dropCurves),
    pointerOpacity: ms < 300 ? 0 : (drop / 0.15).clamp(0.0, 1.0),
    whirl: ms < 700
        ? 0
        : _track(whirlP, const [(0, 0), (0.14, -16), (0.72, 374), (0.88, 356), (1, 360)], Curves.easeInOut),
    flick: ms < 700
        ? 0
        : _track(whirlP, const [
            (0, 0),
            (0.2, 0),
            (0.3, -16),
            (0.4, 6),
            (0.5, -16),
            (0.6, 6),
            (0.72, -10),
            (0.88, 3),
            (1, 0),
          ], Curves.linear),
  );
}

/// The loading splash (src/splash.js): the slices pop out of the hub, the pointer drops on top,
/// and the wheel whirls with the pointer flicking; at the end of a whirl, once [ready], it flies
/// onto the header logo as the background fades. It keeps whirling while there is nothing to
/// show, for up to 5 s. With reduced motion it is the still logo, gone as soon as [ready].
class Splash extends StatefulWidget {
  const Splash({super.key, required this.target, required this.ready, required this.onDone});

  /// The header's mark, where the logo lands.
  final GlobalKey target;
  final bool ready;
  final VoidCallback onDone;

  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> with SingleTickerProviderStateMixin {
  static const _land = 700.0, _turn = 720.0, _limit = 5000.0, _fly = 450.0, _size = 96.0;

  late final Ticker _ticker = createTicker(_tick);
  double _ms = 0;
  double? _flightStart;
  Offset _to = Offset.zero;
  double _toScale = 28 / _size;
  bool _still = false;
  bool _done = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    if (!_ticker.isActive && !_done) _ticker.start();
  }

  bool get _mayLeave => widget.ready || _ms >= _limit;

  void _tick(Duration elapsed) {
    final ms = elapsed.inMicroseconds / 1000;
    if (_still) {
      if (ms >= 200 && _mayLeave) _finish();
      return;
    }
    // Leave at the end of a whirl, when the wheel lines up with the real logo.
    if (_flightStart == null && ms >= _land + _turn && _mayLeave) {
      final turnEnd = _land + ((ms - _land) / _turn).floor() * _turn;
      if (_ms < turnEnd || ms - turnEnd < 34) {
        _measure();
        _flightStart = ms;
      }
    }
    setState(() => _ms = ms);
    if (_flightStart != null && ms - _flightStart! >= _fly) _finish();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _ticker.stop();
    widget.onDone();
  }

  void _measure() {
    final box = widget.target.currentContext?.findRenderObject() as RenderBox?;
    final own = context.findRenderObject() as RenderBox?;
    if (box == null || own == null || !box.hasSize || !own.hasSize) return;
    final centre = box.localToGlobal(box.size.center(Offset.zero), ancestor: own);
    _to = centre - own.size.center(Offset.zero);
    _toScale = box.size.height / _size;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final flying = _flightStart == null
        ? 0.0
        : Motion.easeOut.transform(((_ms - _flightStart!) / _fly).clamp(0.0, 1.0));
    final pose = _still ? MarkPose.rest : (_flightStart != null ? MarkPose.rest : splashPose(_ms));
    return Semantics(
      label: 'Whirl is loading',
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(color: t.bg.withValues(alpha: 1 - flying)),
          ),
          Center(
            child: Transform.translate(
              offset: _to * flying,
              child: Transform.scale(
                scale: 1 + (_toScale - 1) * flying,
                child: SizedBox.square(
                  dimension: _size,
                  child: CustomPaint(painter: MarkPainter(context.whirl.pointer, pose)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
