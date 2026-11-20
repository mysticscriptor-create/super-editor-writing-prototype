import 'package:attributed_text/attributed_text.dart';
import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

/// Supported font families in the prototype formatting toolbar.
const Map<String, String?> kSupportedFontFamilies = {
  'Sans': null,
  'Serif': 'serif',
  'Mono': 'monospace',
};

/// Supported font sizes in logical pixels.
const List<double> kSupportedFontSizes = [14.0, 16.0, 18.0, 22.0, 26.0, 32.0];

/// Supported foreground text colors (`null` = default ink color).
const List<({String label, Color? color})> kSupportedTextColors = [
  (label: 'Default', color: null),
  (label: 'Slate', color: Color(0xFF334155)),
  (label: 'Crimson', color: Color(0xFFB91C1C)),
  (label: 'Cobalt', color: Color(0xFF1D4ED8)),
  (label: 'Forest', color: Color(0xFF15803D)),
  (label: 'Amber', color: Color(0xFFB45309)),
];

/// Supported highlight background colors (`null` = no highlight).
const List<({String label, Color? color})> kSupportedHighlightColors = [
  (label: 'None', color: null),
  (label: 'Yellow', color: Color(0xFFFEF08A)),
  (label: 'Mint', color: Color(0xFFBBF7D0)),
  (label: 'Sky', color: Color(0xFFBAE6FD)),
  (label: 'Rose', color: Color(0xFFFECDD3)),
  (label: 'Lavender', color: Color(0xFFE9D5FF)),
];

/// Replaces any existing attribution with [attributionId] inside [documentRange]
/// with [newAttribution] (or simply clears it when [newAttribution] is `null`).
///
/// This prevents `AttributedText` from throwing overlapping-attribution errors
/// when changing font family, font size, text color, or highlight color over a
/// range that already carries another value of that same attribution family.
class SetExclusiveTextAttributionRequest implements EditRequest {
  const SetExclusiveTextAttributionRequest({
    required this.documentRange,
    required this.attributionId,
    required this.newAttribution,
  });

  final DocumentRange documentRange;
  final String attributionId;
  final Attribution? newAttribution;
}

class SetExclusiveTextAttributionCommand extends EditCommand {
  SetExclusiveTextAttributionCommand({
    required this.documentRange,
    required this.attributionId,
    required this.newAttribution,
  });

  final DocumentRange documentRange;
  final String attributionId;
  final Attribution? newAttribution;

  @override
  HistoryBehavior get historyBehavior => HistoryBehavior.undoable;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final document = context.document;
    final nodes = document.getNodesInside(documentRange.start, documentRange.end);
    if (nodes.isEmpty) {
      return;
    }

    final normalRange = documentRange.normalize(document);
    final events = <EditEvent>[];

    for (final node in nodes) {
      if (node is! TextNode || node.text.isEmpty) {
        continue;
      }

      late final int startOffset;
      late final int endOffsetInclusive;

      if (node == nodes.first && node == nodes.last) {
        startOffset = (normalRange.start.nodePosition as TextPosition).offset;
        endOffsetInclusive = (normalRange.end.nodePosition as TextPosition).offset - 1;
      } else if (node == nodes.first) {
        startOffset = (normalRange.start.nodePosition as TextPosition).offset;
        endOffsetInclusive = node.text.length - 1;
      } else if (node == nodes.last) {
        startOffset = 0;
        endOffsetInclusive = (normalRange.end.nodePosition as TextPosition).offset - 1;
      } else {
        startOffset = 0;
        endOffsetInclusive = node.text.length - 1;
      }

      if (endOffsetInclusive < startOffset || startOffset < 0 || endOffsetInclusive >= node.text.length) {
        continue;
      }

      final range = SpanRange(startOffset, endOffsetInclusive);
      final updatedSpans = node.text.spans.copy();

      // Find all existing attributions with matching ID in this range and remove them.
      final existingToRemove = <Attribution>{};
      for (int i = range.start; i <= range.end; i++) {
        for (final attr in updatedSpans.getAllAttributionsAt(i)) {
          if (attr.id == attributionId) {
            existingToRemove.add(attr);
          }
        }
      }

      for (final oldAttr in existingToRemove) {
        updatedSpans.removeAttribution(
          attributionToRemove: oldAttr,
          start: range.start,
          end: range.end,
        );
      }

      if (newAttribution != null) {
        updatedSpans.addAttribution(
          newAttribution: newAttribution!,
          start: range.start,
          end: range.end,
          autoMerge: true,
        );
      }

      document.replaceNodeById(
        node.id,
        node.copyTextNodeWith(
          text: AttributedText(
            node.text.toPlainText(includePlaceholders: false),
            updatedSpans,
            Map.from(node.text.placeholders),
          ),
        ),
      );

      events.add(
        DocumentEdit(
          AttributionChangeEvent(
            nodeId: node.id,
            change: newAttribution != null ? AttributionChange.added : AttributionChange.removed,
            range: range,
            attributions: {if (newAttribution != null) newAttribution! else ...existingToRemove},
          ),
        ),
      );
    }

    if (events.isNotEmpty) {
      executor.logChanges(events);
    }
  }
}

/// Builds the editor stylesheet supporting headings, normal paragraphs, lists,
/// bold, italic, font-family, font-size, text color, highlight color, and links.
Stylesheet buildPrototypeStylesheet() {
  return Stylesheet(
    documentPadding: const EdgeInsets.symmetric(vertical: 16),
    rules: [
      StyleRule(
        BlockSelector.all,
        (doc, docNode) => {
          Styles.maxWidth: 720.0,
          Styles.padding: const CascadingPadding.symmetric(horizontal: 18),
          Styles.textStyle: const TextStyle(
            color: Color(0xFF1E293B),
            fontSize: 17.0,
            height: 1.48,
          ),
        },
      ),
      StyleRule(
        const BlockSelector('header1'),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 24, bottom: 6),
          Styles.textStyle: const TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 28.0,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
        },
      ),
      StyleRule(
        const BlockSelector('header2'),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 20, bottom: 4),
          Styles.textStyle: const TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 23.0,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
        },
      ),
      StyleRule(
        const BlockSelector('header3'),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 16, bottom: 4),
          Styles.textStyle: const TextStyle(
            color: Color(0xFF1E293B),
            fontSize: 19.5,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        },
      ),
      StyleRule(
        const BlockSelector('paragraph'),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 10, bottom: 4),
        },
      ),
      StyleRule(
        const BlockSelector('paragraph').after('header1'),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 4),
        },
      ),
      StyleRule(
        const BlockSelector('paragraph').after('header2'),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 4),
        },
      ),
      StyleRule(
        const BlockSelector('paragraph').after('header3'),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 4),
        },
      ),
      StyleRule(
        const BlockSelector('listItem'),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 6, bottom: 4),
        },
      ),
      StyleRule(
        const BlockSelector('localImage'),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.symmetric(vertical: 12),
        },
      ),
      StyleRule(
        BlockSelector.all.last(),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(bottom: 72),
        },
      ),
    ],
    inlineTextStyler: prototypeInlineTextStyler,
    inlineWidgetBuilders: defaultInlineWidgetBuilderChain,
  );
}

TextStyle prototypeInlineTextStyler(Set<Attribution> attributions, TextStyle existingStyle) {
  return defaultInlineTextStyler(attributions, existingStyle);
}
