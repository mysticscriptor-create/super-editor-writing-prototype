import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:attributed_text/attributed_text.dart';
import 'package:path/path.dart' as p;
import 'package:super_editor/super_editor.dart';

import '../editor/local_image_node.dart';

class GeneratedSampleDocument {
  const GeneratedSampleDocument({
    required this.document,
    required this.wordCount,
    required this.nodeCount,
    required this.imageCount,
  });

  final MutableDocument document;
  final int wordCount;
  final int nodeCount;
  final int imageCount;
}

/// Generates a realistic >=50,000-word manuscript containing headings, varied
/// wrapped paragraphs, bulleted and numbered lists, inline WYSIWYG formatting,
/// and multiple procedural local PNG images distributed throughout.
class SampleDocumentGenerator {
  static const int targetMinimumWords = 52000;

  static const _chapterTitles = [
    'Foundations of Long-Form Visual Editing',
    'Typography, Measure, and Reading Rhythm',
    'Incremental Layout and Viewport Virtualization',
    'Selection Geometry and Touch Handle Precision',
    'Coordinated Deletion Physics Across Viewports',
    'Local Media Persistence and Decoding Budgets',
    'Structured Document Models Versus Plain Strings',
    'Real-Time IME Composition on Mobile Keyboards',
    'Evaluating Scroll Anchors at Document Boundaries',
    'Field Notes from Physical Device Profiling',
  ];

  static const _subHeadings = [
    'Architectural Boundaries and State Ownership',
    'Wrapped Line Metrics Under Dynamic Font Scaling',
    'Preserving Visual Anchors During Content Collapse',
    'Handling Clamped Scroll Extremes Without Jumps',
    'Balancing Cache Memory Against Frame Pacing',
  ];

  static const _sentences = [
    'A long-form visual writing editor lives or dies by how quietly it handles large selections when the writer moves fast.',
    'When thirty thousand words sit above the current paragraph and twenty thousand sit below it, every unvirtualized layout pass steals frame time from input latency.',
    'Writers rarely pause to consider coordinate spaces, yet a single mismatch between document coordinates and clipped viewport bounds turns a smooth edit into an unexpected jump.',
    'Real WYSIWYG styling requires rich attributed spans—bold emphasis, italic cadence, readable serif or monospace contrast, and gentle highlights—without serializing the active buffer to raw syntax strings on every keystroke.',
    'If a selection begins three pages above the top toolbar and ends two lines inside the visible window, deleting that span should keep the lower surviving sentence anchored exactly where the eye already rests.',
    'Conversely, when only the upper selection handle remains inside the usable viewport while the lower handle sits behind the software keyboard, collapsing the gap upward preserves orientation.',
    'Testing against a toy ten-paragraph note hides quadratic presenter rebuilds, synchronous full-document text shaping, and eager image decoding stalls that immediately surface in a fifty-thousand-word manuscript.',
    'Every inline image belongs inside the document tree as a structured block node backed by a local file reference and stable aspect-ratio metadata.',
    'Before mutating text buffers or collapsing ranges, capturing clipped handle rects against the usable editor viewport gives the layout coordinator ground truth.',
    'Single-shot editor transactions paired with a unified animation clock prevent split-region seams from tearing or drifting apart under frame pressure.',
  ];

  static const _listFragments = [
    'Capture pre-deletion viewport geometry strictly before executing the editor mutation.',
    'Classify handle visibility using clipped screen-space bounds rather than logical indices.',
    'Suppress competing auto-scroll callbacks during active collapse or glide animations.',
    'Virtualize offscreen nodes with bounded frame-budgeted measurement passes.',
    'Store structured node attributes and local image references independently of Markdown exports.',
  ];

  static GeneratedSampleDocument generate50kWordDocument({
    required String imagesDirectoryPath,
    int minimumWords = targetMinimumWords,
  }) {
    final imgDir = Directory(imagesDirectoryPath);
    if (!imgDir.existsSync()) {
      imgDir.createSync(recursive: true);
    }

    // Create 6 distinct local PNG assets distributed across the 50k+ word document.
    final imageSpecs = <({
      String fileName,
      String title,
      int width,
      int height,
      Color c1,
      Color c2,
      double fraction,
    })>[
      (
        fileName: 'sample_plate_01_intro.png',
        title: 'Plate 1: Viewport Coordinate Architecture',
        width: 640,
        height: 360,
        c1: const Color(0xFF1D4ED8),
        c2: const Color(0xFF93C5FD),
        fraction: 0.90,
      ),
      (
        fileName: 'sample_plate_02_layout.png',
        title: 'Plate 2: Virtualized Sliver Windowing',
        width: 600,
        height: 400,
        c1: const Color(0xFF0F766E),
        c2: const Color(0xFF99F6E4),
        fraction: 0.78,
      ),
      (
        fileName: 'sample_plate_03_handles.png',
        title: 'Plate 3: Clipped Handle Geometry',
        width: 560,
        height: 420,
        c1: const Color(0xFFB45309),
        c2: const Color(0xFFFDE68A),
        fraction: 0.72,
      ),
      (
        fileName: 'sample_plate_04_seam.png',
        title: 'Plate 4: Split-Seam Transform Composition',
        width: 640,
        height: 340,
        c1: const Color(0xFF7C3AED),
        c2: const Color(0xFFDDD6FE),
        fraction: 0.85,
      ),
      (
        fileName: 'sample_plate_05_ime.png',
        title: 'Plate 5: Gboard Delta and Composing Boundary',
        width: 600,
        height: 380,
        c1: const Color(0xFFBE123C),
        c2: const Color(0xFFFECDD3),
        fraction: 0.80,
      ),
      (
        fileName: 'sample_plate_06_appendix.png',
        title: 'Plate 6: End-of-Document Boundary Clamping',
        width: 620,
        height: 360,
        c1: const Color(0xFF334155),
        c2: const Color(0xFFCBD5E1),
        fraction: 0.88,
      ),
    ];

    final imagePaths = <String>[];
    for (int i = 0; i < imageSpecs.length; i++) {
      final spec = imageSpecs[i];
      final file = File(p.join(imagesDirectoryPath, spec.fileName));
      if (!file.existsSync()) {
        final pngBytes = _createGradientPng(
          width: spec.width,
          height: spec.height,
          topLeft: spec.c1,
          bottomRight: spec.c2,
          stripePhase: i + 1,
        );
        file.writeAsBytesSync(pngBytes, flush: true);
      }
      imagePaths.add(file.path);
    }

    final nodes = <DocumentNode>[];
    int totalWords = 0;
    int nodeSeq = 0;
    int chapterIdx = 0;
    int imageCursor = 0;

    String nextId(String prefix) => '${prefix}_${nodeSeq++}';

    int countWords(String text) {
      if (text.trim().isEmpty) return 0;
      return text.trim().split(RegExp(r'\s+')).length;
    }

    // Opening title + quick orientation paragraph.
    const introTitle = 'Scribe Long-Document Editor Prototype (50,000+ Words)';
    nodes.add(
      ParagraphNode(
        id: nextId('h1'),
        text: AttributedText(introTitle),
        metadata: const {NodeMetadata.blockType: header1Attribution},
      ),
    );
    totalWords += countWords(introTitle);

    final introText = _buildStyledParagraph(
      'This structured manuscript exceeds 50,000 words and includes rich WYSIWYG formatting '
      '(bold, italic, serif/monospace spans, sizes, colors, highlights, and links), '
      'bulleted and numbered lists, wrapped long paragraphs, and inline local PNG images. '
      'Use Android selection handles and Gboard Backspace or toolbar Delete to exercise Scenarios A through E.',
      seed: 0,
      includeRichStyles: true,
    );
    nodes.add(ParagraphNode(id: nextId('p'), text: introText));
    totalWords += countWords(introText.toPlainText());

    // Distribute images evenly roughly every ~9,000 words so beginning, middle, and end all contain images.
    const wordsPerImageBucket = 9000;

    while (totalWords < minimumWords) {
      final chTitle =
          'Chapter ${chapterIdx + 1}: ${_chapterTitles[chapterIdx % _chapterTitles.length]}';
      nodes.add(
        ParagraphNode(
          id: nextId('h1'),
          text: AttributedText(chTitle),
          metadata: const {NodeMetadata.blockType: header1Attribution},
        ),
      );
      totalWords += countWords(chTitle);

      // Insert an image near the opening of chapters aligned with image buckets.
      if (imageCursor < imageSpecs.length &&
          totalWords >= imageCursor * wordsPerImageBucket + 350) {
        final spec = imageSpecs[imageCursor];
        nodes.add(
          LocalImageNode(
            id: nextId('img'),
            localFileName: spec.fileName,
            resolvedFilePath: imagePaths[imageCursor],
            aspectRatio: spec.width / spec.height,
            widthFraction: spec.fraction,
            altText: spec.title,
          ),
        );
        imageCursor++;
      }

      for (int section = 0; section < 5 && totalWords < minimumWords; section++) {
        final subTitle =
            '${chapterIdx + 1}.${section + 1} ${_subHeadings[(chapterIdx + section) % _subHeadings.length]}';
        nodes.add(
          ParagraphNode(
            id: nextId('h2'),
            text: AttributedText(subTitle),
            metadata: const {NodeMetadata.blockType: header2Attribution},
          ),
        );
        totalWords += countWords(subTitle);

        // 4 varied-length paragraphs per subsection (from short 2-line to long 8-line wrapped paragraphs).
        for (int pIdx = 0; pIdx < 4 && totalWords < minimumWords; pIdx++) {
          final sentenceCount = switch ((chapterIdx + section + pIdx) % 4) {
            0 => 2,
            1 => 4,
            2 => 6,
            _ => 8,
          };
          final buf = StringBuffer();
          for (int s = 0; s < sentenceCount; s++) {
            if (s > 0) buf.write(' ');
            buf.write(_sentences[(chapterIdx * 7 + section * 5 + pIdx * 3 + s) % _sentences.length]);
          }
          final para = _buildStyledParagraph(
            buf.toString(),
            seed: chapterIdx * 31 + section * 7 + pIdx,
            includeRichStyles: (pIdx % 2 == 0),
          );
          nodes.add(ParagraphNode(id: nextId('p'), text: para));
          totalWords += countWords(para.toPlainText());
        }

        // Occasional H3 + bulleted or numbered list.
        if (section % 2 == 0 && totalWords < minimumWords) {
          const h3Text = 'Verification Checklist Items';
          nodes.add(
            ParagraphNode(
              id: nextId('h3'),
              text: AttributedText(h3Text),
              metadata: const {NodeMetadata.blockType: header3Attribution},
            ),
          );
          totalWords += countWords(h3Text);

          final isOrdered = (chapterIdx + section) % 4 == 0;
          for (int li = 0; li < 3 && totalWords < minimumWords; li++) {
            final itemText = _listFragments[(chapterIdx + li) % _listFragments.length];
            final styled = _buildStyledParagraph(
              itemText,
              seed: li + 11,
              includeRichStyles: false,
            );
            nodes.add(
              isOrdered
                  ? ListItemNode.ordered(id: nextId('li'), text: styled)
                  : ListItemNode.unordered(id: nextId('li'), text: styled),
            );
            totalWords += countWords(itemText);
          }
        }
      }
      chapterIdx++;
    }

    // Ensure all 6 images are inserted even if minimumWords was small in a test.
    while (imageCursor < imageSpecs.length) {
      final spec = imageSpecs[imageCursor];
      nodes.add(
        LocalImageNode(
          id: nextId('img'),
          localFileName: spec.fileName,
          resolvedFilePath: imagePaths[imageCursor],
          aspectRatio: spec.width / spec.height,
          widthFraction: spec.fraction,
          altText: spec.title,
        ),
      );
      imageCursor++;
    }

    // Closing paragraph at the end of the document so typing/selection at end is straightforward.
    const closingText =
        'End of manuscript benchmark. Placing the cursor here tests typing latency, scroll clamping, and Scenario B/D deletions near the trailing document boundary.';
    nodes.add(ParagraphNode(id: nextId('p'), text: AttributedText(closingText)));
    totalWords += countWords(closingText);

    return GeneratedSampleDocument(
      document: MutableDocument(nodes: nodes),
      wordCount: totalWords,
      nodeCount: nodes.length,
      imageCount: imageSpecs.length,
    );
  }

  static AttributedText _buildStyledParagraph(
    String text, {
    required int seed,
    required bool includeRichStyles,
  }) {
    if (text.length < 24) {
      return AttributedText(text);
    }
    final spans = AttributedSpans();
    // Apply bold on an early phrase.
    final firstSpace = text.indexOf(' ', 6);
    if (firstSpace > 2) {
      spans.addAttribution(
        newAttribution: boldAttribution,
        start: 0,
        end: math.min(text.length - 1, firstSpace + 8),
      );
    }
    // Apply italics on a mid phrase.
    final midStart = text.length ~/ 3;
    final midEnd = math.min(text.length - 1, midStart + 18);
    if (midEnd > midStart) {
      spans.addAttribution(
        newAttribution: italicsAttribution,
        start: midStart,
        end: midEnd,
      );
    }

    if (includeRichStyles && text.length > 60) {
      if (seed % 3 == 0) {
        spans.addAttribution(
          newAttribution: const ColorAttribution(Color(0xFF1D4ED8)),
          start: midStart,
          end: midEnd,
        );
      } else if (seed % 3 == 1) {
        spans.addAttribution(
          newAttribution: const BackgroundColorAttribution(Color(0xFFFEF08A)),
          start: midStart,
          end: midEnd,
        );
      } else {
        spans.addAttribution(
          newAttribution: const FontFamilyAttribution('serif'),
          start: 0,
          end: math.min(text.length - 1, 20),
        );
      }
      if (seed % 5 == 0) {
        spans.addAttribution(
          newAttribution: const LinkAttribution('https://example.com/scribe-editor-spec'),
          start: text.length - 14,
          end: text.length - 2,
        );
      }
    }

    return AttributedText(text, spans);
  }

  /// Generates a valid 24-bit RGBA PNG image in pure Dart (zero external deps).
  static Uint8List _createGradientPng({
    required int width,
    required int height,
    required Color topLeft,
    required Color bottomRight,
    required int stripePhase,
  }) {
    final raw = BytesBuilder(copy: false);
    final r1 = (topLeft.r * 255.0).round();
    final g1 = (topLeft.g * 255.0).round();
    final b1 = (topLeft.b * 255.0).round();
    final r2 = (bottomRight.r * 255.0).round();
    final g2 = (bottomRight.g * 255.0).round();
    final b2 = (bottomRight.b * 255.0).round();

    for (int y = 0; y < height; y++) {
      raw.addByte(0); // PNG filter type 0 (None)
      final ty = y / math.max(1, height - 1);
      for (int x = 0; x < width; x++) {
        final tx = x / math.max(1, width - 1);
        final t = (tx * 0.55 + ty * 0.45);
        final isGridLine = (x % 48 == 0) || (y % 48 == 0);
        final isDiagonalBand = ((x + y * stripePhase) % 110) < 12;
        int r = (r1 + (r2 - r1) * t).round().clamp(0, 255);
        int g = (g1 + (g2 - g1) * t).round().clamp(0, 255);
        int b = (b1 + (b2 - b1) * t).round().clamp(0, 255);
        if (isGridLine) {
          r = (r + 32).clamp(0, 255);
          g = (g + 32).clamp(0, 255);
          b = (b + 32).clamp(0, 255);
        } else if (isDiagonalBand) {
          r = 255;
          g = 255;
          b = 255;
        }
        raw.addByte(r);
        raw.addByte(g);
        raw.addByte(b);
        raw.addByte(255);
      }
    }

    final compressed = Uint8List.fromList(ZLibCodec(level: 3).encode(raw.toBytes()));
    final ihdr = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8) // bit depth
      ..setUint8(9, 6) // color type RGBA
      ..setUint8(10, 0)
      ..setUint8(11, 0)
      ..setUint8(12, 0);

    final out = BytesBuilder(copy: false)
      ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      ..add(_pngChunk('IHDR', ihdr.buffer.asUint8List()))
      ..add(_pngChunk('IDAT', compressed))
      ..add(_pngChunk('IEND', Uint8List(0)));

    return out.toBytes();
  }

  static Uint8List _pngChunk(String type, Uint8List data) {
    final lenBytes = ByteData(4)..setUint32(0, data.length);
    final typeBytes = type.codeUnits;
    final crcInput = Uint8List(4 + data.length)
      ..setRange(0, 4, typeBytes)
      ..setRange(4, 4 + data.length, data);
    final crcBytes = ByteData(4)..setUint32(0, _crc32(crcInput));

    return (BytesBuilder(copy: false)
          ..add(lenBytes.buffer.asUint8List())
          ..add(typeBytes)
          ..add(data)
          ..add(crcBytes.buffer.asUint8List()))
        .toBytes();
  }

  static int _crc32(Uint8List bytes) {
    int crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc ^= byte;
      for (int i = 0; i < 8; i++) {
        final mask = -(crc & 1);
        crc = (crc >>> 1) ^ (0xEDB88320 & mask);
      }
    }
    return crc ^ 0xFFFFFFFF;
  }
}
