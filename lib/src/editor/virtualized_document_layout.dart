import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:super_editor/super_editor.dart';

import 'local_image_node.dart';

/// Resolves document-local <-> viewport/global coordinates for a Sliver [DocumentLayout].
abstract interface class SliverCoordinateHost {
  RenderSliver? get sliverRenderObject;
  double get currentScrollOffset;
}

/// Per-node metrics entry for O(1) incremental updates and O(log N) hit-testing.
class _NodeMetrics {
  _NodeMetrics({
    required this.nodeId,
    required this.top,
    required this.height,
    required this.padding,
    required this.maxWidth,
    required this.isExact,
  });

  final String nodeId;
  double top;
  double height;
  EdgeInsets padding;
  double maxWidth;
  bool isExact;

  double get bottom => top + height;
}

/// Maintains fast cached layout offsets & heights for every [DocumentNode] in
/// a long document (50,000+ words) without keeping offscreen widgets alive.
class DocumentMetricsIndex extends ChangeNotifier {
  DocumentMetricsIndex({
    required this.document,
    required this.stylesheet,
  });

  Document document;
  Stylesheet stylesheet;

  final List<_NodeMetrics> _entries = [];
  final Map<String, int> _idToIndex = {};
  double _crossAxisExtent = 0.0;
  TextScaler _textScaler = TextScaler.noScaling;
  bool _backgroundPassScheduled = false;
  bool _pauseBackgroundMeasurement = false;
  int _nextBackgroundIndex = 0;
  bool _disposed = false;

  void setPauseBackgroundMeasurement(bool pause) {
    if (_pauseBackgroundMeasurement == pause) return;
    _pauseBackgroundMeasurement = pause;
    if (!pause) {
      _scheduleBackgroundMeasurement();
    }
  }

  int get length => _entries.length;
  double get totalHeight => _entries.isEmpty ? 0.0 : _entries.last.bottom;
  int get exactMeasuredCount => _entries.where((e) => e.isExact).length;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void configureLayoutConstraints({
    required double crossAxisExtent,
    required TextScaler textScaler,
  }) {
    final widthChanged = (crossAxisExtent - _crossAxisExtent).abs() > 0.5;
    final scalerChanged = textScaler != _textScaler;
    if (!widthChanged && !scalerChanged && _entries.length == document.length) {
      return;
    }
    _crossAxisExtent = crossAxisExtent;
    _textScaler = textScaler;
    rebuildAll();
  }

  void rebuildAll() {
    _entries.clear();
    _idToIndex.clear();
    if (_crossAxisExtent <= 0.0) {
      return;
    }

    double runningTop = stylesheet.documentPadding?.top ?? 0.0;
    final docNodes = document.toList(growable: false);
    for (int i = 0; i < docNodes.length; i++) {
      final node = docNodes[i];
      final isFirstWindow = i < 45;
      final measured = isFirstWindow
          ? _measureNodeExact(i, docNodes)
          : _estimateNode(i, docNodes);
      final entry = _NodeMetrics(
        nodeId: node.id,
        top: runningTop,
        height: measured.height,
        padding: measured.padding,
        maxWidth: measured.maxWidth,
        isExact: isFirstWindow,
      );
      _entries.add(entry);
      _idToIndex[node.id] = i;
      runningTop += entry.height;
    }
    _nextBackgroundIndex = math.min(45, docNodes.length);
    _scheduleBackgroundMeasurement();
  }

  /// Incrementally updates metrics for edited, inserted, or removed nodes in O(1)
  /// measurement + O(N) lightweight double prefix-sum update.
  void applyDocumentChanges(Set<String> dirtyNodeIds, {bool structureChanged = false}) {
    if (_crossAxisExtent <= 0.0) return;
    if (structureChanged || _entries.length != document.length) {
      _syncStructurePreservingCache(dirtyNodeIds);
      return;
    }

    final docNodes = document.toList(growable: false);
    int earliestChangedIndex = _entries.length;
    for (final nodeId in dirtyNodeIds) {
      final idx = _idToIndex[nodeId];
      if (idx == null || idx < 0 || idx >= docNodes.length) continue;
      final measured = _measureNodeExact(idx, docNodes);
      _entries[idx]
        ..height = measured.height
        ..padding = measured.padding
        ..maxWidth = measured.maxWidth
        ..isExact = true;
      if (idx < earliestChangedIndex) {
        earliestChangedIndex = idx;
      }
      // Also update padding of the immediate follower (e.g. paragraph.after(header1)).
      if (idx + 1 < docNodes.length) {
        final nextMeasured = _measureNodeExact(idx + 1, docNodes);
        _entries[idx + 1]
          ..height = nextMeasured.height
          ..padding = nextMeasured.padding
          ..maxWidth = nextMeasured.maxWidth
          ..isExact = true;
      }
    }

    if (earliestChangedIndex < _entries.length) {
      _recomputeTopsFrom(earliestChangedIndex);
      notifyListeners();
    }
  }

  void _syncStructurePreservingCache(Set<String> dirtyNodeIds) {
    final oldMap = <String, _NodeMetrics>{
      for (final e in _entries) e.nodeId: e,
    };
    _entries.clear();
    _idToIndex.clear();
    final docNodes = document.toList(growable: false);
    double runningTop = stylesheet.documentPadding?.top ?? 0.0;

    for (int i = 0; i < docNodes.length; i++) {
      final node = docNodes[i];
      final old = oldMap[node.id];
      final isFirst = i == 0;
      final isLast = i == docNodes.length - 1;
      final needsMeasure = old == null ||
          dirtyNodeIds.contains(node.id) ||
          isFirst ||
          isLast ||
          (i > 0 && dirtyNodeIds.contains(docNodes[i - 1].id));

      late final _NodeMetrics entry;
      if (!needsMeasure && old.isExact) {
        entry = _NodeMetrics(
          nodeId: node.id,
          top: runningTop,
          height: old.height,
          padding: old.padding,
          maxWidth: old.maxWidth,
          isExact: true,
        );
      } else if (needsMeasure || i < 45) {
        final m = _measureNodeExact(i, docNodes);
        entry = _NodeMetrics(
          nodeId: node.id,
          top: runningTop,
          height: m.height,
          padding: m.padding,
          maxWidth: m.maxWidth,
          isExact: true,
        );
      } else {
        entry = _NodeMetrics(
          nodeId: node.id,
          top: runningTop,
          height: old.height,
          padding: old.padding,
          maxWidth: old.maxWidth,
          isExact: old.isExact,
        );
      }
      _entries.add(entry);
      _idToIndex[node.id] = i;
      runningTop += entry.height;
    }

    _nextBackgroundIndex = 0;
    _scheduleBackgroundMeasurement();
    notifyListeners();
  }

  void _recomputeTopsFrom(int startIndex) {
    if (_entries.isEmpty) return;
    final docTopPad = stylesheet.documentPadding?.top ?? 0.0;
    double runningTop = startIndex <= 0 ? docTopPad : _entries[startIndex - 1].bottom;
    for (int i = startIndex; i < _entries.length; i++) {
      _entries[i].top = runningTop;
      runningTop += _entries[i].height;
    }
  }

  void _scheduleBackgroundMeasurement() {
    if (_backgroundPassScheduled || _pauseBackgroundMeasurement || _disposed) return;
    if (_nextBackgroundIndex >= _entries.length) return;
    _backgroundPassScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _backgroundPassScheduled = false;
      if (_disposed || _pauseBackgroundMeasurement || _crossAxisExtent <= 0.0) return;

      final sw = Stopwatch()..start();
      final docNodes = document.toList(growable: false);
      int firstModified = _entries.length;

      while (_nextBackgroundIndex < _entries.length &&
          _nextBackgroundIndex < docNodes.length &&
          sw.elapsedMicroseconds < 4000) {
        final i = _nextBackgroundIndex++;
        if (!_entries[i].isExact) {
          final measured = _measureNodeExact(i, docNodes);
          if ((_entries[i].height - measured.height).abs() > 0.1) {
            _entries[i]
              ..height = measured.height
              ..padding = measured.padding
              ..maxWidth = measured.maxWidth;
            if (i < firstModified) firstModified = i;
          }
          _entries[i].isExact = true;
        }
      }

      if (firstModified < _entries.length) {
        _recomputeTopsFrom(firstModified);
        notifyListeners();
      }
      if (_nextBackgroundIndex < _entries.length) {
        _scheduleBackgroundMeasurement();
      }
    });
  }

  /// Ensures node at [index] has exact measured geometry on demand (e.g. offscreen selection endpoint).
  void ensureExactMeasured(int index) {
    if (index < 0 || index >= _entries.length) return;
    if (_entries[index].isExact) return;
    final docNodes = document.toList(growable: false);
    if (index >= docNodes.length) return;
    final m = _measureNodeExact(index, docNodes);
    _entries[index]
      ..height = m.height
      ..padding = m.padding
      ..maxWidth = m.maxWidth
      ..isExact = true;
    _recomputeTopsFrom(index);
  }

  /// Ensures all nodes up to [index] are exact measured (used before long jumps).
  void ensureExactUpTo(int index) {
    final limit = math.min(index, _entries.length - 1);
    if (limit < 0) return;
    final docNodes = document.toList(growable: false);
    int firstChanged = _entries.length;
    for (int i = 0; i <= limit && i < docNodes.length; i++) {
      if (!_entries[i].isExact) {
        final m = _measureNodeExact(i, docNodes);
        if ((_entries[i].height - m.height).abs() > 0.1) {
          _entries[i]
            ..height = m.height
            ..padding = m.padding
            ..maxWidth = m.maxWidth;
          if (i < firstChanged) firstChanged = i;
        }
        _entries[i].isExact = true;
      }
    }
    if (firstChanged < _entries.length) {
      _recomputeTopsFrom(firstChanged);
    }
  }

  double getExtentForIndex(int index) {
    if (index < 0 || index >= _entries.length) return 40.0;
    if (!_entries[index].isExact) {
      ensureExactMeasured(index);
    }
    return _entries[index].height;
  }

  void recordActualComponentHeight(String nodeId, double actualHeight) {
    final idx = _idToIndex[nodeId];
    if (idx == null || idx < 0 || idx >= _entries.length) return;
    if ((_entries[idx].height - actualHeight).abs() > 0.5) {
      _entries[idx]
        ..height = actualHeight
        ..isExact = true;
      _recomputeTopsFrom(idx);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) {
          notifyListeners();
        }
      });
    }
  }

  int? indexOfNodeId(String nodeId) => _idToIndex[nodeId];

  double? topOfNodeIndex(int index) {
    if (index < 0 || index >= _entries.length) return null;
    return _entries[index].top;
  }

  double? heightOfNodeIndex(int index) {
    if (index < 0 || index >= _entries.length) return null;
    return _entries[index].height;
  }

  EdgeInsets paddingOfNodeIndex(int index) {
    if (index < 0 || index >= _entries.length) return EdgeInsets.zero;
    return _entries[index].padding;
  }

  /// Binary search O(log N) for the node index intersecting [docY].
  int findIndexAtY(double docY) {
    if (_entries.isEmpty) return -1;
    if (docY <= _entries.first.top) return 0;
    if (docY >= _entries.last.bottom) return _entries.length - 1;

    int low = 0;
    int high = _entries.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final entry = _entries[mid];
      if (docY < entry.top) {
        high = mid - 1;
      } else if (docY > entry.bottom) {
        low = mid + 1;
      } else {
        return mid;
      }
    }
    return low.clamp(0, _entries.length - 1);
  }

  ({EdgeInsets padding, double maxWidth, TextStyle baseStyle}) resolveNodeStyles(DocumentNode node) {
    final styles = <String, dynamic>{};
    for (final rule in stylesheet.rules) {
      if (rule.selector.matches(document, node)) {
        final ruleStyles = rule.styler(document, node);
        for (final entry in ruleStyles.entries) {
          final existing = styles[entry.key];
          final incoming = entry.value;
          if (existing is TextStyle && incoming is TextStyle) {
            styles[entry.key] = existing.merge(incoming);
          } else if (existing is CascadingPadding && incoming is CascadingPadding) {
            styles[entry.key] = incoming.applyOnTopOf(existing);
          } else {
            styles[entry.key] = incoming;
          }
        }
      }
    }

    final cascading = styles[Styles.padding] as CascadingPadding?;
    final padding = cascading?.toEdgeInsets() ?? EdgeInsets.zero;
    final maxWidth = (styles[Styles.maxWidth] as double?) ?? _crossAxisExtent;
    final baseStyle = (styles[Styles.textStyle] as TextStyle?) ?? const TextStyle(fontSize: 17.0, height: 1.48);
    return (padding: padding, maxWidth: maxWidth, baseStyle: baseStyle);
  }

  ({double height, EdgeInsets padding, double maxWidth}) _estimateNode(int index, List<DocumentNode> docNodes) {
    final node = docNodes[index];
    final resolved = resolveNodeStyles(node);
    final constrainedWidth = math.min(_crossAxisExtent, resolved.maxWidth);
    final contentWidth = math.max(40.0, constrainedWidth - resolved.padding.horizontal);

    if (node is LocalImageNode) {
      final h = node.computeDisplayHeight(contentWidth);
      return (height: h + resolved.padding.vertical, padding: resolved.padding, maxWidth: resolved.maxWidth);
    }
    if (node is TextNode) {
      final lineH = (resolved.baseStyle.fontSize ?? 17.0) * (resolved.baseStyle.height ?? 1.48);
      final charsPerLine = math.max(18.0, contentWidth / ((resolved.baseStyle.fontSize ?? 17.0) * 0.52));
      final lines = math.max(1, (node.text.length / charsPerLine).ceil());
      return (
        height: lines * lineH + resolved.padding.vertical,
        padding: resolved.padding,
        maxWidth: resolved.maxWidth,
      );
    }
    return (height: 36.0 + resolved.padding.vertical, padding: resolved.padding, maxWidth: resolved.maxWidth);
  }

  ({double height, EdgeInsets padding, double maxWidth}) _measureNodeExact(int index, List<DocumentNode> docNodes) {
    final node = docNodes[index];
    final resolved = resolveNodeStyles(node);
    final constrainedWidth = math.min(_crossAxisExtent, resolved.maxWidth);
    final innerWidth = math.max(40.0, constrainedWidth - resolved.padding.horizontal);

    if (node is LocalImageNode) {
      final h = node.computeDisplayHeight(innerWidth);
      return (height: h + resolved.padding.vertical, padding: resolved.padding, maxWidth: resolved.maxWidth);
    }

    if (node is TextNode) {
      final painter = buildTextPainterForNode(
        node: node,
        innerWidth: innerWidth,
        baseStyle: resolved.baseStyle,
      );
      final minLineH = _textScaler.scale((resolved.baseStyle.fontSize ?? 17.0) * (resolved.baseStyle.height ?? 1.48));
      final textHeight = math.max(minLineH, painter.height);
      return (
        height: textHeight + resolved.padding.vertical,
        padding: resolved.padding,
        maxWidth: resolved.maxWidth,
      );
    }

    return (height: 36.0 + resolved.padding.vertical, padding: resolved.padding, maxWidth: resolved.maxWidth);
  }

  TextPainter buildTextPainterForNode({
    required TextNode node,
    required double innerWidth,
    required TextStyle baseStyle,
  }) {
    double indentSpace = 0.0;
    final firstAttrs = node.text.isNotEmpty ? node.text.getAllAttributionsAt(0) : <Attribution>{};
    final firstStyle = stylesheet.inlineTextStyler(firstAttrs, baseStyle);

    if (node is ListItemNode) {
      indentSpace = defaultListItemIndentCalculator(firstStyle, node.indent);
    } else if (node is ParagraphNode && node.indent > 0) {
      indentSpace = defaultParagraphIndentCalculator(firstStyle, node.indent);
    }

    final availableTextWidth = math.max(24.0, innerWidth - indentSpace);
    final span = _buildSpan(node.text, baseStyle);
    final painter = TextPainter(
      text: span,
      textDirection: getParagraphDirection(node.text.toPlainText()),
      textScaler: _textScaler,
    )..layout(maxWidth: availableTextWidth);
    return painter;
  }

  TextSpan _buildSpan(AttributedText text, TextStyle baseStyle) {
    if (text.isEmpty) {
      return TextSpan(text: '', style: baseStyle);
    }
    final collapsed = text.spans.collapseSpans(contentLength: text.length);
    return TextSpan(
      style: baseStyle,
      children: [
        for (final span in collapsed)
          TextSpan(
            text: text.substring(span.start, span.end + 1),
            style: stylesheet.inlineTextStyler(span.attributions, baseStyle),
          ),
      ],
    );
  }

  double contentLeftOffset(double innerWidth, double constrainedWidth) {
    return math.max(0.0, (_crossAxisExtent - constrainedWidth) / 2.0);
  }

  /// Offscreen fallback geometry for [DocumentPosition] when a Sliver child is unmounted.
  Rect getOffscreenRectForPosition(DocumentPosition position) {
    final idx = _idToIndex[position.nodeId];
    if (idx == null) return Rect.zero;
    ensureExactMeasured(idx);
    final entry = _entries[idx];
    final node = document.getNodeById(position.nodeId);
    if (node == null) return Rect.fromLTWH(0, entry.top, 2, entry.height);

    final resolved = resolveNodeStyles(node);
    final constrainedWidth = math.min(_crossAxisExtent, resolved.maxWidth);
    final nodeLeft = math.max(0.0, (_crossAxisExtent - constrainedWidth) / 2.0) + entry.padding.left;
    final innerWidth = math.max(40.0, constrainedWidth - entry.padding.horizontal);

    if (node is LocalImageNode) {
      final pos = position.nodePosition;
      final imgW = node.computeDisplayWidth(innerWidth);
      final imgH = node.computeDisplayHeight(innerWidth);
      final imgLeft = nodeLeft + math.max(0.0, (innerWidth - imgW) / 2.0);
      final x = (pos is UpstreamDownstreamNodePosition && pos.affinity == TextAffinity.downstream)
          ? imgLeft + imgW
          : imgLeft;
      return Rect.fromLTWH(x, entry.top + entry.padding.top, 2.0, imgH);
    }

    if (node is TextNode && position.nodePosition is TextNodePosition) {
      final textPos = position.nodePosition as TextNodePosition;
      final painter = buildTextPainterForNode(
        node: node,
        innerWidth: innerWidth,
        baseStyle: resolved.baseStyle,
      );
      final firstAttrs = node.text.isNotEmpty ? node.text.getAllAttributionsAt(0) : <Attribution>{};
      final firstStyle = stylesheet.inlineTextStyler(firstAttrs, resolved.baseStyle);
      double indentSpace = 0.0;
      if (node is ListItemNode) {
        indentSpace = defaultListItemIndentCalculator(firstStyle, node.indent);
      } else if (node is ParagraphNode && node.indent > 0) {
        indentSpace = defaultParagraphIndentCalculator(firstStyle, node.indent);
      }
      final offset = textPos.offset.clamp(0, node.text.length);
      final caretOffset = painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero);
      final caretHeight = painter.getFullHeightForCaret(TextPosition(offset: offset), Rect.zero);
      return Rect.fromLTWH(
        nodeLeft + indentSpace + caretOffset.dx,
        entry.top + entry.padding.top + caretOffset.dy,
        2.0,
        caretHeight,
      );
    }

    return Rect.fromLTWH(nodeLeft, entry.top + entry.padding.top, 2.0, entry.height - entry.padding.vertical);
  }

  Rect getOffscreenRectForNode(int index) {
    ensureExactMeasured(index);
    final entry = _entries[index];
    final constrainedWidth = math.min(_crossAxisExtent, entry.maxWidth);
    final left = math.max(0.0, (_crossAxisExtent - constrainedWidth) / 2.0) + entry.padding.left;
    final width = math.max(40.0, constrainedWidth - entry.padding.horizontal);
    return Rect.fromLTWH(
      left,
      entry.top + entry.padding.top,
      width,
      math.max(1.0, entry.height - entry.padding.vertical),
    );
  }
}

/// O(1)-per-node view model builder replacing full-document N-node presenter passes.
class VirtualizedNodeViewModelFactory {
  VirtualizedNodeViewModelFactory({
    required this.document,
    required this.composer,
    required this.componentBuilders,
    required this.stylesheet,
    required this.selectionStyles,
  });

  Document document;
  MutableDocumentComposer composer;
  List<ComponentBuilder> componentBuilders;
  Stylesheet stylesheet;
  SelectionStyles selectionStyles;

  final Map<String, SingleColumnLayoutComponentViewModel> _cache = {};

  void invalidateNode(String nodeId) => _cache.remove(nodeId);
  void invalidateAll() => _cache.clear();

  SingleColumnLayoutComponentViewModel buildViewModel(DocumentNode node) {
    final cached = _cache[node.id];
    if (cached != null) {
      return cached;
    }

    SingleColumnLayoutComponentViewModel? vm;
    for (final builder in componentBuilders) {
      vm = builder.createViewModel(document, node);
      if (vm != null) break;
    }
    if (vm == null) {
      throw StateError('No ComponentBuilder found for node type ${node.runtimeType}');
    }

    // 1. Apply Stylesheet rules for this single node only.
    final aggregateStyles = <String, dynamic>{
      Styles.inlineTextStyler: stylesheet.inlineTextStyler,
      Styles.inlineWidgetBuilders: stylesheet.inlineWidgetBuilders,
    };
    for (final rule in stylesheet.rules) {
      if (rule.selector.matches(document, node)) {
        final incoming = rule.styler(document, node);
        for (final entry in incoming.entries) {
          final oldVal = aggregateStyles[entry.key];
          final newVal = entry.value;
          if (oldVal is TextStyle && newVal is TextStyle) {
            aggregateStyles[entry.key] = oldVal.merge(newVal);
          } else if (oldVal is CascadingPadding && newVal is CascadingPadding) {
            aggregateStyles[entry.key] = newVal.applyOnTopOf(oldVal);
          } else {
            aggregateStyles[entry.key] = newVal;
          }
        }
      }
    }
    vm.applyStyles(aggregateStyles);

    // 2. Apply ComposingRegion if it intersects this node.
    final composing = composer.composingRegion.value;
    if (composing != null && vm is TextComponentViewModel && node is TextNode) {
      final normal = composing.normalize(document);
      final idx = document.getNodeIndexById(node.id);
      final startIdx = document.getNodeIndexById(normal.start.nodeId);
      final endIdx = document.getNodeIndexById(normal.end.nodeId);
      if (idx >= startIdx && idx <= endIdx) {
        final startOff = idx == startIdx ? (normal.start.nodePosition as TextNodePosition).offset : 0;
        final endOff = idx == endIdx ? (normal.end.nodePosition as TextNodePosition).offset : node.text.length;
        vm
          ..composingRegion = TextRange(start: startOff, end: endOff)
          ..showComposingRegionUnderline = true;
      }
    }

    // 3. Apply Selection if it intersects this node.
    final sel = composer.selection;
    if (sel != null) {
      final normal = sel.normalize(document);
      final idx = document.getNodeIndexById(node.id);
      final startIdx = document.getNodeIndexById(normal.start.nodeId);
      final endIdx = document.getNodeIndexById(normal.end.nodeId);
      if (idx >= startIdx && idx <= endIdx) {
        final NodeSelection nodeSelection;
        if (startIdx == endIdx) {
          nodeSelection = node.computeSelection(
            base: normal.start.nodePosition,
            extent: normal.end.nodePosition,
          );
        } else if (idx == startIdx) {
          nodeSelection = node.computeSelection(
            base: normal.start.nodePosition,
            extent: node.endPosition,
          );
        } else if (idx == endIdx) {
          nodeSelection = node.computeSelection(
            base: node.beginningPosition,
            extent: normal.end.nodePosition,
          );
        } else {
          nodeSelection = node.computeSelection(
            base: node.beginningPosition,
            extent: node.endPosition,
          );
        }

        if (vm is TextComponentViewModel && nodeSelection is TextNodeSelection) {
          vm
            ..selection = TextSelection(
              baseOffset: nodeSelection.baseOffset,
              extentOffset: nodeSelection.extentOffset,
              affinity: nodeSelection.affinity,
            )
            ..selectionColor = selectionStyles.selectionColor
            ..highlightWhenEmpty = sel.base.nodeId != sel.extent.nodeId;
        } else if (vm is SelectionAwareViewModelMixin) {
          vm
            ..selection = DocumentNodeSelection(nodeId: node.id, nodeSelection: nodeSelection)
            ..selectionColor = selectionStyles.selectionColor;
        }
      }
    }

    _cache[node.id] = vm;
    return vm;
  }
}

/// Sliver-based virtualized [DocumentLayout] for smooth 60 FPS performance on 50,000+ words.
class VirtualizedSingleColumnDocumentLayout extends StatefulWidget {
  const VirtualizedSingleColumnDocumentLayout({
    super.key,
    required this.editor,
    required this.document,
    required this.composer,
    required this.metricsIndex,
    required this.viewModelFactory,
    required this.componentBuilders,
    required this.coordinateHost,
    this.onBuildScheduled,
  });

  final Editor editor;
  final MutableDocument document;
  final MutableDocumentComposer composer;
  final DocumentMetricsIndex metricsIndex;
  final VirtualizedNodeViewModelFactory viewModelFactory;
  final List<ComponentBuilder> componentBuilders;
  final SliverCoordinateHost coordinateHost;
  final VoidCallback? onBuildScheduled;

  @override
  State<VirtualizedSingleColumnDocumentLayout> createState() =>
      VirtualizedSingleColumnDocumentLayoutState();
}

class VirtualizedSingleColumnDocumentLayoutState
    extends State<VirtualizedSingleColumnDocumentLayout> implements DocumentLayout {
  final Map<String, GlobalKey> _mountedComponentKeys = {};
  final Map<GlobalKey, String> _keyToNodeId = {};
  DocumentSelection? _lastSelection;
  DocumentRange? _lastComposingRegion;

  @override
  void initState() {
    super.initState();
    _lastSelection = widget.composer.selection;
    _lastComposingRegion = widget.composer.composingRegion.value;
    widget.document.addListener(_onDocumentChanged);
    widget.composer.selectionNotifier.addListener(_onSelectionChanged);
    widget.composer.composingRegion.addListener(_onComposingChanged);
    widget.metricsIndex.addListener(_onMetricsUpdated);
  }

  @override
  void didUpdateWidget(VirtualizedSingleColumnDocumentLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      oldWidget.document.removeListener(_onDocumentChanged);
      widget.document.addListener(_onDocumentChanged);
    }
    if (oldWidget.composer != widget.composer) {
      oldWidget.composer.selectionNotifier.removeListener(_onSelectionChanged);
      oldWidget.composer.composingRegion.removeListener(_onComposingChanged);
      widget.composer.selectionNotifier.addListener(_onSelectionChanged);
      widget.composer.composingRegion.addListener(_onComposingChanged);
    }
    if (oldWidget.metricsIndex != widget.metricsIndex) {
      oldWidget.metricsIndex.removeListener(_onMetricsUpdated);
      widget.metricsIndex.addListener(_onMetricsUpdated);
    }
  }

  @override
  void dispose() {
    widget.document.removeListener(_onDocumentChanged);
    widget.composer.selectionNotifier.removeListener(_onSelectionChanged);
    widget.composer.composingRegion.removeListener(_onComposingChanged);
    widget.metricsIndex.removeListener(_onMetricsUpdated);
    super.dispose();
  }

  void _onMetricsUpdated() {
    if (!mounted) return;
    setState(() {
      widget.onBuildScheduled?.call();
    });
  }

  void _onDocumentChanged(DocumentChangeLog log) {
    final dirtyNodes = <String>{};
    bool structureChanged = false;
    for (final change in log.changes) {
      if (change is NodeInsertedEvent || change is NodeRemovedEvent || change is NodeMovedEvent) {
        structureChanged = true;
      }
      if (change is NodeDocumentChange) {
        dirtyNodes.add(change.nodeId);
        widget.viewModelFactory.invalidateNode(change.nodeId);
      }
    }
    // Ordered list ordinals can change when inserting/removing list items.
    if (structureChanged) {
      widget.viewModelFactory.invalidateAll();
    }
    widget.metricsIndex.applyDocumentChanges(dirtyNodes, structureChanged: structureChanged);
    if (mounted) {
      setState(() {
        widget.onBuildScheduled?.call();
      });
    }
  }

  void _onSelectionChanged() {
    final prev = _lastSelection;
    final next = widget.composer.selection;
    _lastSelection = next;
    _invalidateRange(prev);
    _invalidateRange(next);
    if (mounted) {
      setState(() {
        widget.onBuildScheduled?.call();
      });
    }
  }

  void _onComposingChanged() {
    final prev = _lastComposingRegion;
    final next = widget.composer.composingRegion.value;
    _lastComposingRegion = next;
    _invalidateDocRange(prev);
    _invalidateDocRange(next);
    if (mounted) {
      setState(() {
        widget.onBuildScheduled?.call();
      });
    }
  }

  void _invalidateRange(DocumentSelection? sel) {
    if (sel == null) return;
    _invalidateDocRange(DocumentRange(start: sel.base, end: sel.extent));
  }

  void _invalidateDocRange(DocumentRange? range) {
    if (range == null) return;
    final startNode = widget.document.getNodeById(range.start.nodeId);
    final endNode = widget.document.getNodeById(range.end.nodeId);
    if (startNode == null || endNode == null) {
      widget.viewModelFactory.invalidateAll();
      return;
    }
    final nodes = widget.document.getNodesInside(range.start, range.end);
    for (final n in nodes) {
      widget.viewModelFactory.invalidateNode(n.id);
    }
  }

  GlobalKey _keyForNode(String nodeId) {
    return _mountedComponentKeys.putIfAbsent(nodeId, () {
      final k = GlobalKey(debugLabel: 'doc-node-$nodeId');
      _keyToNodeId[k] = nodeId;
      return k;
    });
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final docNodes = widget.document;
    final topDocPad = widget.metricsIndex.stylesheet.documentPadding?.top ?? 0.0;
    final bottomDocPad = widget.metricsIndex.stylesheet.documentPadding?.bottom ?? 0.0;
    final totalCount = docNodes.length;

    return SliverLayoutBuilder(
      builder: (context, sliverConstraints) {
        widget.metricsIndex.configureLayoutConstraints(
          crossAxisExtent: sliverConstraints.crossAxisExtent,
          textScaler: textScaler,
        );

        return SliverPadding(
          padding: EdgeInsets.only(top: topDocPad, bottom: bottomDocPad),
          sliver: SliverVariedExtentList.builder(
            itemCount: totalCount,
            itemExtentBuilder: (index, dimensions) {
              return widget.metricsIndex.getExtentForIndex(index);
            },
            itemBuilder: (context, index) {
              final node = docNodes.getNodeAt(index);
              if (node == null) return const SizedBox.shrink();
              final componentKey = _keyForNode(node.id);
              final vm = widget.viewModelFactory.buildViewModel(node);
              final componentContext = SingleColumnDocumentComponentContext(
                context: context,
                componentKey: componentKey,
              );

              Widget? built;
              for (final builder in widget.componentBuilders) {
                built = builder.createComponent(componentContext, vm);
                if (built != null) break;
              }
              built ??= const SizedBox.shrink();

              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: vm.maxWidth ?? double.infinity),
                  child: SizedBox(
                    width: double.infinity,
                    child: OverflowBox(
                      alignment: Alignment.topCenter,
                      minHeight: 0,
                      maxHeight: double.infinity,
                      child: _HeightMeasuringBox(
                        onHeightMeasured: (h) {
                          widget.metricsIndex.recordActualComponentHeight(node.id, h);
                        },
                        child: Padding(
                          padding: vm.padding,
                          child: built,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  // --- Coordinate space transforms (Document <-> Viewport <-> Ancestor/Global) ---

  RenderViewportBase? _findViewport() {
    final sliver = widget.coordinateHost.sliverRenderObject;
    if (sliver == null || !sliver.attached) return null;
    return RenderAbstractViewport.maybeOf(sliver) as RenderViewportBase?;
  }

  Offset _documentOffsetToViewportOffset(Offset documentOffset) {
    final sliver = widget.coordinateHost.sliverRenderObject;
    final preceding = (sliver != null && sliver.attached) ? sliver.constraints.precedingScrollExtent : 0.0;
    final scroll = widget.coordinateHost.currentScrollOffset;
    return Offset(documentOffset.dx, documentOffset.dy + preceding - scroll);
  }

  Offset _viewportOffsetToDocumentOffset(Offset viewportOffset) {
    final sliver = widget.coordinateHost.sliverRenderObject;
    final preceding = (sliver != null && sliver.attached) ? sliver.constraints.precedingScrollExtent : 0.0;
    final scroll = widget.coordinateHost.currentScrollOffset;
    return Offset(viewportOffset.dx, viewportOffset.dy - preceding + scroll);
  }

  @override
  Offset getDocumentOffsetFromAncestorOffset(Offset ancestorOffset, [RenderObject? ancestor]) {
    final viewport = _findViewport();
    if (viewport == null) return ancestorOffset;
    final viewportOffset = viewport.globalToLocal(ancestorOffset, ancestor: ancestor);
    return _viewportOffsetToDocumentOffset(viewportOffset);
  }

  @override
  Offset getAncestorOffsetFromDocumentOffset(Offset documentOffset, [RenderObject? ancestor]) {
    final viewport = _findViewport();
    if (viewport == null) return documentOffset;
    final viewportOffset = _documentOffsetToViewportOffset(documentOffset);
    return viewport.localToGlobal(viewportOffset, ancestor: ancestor);
  }

  @override
  Offset getGlobalOffsetFromDocumentOffset(Offset documentOffset) {
    return getAncestorOffsetFromDocumentOffset(documentOffset);
  }

  // --- DocumentLayout queries (mounted fast-path + offscreen exact fallback) ---

  @override
  DocumentComponent? getComponentByNodeId(String nodeId) {
    final key = _mountedComponentKeys[nodeId];
    if (key == null || key.currentContext == null) return null;
    final state = key.currentState;
    return state is DocumentComponent ? state : null;
  }

  Rect _componentToDocumentRect(String nodeId, Rect localRect) {
    final idx = widget.metricsIndex.indexOfNodeId(nodeId);
    final component = getComponentByNodeId(nodeId);
    final viewport = _findViewport();
    if (component != null && viewport != null && component.context.mounted) {
      final box = component.context.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize && box.attached) {
        final vpTopLeft = box.localToGlobal(localRect.topLeft, ancestor: viewport);
        final docTopLeft = _viewportOffsetToDocumentOffset(vpTopLeft);
        return docTopLeft & localRect.size;
      }
    }
    if (idx != null) {
      final top = widget.metricsIndex.topOfNodeIndex(idx) ?? 0.0;
      final pad = widget.metricsIndex.paddingOfNodeIndex(idx);
      return localRect.translate(pad.left, top + pad.top);
    }
    return localRect;
  }

  Offset _documentToComponentOffset(String nodeId, Offset documentOffset) {
    final component = getComponentByNodeId(nodeId);
    final viewport = _findViewport();
    if (component != null && viewport != null && component.context.mounted) {
      final box = component.context.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize && box.attached) {
        final vpOffset = _documentOffsetToViewportOffset(documentOffset);
        final global = viewport.localToGlobal(vpOffset);
        return box.globalToLocal(global);
      }
    }
    final idx = widget.metricsIndex.indexOfNodeId(nodeId);
    if (idx != null) {
      final top = widget.metricsIndex.topOfNodeIndex(idx) ?? 0.0;
      final pad = widget.metricsIndex.paddingOfNodeIndex(idx);
      return documentOffset - Offset(pad.left, top + pad.top);
    }
    return documentOffset;
  }

  @override
  Rect? getEdgeForPosition(DocumentPosition position) {
    final component = getComponentByNodeId(position.nodeId);
    if (component != null) {
      final localEdge = component.getEdgeForPosition(position.nodePosition);
      return _componentToDocumentRect(position.nodeId, localEdge);
    }
    if (widget.document.getNodeById(position.nodeId) == null) return null;
    return widget.metricsIndex.getOffscreenRectForPosition(position);
  }

  @override
  Rect? getRectForPosition(DocumentPosition position) {
    final component = getComponentByNodeId(position.nodeId);
    if (component != null) {
      final localRect = component.getRectForPosition(position.nodePosition);
      return _componentToDocumentRect(position.nodeId, localRect);
    }
    if (widget.document.getNodeById(position.nodeId) == null) return null;
    return widget.metricsIndex.getOffscreenRectForPosition(position);
  }

  @override
  Rect? getRectForSelection(DocumentPosition base, DocumentPosition extent) {
    if (widget.document.isEmpty) return null;
    final startNode = widget.document.getNodeById(base.nodeId);
    final endNode = widget.document.getNodeById(extent.nodeId);
    if (startNode == null || endNode == null) return null;

    if (base.nodeId == extent.nodeId) {
      final component = getComponentByNodeId(base.nodeId);
      if (component != null) {
        final local = component.getRectForSelection(base.nodePosition, extent.nodePosition);
        return _componentToDocumentRect(base.nodeId, local);
      }
      final r1 = getRectForPosition(base)!;
      final r2 = getRectForPosition(extent)!;
      return r1.expandToInclude(r2);
    }

    final startIdx = widget.document.getNodeIndexById(base.nodeId);
    final endIdx = widget.document.getNodeIndexById(extent.nodeId);
    final topIdx = math.min(startIdx, endIdx);
    final bottomIdx = math.max(startIdx, endIdx);
    final topPos = startIdx <= endIdx ? base : extent;
    final bottomPos = startIdx <= endIdx ? extent : base;

    Rect? boundingBox;
    for (int i = topIdx; i <= bottomIdx; i++) {
      final node = widget.document.getNodeAt(i);
      if (node == null) continue;
      final component = getComponentByNodeId(node.id);
      late final Rect nodeSelRect;
      if (component != null) {
        final np1 = i == topIdx ? topPos.nodePosition : component.getBeginningPosition();
        final np2 = i == bottomIdx ? bottomPos.nodePosition : component.getEndPosition();
        nodeSelRect = _componentToDocumentRect(node.id, component.getRectForSelection(np1, np2));
      } else {
        if (i == topIdx) {
          final rStart = getRectForPosition(topPos)!;
          final rNode = widget.metricsIndex.getOffscreenRectForNode(i);
          nodeSelRect = Rect.fromLTRB(rNode.left, rStart.top, rNode.right, rNode.bottom);
        } else if (i == bottomIdx) {
          final rEnd = getRectForPosition(bottomPos)!;
          final rNode = widget.metricsIndex.getOffscreenRectForNode(i);
          nodeSelRect = Rect.fromLTRB(rNode.left, rNode.top, rNode.right, rEnd.bottom);
        } else {
          nodeSelRect = widget.metricsIndex.getOffscreenRectForNode(i);
        }
      }
      boundingBox = boundingBox == null ? nodeSelRect : boundingBox.expandToInclude(nodeSelRect);
    }
    return boundingBox;
  }

  @override
  DocumentPosition? getDocumentPositionAtOffset(Offset documentOffset) {
    if (widget.document.isEmpty) return null;
    final idx = widget.metricsIndex.findIndexAtY(documentOffset.dy);
    if (idx < 0) return null;
    final node = widget.document.getNodeAt(idx);
    if (node == null) return null;
    final top = widget.metricsIndex.topOfNodeIndex(idx) ?? 0.0;
    final h = widget.metricsIndex.heightOfNodeIndex(idx) ?? 0.0;
    if (documentOffset.dy < top || documentOffset.dy > top + h) {
      return null;
    }
    final component = getComponentByNodeId(node.id);
    if (component == null) return null;
    final local = _documentToComponentOffset(node.id, documentOffset);
    final nodePos = component.getPositionAtOffset(local);
    return nodePos == null ? null : DocumentPosition(nodeId: node.id, nodePosition: nodePos);
  }

  @override
  DocumentPosition? getDocumentPositionNearestToOffset(Offset rawDocumentOffset) {
    if (widget.document.isEmpty) return null;
    final totalHeight = widget.metricsIndex.totalHeight;
    if (rawDocumentOffset.dy <= (widget.metricsIndex.topOfNodeIndex(0) ?? 0.0)) {
      final first = widget.document.first;
      return DocumentPosition(nodeId: first.id, nodePosition: first.beginningPosition);
    }
    if (rawDocumentOffset.dy >= totalHeight) {
      final last = widget.document.last;
      return DocumentPosition(nodeId: last.id, nodePosition: last.endPosition);
    }

    final idx = widget.metricsIndex.findIndexAtY(rawDocumentOffset.dy);
    if (idx < 0) return null;
    final node = widget.document.getNodeAt(idx);
    if (node == null) return null;
    final component = getComponentByNodeId(node.id);
    if (component != null) {
      final local = _documentToComponentOffset(node.id, rawDocumentOffset);
      final pos = component.getPositionAtOffset(local);
      if (pos != null) {
        return DocumentPosition(nodeId: node.id, nodePosition: pos);
      }
    }
    final top = widget.metricsIndex.topOfNodeIndex(idx) ?? 0.0;
    final h = widget.metricsIndex.heightOfNodeIndex(idx) ?? 0.0;
    return DocumentPosition(
      nodeId: node.id,
      nodePosition: rawDocumentOffset.dy < top + h / 2 ? node.beginningPosition : node.endPosition,
    );
  }

  @override
  CaretGeometry getCaretForPosition(DocumentPosition position) {
    final rect = getRectForPosition(position) ?? Rect.zero;
    return CaretGeometry(x: rect.left, top: rect.top, bottom: rect.bottom);
  }

  @override
  DocumentSelection? getDocumentSelectionInRegion(Offset baseOffset, Offset extentOffset) {
    final basePos = getDocumentPositionNearestToOffset(baseOffset);
    final extentPos = getDocumentPositionNearestToOffset(extentOffset);
    if (basePos == null || extentPos == null) return null;
    return DocumentSelection(base: basePos, extent: extentPos);
  }

  @override
  DocumentPosition? findLastSelectablePosition() {
    for (int i = widget.document.length - 1; i >= 0; i--) {
      final node = widget.document.getNodeAt(i);
      if (node == null) continue;
      final comp = getComponentByNodeId(node.id);
      if (comp == null || comp.isVisualSelectionSupported()) {
        return DocumentPosition(nodeId: node.id, nodePosition: node.endPosition);
      }
    }
    return null;
  }

  @override
  MouseCursor? getDesiredCursorAtOffset(Offset documentOffset) {
    final idx = widget.metricsIndex.findIndexAtY(documentOffset.dy);
    if (idx < 0) return null;
    final node = widget.document.getNodeAt(idx);
    if (node == null) return null;
    final comp = getComponentByNodeId(node.id);
    if (comp == null) return null;
    return comp.getDesiredCursorAtOffset(_documentToComponentOffset(node.id, documentOffset));
  }
}

class _HeightMeasuringBox extends SingleChildRenderObjectWidget {
  const _HeightMeasuringBox({
    required this.onHeightMeasured,
    required super.child,
  });

  final ValueChanged<double> onHeightMeasured;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderHeightMeasuringBox(onHeightMeasured);
  }

  @override
  void updateRenderObject(BuildContext context, _RenderHeightMeasuringBox renderObject) {
    renderObject.onHeightMeasured = onHeightMeasured;
  }
}

class _RenderHeightMeasuringBox extends RenderProxyBox {
  _RenderHeightMeasuringBox(this.onHeightMeasured);

  ValueChanged<double> onHeightMeasured;
  double? _lastHeight;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (_lastHeight == null || (_lastHeight! - h).abs() > 0.5) {
      _lastHeight = h;
      onHeightMeasured(h);
    }
  }
}
