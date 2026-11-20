import 'dart:io';

import 'package:attributed_text/attributed_text.dart';
import 'package:path/path.dart' as p;
import 'package:super_editor/super_editor.dart';

import '../editor/local_image_node.dart';
import 'document_json_codec.dart';

/// Explicit report of document formatting that cannot be represented losslessly
/// in standard Markdown.
class MarkdownLossReport {
  const MarkdownLossReport({
    required this.fontFamilySpans,
    required this.fontSizeSpans,
    required this.textColorSpans,
    required this.highlightColorSpans,
    required this.resizedImages,
    required this.indentedParagraphs,
  });

  final int fontFamilySpans;
  final int fontSizeSpans;
  final int textColorSpans;
  final int highlightColorSpans;
  final int resizedImages;
  final int indentedParagraphs;

  bool get isLossless =>
      fontFamilySpans == 0 &&
      fontSizeSpans == 0 &&
      textColorSpans == 0 &&
      highlightColorSpans == 0 &&
      resizedImages == 0 &&
      indentedParagraphs == 0;

  List<String> describeLosses() {
    final items = <String>[];
    if (fontFamilySpans > 0) {
      items.add(
        '$fontFamilySpans font-family span(s): standard Markdown has no font-family syntax.',
      );
    }
    if (fontSizeSpans > 0) {
      items.add(
        '$fontSizeSpans inline font-size span(s): standard Markdown only supports H1-H3 headings, not arbitrary font sizes.',
      );
    }
    if (textColorSpans > 0) {
      items.add(
        '$textColorSpans text-color span(s): standard Markdown does not encode foreground colors.',
      );
    }
    if (highlightColorSpans > 0) {
      items.add(
        '$highlightColorSpans highlight-color span(s): standard Markdown does not encode background highlights.',
      );
    }
    if (resizedImages > 0) {
      items.add(
        '$resizedImages custom-sized image(s): standard ![alt](path) drops custom width-fraction resize state.',
      );
    }
    if (indentedParagraphs > 0) {
      items.add(
        '$indentedParagraphs indented paragraph(s): standard Markdown flattens paragraph indent levels.',
      );
    }
    return items;
  }
}

class MarkdownExportResult {
  const MarkdownExportResult({
    required this.markdown,
    required this.lossReport,
  });

  final String markdown;
  final MarkdownLossReport lossReport;
}

class _LocalImageMarkdownSerializer
    extends NodeTypedDocumentNodeMarkdownSerializer<LocalImageNode> {
  const _LocalImageMarkdownSerializer();

  @override
  String doSerialization(
    Document document,
    LocalImageNode node, {
    NodeSelection? selection,
  }) {
    if (selection != null) {
      if (selection is! UpstreamDownstreamNodeSelection || selection.isCollapsed) {
        return '';
      }
    }
    final alt = node.altText.replaceAll('[', r'\[').replaceAll(']', r'\]');
    return '![$alt](${node.localFileName})';
  }
}

/// Real AST-based Markdown serializer & deserializer built on `super_editor`'s
/// `package:markdown` pipeline, paired with explicit loss reporting.
class MarkdownCodec {
  static MarkdownExportResult exportDocument(Document document) {
    final report = analyzeMarkdownLosses(document);
    final markdown = serializeDocumentToMarkdown(
      document,
      syntax: MarkdownSyntax.normal,
      customNodeSerializers: const [
        _LocalImageMarkdownSerializer(),
      ],
    );
    return MarkdownExportResult(
      markdown: markdown,
      lossReport: report,
    );
  }

  static MarkdownLossReport analyzeMarkdownLosses(Document document) {
    int fontFamilySpans = 0;
    int fontSizeSpans = 0;
    int textColorSpans = 0;
    int highlightColorSpans = 0;
    int resizedImages = 0;
    int indentedParagraphs = 0;

    for (int i = 0; i < document.length; i++) {
      final node = document.getNodeAt(i);
      if (node is LocalImageNode) {
        if ((node.widthFraction - 0.85).abs() > 0.01) {
          resizedImages++;
        }
        continue;
      }
      if (node is ParagraphNode && node.indent > 0) {
        indentedParagraphs++;
      }
      if (node is TextNode && node.text.isNotEmpty) {
        final collapsed = node.text.spans.collapseSpans(contentLength: node.text.length);
        for (final span in collapsed) {
          for (final attr in span.attributions) {
            if (attr is FontFamilyAttribution) {
              fontFamilySpans++;
            } else if (attr is FontSizeAttribution) {
              fontSizeSpans++;
            } else if (attr is ColorAttribution) {
              textColorSpans++;
            } else if (attr is BackgroundColorAttribution) {
              highlightColorSpans++;
            }
          }
        }
      }
    }

    return MarkdownLossReport(
      fontFamilySpans: fontFamilySpans,
      fontSizeSpans: fontSizeSpans,
      textColorSpans: textColorSpans,
      highlightColorSpans: highlightColorSpans,
      resizedImages: resizedImages,
      indentedParagraphs: indentedParagraphs,
    );
  }

  static MutableDocument importMarkdown(
    String markdown, {
    required String imagesDirectoryPath,
  }) {
    final parsed = deserializeMarkdownToDocument(
      markdown,
      syntax: MarkdownSyntax.normal,
    );

    final convertedNodes = <DocumentNode>[];
    for (int i = 0; i < parsed.length; i++) {
      final node = parsed.getNodeAt(i);
      if (node == null) continue;
      if (node is ImageNode) {
        final rawSrc = node.imageUrl.trim();
        final fileName = rawSrc.isEmpty ? '' : p.basename(rawSrc);
        String resolvedPath = fileName.isEmpty ? '' : p.join(imagesDirectoryPath, fileName);
        if (rawSrc.isNotEmpty && File(rawSrc).existsSync()) {
          resolvedPath = rawSrc;
        }
        double aspectRatio = 1.5;
        if (node.expectedBitmapSize?.width != null &&
            node.expectedBitmapSize?.height != null &&
            node.expectedBitmapSize!.height! > 0) {
          aspectRatio = node.expectedBitmapSize!.width! / node.expectedBitmapSize!.height!;
        } else if (resolvedPath.isNotEmpty) {
          aspectRatio = DocumentJsonCodec.readAspectRatioFromFile(File(resolvedPath));
        }
        convertedNodes.add(
          LocalImageNode(
            id: node.id,
            localFileName: fileName,
            resolvedFilePath: resolvedPath,
            aspectRatio: aspectRatio,
            widthFraction: 0.85,
            altText: node.altText,
          ),
        );
      } else {
        convertedNodes.add(node);
      }
    }

    if (convertedNodes.isEmpty) {
      convertedNodes.add(
        ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText(),
        ),
      );
    }

    return MutableDocument(nodes: convertedNodes);
  }
}
