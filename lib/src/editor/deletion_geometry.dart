import 'dart:math' as math;
import 'dart:ui';

/// The five selection-deletion scenarios defined in the prototype specification.
enum DeletionScenario {
  /// U = true, L = false: Upper stationary, lower moves upward.
  A,

  /// U = false, L = true: Lower stationary, upper moves downward.
  B,

  /// U = true, L = true: Lower stationary, upper moves downward.
  C,

  /// U = false, L = false, T = true: Converge around vertical center of usable viewport.
  D,

  /// U = false, L = false, T = false: Continuous glide toward resulting caret.
  E,
}

/// Pre-deletion snapshot captured strictly BEFORE mutating the document.
class DeletionSnapshot {
  const DeletionSnapshot({
    required this.usableViewportRectGlobal,
    required this.preScroll,
    required this.preMinScroll,
    required this.preMaxScroll,
    required this.preTopSpacer,
    required this.preBottomSpacer,
    required this.upstreamRectDoc,
    required this.downstreamRectDoc,
    required this.selectionRectDoc,
    required this.upstreamHandleVisible,
    required this.downstreamHandleVisible,
    required this.selectionIntersectsViewport,
    required this.scenario,
  });

  final Rect usableViewportRectGlobal;
  final double preScroll;
  final double preMinScroll;
  final double preMaxScroll;
  final double preTopSpacer;
  final double preBottomSpacer;

  /// Document-space line rects for the normalized upstream & downstream endpoints.
  final Rect upstreamRectDoc;
  final Rect downstreamRectDoc;

  /// Document-space bounding rect of the selected text across nodes/wrapped lines.
  final Rect selectionRectDoc;

  final bool upstreamHandleVisible;
  final bool downstreamHandleVisible;
  final bool selectionIntersectsViewport;
  final DeletionScenario scenario;

  double get viewportHeight => usableViewportRectGlobal.height;
  double get viewportWidth => usableViewportRectGlobal.width;

  /// Converts a document-local Y coordinate to viewport-local Y before deletion.
  double docYToPreViewportY(double docY) => preTopSpacer + docY - preScroll;

  double get upstreamTopVp0 => docYToPreViewportY(upstreamRectDoc.top);
  double get upstreamBottomVp0 => docYToPreViewportY(upstreamRectDoc.bottom);
  double get downstreamTopVp0 => docYToPreViewportY(downstreamRectDoc.top);
  double get downstreamBottomVp0 => docYToPreViewportY(downstreamRectDoc.bottom);
}

/// Visual handle dimensions matching SuperEditor's [AndroidSelectionHandle]
/// (radius = 10 -> 20x20 visual teardrop hanging below the edge anchor).
const double kAndroidHandleVisualSize = 20.0;

/// Computes exact clipped handle visibility (U, L) and selection intersection (T)
/// using viewport-local geometry (excluding app bar, toolbars, and IME insets).
({bool u, bool l, bool t, DeletionScenario scenario}) classifyDeletionGeometry({
  required Rect usableViewportLocal,
  required Rect upstreamRectVp,
  required Rect downstreamRectVp,
  required Rect selectionRectVp,
  Rect? actualUpstreamHandleVp,
  Rect? actualDownstreamHandleVp,
}) {
  final upstreamVisualRect = actualUpstreamHandleVp ??
      Rect.fromLTWH(
        upstreamRectVp.left - kAndroidHandleVisualSize,
        upstreamRectVp.bottom,
        kAndroidHandleVisualSize,
        kAndroidHandleVisualSize,
      );
  final downstreamVisualRect = actualDownstreamHandleVp ??
      Rect.fromLTWH(
        downstreamRectVp.right,
        downstreamRectVp.bottom,
        kAndroidHandleVisualSize,
        kAndroidHandleVisualSize,
      );

  final uClipped = upstreamVisualRect.intersect(usableViewportLocal);
  final lClipped = downstreamVisualRect.intersect(usableViewportLocal);

  // Require >= 2px overlap in both axes so hairline edge rounding does not
  // misclassify an offscreen handle as visible.
  final bool u = !uClipped.isEmpty && uClipped.width >= 2.0 && uClipped.height >= 2.0;
  final bool l = !lClipped.isEmpty && lClipped.width >= 2.0 && lClipped.height >= 2.0;

  final selClipped = selectionRectVp.intersect(usableViewportLocal);
  final bool t = !selClipped.isEmpty && selClipped.height >= 1.0 && selClipped.width >= 1.0;

  final DeletionScenario scenario;
  if (u && !l) {
    scenario = DeletionScenario.A;
  } else if (!u && l) {
    scenario = DeletionScenario.B;
  } else if (u && l) {
    scenario = DeletionScenario.C;
  } else if (t) {
    scenario = DeletionScenario.D;
  } else {
    scenario = DeletionScenario.E;
  }

  return (u: u, l: l, t: t, scenario: scenario);
}

/// Immutable plan for Scenarios A-D driven by a single authoritative progress `p in [0, 1]`.
class SplitSeamAnimationPlan {
  const SplitSeamAnimationPlan({
    required this.scenario,
    required this.seamSplitDocY,
    required this.finalScrollOffset,
    required this.finalTopSpacer,
    required this.finalBottomSpacer,
    required this.upperStartVpY,
    required this.upperEndVpY,
    required this.lowerStartVpY,
    required this.lowerEndVpY,
    required this.anchorDocYForUpper,
    required this.anchorDocYForLower,
  });

  final DeletionScenario scenario;

  /// Document Y dividing upper surviving content from lower surviving content.
  final double seamSplitDocY;

  /// Physical scroll offset applied during and at completion of the animation.
  final double finalScrollOffset;

  /// Boundary spacers preserving stationary anchors & center convergence when
  /// physical scroll clamping would otherwise shift the document.
  final double finalTopSpacer;
  final double finalBottomSpacer;

  final double upperStartVpY;
  final double upperEndVpY;
  final double lowerStartVpY;
  final double lowerEndVpY;

  final double anchorDocYForUpper;
  final double anchorDocYForLower;

  /// Computes the natural viewport Y of [docY] when scrolled to [finalScrollOffset]
  /// with [finalTopSpacer].
  double naturalVpY(double docY) => finalTopSpacer + docY - finalScrollOffset;

  /// Evaluates both region vertical translations from the single progress [easedProgress].
  ({double upperTranslateY, double lowerTranslateY}) evaluateAt(double easedProgress) {
    final p = easedProgress.clamp(0.0, 1.0);
    final upperCurrentVpY = lerpDouble(upperStartVpY, upperEndVpY, p)!;
    final lowerCurrentVpY = lerpDouble(lowerStartVpY, lowerEndVpY, p)!;

    final upperTranslateY = upperCurrentVpY - naturalVpY(anchorDocYForUpper);
    final lowerTranslateY = lowerCurrentVpY - naturalVpY(anchorDocYForLower);
    return (upperTranslateY: upperTranslateY, lowerTranslateY: lowerTranslateY);
  }
}

/// Immutable plan for Scenario E (continuous document-level glide, no split rendering).
class GlideAnimationPlan {
  const GlideAnimationPlan({
    required this.initialScrollOffset,
    required this.targetScrollOffset,
    required this.initialTopSpacer,
    required this.initialBottomSpacer,
  });

  final double initialScrollOffset;
  final double targetScrollOffset;
  final double initialTopSpacer;
  final double initialBottomSpacer;

  double evaluateScroll(double easedProgress) {
    return lerpDouble(initialScrollOffset, targetScrollOffset, easedProgress.clamp(0.0, 1.0))!;
  }
}

/// Computes the authoritative animation plan after the single-shot deletion mutation
/// has produced [postCaretRectDoc] and [postBaseMaxScroll] (without artificial spacers).
SplitSeamAnimationPlan buildSplitSeamPlan({
  required DeletionSnapshot snapshot,
  required Rect postCaretRectDoc,
  required double postBaseMaxScroll,
}) {
  final vh = math.max(1.0, snapshot.viewportHeight);
  final sTop = postCaretRectDoc.top;
  final sBottom = postCaretRectDoc.bottom;
  final sHeight = math.max(1.0, postCaretRectDoc.height);

  late final double desiredSeamTopVpY;
  late final double seamSplitDocY;
  late final double upperStartVpY;
  late final double upperEndVpY;
  late final double lowerStartVpY;
  late final double lowerEndVpY;
  late final double anchorDocYForUpper;
  late final double anchorDocYForLower;

  switch (snapshot.scenario) {
    case DeletionScenario.A:
      // Upper stationary at its pre-deletion screen Y; lower slides up until gap closes.
      desiredSeamTopVpY = snapshot.upstreamTopVp0;
      seamSplitDocY = sBottom;
      anchorDocYForUpper = sTop;
      anchorDocYForLower = sBottom;
      upperStartVpY = desiredSeamTopVpY;
      upperEndVpY = desiredSeamTopVpY;
      // Lower content was below viewport (L=false); clamp huge offscreen starts
      // so the closing motion enters smoothly within the animation duration.
      lowerStartVpY = math.max(
        desiredSeamTopVpY + sHeight,
        math.min(snapshot.downstreamBottomVp0, vh * 1.25),
      );
      lowerEndVpY = desiredSeamTopVpY + sHeight;
      break;

    case DeletionScenario.B:
      // Lower stationary at its pre-deletion screen Y; upper slides down to meet it.
      desiredSeamTopVpY = snapshot.downstreamTopVp0;
      seamSplitDocY = sTop;
      anchorDocYForUpper = sTop;
      anchorDocYForLower = sTop;
      upperStartVpY = math.min(
        desiredSeamTopVpY,
        math.max(snapshot.upstreamTopVp0, -vh * 0.25),
      );
      upperEndVpY = desiredSeamTopVpY;
      lowerStartVpY = desiredSeamTopVpY;
      lowerEndVpY = desiredSeamTopVpY;
      break;

    case DeletionScenario.C:
      // Both handles visible: lower stationary, upper moves smoothly downward.
      desiredSeamTopVpY = snapshot.downstreamTopVp0;
      seamSplitDocY = sTop;
      anchorDocYForUpper = sTop;
      anchorDocYForLower = sTop;
      upperStartVpY = math.min(desiredSeamTopVpY, snapshot.upstreamTopVp0);
      upperEndVpY = desiredSeamTopVpY;
      lowerStartVpY = desiredSeamTopVpY;
      lowerEndVpY = desiredSeamTopVpY;
      break;

    case DeletionScenario.D:
      // Converge upper & lower around exact vertical center of usable editor viewport.
      final centerVpY = vh / 2.0;
      desiredSeamTopVpY = centerVpY - sHeight / 2.0;
      seamSplitDocY = sTop;
      anchorDocYForUpper = sTop;
      anchorDocYForLower = sTop;
      upperStartVpY = math.min(
        desiredSeamTopVpY,
        math.max(snapshot.upstreamBottomVp0, -vh * 0.20),
      );
      upperEndVpY = desiredSeamTopVpY;
      lowerStartVpY = math.max(
        desiredSeamTopVpY,
        math.min(snapshot.downstreamTopVp0, vh * 1.20),
      );
      lowerEndVpY = desiredSeamTopVpY;
      break;

    case DeletionScenario.E:
      throw StateError('buildSplitSeamPlan must not be called for Scenario E');
  }

  // Desired natural scroll offset so that `sTop` naturally rests at `desiredSeamTopVpY`
  // when `topSpacer == 0`:
  //   desiredSeamTopVpY = sTop - idealScroll  =>  idealScroll = sTop - desiredSeamTopVpY
  final idealScroll = sTop - desiredSeamTopVpY;

  double finalTopSpacer = 0.0;
  double finalBottomSpacer = 0.0;
  double finalScrollOffset = idealScroll;

  if (idealScroll < 0.0) {
    // Clamped at top boundary (e.g. Scenario B or D near start of document):
    // Compensate with topSpacer so normal rendering at scroll=0 matches desiredSeamTopVpY.
    finalTopSpacer = -idealScroll;
    finalScrollOffset = 0.0;
  } else if (idealScroll > postBaseMaxScroll) {
    // Clamped at bottom boundary (e.g. Scenario A or D when post-deletion maxScroll shrank):
    // Compensate with bottomSpacer so normal rendering at scroll=idealScroll is valid without jump.
    finalBottomSpacer = idealScroll - postBaseMaxScroll;
    finalScrollOffset = idealScroll;
  }

  return SplitSeamAnimationPlan(
    scenario: snapshot.scenario,
    seamSplitDocY: seamSplitDocY,
    finalScrollOffset: finalScrollOffset,
    finalTopSpacer: finalTopSpacer,
    finalBottomSpacer: finalBottomSpacer,
    upperStartVpY: upperStartVpY,
    upperEndVpY: upperEndVpY,
    lowerStartVpY: lowerStartVpY,
    lowerEndVpY: lowerEndVpY,
    anchorDocYForUpper: anchorDocYForUpper,
    anchorDocYForLower: anchorDocYForLower,
  );
}

/// Computes the continuous glide plan for Scenario E.
GlideAnimationPlan buildScenarioEGlidePlan({
  required DeletionSnapshot snapshot,
  required Rect postCaretRectDoc,
  required double postBaseMaxScroll,
}) {
  final vh = math.max(1.0, snapshot.viewportHeight);
  final deletedWasAboveViewport = snapshot.downstreamRectDoc.bottom < snapshot.preScroll - snapshot.preTopSpacer;

  // Estimate the height removed above the viewport so currently visible content
  // stays rock-solid on frame 0 before gliding smoothly toward the caret.
  final deletedHeightAbove = deletedWasAboveViewport
      ? math.max(0.0, snapshot.downstreamRectDoc.bottom - postCaretRectDoc.bottom)
      : 0.0;

  double initialScroll = snapshot.preScroll - deletedHeightAbove;
  double initialTopSpacer = 0.0;
  double initialBottomSpacer = 0.0;

  if (initialScroll < 0.0) {
    initialScroll = 0.0;
  } else if (initialScroll > postBaseMaxScroll) {
    initialBottomSpacer = initialScroll - postBaseMaxScroll;
  }

  // Target scroll brings the resulting caret comfortably into the usable viewport.
  final targetMaxScroll = math.max(postBaseMaxScroll, initialScroll);
  final targetScroll = (postCaretRectDoc.center.dy - vh * 0.45).clamp(0.0, targetMaxScroll);

  return GlideAnimationPlan(
    initialScrollOffset: initialScroll,
    targetScrollOffset: targetScroll,
    initialTopSpacer: initialTopSpacer,
    initialBottomSpacer: initialBottomSpacer,
  );
}
