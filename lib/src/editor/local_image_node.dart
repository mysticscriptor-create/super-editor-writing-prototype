import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

/// Structured document node representing an inline local image file with
/// aspect-ratio-preserving relative width.
@immutable
class LocalImageNode extends BlockNode {
  LocalImageNode({
    required this.id,
    required this.localFileName,
    required this.resolvedFilePath,
    required this.aspectRatio,
    this.widthFraction = 0.85,
    this.altText = '',
    super.metadata,
  }) {
    initAddToMetadata({
      NodeMetadata.blockType: const NamedAttribution('localImage'),
    });
  }

  @override
  final String id;

  /// Filename (relative to the app's local images directory) for persistence.
  final String localFileName;

  /// Absolute path on the Android device filesystem.
  final String resolvedFilePath;

  /// Natural width / height ratio (> 0).
  final double aspectRatio;

  /// Fraction of available content width in `[0.25, 1.0]`.
  final double widthFraction;

  final String altText;

  double computeDisplayWidth(double maxContentWidth) {
    return (maxContentWidth * widthFraction.clamp(0.25, 1.0)).clamp(80.0, maxContentWidth);
  }

  double computeDisplayHeight(double maxContentWidth) {
    final safeRatio = aspectRatio > 0.05 ? aspectRatio : 1.5;
    return computeDisplayWidth(maxContentWidth) / safeRatio;
  }

  @override
  String? copyContent(dynamic selection) {
    if (selection is! UpstreamDownstreamNodeSelection) {
      throw Exception('LocalImageNode can only copy content from an UpstreamDownstreamNodeSelection.');
    }
    return !selection.isCollapsed ? '![${altText.isEmpty ? 'image' : altText}]($localFileName)' : null;
  }

  @override
  bool hasEquivalentContent(DocumentNode other) {
    return other is LocalImageNode &&
        localFileName == other.localFileName &&
        resolvedFilePath == other.resolvedFilePath &&
        aspectRatio == other.aspectRatio &&
        widthFraction == other.widthFraction &&
        altText == other.altText;
  }

  @override
  DocumentNode copyWithAddedMetadata(Map<String, dynamic> newProperties) {
    return LocalImageNode(
      id: id,
      localFileName: localFileName,
      resolvedFilePath: resolvedFilePath,
      aspectRatio: aspectRatio,
      widthFraction: widthFraction,
      altText: altText,
      metadata: {
        ...metadata,
        ...newProperties,
      },
    );
  }

  @override
  DocumentNode copyAndReplaceMetadata(Map<String, dynamic> newMetadata) {
    return LocalImageNode(
      id: id,
      localFileName: localFileName,
      resolvedFilePath: resolvedFilePath,
      aspectRatio: aspectRatio,
      widthFraction: widthFraction,
      altText: altText,
      metadata: newMetadata,
    );
  }

  LocalImageNode copyWith({
    double? widthFraction,
    String? altText,
    String? resolvedFilePath,
  }) {
    return LocalImageNode(
      id: id,
      localFileName: localFileName,
      resolvedFilePath: resolvedFilePath ?? this.resolvedFilePath,
      aspectRatio: aspectRatio,
      widthFraction: (widthFraction ?? this.widthFraction).clamp(0.25, 1.0),
      altText: altText ?? this.altText,
      metadata: Map.from(metadata),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalImageNode &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          localFileName == other.localFileName &&
          resolvedFilePath == other.resolvedFilePath &&
          aspectRatio == other.aspectRatio &&
          widthFraction == other.widthFraction &&
          altText == other.altText;

  @override
  int get hashCode =>
      id.hashCode ^
      localFileName.hashCode ^
      resolvedFilePath.hashCode ^
      aspectRatio.hashCode ^
      widthFraction.hashCode ^
      altText.hashCode;
}

class ResizeLocalImageRequest implements EditRequest {
  const ResizeLocalImageRequest({
    required this.nodeId,
    required this.widthFraction,
  });

  final String nodeId;
  final double widthFraction;
}

class ResizeLocalImageCommand extends EditCommand {
  ResizeLocalImageCommand({
    required this.nodeId,
    required this.widthFraction,
  });

  final String nodeId;
  final double widthFraction;

  @override
  HistoryBehavior get historyBehavior => HistoryBehavior.undoable;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final node = context.document.getNodeById(nodeId);
    if (node is! LocalImageNode) {
      return;
    }
    final clamped = widthFraction.clamp(0.25, 1.0);
    if ((node.widthFraction - clamped).abs() < 0.001) {
      return;
    }
    final updated = node.copyWith(widthFraction: clamped);
    context.document.replaceNodeById(nodeId, updated);
    executor.logChanges([
      DocumentEdit(NodeChangeEvent(nodeId)),
    ]);
  }
}

class LocalImageComponentViewModel extends SingleColumnLayoutComponentViewModel
    with SelectionAwareViewModelMixin {
  LocalImageComponentViewModel({
    required super.nodeId,
    super.createdAt,
    super.maxWidth,
    super.padding = EdgeInsets.zero,
    super.opacity = 1.0,
    required this.resolvedFilePath,
    required this.aspectRatio,
    required this.widthFraction,
    required this.altText,
    DocumentNodeSelection? selection,
    Color selectionColor = Colors.transparent,
  }) {
    this.selection = selection;
    this.selectionColor = selectionColor;
  }

  final String resolvedFilePath;
  final double aspectRatio;
  final double widthFraction;
  final String altText;

  @override
  LocalImageComponentViewModel copy() {
    return LocalImageComponentViewModel(
      nodeId: nodeId,
      createdAt: createdAt,
      maxWidth: maxWidth,
      padding: padding,
      opacity: opacity,
      resolvedFilePath: resolvedFilePath,
      aspectRatio: aspectRatio,
      widthFraction: widthFraction,
      altText: altText,
      selection: selection,
      selectionColor: selectionColor,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      super == other &&
          other is LocalImageComponentViewModel &&
          runtimeType == other.runtimeType &&
          nodeId == other.nodeId &&
          resolvedFilePath == other.resolvedFilePath &&
          aspectRatio == other.aspectRatio &&
          widthFraction == other.widthFraction &&
          altText == other.altText &&
          selection == other.selection &&
          selectionColor == other.selectionColor;

  @override
  int get hashCode =>
      super.hashCode ^
      nodeId.hashCode ^
      resolvedFilePath.hashCode ^
      aspectRatio.hashCode ^
      widthFraction.hashCode ^
      altText.hashCode ^
      selection.hashCode ^
      selectionColor.hashCode;
}

class LocalImageComponentBuilder implements ComponentBuilder {
  const LocalImageComponentBuilder({
    required this.editor,
  });

  final Editor editor;

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    if (node is! LocalImageNode) {
      return null;
    }
    return LocalImageComponentViewModel(
      nodeId: node.id,
      createdAt: node.metadata[NodeMetadata.createdAt],
      resolvedFilePath: node.resolvedFilePath,
      aspectRatio: node.aspectRatio,
      widthFraction: node.widthFraction,
      altText: node.altText,
      selectionColor: const Color(0x00000000),
    );
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! LocalImageComponentViewModel) {
      return null;
    }
    return LocalImageComponent(
      componentKey: componentContext.componentKey,
      nodeId: componentViewModel.nodeId,
      resolvedFilePath: componentViewModel.resolvedFilePath,
      aspectRatio: componentViewModel.aspectRatio,
      widthFraction: componentViewModel.widthFraction,
      altText: componentViewModel.altText,
      selection: componentViewModel.selection?.nodeSelection as UpstreamDownstreamNodeSelection?,
      selectionColor: componentViewModel.selectionColor,
      opacity: componentViewModel.opacity,
      onResizeFraction: (fraction) {
        editor.execute([
          ResizeLocalImageRequest(
            nodeId: componentViewModel.nodeId,
            widthFraction: fraction,
          ),
        ]);
      },
    );
  }
}

class LocalImageComponent extends StatelessWidget {
  const LocalImageComponent({
    super.key,
    required this.componentKey,
    required this.nodeId,
    required this.resolvedFilePath,
    required this.aspectRatio,
    required this.widthFraction,
    required this.altText,
    this.selection,
    this.selectionColor = Colors.blue,
    this.opacity = 1.0,
    required this.onResizeFraction,
  });

  final GlobalKey componentKey;
  final String nodeId;
  final String resolvedFilePath;
  final double aspectRatio;
  final double widthFraction;
  final String altText;
  final UpstreamDownstreamNodeSelection? selection;
  final Color selectionColor;
  final double opacity;
  final ValueChanged<double> onResizeFraction;

  @override
  Widget build(BuildContext context) {
    final isSelected = selection != null && !selection!.isCollapsed;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
        final displayWidth = (maxWidth * widthFraction.clamp(0.25, 1.0)).clamp(80.0, maxWidth);
        final safeRatio = aspectRatio > 0.05 ? aspectRatio : 1.5;
        final displayHeight = displayWidth / safeRatio;
        final decodeWidth = math.max(120, (displayWidth * MediaQuery.devicePixelRatioOf(context)).round());

        return Center(
          child: SizedBox(
            width: displayWidth,
            height: displayHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                IgnorePointer(
                  child: SelectableBox(
                    selection: selection,
                    selectionColor: selectionColor,
                    child: BoxComponent(
                      key: componentKey,
                      opacity: opacity,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: _buildImageWidget(displayWidth, displayHeight, decodeWidth),
                      ),
                    ),
                  ),
                ),
                if (isSelected)
                  Positioned(
                    right: -6,
                    bottom: -6,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) {
                        final nextWidth = (displayWidth + details.delta.dx).clamp(80.0, maxWidth);
                        onResizeFraction((nextWidth / maxWidth).clamp(0.25, 1.0));
                      },
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1D4ED8),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: const [
                            BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 1)),
                          ],
                        ),
                        child: const Icon(Icons.open_in_full, size: 13, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildImageWidget(double width, double height, int decodeWidth) {
    final file = File(resolvedFilePath);
    if (!file.existsSync()) {
      return Container(
        width: width,
        height: height,
        color: const Color(0xFFE2E8F0),
        alignment: Alignment.center,
        child: Text(
          altText.isEmpty ? 'Missing local image' : altText,
          style: const TextStyle(color: Color(0xFF475569), fontSize: 13),
        ),
      );
    }
    return Image(
      image: ResizeImage(
        FileImage(file),
        width: decodeWidth,
      ),
      width: width,
      height: height,
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );
  }
}
