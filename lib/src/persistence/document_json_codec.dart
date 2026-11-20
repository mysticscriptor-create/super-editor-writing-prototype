import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:path/path.dart' as p;
import 'package:super_editor/super_editor.dart';

import '../editor/local_image_node.dart';

/// Structured, extensible JSON codec for persisting the editor's [Document]
/// without collapsing to a plain string or Markdown.
///
/// Preserves:
/// - Block types: normal paragraph, header1..3, unordered/ordered list items (+ indent), LocalImageNode
/// - Inline attributions: bold, italics, fontFamily, fontSize, color, backgroundColor, link
/// - Local image filenames (resolved relative to [imagesDirectoryPath]), aspectRatio, widthFraction, altText
class DocumentJsonCodec {
  static const int currentFormatVersion = 1;

  static String encodeDocument(Document document) {
    final nodesJson = <Map<String, dynamic>>[];
    for (int i = 0; i < document.length; i++) {
      final node = document.getNodeAt(i);
      if (node != null) {
        nodesJson.add(_encodeNode(node));
      }
    }
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'scribe_super_editor_doc',
      'version': currentFormatVersion,
      'nodes': nodesJson,
    });
  }

  static MutableDocument decodeDocument(
    String jsonText, {
    required String imagesDirectoryPath,
  }) {
    final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
    final rawNodes = decoded['nodes'] as List<dynamic>? ?? const [];
    final nodes = <DocumentNode>[];

    for (final item in rawNodes) {
      if (item is Map<String, dynamic>) {
        final node = _decodeNode(item, imagesDirectoryPath: imagesDirectoryPath);
        if (node != null) {
          nodes.add(node);
        }
      }
    }

    if (nodes.isEmpty) {
      nodes.add(
        ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText(),
        ),
      );
    }

    return MutableDocument(nodes: nodes);
  }

  static Map<String, dynamic> _encodeNode(DocumentNode node) {
    if (node is LocalImageNode) {
      return {
        'type': 'localImage',
        'id': node.id,
        'localFileName': node.localFileName,
        'aspectRatio': node.aspectRatio,
        'widthFraction': node.widthFraction,
        'altText': node.altText,
      };
    }

    if (node is ImageNode) {
      return {
        'type': 'image',
        'id': node.id,
        'imageUrl': node.imageUrl,
        'altText': node.altText,
      };
    }

    if (node is ListItemNode) {
      return {
        'type': 'listItem',
        'id': node.id,
        'listType': node.type == ListItemType.ordered ? 'ordered' : 'unordered',
        'indent': node.indent,
        'text': node.text.toPlainText(includePlaceholders: false),
        'spans': _encodeSpans(node.text),
      };
    }

    if (node is ParagraphNode) {
      final blockAttr = node.getMetadataValue(NodeMetadata.blockType);
      final blockType = blockAttr is Attribution ? blockAttr.id : 'paragraph';
      return {
        'type': 'paragraph',
        'id': node.id,
        'blockType': blockType,
        'indent': node.indent,
        'text': node.text.toPlainText(includePlaceholders: false),
        'spans': _encodeSpans(node.text),
      };
    }

    if (node is TextNode) {
      return {
        'type': 'paragraph',
        'id': node.id,
        'blockType': 'paragraph',
        'indent': 0,
        'text': node.text.toPlainText(includePlaceholders: false),
        'spans': _encodeSpans(node.text),
      };
    }

    return {
      'type': 'paragraph',
      'id': node.id,
      'blockType': 'paragraph',
      'indent': 0,
      'text': '',
      'spans': const [],
    };
  }

  static List<Map<String, dynamic>> _encodeSpans(AttributedText text) {
    if (text.isEmpty) return const [];
    final collapsed = text.spans.collapseSpans(contentLength: text.length);
    final result = <Map<String, dynamic>>[];

    for (final span in collapsed) {
      if (span.attributions.isEmpty) continue;
      final attrs = <Map<String, dynamic>>[];
      for (final attr in span.attributions) {
        final encoded = _encodeAttribution(attr);
        if (encoded != null) {
          attrs.add(encoded);
        }
      }
      if (attrs.isNotEmpty) {
        result.add({
          'start': span.start,
          'end': span.end,
          'attributions': attrs,
        });
      }
    }
    return result;
  }

  static Map<String, dynamic>? _encodeAttribution(Attribution attr) {
    if (attr == boldAttribution) {
      return {'kind': 'bold'};
    }
    if (attr == italicsAttribution) {
      return {'kind': 'italics'};
    }
    if (attr == underlineAttribution) {
      return {'kind': 'underline'};
    }
    if (attr == strikethroughAttribution) {
      return {'kind': 'strikethrough'};
    }
    if (attr is FontFamilyAttribution) {
      return {'kind': 'font_family', 'value': attr.fontFamily};
    }
    if (attr is FontSizeAttribution) {
      return {'kind': 'font_size', 'value': attr.fontSize};
    }
    if (attr is ColorAttribution) {
      return {'kind': 'color', 'value': attr.color.toARGB32()};
    }
    if (attr is BackgroundColorAttribution) {
      return {'kind': 'background_color', 'value': attr.color.toARGB32()};
    }
    if (attr is LinkAttribution) {
      return {'kind': 'link', 'value': attr.plainTextUri};
    }
    return null;
  }

  static DocumentNode? _decodeNode(
    Map<String, dynamic> map, {
    required String imagesDirectoryPath,
  }) {
    final type = map['type'] as String? ?? 'paragraph';
    final id = map['id'] as String? ?? Editor.createNodeId();

    if (type == 'localImage') {
      final fileName = map['localFileName'] as String? ?? '';
      final resolvedPath = fileName.isEmpty ? '' : p.join(imagesDirectoryPath, fileName);
      final aspect = (map['aspectRatio'] as num?)?.toDouble() ?? 1.5;
      final fraction = (map['widthFraction'] as num?)?.toDouble() ?? 0.85;
      final altText = map['altText'] as String? ?? '';
      return LocalImageNode(
        id: id,
        localFileName: fileName,
        resolvedFilePath: resolvedPath,
        aspectRatio: aspect > 0.05 ? aspect : 1.5,
        widthFraction: fraction.clamp(0.25, 1.0),
        altText: altText,
      );
    }

    if (type == 'image') {
      return ImageNode(
        id: id,
        imageUrl: map['imageUrl'] as String? ?? '',
        altText: map['altText'] as String? ?? '',
      );
    }

    final plainText = map['text'] as String? ?? '';
    final spansRaw = map['spans'] as List<dynamic>? ?? const [];
    final text = _decodeAttributedText(plainText, spansRaw);

    if (type == 'listItem') {
      final listType = (map['listType'] as String?) == 'ordered'
          ? ListItemType.ordered
          : ListItemType.unordered;
      final indent = (map['indent'] as num?)?.toInt() ?? 0;
      return ListItemNode(
        id: id,
        itemType: listType,
        indent: indent,
        text: text,
      );
    }

    final blockTypeStr = map['blockType'] as String? ?? 'paragraph';
    final indent = (map['indent'] as num?)?.toInt() ?? 0;
    final blockTypeAttr = switch (blockTypeStr) {
      'header1' => header1Attribution,
      'header2' => header2Attribution,
      'header3' => header3Attribution,
      'header4' => header4Attribution,
      'header5' => header5Attribution,
      'header6' => header6Attribution,
      'blockquote' => blockquoteAttribution,
      _ => paragraphAttribution,
    };

    return ParagraphNode(
      id: id,
      text: text,
      indent: indent,
      metadata: {
        NodeMetadata.blockType: blockTypeAttr,
      },
    );
  }

  static AttributedText _decodeAttributedText(
    String plainText,
    List<dynamic> spansRaw,
  ) {
    if (plainText.isEmpty || spansRaw.isEmpty) {
      return AttributedText(plainText);
    }
    final markers = <SpanMarker>[];
    for (final item in spansRaw) {
      if (item is! Map<String, dynamic>) continue;
      final start = (item['start'] as num?)?.toInt() ?? 0;
      final end = (item['end'] as num?)?.toInt() ?? -1;
      if (start < 0 || end < start || end >= plainText.length) continue;
      final attrsRaw = item['attributions'] as List<dynamic>? ?? const [];
      for (final attrMap in attrsRaw) {
        if (attrMap is! Map<String, dynamic>) continue;
        final attr = _decodeAttribution(attrMap);
        if (attr != null) {
          markers.add(
            SpanMarker(
              attribution: attr,
              offset: start,
              markerType: SpanMarkerType.start,
            ),
          );
          markers.add(
            SpanMarker(
              attribution: attr,
              offset: end,
              markerType: SpanMarkerType.end,
            ),
          );
        }
      }
    }
    return AttributedText(
      plainText,
      AttributedSpans(attributions: markers),
    );
  }

  static Attribution? _decodeAttribution(Map<String, dynamic> map) {
    final kind = map['kind'] as String?;
    return switch (kind) {
      'bold' => boldAttribution,
      'italics' => italicsAttribution,
      'underline' => underlineAttribution,
      'strikethrough' => strikethroughAttribution,
      'font_family' => map['value'] is String ? FontFamilyAttribution(map['value'] as String) : null,
      'font_size' => map['value'] is num ? FontSizeAttribution((map['value'] as num).toDouble()) : null,
      'color' => map['value'] is int ? ColorAttribution(Color(map['value'] as int)) : null,
      'background_color' =>
        map['value'] is int ? BackgroundColorAttribution(Color(map['value'] as int)) : null,
      'link' => map['value'] is String ? LinkAttribution(map['value'] as String) : null,
      _ => null,
    };
  }

  /// Reads natural width/height from PNG, JPEG, GIF, or WebP headers synchronously.
  static double readAspectRatioFromImageBytes(Uint8List bytes) {
    if (bytes.length < 24) return 1.5;

    // PNG signature: 89 50 4E 47 0D 0A 1A 0A
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      final w = _readUint32BE(bytes, 16);
      final h = _readUint32BE(bytes, 20);
      if (w > 0 && h > 0) return w / h;
    }

    // GIF87a / GIF89a
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      final w = bytes[6] | (bytes[7] << 8);
      final h = bytes[8] | (bytes[9] << 8);
      if (w > 0 && h > 0) return w / h;
    }

    // JPEG: FF D8
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      int i = 2;
      while (i + 9 < bytes.length) {
        if (bytes[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = bytes[i + 1];
        if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
          final h = (bytes[i + 5] << 8) | bytes[i + 6];
          final w = (bytes[i + 7] << 8) | bytes[i + 8];
          if (w > 0 && h > 0) return w / h;
          break;
        }
        if (marker == 0xD8 || marker == 0xD9 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
          i += 2;
          continue;
        }
        if (i + 3 >= bytes.length) break;
        final segLen = (bytes[i + 2] << 8) | bytes[i + 3];
        if (segLen < 2) break;
        i += 2 + segLen;
      }
    }

    return 1.5;
  }

  static double readAspectRatioFromFile(File file) {
    try {
      if (!file.existsSync()) return 1.5;
      final bytes = file.readAsBytesSync();
      return readAspectRatioFromImageBytes(bytes);
    } catch (_) {
      return 1.5;
    }
  }

  static int _readUint32BE(Uint8List b, int offset) {
    return (b[offset] << 24) | (b[offset + 1] << 16) | (b[offset + 2] << 8) | b[offset + 3];
  }
}
