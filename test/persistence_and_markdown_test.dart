import 'dart:io';
import 'dart:ui' show Color;

import 'package:attributed_text/attributed_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scribe_supereditor_prototype/src/editor/document_attributions.dart';
import 'package:scribe_supereditor_prototype/src/editor/local_image_node.dart';
import 'package:scribe_supereditor_prototype/src/persistence/document_json_codec.dart';
import 'package:scribe_supereditor_prototype/src/persistence/markdown_codec.dart';
import 'package:scribe_supereditor_prototype/src/persistence/sample_document_generator.dart';
import 'package:super_editor/super_editor.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('scribe_proto_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('DocumentJsonCodec preserves headings, lists, rich spans, and LocalImageNode', () {
    final doc = MutableDocument(
      nodes: [
        ParagraphNode(
          id: 'h1',
          text: AttributedText('Chapter One'),
          metadata: const {NodeMetadata.blockType: header1Attribution},
        ),
        ParagraphNode(
          id: 'p1',
          text: AttributedText(
            'Styled words here',
            AttributedSpans(
              attributions: const [
                SpanMarker(attribution: boldAttribution, offset: 0, markerType: SpanMarkerType.start),
                SpanMarker(attribution: boldAttribution, offset: 5, markerType: SpanMarkerType.end),
                SpanMarker(attribution: FontFamilyAttribution('serif'), offset: 0, markerType: SpanMarkerType.start),
                SpanMarker(attribution: FontFamilyAttribution('serif'), offset: 5, markerType: SpanMarkerType.end),
                SpanMarker(attribution: FontSizeAttribution(22.0), offset: 7, markerType: SpanMarkerType.start),
                SpanMarker(attribution: FontSizeAttribution(22.0), offset: 11, markerType: SpanMarkerType.end),
                SpanMarker(attribution: ColorAttribution(Color(0xFFB91C1C)), offset: 7, markerType: SpanMarkerType.start),
                SpanMarker(attribution: ColorAttribution(Color(0xFFB91C1C)), offset: 11, markerType: SpanMarkerType.end),
                SpanMarker(attribution: BackgroundColorAttribution(Color(0xFFFEF08A)), offset: 13, markerType: SpanMarkerType.start),
                SpanMarker(attribution: BackgroundColorAttribution(Color(0xFFFEF08A)), offset: 16, markerType: SpanMarkerType.end),
              ],
            ),
          ),
        ),
        ListItemNode.ordered(
          id: 'li1',
          indent: 1,
          text: AttributedText('Ordered item'),
        ),
        LocalImageNode(
          id: 'img1',
          localFileName: 'photo_1.png',
          resolvedFilePath: p.join(tempDir.path, 'photo_1.png'),
          aspectRatio: 16 / 9,
          widthFraction: 0.50,
          altText: 'Desk setup',
        ),
      ],
    );

    final jsonText = DocumentJsonCodec.encodeDocument(doc);
    final reopened = DocumentJsonCodec.decodeDocument(
      jsonText,
      imagesDirectoryPath: tempDir.path,
    );

    expect(reopened.length, 4);
    expect(reopened.getNodeAt(0)!.getMetadataValue(NodeMetadata.blockType), header1Attribution);
    final p1 = reopened.getNodeAt(1)! as ParagraphNode;
    expect(p1.text.toPlainText(), 'Styled words here');
    expect(p1.text.getAllAttributionsAt(0), containsAll([boldAttribution, const FontFamilyAttribution('serif')]));
    expect(p1.text.getAllAttributionsAt(8), containsAll([const FontSizeAttribution(22.0), const ColorAttribution(Color(0xFFB91C1C))]));
    expect(p1.text.getAllAttributionsAt(14), contains(const BackgroundColorAttribution(Color(0xFFFEF08A))));

    final li1 = reopened.getNodeAt(2)! as ListItemNode;
    expect(li1.type, ListItemType.ordered);
    expect(li1.indent, 1);

    final img1 = reopened.getNodeAt(3)! as LocalImageNode;
    expect(img1.localFileName, 'photo_1.png');
    expect(img1.resolvedFilePath, p.join(tempDir.path, 'photo_1.png'));
    expect(img1.aspectRatio, closeTo(16 / 9, 0.001));
    expect(img1.widthFraction, closeTo(0.50, 0.001));
    expect(img1.altText, 'Desk setup');
  });

  test('MarkdownCodec exports & imports real AST Markdown and reports non-lossless attributes', () {
    final doc = MutableDocument(
      nodes: [
        ParagraphNode(
          id: 'h1',
          text: AttributedText('Title'),
          metadata: const {NodeMetadata.blockType: header1Attribution},
        ),
        ParagraphNode(
          id: 'p1',
          text: AttributedText(
            'Bold italic colored link',
            AttributedSpans(
              attributions: const [
                SpanMarker(attribution: boldAttribution, offset: 0, markerType: SpanMarkerType.start),
                SpanMarker(attribution: boldAttribution, offset: 3, markerType: SpanMarkerType.end),
                SpanMarker(attribution: italicsAttribution, offset: 5, markerType: SpanMarkerType.start),
                SpanMarker(attribution: italicsAttribution, offset: 10, markerType: SpanMarkerType.end),
                SpanMarker(attribution: ColorAttribution(Color(0xFF1D4ED8)), offset: 12, markerType: SpanMarkerType.start),
                SpanMarker(attribution: ColorAttribution(Color(0xFF1D4ED8)), offset: 18, markerType: SpanMarkerType.end),
                SpanMarker(attribution: LinkAttribution('https://flutter.dev'), offset: 20, markerType: SpanMarkerType.start),
                SpanMarker(attribution: LinkAttribution('https://flutter.dev'), offset: 23, markerType: SpanMarkerType.end),
              ],
            ),
          ),
        ),
        ListItemNode.unordered(id: 'ul1', text: AttributedText('Bullet one')),
        ListItemNode.ordered(id: 'ol1', text: AttributedText('Number one')),
        LocalImageNode(
          id: 'img1',
          localFileName: 'diagram.png',
          resolvedFilePath: p.join(tempDir.path, 'diagram.png'),
          aspectRatio: 1.5,
          widthFraction: 0.5,
          altText: 'Architecture',
        ),
      ],
    );

    final exported = MarkdownCodec.exportDocument(doc);
    expect(exported.markdown, contains('# Title'));
    expect(exported.markdown, contains('**Bold**'));
    expect(exported.markdown, contains('*italic*'));
    expect(exported.markdown, contains('[link](https://flutter.dev)'));
    expect(exported.markdown, contains('* Bullet one'));
    expect(exported.markdown, contains('1. Number one'));
    expect(exported.markdown, contains('![Architecture](diagram.png)'));

    expect(exported.lossReport.isLossless, isFalse);
    expect(exported.lossReport.textColorSpans, 1);
    expect(exported.lossReport.resizedImages, 1);
    expect(exported.lossReport.describeLosses(), isNotEmpty);

    final reimported = MarkdownCodec.importMarkdown(
      exported.markdown,
      imagesDirectoryPath: tempDir.path,
    );
    expect(reimported.length, 5);
    expect(reimported.getNodeAt(0)!.getMetadataValue(NodeMetadata.blockType), header1Attribution);
    expect((reimported.getNodeAt(4)! as LocalImageNode).localFileName, 'diagram.png');
  });

  test('SampleDocumentGenerator builds >=50,000 words with local PNGs & supports Editor edits', () {
    final generated = SampleDocumentGenerator.generate50kWordDocument(
      imagesDirectoryPath: tempDir.path,
    );

    expect(generated.wordCount, greaterThanOrEqualTo(50000));
    expect(generated.imageCount, 6);

    final imageNodes = generated.document.whereType<LocalImageNode>().toList();
    expect(imageNodes.length, 6);
    for (final img in imageNodes) {
      final file = File(img.resolvedFilePath);
      expect(file.existsSync(), isTrue);
      final parsedRatio = DocumentJsonCodec.readAspectRatioFromFile(file);
      expect(parsedRatio, closeTo(img.aspectRatio, 0.01));
    }

    // Verify custom Editor commands execute cleanly on the 50k+ word document.
    final composer = MutableDocumentComposer();
    final editor = Editor(
      editables: {
        Editor.documentKey: generated.document,
        Editor.composerKey: composer,
      },
      requestHandlers: [
        (ed, req) => req is SetExclusiveTextAttributionRequest
            ? SetExclusiveTextAttributionCommand(
                documentRange: req.documentRange,
                attributionId: req.attributionId,
                newAttribution: req.newAttribution,
              )
            : null,
        (ed, req) => req is ResizeLocalImageRequest
            ? ResizeLocalImageCommand(
                nodeId: req.nodeId,
                widthFraction: req.widthFraction,
              )
            : null,
        ...defaultRequestHandlers,
      ],
    );

    final firstPara = generated.document.whereType<ParagraphNode>().skip(1).first;
    editor.execute([
      SetExclusiveTextAttributionRequest(
        documentRange: DocumentRange(
          start: DocumentPosition(nodeId: firstPara.id, nodePosition: const TextNodePosition(offset: 0)),
          end: DocumentPosition(nodeId: firstPara.id, nodePosition: const TextNodePosition(offset: 10)),
        ),
        attributionId: 'font_size',
        newAttribution: const FontSizeAttribution(26.0),
      ),
      ResizeLocalImageRequest(
        nodeId: imageNodes.first.id,
        widthFraction: 0.50,
      ),
    ]);

    final updatedPara = generated.document.getNodeById(firstPara.id)! as ParagraphNode;
    expect(updatedPara.text.getAllAttributionsAt(2), contains(const FontSizeAttribution(26.0)));
    final updatedImg = generated.document.getNodeById(imageNodes.first.id)! as LocalImageNode;
    expect(updatedImg.widthFraction, closeTo(0.50, 0.001));
  });
}
