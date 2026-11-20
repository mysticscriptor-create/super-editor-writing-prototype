import 'dart:math' as math;

import 'package:flutter/material.dart';
// ignore: implementation_imports
import 'package:super_editor/src/infrastructure/platforms/android/selection_handles.dart';
import 'package:super_editor/super_editor.dart';

import 'authoritative_scroll.dart';
import 'deletion_geometry.dart';
import 'split_seam_content_layers.dart';
import 'virtualized_document_layout.dart';

/// Diagnostic summary of the most recent deletion transaction (for verification & inspection).
class LastDeletionReport {
  const LastDeletionReport({
    required this.scenario,
    required this.u,
    required this.l,
    required this.t,
    required this.preScroll,
    required this.finalScroll,
    required this.topSpacer,
    required this.bottomSpacer,
    required this.durationMs,
  });

  final DeletionScenario scenario;
  final bool u;
  final bool l;
  final bool t;
  final double preScroll;
  final double finalScroll;
  final double topSpacer;
  final double bottomSpacer;
  final int durationMs;
}

/// Authoritative coordinator for all selection-deletion routes (Android handles +
/// Gboard Backspace, toolbar Delete, and hardware keyboard Delete/Backspace).
class DeletionCoordinator extends ChangeNotifier {
  DeletionCoordinator({
    required TickerProvider vsync,
    required this.editor,
    required this.document,
    required this.composer,
    required this.scrollController,
    required this.metricsIndex,
    required this.getDocumentLayout,
    required this.viewportKey,
    required this.getControlsController,
    required this.splitState,
  }) {
    _animController = AnimationController(vsync: vsync)
      ..addListener(_onAnimationTick)
      ..addStatusListener(_onAnimationStatus);
  }

  final Editor editor;
  final MutableDocument document;
  final MutableDocumentComposer composer;
  final AuthoritativeScrollController scrollController;
  final DocumentMetricsIndex metricsIndex;
  final DocumentLayout? Function() getDocumentLayout;
  final GlobalKey viewportKey;
  final SuperEditorAndroidControlsController? Function() getControlsController;
  final SplitSeamRenderState splitState;

  late final AnimationController _animController;

  double _topSpacer = 0.0;
  double _bottomSpacer = 0.0;
  double get topSpacer => _topSpacer;
  double get bottomSpacer => _bottomSpacer;

  SplitSeamAnimationPlan? _activeSplitPlan;
  GlideAnimationPlan? _activeGlidePlan;
  CurvedAnimation? _activeCurve;
  bool _isMutating = false;

  GlobalKey? _upstreamHandleKey;
  GlobalKey? _downstreamHandleKey;

  void attachHandleKeys({required GlobalKey upstream, required GlobalKey downstream}) {
    _upstreamHandleKey = upstream;
    _downstreamHandleKey = downstream;
  }

  void detachHandleKeys() {
    _upstreamHandleKey = null;
    _downstreamHandleKey = null;
  }

  LastDeletionReport? _lastReport;
  LastDeletionReport? get lastReport => _lastReport;

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  /// Called when the user physically drags/scrolls the document:
  /// yields any active Scenario E glide immediately, and smoothly absorbs
  /// boundary spacers back to 0 when the user scrolls away from clamped boundaries.
  void handleUserScrollStarted() {
    if (_activeGlidePlan != null && _animController.isAnimating) {
      _finishAllAnimations(snapToEnd: false);
    }
  }

  /// Smoothly consumes any temporary boundary spacers as the user scrolls naturally.
  void absorbSpacersOnScroll() {
    if (_activeSplitPlan != null || _activeGlidePlan != null) {
      return;
    }
    final pos = scrollController.authoritativePosition;
    if (pos == null) return;

    bool changed = false;
    if (_topSpacer > 0.0 && pos.pixels > 0.0) {
      final absorbed = math.min(_topSpacer, pos.pixels);
      _topSpacer -= absorbed;
      pos.authoritativeJumpTo(pos.pixels - absorbed);
      changed = true;
    }
    if (_bottomSpacer > 0.0) {
      final baseMax = _computePostBaseMaxScroll(pos.viewportDimension);
      final targetBottom = math.max(0.0, pos.pixels - baseMax);
      if (targetBottom < _bottomSpacer - 0.5) {
        _bottomSpacer = targetBottom;
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  /// Collapses topSpacer when the user drags downward (overscroll < 0) at scroll = 0.
  void handleTopOverscroll(double overscroll) {
    if (_activeSplitPlan != null || _activeGlidePlan != null) return;
    if (_topSpacer > 0.0 && overscroll < 0.0) {
      _topSpacer = math.max(0.0, _topSpacer + overscroll);
      notifyListeners();
    }
  }

  double _computePostBaseMaxScroll(double viewportHeight) {
    final bottomPad = metricsIndex.stylesheet.documentPadding?.bottom ?? 0.0;
    return math.max(0.0, metricsIndex.totalHeight + bottomPad - viewportHeight);
  }

  Rect? _getUsableViewportRectGlobal() {
    final ctx = viewportKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Rect? _getActualHandleRectVp(GlobalKey key, Rect usableViewportGlobal) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return null;
    // AndroidSelectionHandle adds defaultTouchRegionExpansion padding around the 20x20 visual teardrop.
    final fullGlobal = box.localToGlobal(Offset.zero) & box.size;
    final pad = AndroidSelectionHandle.defaultTouchRegionExpansion;
    final visualGlobal = Rect.fromLTRB(
      fullGlobal.left + pad.left,
      fullGlobal.top + pad.top,
      fullGlobal.right - pad.right,
      fullGlobal.bottom - pad.bottom,
    );
    return visualGlobal.translate(-usableViewportGlobal.left, -usableViewportGlobal.top);
  }

  /// Single authoritative deletion transaction invoked by ALL deletion routes.
  /// Returns `true` if an expanded selection was captured and deleted.
  bool requestAuthoritativeDeleteSelection({
    TextAffinity affinity = TextAffinity.upstream,
  }) {
    if (_isMutating) return false;
    final selection = composer.selection;
    if (selection == null || selection.isCollapsed) {
      return false;
    }

    final docLayout = getDocumentLayout();
    final scrollPos = scrollController.authoritativePosition;
    final usableViewportGlobal = _getUsableViewportRectGlobal();
    if (docLayout == null || scrollPos == null || usableViewportGlobal == null) {
      // Fallback: still execute single deletion safely if layout isn't mounted yet.
      editor.execute([
        const ClearComposingRegionRequest(),
        DeleteSelectionRequest(affinity),
      ]);
      return true;
    }

    // Finish any prior in-flight deletion animation cleanly before capturing fresh state.
    if (_animController.isAnimating || _activeSplitPlan != null || _activeGlidePlan != null) {
      _finishAllAnimations(snapToEnd: true);
    }

    // 1. Capture ALL pre-deletion geometry strictly BEFORE mutating the document.
    final upstreamPos = document.selectUpstreamPosition(selection.base, selection.extent);
    final downstreamPos = document.selectDownstreamPosition(selection.base, selection.extent);

    final upstreamIdx = metricsIndex.indexOfNodeId(upstreamPos.nodeId);
    final downstreamIdx = metricsIndex.indexOfNodeId(downstreamPos.nodeId);
    if (upstreamIdx != null) metricsIndex.ensureExactMeasured(upstreamIdx);
    if (downstreamIdx != null) metricsIndex.ensureExactMeasured(downstreamIdx);

    final upstreamRectDoc = docLayout.getRectForPosition(upstreamPos);
    final downstreamRectDoc = docLayout.getRectForPosition(downstreamPos);
    if (upstreamRectDoc == null || downstreamRectDoc == null) {
      editor.execute([
        const ClearComposingRegionRequest(),
        DeleteSelectionRequest(affinity),
      ]);
      return true;
    }

    final selectionRectDoc = docLayout.getRectForSelection(upstreamPos, downstreamPos) ??
        upstreamRectDoc.expandToInclude(downstreamRectDoc);

    final preScroll = scrollPos.pixels;
    final preTopSpacer = _topSpacer;
    final preBottomSpacer = _bottomSpacer;
    final vpShift = preTopSpacer - preScroll;

    final usableViewportLocal = Offset.zero & usableViewportGlobal.size;
    final upstreamRectVp = upstreamRectDoc.translate(0.0, vpShift);
    final downstreamRectVp = downstreamRectDoc.translate(0.0, vpShift);
    final selectionRectVp = selectionRectDoc.translate(0.0, vpShift);

    final actualUpstreamHandleVp = _upstreamHandleKey != null
        ? _getActualHandleRectVp(_upstreamHandleKey!, usableViewportGlobal)
        : null;
    final actualDownstreamHandleVp = _downstreamHandleKey != null
        ? _getActualHandleRectVp(_downstreamHandleKey!, usableViewportGlobal)
        : null;

    final classification = classifyDeletionGeometry(
      usableViewportLocal: usableViewportLocal,
      upstreamRectVp: upstreamRectVp,
      downstreamRectVp: downstreamRectVp,
      selectionRectVp: selectionRectVp,
      actualUpstreamHandleVp: actualUpstreamHandleVp,
      actualDownstreamHandleVp: actualDownstreamHandleVp,
    );

    final snapshot = DeletionSnapshot(
      usableViewportRectGlobal: usableViewportGlobal,
      preScroll: preScroll,
      preMinScroll: scrollPos.minScrollExtent,
      preMaxScroll: scrollPos.maxScrollExtent,
      preTopSpacer: preTopSpacer,
      preBottomSpacer: preBottomSpacer,
      upstreamRectDoc: upstreamRectDoc,
      downstreamRectDoc: downstreamRectDoc,
      selectionRectDoc: selectionRectDoc,
      upstreamHandleVisible: classification.u,
      downstreamHandleVisible: classification.l,
      selectionIntersectsViewport: classification.t,
      scenario: classification.scenario,
    );

    // 2. Lock out competing scroll/auto-scroll & background layout shifts.
    metricsIndex.setPauseBackgroundMeasurement(true);
    scrollPos.suppressCompetingScrolls = true;
    final controls = getControlsController();
    if (controls != null) {
      controls
        ..hideExpandedHandles()
        ..hideCollapsedHandle()
        ..hideMagnifier()
        ..hideToolbar();
    }

    // 3. Mutate the document EXACTLY ONCE via SuperEditor's Editor pipeline.
    _isMutating = true;
    try {
      editor.execute([
        const ClearComposingRegionRequest(),
        DeleteSelectionRequest(affinity),
      ]);
    } finally {
      _isMutating = false;
    }

    final postSel = composer.selection;
    if (postSel == null) {
      scrollPos.suppressCompetingScrolls = false;
      metricsIndex.setPauseBackgroundMeasurement(false);
      return true;
    }

    // Ensure metrics are exact up to the resulting caret node so document-Y and
    // postBaseMaxScroll reflect the exact mutated document layout.
    final postNodeIdx = metricsIndex.indexOfNodeId(postSel.extent.nodeId);
    if (postNodeIdx != null) {
      metricsIndex.ensureExactUpTo(postNodeIdx);
    }
    final postCaretRectDoc = docLayout.getRectForPosition(postSel.extent) ??
        metricsIndex.getOffscreenRectForPosition(postSel.extent);
    final postBaseMaxScroll = _computePostBaseMaxScroll(usableViewportGlobal.height);

    // 4. Route to Scenarios A-D (single-clock split rendering) or Scenario E (continuous glide).
    if (snapshot.scenario != DeletionScenario.E) {
      final plan = buildSplitSeamPlan(
        snapshot: snapshot,
        postCaretRectDoc: postCaretRectDoc,
        postBaseMaxScroll: postBaseMaxScroll,
      );
      _activeSplitPlan = plan;
      _activeGlidePlan = null;
      _topSpacer = plan.finalTopSpacer;
      _bottomSpacer = plan.finalBottomSpacer;

      // Jump scroll offset to plan.finalScrollOffset immediately (or as far as
      // current maxScrollExtent permits, finalized right after sliver layout).
      scrollPos.authoritativeJumpTo(plan.finalScrollOffset);

      final durationMs = snapshot.scenario == DeletionScenario.D ? 300 : 260;
      _lastReport = LastDeletionReport(
        scenario: snapshot.scenario,
        u: snapshot.upstreamHandleVisible,
        l: snapshot.downstreamHandleVisible,
        t: snapshot.selectionIntersectsViewport,
        preScroll: snapshot.preScroll,
        finalScroll: plan.finalScrollOffset,
        topSpacer: plan.finalTopSpacer,
        bottomSpacer: plan.finalBottomSpacer,
        durationMs: durationMs,
      );

      _applySplitAtProgress(0.0);
      notifyListeners();

      _activeCurve = CurvedAnimation(
        parent: _animController,
        curve: Curves.easeOutCubic,
      );
      _animController.duration = Duration(milliseconds: durationMs);
      _animController.forward(from: 0.0);

      // Re-apply authoritativeJumpTo on the post-build microtask in case
      // bottomSpacer increased maxScrollExtent on this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_activeSplitPlan == plan && scrollPos.hasPixels) {
          scrollPos.authoritativeJumpTo(plan.finalScrollOffset);
          _applySplitAtProgress(_activeCurve?.value ?? _animController.value);
        }
      });
    } else {
      splitState.clear();
      final glide = buildScenarioEGlidePlan(
        snapshot: snapshot,
        postCaretRectDoc: postCaretRectDoc,
        postBaseMaxScroll: postBaseMaxScroll,
      );
      _activeSplitPlan = null;
      _activeGlidePlan = glide;
      _topSpacer = glide.initialTopSpacer;
      _bottomSpacer = glide.initialBottomSpacer;

      scrollPos.authoritativeJumpTo(glide.initialScrollOffset);

      final distance = (glide.targetScrollOffset - glide.initialScrollOffset).abs();
      final durationMs = (320 + (distance / 12.0)).clamp(320, 650).round();
      _lastReport = LastDeletionReport(
        scenario: DeletionScenario.E,
        u: snapshot.upstreamHandleVisible,
        l: snapshot.downstreamHandleVisible,
        t: snapshot.selectionIntersectsViewport,
        preScroll: snapshot.preScroll,
        finalScroll: glide.targetScrollOffset,
        topSpacer: glide.initialTopSpacer,
        bottomSpacer: glide.initialBottomSpacer,
        durationMs: durationMs,
      );

      notifyListeners();

      _activeCurve = CurvedAnimation(
        parent: _animController,
        curve: Curves.easeInOutCubic,
      );
      _animController.duration = Duration(milliseconds: durationMs);
      _animController.forward(from: 0.0);
    }

    return true;
  }

  void _applySplitAtProgress(double easedProgress) {
    final plan = _activeSplitPlan;
    final pos = scrollController.authoritativePosition;
    if (plan == null || pos == null) return;

    // Evaluate against actual live scrollPos.pixels and _topSpacer so even if
    // maxScrollExtent adjusts during frame 0 layout, screen positions have 0 jump.
    final liveScroll = pos.pixels;
    final p = easedProgress.clamp(0.0, 1.0);
    final upperTargetVpY = lerpDoubleSafe(plan.upperStartVpY, plan.upperEndVpY, p);
    final lowerTargetVpY = lerpDoubleSafe(plan.lowerStartVpY, plan.lowerEndVpY, p);

    final upperLiveNaturalVpY = _topSpacer + plan.anchorDocYForUpper - liveScroll;
    final lowerLiveNaturalVpY = _topSpacer + plan.anchorDocYForLower - liveScroll;

    splitState.updateSplit(
      seamSplitDocY: plan.seamSplitDocY,
      upperTranslateY: upperTargetVpY - upperLiveNaturalVpY,
      lowerTranslateY: lowerTargetVpY - lowerLiveNaturalVpY,
    );
  }

  void _onAnimationTick() {
    final eased = _activeCurve?.value ?? _animController.value;
    if (_activeSplitPlan != null) {
      final pos = scrollController.authoritativePosition;
      if (pos != null && (pos.pixels - _activeSplitPlan!.finalScrollOffset).abs() > 0.5) {
        pos.authoritativeJumpTo(_activeSplitPlan!.finalScrollOffset);
      }
      _applySplitAtProgress(eased);
    } else if (_activeGlidePlan != null) {
      final pos = scrollController.authoritativePosition;
      if (pos != null) {
        pos.authoritativeJumpTo(_activeGlidePlan!.evaluateScroll(eased));
      }
    }
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
      _finishAllAnimations(snapToEnd: true);
    }
  }

  void _finishAllAnimations({required bool snapToEnd}) {
    final splitPlan = _activeSplitPlan;
    final glidePlan = _activeGlidePlan;
    final pos = scrollController.authoritativePosition;

    _animController.stop();
    _activeCurve = null;
    _activeSplitPlan = null;
    _activeGlidePlan = null;

    if (snapToEnd && pos != null) {
      if (splitPlan != null) {
        pos.authoritativeJumpTo(splitPlan.finalScrollOffset);
      } else if (glidePlan != null) {
        pos.authoritativeJumpTo(glidePlan.targetScrollOffset);
      }
    }

    // Remove temporary split transforms ONLY after scroll matches finalScrollOffset,
    // ensuring normal document rendering matches screen-space result with zero jump.
    splitState.clear();
    if (pos != null) {
      pos.suppressCompetingScrolls = false;
    }
    metricsIndex.setPauseBackgroundMeasurement(false);
    notifyListeners();
  }
}

double lerpDoubleSafe(double a, double b, double t) => a + (b - a) * t;
