import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:kit/kit.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/model.dart';
import '../theme.dart';

/// The wheel is drawn in the web app's units (src/Wheel.jsx): a 1000 × 1040 box, centre
/// (500, 530), radius 450, hub 64, labels end 28 inside the rim.
const _w = 1000.0, _h = 1040.0, _cx = 500.0, _cy = 530.0, _r = 450.0, _hub = 64.0;
const _minSegments = 6, _maxLabelled = 16;
const _labelRoom = _r - _hub - 50;

/// With few ideas, repeat them so the wheel still looks like a wheel.
List<Project> wheelSegments(List<Project> ideas) {
  if (ideas.isEmpty) return const [];
  final copies = (_minSegments / ideas.length).ceil();
  return [for (var c = 0; c < copies; c++) ...ideas];
}

/// How one spin moves: from [from], [distance] degrees (negative = anticlockwise) over
/// [duration] seconds with a friction-like slow-down `1 - (1 - u)^k`, after an optional
/// wind-up of [windUp] degrees the other way. Its speed at the start is `distance · k / duration`.
class SpinPlan {
  const SpinPlan({
    required this.from,
    required this.distance,
    required this.duration,
    required this.k,
    this.windUp = 0,
  });
  final double from, distance, duration, k, windUp;

  static const windUpSeconds = 0.16;
  double get total => duration + (windUp == 0 ? 0 : windUpSeconds);

  double angleAt(double s) {
    if (windUp != 0 && s < windUpSeconds) {
      return from - windUp * distance.sign * math.sin(s / windUpSeconds * math.pi / 2);
    }
    final start = from - windUp * distance.sign;
    final u = ((s - (windUp == 0 ? 0 : windUpSeconds)) / duration).clamp(0.0, 1.0);
    return start + (distance + windUp * distance.sign) * (1 - math.pow(1 - u, k));
  }

  /// Picks how many turns and how long, so a spin started at [speed] deg/s slows down naturally
  /// and stops on [toTarget] degrees ahead (in the direction of travel): about 4 s, never under
  /// 2.6 or over 6.
  static ({double distance, double duration, double k}) forSpeed(double speed, double toTarget) {
    const k0 = 3.2, ideal = 4.2;
    var best = (distance: toTarget + 720.0, duration: 0.0, k: k0);
    var score = double.infinity;
    for (var n = 2; n <= 14; n++) {
      final d = toTarget + 360.0 * n;
      final t = k0 * d / speed;
      if ((t - ideal).abs() < score) {
        score = (t - ideal).abs();
        best = (distance: d, duration: t, k: k0);
      }
    }
    final t = best.duration.clamp(2.6, 6.0);
    final k = (speed * t / best.distance).clamp(1.4, 6.0);
    return (distance: best.distance, duration: k * best.distance / speed, k: k);
  }
}

/// The wheel (DESIGN.md §7). The winner is picked first, uniformly over the pool, then the
/// wheel is spun so it lands inside one of its slices. Tap it or use the Spin button for a
/// wound-up spin of 5–7 turns; or fling it with a finger and it starts at the finger's speed.
/// The pointer is pushed aside by each slice edge and snaps back, with a haptic tick, and the
/// landing gives a heavier one. With reduced motion it just highlights the winner.
class SpinWheel extends StatefulWidget {
  const SpinWheel({
    super.key,
    required this.ideas,
    required this.spinSignal,
    required this.onResult,
    this.onSpinning,
    this.haptics = true,
    this.random,
  });

  final List<Project> ideas;

  /// A new value asks for a spin (the Spin buttons).
  final int spinSignal;
  final ValueChanged<Project> onResult;
  final ValueChanged<bool>? onSpinning;
  final bool haptics;

  /// Tests and screenshots pass a seeded one.
  final math.Random? random;

  @override
  State<SpinWheel> createState() => SpinWheelState();
}

class SpinWheelState extends State<SpinWheel> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final math.Random _random = widget.random ?? math.Random();

  /// Rotation in degrees, clockwise, accumulated over every spin.
  final angle = ValueNotifier<double>(0);

  /// The pointer's lean in degrees (negative = its tip pushed right).
  final pointer = ValueNotifier<double>(0);

  /// 0–1: how far the slices other than the winner have faded.
  final picked = ValueNotifier<double>(0);
  int? _pickedSlot;

  late List<Project> _segments = wheelSegments(widget.ideas);
  List<_Label> _labels = const [];
  double _labelsFor = -1;

  SpinPlan? _plan;
  Project? _winner;
  Duration _planStart = Duration.zero;
  Duration _last = Duration.zero;
  double _pointerSpeed = 0;
  int? _lastPeg;
  int _lastHaptic = -1000;
  bool _dragging = false;
  double? _dragAngle;

  bool get spinning => _plan != null;
  double get _slice => _segments.isEmpty ? 360 : 360 / _segments.length;

  @override
  void didUpdateWidget(SpinWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The slices stay put during a spin, so it lands where it was aimed.
    if (!spinning && !identical(oldWidget.ideas, widget.ideas)) {
      final next = wheelSegments(widget.ideas);
      if (!_sameSegments(next)) {
        _segments = next;
        _labelsFor = -1;
        _pickedSlot = null;
        picked.value = 0;
      }
    }
    // Asked for while the page rebuilds: start once this frame is done.
    if (oldWidget.spinSignal != widget.spinSignal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) spin();
      });
    }
  }

  bool _sameSegments(List<Project> next) {
    if (next.length != _segments.length) return false;
    for (var i = 0; i < next.length; i++) {
      if (next[i].id != _segments[i].id || next[i].name != _segments[i].name) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _ticker.dispose();
    angle.dispose();
    pointer.dispose();
    picked.dispose();
    super.dispose();
  }

  // ---------- spinning ----------

  /// The winner, then the rotation that puts a random point of one of its slices under the
  /// pointer (src/Wheel.jsx spin).
  ({Project winner, int slot, double target}) _aim() {
    final pool = widget.ideas;
    final winner = pool[_random.nextInt(pool.length)];
    final slots = [
      for (var i = 0; i < _segments.length; i++)
        if (_segments[i].id == winner.id) i,
    ];
    final slot = slots[_random.nextInt(slots.length)];
    // Not always dead centre, but clear of the edges, so the pointer never comes to rest
    // leaning on one and the pick is never in doubt.
    final offset = (_random.nextDouble() - 0.5) * _slice * 0.56;
    return (winner: winner, slot: slot, target: 360 - ((slot + 0.5) * _slice + offset));
  }

  /// A spin from the button: 5–7 turns after a small wind-up.
  void spin() => _start(null);

  void _start(double? speed) {
    if (spinning || widget.ideas.isEmpty) return;
    _segments = wheelSegments(widget.ideas);
    _labelsFor = -1;
    final aim = _aim();
    _pickedSlot = null;
    picked.value = 0;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _pickedSlot = aim.slot;
      picked.value = 1;
      widget.onResult(aim.winner);
      return;
    }
    final from = angle.value;
    final clockwise = speed == null || speed >= 0;
    final toTarget = clockwise ? ((aim.target - from) % 360 + 360) % 360 : ((from - aim.target) % 360 + 360) % 360;
    SpinPlan plan;
    if (speed == null) {
      final turns = 5 + _random.nextInt(3);
      plan = SpinPlan(from: from, distance: turns * 360 + toTarget, duration: 4.2, k: 3.6, windUp: 10);
    } else {
      final p = SpinPlan.forSpeed(speed.abs(), toTarget);
      plan = SpinPlan(from: from, distance: clockwise ? p.distance : -p.distance, duration: p.duration, k: p.k);
    }
    _plan = plan;
    _winner = aim.winner;
    _pickedSlot = aim.slot;
    _planStart = _last;
    widget.onSpinning?.call(true);
    if (widget.haptics && speed == null) HapticFeedback.lightImpact();
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _planStart = Duration.zero;
      _ticker.start();
    }
    setState(() {});
  }

  void _land() {
    final winner = _winner!;
    _plan = null;
    _winner = null;
    if (widget.haptics) HapticFeedback.heavyImpact();
    widget.onSpinning?.call(false);
    setState(() {});
    Future<void>.delayed(const Duration(milliseconds: 280), () {
      if (mounted) widget.onResult(winner);
    });
  }

  void _tick(Duration now) {
    final dt = ((now - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = now;
    final plan = _plan;
    if (plan != null) {
      final s = (now - _planStart).inMicroseconds / 1e6;
      angle.value = plan.angleAt(s);
      if (s >= plan.total) {
        angle.value = plan.angleAt(plan.total);
        _land();
      }
    }
    if (_pickedSlot != null && _plan == null && picked.value < 1) {
      picked.value = math.min(1, picked.value + dt / 0.22);
    }
    _stepPointer(dt);
    if (_plan == null &&
        !_dragging &&
        pointer.value.abs() < 0.05 &&
        _pointerSpeed.abs() < 1 &&
        picked.value >= (_pickedSlot == null ? 0 : 1)) {
      pointer.value = 0;
      _ticker.stop();
    }
  }

  /// The pointer is a sprung clapper: a slice edge coming towards it pushes its tip aside, and
  /// once the edge has passed it springs back.
  void _stepPointer(double dt) {
    if (_segments.isEmpty) return;
    final slice = _slice;
    final a = ((-angle.value) % 360 + 360) % 360;
    final peg = (a / slice).floor();
    // How far the nearest edge is from the pointer on each side, in degrees.
    final behind = a - peg * slice; // the edge a clockwise turn brings in
    final ahead = (peg + 1) * slice - a; // the edge an anticlockwise turn brings in
    const maxLean = 18.0;
    final contact = math.min(8.0, slice * 0.2);
    var push = 0.0;
    if (behind < contact) push = -maxLean * (1 - behind / contact);
    if (ahead < contact) push = maxLean * (1 - ahead / contact);

    // A damped spring back to rest, in small steps so it stays stable.
    const omega = 55.0, zeta = 0.42;
    var p = pointer.value, v = _pointerSpeed;
    const steps = 4;
    for (var i = 0; i < steps; i++) {
      final h = dt / steps;
      final acc = -omega * omega * p - 2 * zeta * omega * v;
      v += acc * h;
      p += v * h;
    }
    if ((push < 0 && p > push) || (push > 0 && p < push)) {
      p = push;
      v = 0;
    }
    pointer.value = p;
    _pointerSpeed = v;

    if (_lastPeg != null && peg != _lastPeg && (_plan != null || _dragging)) {
      final ms = DateTime.now().millisecondsSinceEpoch;
      if (widget.haptics && ms - _lastHaptic >= 40) {
        _lastHaptic = ms;
        HapticFeedback.selectionClick();
      }
    }
    _lastPeg = peg;
  }

  // ---------- touch ----------

  Offset _centre(Size size) {
    final s = _scale(size);
    return Offset(size.width / 2, _cy * s + (size.height - _h * s) / 2);
  }

  double _scale(Size size) => math.min(size.width / _w, size.height / _h);

  void _panStart(DragStartDetails d, Size size) {
    if (spinning || widget.ideas.isEmpty) return;
    _dragging = true;
    _pickedSlot = null;
    picked.value = 0;
    final c = _centre(size);
    _dragAngle = math.atan2(d.localPosition.dy - c.dy, d.localPosition.dx - c.dx);
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _panUpdate(DragUpdateDetails d, Size size) {
    if (!_dragging) return;
    final c = _centre(size);
    final a = math.atan2(d.localPosition.dy - c.dy, d.localPosition.dx - c.dx);
    var delta = a - _dragAngle!;
    if (delta > math.pi) delta -= 2 * math.pi;
    if (delta < -math.pi) delta += 2 * math.pi;
    // Near the hub a small move is a big angle: let it count less there.
    final reach = ((d.localPosition - c).distance / (_r * _scale(size))).clamp(0.0, 1.0);
    angle.value += delta * 180 / math.pi * math.min(1, reach * 2.5);
    _dragAngle = a;
  }

  void _panEnd(DragEndDetails d, Size size) {
    if (!_dragging) return;
    _dragging = false;
    final c = _centre(size);
    final r = d.localPosition - c;
    final v = d.velocity.pixelsPerSecond;
    final r2 = math.max(r.distanceSquared, 400.0);
    final degPerSecond = (r.dx * v.dy - r.dy * v.dx) / r2 * 180 / math.pi;
    if (degPerSecond.abs() >= 240) _start(degPerSecond.clamp(-3200, 3200));
  }

  // ---------- drawing ----------

  void _layoutLabels(double fontSize, double scale, Color ink) {
    final key = fontSize * 1000 + _segments.length + scale;
    if (key == _labelsFor) return;
    _labelsFor = key;
    if (_segments.length > _maxLabelled) {
      _labels = const [];
      return;
    }
    final style = TextStyle(
      fontFamily: whirlSans,
      fontFamilyFallback: const ['DMSansExt'],
      fontSize: fontSize * scale,
      fontWeight: FontWeight.w500,
      fontVariations: const [FontVariation.weight(500)],
      color: ink,
    );
    _labels = [
      for (final s in _segments)
        _Label(
          TextPainter(
            text: TextSpan(text: s.name, style: style),
            textDirection: TextDirection.ltr,
            maxLines: 1,
            ellipsis: '…',
          )..layout(maxWidth: _labelRoom * scale),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final w = context.whirl;
    final n = widget.ideas.length;
    return Semantics(
      label: 'Wheel with $n ${n == 1 ? 'idea' : 'ideas'}',
      button: n > 0,
      onTap: n > 0 ? spin : null,
      excludeSemantics: true,
      child: AspectRatio(
        aspectRatio: _w / _h,
        child: LayoutBuilder(
          builder: (context, box) {
            final size = box.biggest;
            final scale = _scale(size);
            final fontSize = _segments.length > 12 ? 34.0 : (_segments.length > 8 ? 38.0 : 42.0);
            _layoutLabels(fontSize, scale, w.onStatus);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: n > 0 ? spin : null,
              onPanStart: (d) => _panStart(d, size),
              onPanUpdate: (d) => _panUpdate(d, size),
              onPanEnd: (d) => _panEnd(d, size),
              onPanCancel: () => _dragging = false,
              child: RepaintBoundary(
                child: CustomPaint(
                  size: size,
                  painter: _WheelPainter(
                    state: this,
                    segments: n == 0 ? const [] : _segments,
                    labels: n == 0 ? const [] : _labels,
                    colors: w,
                    bg: t.bg,
                    disc: t.surfaceSunken,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Label {
  const _Label(this.painter);
  final TextPainter painter;
}

class _WheelPainter extends CustomPainter {
  _WheelPainter({
    required this.state,
    required this.segments,
    required this.labels,
    required this.colors,
    required this.bg,
    required this.disc,
  }) : super(repaint: Listenable.merge([state.angle, state.pointer, state.picked]));

  final SpinWheelState state;
  final List<Project> segments;
  final List<_Label> labels;
  final WhirlColors colors;
  final Color bg, disc;

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width / _w, size.height / _h);
    canvas.save();
    canvas.translate((size.width - _w * s) / 2, (size.height - _h * s) / 2);
    canvas.scale(s);
    const centre = Offset(_cx, _cy);

    if (segments.isEmpty) {
      canvas.drawCircle(centre, _r, Paint()..color = disc);
      canvas.restore();
      return;
    }

    final n = segments.length;
    final slice = 2 * math.pi / n;
    final picked = state._pickedSlot;
    final fade = state.picked.value;
    canvas.save();
    canvas.translate(_cx, _cy);
    canvas.rotate(state.angle.value * math.pi / 180);
    final rect = Rect.fromCircle(center: Offset.zero, radius: _r);
    for (var i = 0; i < n; i++) {
      final dim = picked != null && picked != i ? 1 - 0.75 * fade : 1.0;
      final path = Path()
        ..moveTo(0, 0)
        ..arcTo(rect, -math.pi / 2 + i * slice, slice, false)
        ..close();
      canvas.drawPath(path, Paint()..color = colors.slice(i, n).withValues(alpha: dim));
    }
    // The bg-coloured lines between slices (stroke: var(--bg)).
    final line = Paint()
      ..color = bg
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < n; i++) {
      final a = -math.pi / 2 + i * slice;
      canvas.drawLine(Offset.zero, Offset(math.cos(a) * _r, math.sin(a) * _r), line);
    }
    // Labels run along the radius and end near the rim.
    for (var i = 0; i < labels.length; i++) {
      final tp = labels[i].painter;
      canvas.save();
      canvas.rotate(-math.pi / 2 + (i + 0.5) * slice);
      canvas.scale(1 / s);
      tp.paint(canvas, Offset((_r - 28) * s - tp.width, -tp.height / 2));
      canvas.restore();
    }
    canvas.restore();

    canvas.drawCircle(centre, _hub, Paint()..color = colors.pointer);

    // The pointer, hinged at its top edge.
    canvas.save();
    canvas.translate(_cx, 20);
    canvas.rotate(state.pointer.value * math.pi / 180);
    canvas.translate(-_cx, -20);
    canvas.drawPath(
      Path()
        ..moveTo(_cx - 42, 8)
        ..lineTo(_cx + 42, 8)
        ..lineTo(_cx, _cy - _r + 30)
        ..close(),
      Paint()..color = colors.pointer,
    );
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WheelPainter old) =>
      old.segments != segments || old.labels != labels || old.colors != colors || old.bg != bg || old.disc != disc;
}
