import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:kit/kit.dart';
import 'package:material_ui/material_ui.dart';

/// A long press lifts a card on the Board (DESIGN.md §12: hold, then drag).
const liftDelay = Duration(milliseconds: 300);

/// Reports a long press and the finger's travel after it. Before the press is recognised the
/// touch still scrolls and swipes as usual (from Tack's lib/ui/widgets/drag.dart).
class LiftDetector extends StatelessWidget {
  const LiftDetector({
    super.key,
    required this.child,
    required this.onStart,
    required this.onMove,
    required this.onEnd,
    this.enabled = true,
  });

  final Widget child;
  final bool enabled;
  final void Function(Offset global) onStart;
  final void Function(Offset global) onMove;

  /// [cancelled] when the system took the touch away.
  final void Function(bool cancelled) onEnd;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(duration: liftDelay),
          (r) {
            r
              ..onLongPressStart = ((d) => onStart(d.globalPosition))
              ..onLongPressMoveUpdate = ((d) => onMove(d.globalPosition))
              ..onLongPressEnd = ((_) => onEnd(false))
              ..onLongPressCancel = (() => onEnd(true));
          },
        ),
      },
      child: child,
    );
  }
}

/// What follows the finger: the lifted card, scaled up a little and tilted 2°. With reduced
/// motion it has no tilt or scale.
class DragProxy {
  OverlayEntry? _entry;
  final _topLeft = ValueNotifier(Offset.zero);

  bool get showing => _entry != null;

  void show(BuildContext context, {required Rect from, required Widget child}) {
    hide();
    _topLeft.value = from.topLeft;
    final still = MediaQuery.disableAnimationsOf(context);
    final entry = OverlayEntry(
      builder: (context) => ValueListenableBuilder<Offset>(
        valueListenable: _topLeft,
        builder: (context, at, inner) => Positioned(left: at.dx, top: at.dy, width: from.width, child: inner!),
        child: IgnorePointer(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: still ? Duration.zero : Motion.fast,
            curve: Motion.easeOut,
            builder: (context, v, inner) => Transform.rotate(
              angle: still ? 0 : 0.035 * v,
              child: Transform.scale(scale: still ? 1 : 1 + 0.03 * v, child: inner),
            ),
            // A little see-through, so the tab it is over still shows.
            child: Opacity(
              opacity: 0.9,
              child: Material(type: MaterialType.transparency, child: child),
            ),
          ),
        ),
      ),
    );
    _entry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void moveTo(Offset topLeft) => _topLeft.value = topLeft;

  void hide() {
    _entry?.remove();
    _entry = null;
  }
}

/// The box of a keyed widget, in screen coordinates.
Rect? rectOf(GlobalKey key) {
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Scrolls a list while a finger holds a card near its top or bottom edge.
class EdgeScroller {
  Timer? _timer;

  void update(ScrollController? controller, Rect? viewport, Offset pointer) {
    stop();
    if (controller == null || viewport == null || !controller.hasClients) return;
    const edge = 64.0;
    double speed = 0;
    if (pointer.dy < viewport.top + edge) speed = -((viewport.top + edge - pointer.dy) / edge).clamp(0.0, 1.0);
    if (pointer.dy > viewport.bottom - edge) speed = ((pointer.dy - (viewport.bottom - edge)) / edge).clamp(0.0, 1.0);
    if (speed == 0) return;
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!controller.hasClients) return stop();
      final pos = controller.position;
      final next = (pos.pixels + speed * 12).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if (next == pos.pixels) return stop();
      controller.jumpTo(next);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
