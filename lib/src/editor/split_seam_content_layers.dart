import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:super_editor/super_editor.dart';

/// Reactive state controlling GPU split-region rendering during deletion scenarios A-D.
class SplitSeamRenderState extends ChangeNotifier {
  bool _isActive = false;
  double _seamSplitDocY = 0.0;
  double _upperTranslateY = 0.0;
  double _lowerTranslateY = 0.0;

  bool get isActive => _isActive;
  double get seamSplitDocY => _seamSplitDocY;
  double get upperTranslateY => _upperTranslateY;
  double get lowerTranslateY => _lowerTranslateY;

  void updateSplit({
    required double seamSplitDocY,
    required double upperTranslateY,
    required double lowerTranslateY,
  }) {
    _isActive = true;
    _seamSplitDocY = seamSplitDocY;
    _upperTranslateY = upperTranslateY;
    _lowerTranslateY = lowerTranslateY;
    notifyListeners();
  }

  void clear() {
    if (!_isActive && _upperTranslateY == 0.0 && _lowerTranslateY == 0.0) {
      return;
    }
    _isActive = false;
    _seamSplitDocY = 0.0;
    _upperTranslateY = 0.0;
    _lowerTranslateY = 0.0;
    notifyListeners();
  }
}

/// Drop-in replacement for SuperEditor's [SliverContentLayers] that supports
/// single-frame GPU-clipped upper/lower region translations around [SplitSeamRenderState.seamSplitDocY]
/// during deletion animations A-D without re-laying out the document per frame.
class SplitSeamSliverContentLayers extends ContentLayers {
  const SplitSeamSliverContentLayers({
    super.key,
    required this.splitState,
    super.underlays = const [],
    required super.content,
    super.overlays = const [],
  });

  final SplitSeamRenderState splitState;

  @override
  RenderSliverSplitSeamContentLayers createRenderObject(BuildContext context) {
    return RenderSliverSplitSeamContentLayers(
      context as ContentLayersElement,
      splitState: splitState,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverSplitSeamContentLayers renderObject,
  ) {
    renderObject.splitState = splitState;
  }
}

class RenderSliverSplitSeamContentLayers extends RenderSliver
    with RenderSliverHelpers
    implements RenderContentLayers {
  RenderSliverSplitSeamContentLayers(
    this._element, {
    required SplitSeamRenderState splitState,
  }) : _splitState = splitState {
    _splitState.addListener(_onSplitStateChanged);
  }

  SplitSeamRenderState _splitState;
  SplitSeamRenderState get splitState => _splitState;
  set splitState(SplitSeamRenderState value) {
    if (identical(_splitState, value)) return;
    _splitState.removeListener(_onSplitStateChanged);
    _splitState = value;
    _splitState.addListener(_onSplitStateChanged);
    markNeedsPaint();
  }

  void _onSplitStateChanged() {
    markNeedsPaint();
  }

  @override
  void dispose() {
    _splitState.removeListener(_onSplitStateChanged);
    _element = null;
    super.dispose();
  }

  ContentLayersElement? _element;
  final _underlays = <RenderBox>[];
  RenderSliver? _content;
  final _overlays = <RenderBox>[];

  @override
  bool get contentNeedsLayout => _contentNeedsLayout;
  bool _contentNeedsLayout = true;
  bool _runningLayout = false;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    visitChildren((child) => child.attach(owner));
  }

  @override
  void detach() {
    super.detach();
    visitChildren((child) => child.detach());
  }

  @override
  void markNeedsLayout() {
    super.markNeedsLayout();
    if (_runningLayout) {
      return;
    }
    _contentNeedsLayout = true;
  }

  @override
  List<DiagnosticsNode> debugDescribeChildren() {
    final childDiagnostics = <DiagnosticsNode>[];
    if (_content != null) {
      childDiagnostics.add(_content!.toDiagnosticsNode(name: 'content'));
    }
    for (int i = 0; i < _underlays.length; i++) {
      childDiagnostics.add(_underlays[i].toDiagnosticsNode(name: 'underlay-$i'));
    }
    for (int i = 0; i < _overlays.length; i++) {
      childDiagnostics.add(_overlays[i].toDiagnosticsNode(name: 'overlay-$i'));
    }
    return childDiagnostics;
  }

  @override
  void insertChild(RenderObject child, Object slot) {
    assert(isContentLayersSlot(slot));
    if (slot == contentSlot) {
      _content = child as RenderSliver;
    } else if (slot is UnderlaySlot) {
      _underlays.insert(slot.index, child as RenderBox);
    } else if (slot is OverlaySlot) {
      _overlays.insert(slot.index, child as RenderBox);
    }
    adoptChild(child);
  }

  @override
  void moveChildLayer(RenderBox child, Object oldSlot, Object newSlot) {
    if (oldSlot is UnderlaySlot) {
      _underlays.remove(child);
    } else if (oldSlot is OverlaySlot) {
      _overlays.remove(child);
    }
    if (newSlot is UnderlaySlot) {
      _underlays.insert(newSlot.index, child);
    } else if (newSlot is OverlaySlot) {
      _overlays.insert(newSlot.index, child);
    }
  }

  @override
  void removeChild(RenderObject child, Object slot) {
    assert(isContentLayersSlot(slot));
    if (slot == contentSlot) {
      _content = null;
    } else if (slot is UnderlaySlot) {
      _underlays.remove(child);
    } else if (slot is OverlaySlot) {
      _overlays.remove(child);
    }
    dropChild(child);
  }

  @override
  void visitChildren(RenderObjectVisitor visitor) {
    if (_content != null) {
      visitor(_content!);
    }
    for (final child in _underlays) {
      visitor(child);
    }
    for (final child in _overlays) {
      visitor(child);
    }
  }

  @override
  void performLayout() {
    if (_content == null) {
      geometry = SliverGeometry.zero;
      _contentNeedsLayout = false;
      return;
    }

    _runningLayout = true;
    (_content!.parentData! as SliverLogicalParentData).layoutOffset = 0.0;
    _content!.layout(constraints, parentUsesSize: true);

    final sliverLayoutGeometry = _content!.geometry!;
    if (sliverLayoutGeometry.scrollOffsetCorrection != null) {
      geometry = SliverGeometry(
        scrollOffsetCorrection: sliverLayoutGeometry.scrollOffsetCorrection,
      );
      _runningLayout = false;
      return;
    }

    geometry = SliverGeometry(
      scrollExtent: sliverLayoutGeometry.scrollExtent,
      paintExtent: sliverLayoutGeometry.paintExtent,
      maxPaintExtent: sliverLayoutGeometry.maxPaintExtent,
      maxScrollObstructionExtent: sliverLayoutGeometry.maxScrollObstructionExtent,
      cacheExtent: sliverLayoutGeometry.cacheExtent,
      hasVisualOverflow: sliverLayoutGeometry.hasVisualOverflow,
    );
    _contentNeedsLayout = false;

    invokeLayoutCallback((constraints) {
      _element!.owner!.buildScope(_element!, () {
        _element!.buildLayers();
      });
    });

    final layerConstraints = ScrollingBoxConstraints(
      minWidth: constraints.crossAxisExtent,
      maxWidth: constraints.crossAxisExtent,
      minHeight: sliverLayoutGeometry.scrollExtent,
      maxHeight: sliverLayoutGeometry.scrollExtent,
      scrollOffset: constraints.scrollOffset,
    );

    for (final underlay in _underlays) {
      final childParentData = underlay.parentData! as SliverLogicalParentData;
      childParentData.layoutOffset = -constraints.scrollOffset;
      underlay.layout(layerConstraints);
    }
    for (final overlay in _overlays) {
      final childParentData = overlay.parentData! as SliverLogicalParentData;
      childParentData.layoutOffset = -constraints.scrollOffset;
      overlay.layout(layerConstraints);
    }
    _runningLayout = false;
  }

  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    if (_content == null) {
      return false;
    }
    final boxResult = BoxHitTestResult.wrap(result);
    for (final overlay in _overlays) {
      if (hitTestBoxChild(
        boxResult,
        overlay,
        mainAxisPosition: mainAxisPosition,
        crossAxisPosition: crossAxisPosition,
      )) {
        return true;
      }
    }
    if (_content!.hitTest(
      result,
      mainAxisPosition: mainAxisPosition,
      crossAxisPosition: crossAxisPosition,
    )) {
      return true;
    }
    for (final underlay in _underlays) {
      if (hitTestBoxChild(
        boxResult,
        underlay,
        mainAxisPosition: mainAxisPosition,
        crossAxisPosition: crossAxisPosition,
      )) {
        return true;
      }
    }
    return false;
  }

  void _paintAllChildren(PaintingContext context, Offset offset) {
    void paintChild(RenderObject child) {
      final childParentData = child.parentData! as SliverLogicalParentData;
      context.paintChild(
        child,
        offset + Offset(0, childParentData.layoutOffset!),
      );
    }

    for (final underlay in _underlays) {
      paintChild(underlay);
    }
    paintChild(_content!);
    for (final overlay in _overlays) {
      paintChild(overlay);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_content == null) {
      return;
    }

    if (!_splitState.isActive) {
      _paintAllChildren(context, offset);
      return;
    }

    // Document Y = seamSplitDocY maps to paint-space Y = offset.dy + (seamSplitDocY - constraints.scrollOffset).
    final splitPaintY = offset.dy + (_splitState.seamSplitDocY - constraints.scrollOffset);
    final width = constraints.crossAxisExtent;

    // 1. Paint upper surviving region (docY < seamSplitDocY), translated by upperTranslateY.
    context.pushTransform(
      needsCompositing,
      Offset.zero,
      Matrix4.translationValues(0.0, _splitState.upperTranslateY, 0.0),
      (upperContext, upperOffset) {
        upperContext.pushClipRect(
          needsCompositing,
          Offset.zero,
          Rect.fromLTRB(-1000.0, -200000.0, width + 1000.0, splitPaintY),
          (clippedContext, clippedOffset) {
            _paintAllChildren(clippedContext, offset);
          },
        );
      },
    );

    // 2. Paint lower surviving region (docY >= seamSplitDocY), translated by lowerTranslateY.
    context.pushTransform(
      needsCompositing,
      Offset.zero,
      Matrix4.translationValues(0.0, _splitState.lowerTranslateY, 0.0),
      (lowerContext, lowerOffset) {
        lowerContext.pushClipRect(
          needsCompositing,
          Offset.zero,
          Rect.fromLTRB(-1000.0, splitPaintY, width + 1000.0, 200000.0),
          (clippedContext, clippedOffset) {
            _paintAllChildren(clippedContext, offset);
          },
        );
      },
    );
  }

  @override
  void applyPaintTransform(covariant RenderObject child, Matrix4 transform) {
    final childParentData = child.parentData! as SliverLogicalParentData;
    transform.translateByDouble(0.0, childParentData.layoutOffset!, 0.0, 1.0);
  }

  @override
  double childMainAxisPosition(covariant RenderObject child) {
    final childParentData = child.parentData! as SliverLogicalParentData;
    return childParentData.layoutOffset!;
  }

  @override
  void setupParentData(covariant RenderObject child) {
    child.parentData = _SplitChildParentData();
  }
}

class _SplitChildParentData extends SliverLogicalParentData
    with ContainerParentDataMixin<RenderObject> {}
