import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A [ScrollPositionWithSingleContext] that lets an authoritative animation
/// controller suppress competing jumps/auto-scrolls (e.g. SuperEditor's
/// DragHandleAutoScroller.ensureOffsetIsVisible) during deletion scenarios A-E.
class AuthoritativeScrollPosition extends ScrollPositionWithSingleContext {
  AuthoritativeScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
    this.onUserScrollStarted,
  });

  /// Called when a physical user drag or fling begins so an active glide
  /// animation (Scenario E) can yield cleanly without fighting user touch.
  final VoidCallback? onUserScrollStarted;

  bool suppressCompetingScrolls = false;

  /// Authoritative scroll update used exclusively by our deletion coordinator.
  void authoritativeJumpTo(double value) {
    final clamped = clampDouble(value, minScrollExtent, maxScrollExtent);
    if ((pixels - clamped).abs() < 1e-6) {
      return;
    }
    forcePixels(clamped);
    notifyListeners();
  }

  @override
  void jumpTo(double value) {
    if (suppressCompetingScrolls) {
      return;
    }
    super.jumpTo(value);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) async {
    if (suppressCompetingScrolls) {
      return;
    }
    return super.animateTo(to, duration: duration, curve: curve);
  }

  @override
  Future<void> moveTo(
    double to, {
    Duration? duration,
    Curve? curve,
    bool? clamp = true,
  }) async {
    if (suppressCompetingScrolls) {
      return;
    }
    return super.moveTo(to, duration: duration, curve: curve, clamp: clamp);
  }

  @override
  Drag drag(DragStartDetails details, VoidCallback dragCancelCallback) {
    onUserScrollStarted?.call();
    return super.drag(details, dragCancelCallback);
  }

  @override
  void pointerScroll(double delta) {
    onUserScrollStarted?.call();
    super.pointerScroll(delta);
  }
}

class AuthoritativeScrollController extends ScrollController {
  AuthoritativeScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    this.onUserScrollStarted,
  });

  final VoidCallback? onUserScrollStarted;

  AuthoritativeScrollPosition? get authoritativePosition {
    if (!hasClients) return null;
    final pos = position;
    return pos is AuthoritativeScrollPosition ? pos : null;
  }

  void authoritativeJumpTo(double value) {
    authoritativePosition?.authoritativeJumpTo(value);
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return AuthoritativeScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      onUserScrollStarted: onUserScrollStarted,
    );
  }
}
