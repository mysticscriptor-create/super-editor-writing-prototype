import 'dart:io';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_editor/super_editor.dart';
import 'package:uuid/uuid.dart';

import '../editor/authoritative_scroll.dart';
import '../editor/deletion_coordinator.dart';
import '../editor/document_attributions.dart';
import '../editor/local_image_node.dart';
import '../editor/scribe_super_editor.dart';
import '../editor/split_seam_content_layers.dart';
import '../editor/virtualized_document_layout.dart';
import '../persistence/document_json_codec.dart';
import '../persistence/markdown_codec.dart';
import '../persistence/sample_document_generator.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with SingleTickerProviderStateMixin {
  static const _docFileName = 'scribe_document.json';
  static const _imagesSubdir = 'scribe_images';

  final GlobalKey _viewportKey = GlobalKey(debugLabel: 'usable-editor-viewport');
  final FocusNode _editorFocusNode = FocusNode(debugLabel: 'scribe-editor-focus');
  final Stylesheet _stylesheet = buildPrototypeStylesheet();
  final ImagePicker _imagePicker = ImagePicker();
  final Uuid _uuid = const Uuid();

  late AuthoritativeScrollController _scrollController;
  late SplitSeamRenderState _splitState;

  MutableDocument? _document;
  MutableDocumentComposer? _composer;
  Editor? _editor;
  DocumentMetricsIndex? _metricsIndex;
  DeletionCoordinator? _deletionCoordinator;
  DocumentLayout? Function()? _getDocumentLayout;

  String? _storageDirPath;
  String? _imagesDirPath;
  bool _isLoading = true;
  String _loadSummary = 'Initializing editor...';
  int _cachedWordCount = 0;

  @override
  void initState() {
    super.initState();
    _splitState = SplitSeamRenderState();
    _scrollController = AuthoritativeScrollController(
      onUserScrollStarted: () => _deletionCoordinator?.handleUserScrollStarted(),
    );
    _initializeStorageAndDocument();
  }

  @override
  void dispose() {
    _disposeEditorSession();
    _scrollController.dispose();
    _splitState.dispose();
    _editorFocusNode.dispose();
    super.dispose();
  }

  void _disposeEditorSession() {
    _composer?.selectionNotifier.removeListener(_onSelectionChanged);
    _document?.removeListener(_onDocumentChanged);
    _deletionCoordinator?.dispose();
    _metricsIndex?.dispose();
    _composer?.dispose();
    _editor?.dispose();
    _document?.dispose();
    _deletionCoordinator = null;
    _metricsIndex = null;
    _composer = null;
    _editor = null;
    _document = null;
  }

  Future<void> _initializeStorageAndDocument() async {
    final appDir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory(p.join(appDir.path, _imagesSubdir));
    if (!imagesDir.existsSync()) {
      imagesDir.createSync(recursive: true);
    }
    _storageDirPath = appDir.path;
    _imagesDirPath = imagesDir.path;

    final savedFile = File(p.join(appDir.path, _docFileName));
    if (savedFile.existsSync()) {
      try {
        final sw = Stopwatch()..start();
        final jsonText = await savedFile.readAsString();
        final doc = DocumentJsonCodec.decodeDocument(
          jsonText,
          imagesDirectoryPath: imagesDir.path,
        );
        sw.stop();
        _mountDocument(
          doc,
          statusMessage: 'Reopened saved document in ${sw.elapsedMilliseconds} ms',
        );
        return;
      } catch (_) {
        // Fall through to 50k sample generation if saved file is corrupted.
      }
    }

    await _load50kSample(saveImmediately: true);
  }

  void _mountDocument(
    MutableDocument newDoc, {
    String? statusMessage,
  }) {
    _disposeEditorSession();

    final composer = MutableDocumentComposer();
    final editor = Editor(
      editables: {
        Editor.documentKey: newDoc,
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
      historyGroupingPolicy: defaultMergePolicy,
      reactionPipeline: List.from(defaultEditorReactions),
      isHistoryEnabled: true,
    );

    final metricsIndex = DocumentMetricsIndex(
      document: newDoc,
      stylesheet: _stylesheet,
    );

    final coordinator = DeletionCoordinator(
      vsync: this,
      editor: editor,
      document: newDoc,
      composer: composer,
      scrollController: _scrollController,
      metricsIndex: metricsIndex,
      getDocumentLayout: () => _getDocumentLayout?.call(),
      viewportKey: _viewportKey,
      getControlsController: () => _scribeEditorKey.currentState?.controlsController,
      splitState: _splitState,
    );

    _document = newDoc;
    _composer = composer;
    _editor = editor;
    _metricsIndex = metricsIndex;
    _deletionCoordinator = coordinator;
    _cachedWordCount = _countDocumentWords(newDoc);

    newDoc.addListener(_onDocumentChanged);
    composer.selectionNotifier.addListener(_onSelectionChanged);

    if (_scrollController.hasClients) {
      _scrollController.authoritativeJumpTo(0.0);
    }

    setState(() {
      _isLoading = false;
      _loadSummary = statusMessage ?? '$_cachedWordCount words · ${newDoc.length} nodes';
    });
  }

  // Note: ScribeSuperEditorState owns the live SuperEditorAndroidControlsController;
  // DeletionCoordinator hides overlays on deletion start via a controller wired below.
  final GlobalKey<ScribeSuperEditorState> _scribeEditorKey = GlobalKey();

  void _onDocumentChanged(DocumentChangeLog log) {
    final doc = _document;
    if (doc == null || !mounted) return;
    // Update word count lazily without scanning on every single keystroke for 50k docs.
    if (log.changes.any((c) => c is NodeInsertedEvent || c is NodeRemovedEvent)) {
      _cachedWordCount = _countDocumentWords(doc);
    }
    setState(() {});
  }

  void _onSelectionChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  int _countDocumentWords(Document doc) {
    int count = 0;
    for (int i = 0; i < doc.length; i++) {
      final node = doc.getNodeAt(i);
      if (node is TextNode) {
        final t = node.text.toPlainText(includePlaceholders: false).trim();
        if (t.isNotEmpty) {
          count += t.split(RegExp(r'\s+')).length;
        }
      }
    }
    return count;
  }

  Future<void> _load50kSample({bool saveImmediately = false}) async {
    final imagesDir = _imagesDirPath;
    if (imagesDir == null) return;
    setState(() {
      _isLoading = true;
      _loadSummary = 'Generating 50,000+ word document...';
    });
    await Future<void>.delayed(const Duration(milliseconds: 16));
    final sw = Stopwatch()..start();
    final generated = SampleDocumentGenerator.generate50kWordDocument(
      imagesDirectoryPath: imagesDir,
    );
    sw.stop();
    _mountDocument(
      generated.document,
      statusMessage:
          'Loaded ${generated.wordCount} words (${generated.nodeCount} nodes, ${generated.imageCount} images) in ${sw.elapsedMilliseconds} ms',
    );
    if (saveImmediately) {
      await _saveDocumentToDisk(silent: true);
    } else if (mounted) {
      _showSnack(
        'Loaded ${generated.wordCount} words & ${generated.imageCount} local images in ${sw.elapsedMilliseconds} ms',
      );
    }
  }

  void _createBlankDocument() {
    final doc = MutableDocument(
      nodes: [
        ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('Untitled Document'),
          metadata: const {NodeMetadata.blockType: header1Attribution},
        ),
        ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('Start writing here...'),
        ),
      ],
    );
    _mountDocument(doc, statusMessage: 'Created new document');
  }

  Future<void> _saveDocumentToDisk({bool silent = false}) async {
    final doc = _document;
    final dirPath = _storageDirPath;
    if (doc == null || dirPath == null) return;
    final sw = Stopwatch()..start();
    final encoded = DocumentJsonCodec.encodeDocument(doc);
    final file = File(p.join(dirPath, _docFileName));
    await file.writeAsString(encoded, flush: true);
    sw.stop();
    if (!silent && mounted) {
      _showSnack('Saved structured document (${(encoded.length / 1024).toStringAsFixed(1)} KB) in ${sw.elapsedMilliseconds} ms');
    }
  }

  Future<void> _reopenSavedDocument() async {
    final dirPath = _storageDirPath;
    final imagesDir = _imagesDirPath;
    if (dirPath == null || imagesDir == null) return;
    final file = File(p.join(dirPath, _docFileName));
    if (!file.existsSync()) {
      _showSnack('No saved document found yet.');
      return;
    }
    final sw = Stopwatch()..start();
    final jsonText = await file.readAsString();
    final doc = DocumentJsonCodec.decodeDocument(
      jsonText,
      imagesDirectoryPath: imagesDir,
    );
    sw.stop();
    _mountDocument(
      doc,
      statusMessage: 'Reopened saved document in ${sw.elapsedMilliseconds} ms',
    );
    if (mounted) {
      _showSnack('Reopened saved document in ${sw.elapsedMilliseconds} ms');
    }
  }

  Future<void> _pickAndInsertLocalImage() async {
    final imagesDir = _imagesDirPath;
    final doc = _document;
    final editor = _editor;
    final composer = _composer;
    if (imagesDir == null || doc == null || editor == null || composer == null) {
      return;
    }

    final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    final ext = p.extension(picked.path).isEmpty ? '.jpg' : p.extension(picked.path);
    final localFileName = 'img_${_uuid.v4()}$ext';
    final destFile = File(p.join(imagesDir, localFileName));
    final bytes = await picked.readAsBytes();
    await destFile.writeAsBytes(bytes, flush: true);

    final aspectRatio = DocumentJsonCodec.readAspectRatioFromImageBytes(bytes);
    final imageNode = LocalImageNode(
      id: Editor.createNodeId(),
      localFileName: localFileName,
      resolvedFilePath: destFile.path,
      aspectRatio: aspectRatio,
      widthFraction: 0.85,
      altText: p.basenameWithoutExtension(picked.name),
    );

    final sel = composer.selection;
    final targetNodeId = sel?.extent.nodeId ?? doc.lastOrNull?.id;
    if (targetNodeId == null) return;

    final anchorId = composer.selection?.extent.nodeId ?? doc.lastOrNull?.id;
    if (anchorId == null) return;

    final trailingParaId = Editor.createNodeId();
    editor.execute([
      InsertNodeAfterNodeRequest(
        existingNodeId: anchorId,
        newNode: imageNode,
      ),
      InsertNodeAfterNodeRequest(
        existingNodeId: imageNode.id,
        newNode: ParagraphNode(
          id: trailingParaId,
          text: AttributedText(),
        ),
      ),
      ChangeSelectionRequest(
        DocumentSelection(
          base: DocumentPosition(
            nodeId: imageNode.id,
            nodePosition: const UpstreamDownstreamNodePosition.upstream(),
          ),
          extent: DocumentPosition(
            nodeId: imageNode.id,
            nodePosition: const UpstreamDownstreamNodePosition.downstream(),
          ),
        ),
        SelectionChangeType.insertContent,
        SelectionReason.userInteraction,
      ),
    ]);
    await _saveDocumentToDisk(silent: true);
    if (mounted) {
      _showSnack('Inserted local image ($localFileName) and saved reference');
    }
  }

  Future<void> _showExportMarkdownDialog() async {
    final doc = _document;
    if (doc == null) return;

    final result = MarkdownCodec.exportDocument(doc);
    final losses = result.lossReport.describeLosses();
    final previewText = result.markdown.length > 40000
        ? '${result.markdown.substring(0, 40000)}\n\n... [preview truncated at 40,000 chars; Copy exports full ${result.markdown.length} chars]'
        : result.markdown;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Markdown Export & Loss Report'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: result.lossReport.isLossless
                          ? const Color(0xFFECFDF5)
                          : const Color(0xFFFFFBEB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: result.lossReport.isLossless
                            ? const Color(0xFF10B981)
                            : const Color(0xFFF59E0B),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          result.lossReport.isLossless
                              ? 'Lossless Export: All formatting in this document is representable in standard Markdown.'
                              : 'Formatting Not Losslessly Representable in Standard Markdown:',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        if (losses.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          for (final item in losses)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text('• $item', style: const TextStyle(fontSize: 12)),
                            ),
                        ],
                        const SizedBox(height: 4),
                        const Text(
                          'Use Save Document (JSON) to preserve font family, font size, colors, highlights, and image resize fractions losslessly.',
                          style: TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: SelectableText(
                      previewText,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: result.markdown));
                Navigator.of(ctx).pop();
                _showSnack('Copied ${result.markdown.length} chars of Markdown to clipboard');
              },
              child: const Text('Copy Full Markdown'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showImportMarkdownDialog() async {
    final imagesDir = _imagesDirPath;
    if (imagesDir == null) return;
    final controller = TextEditingController(
      text: '# Imported Markdown\n\nThis paragraph has **bold**, *italic*, and a [link](https://example.com).\n\n- Bullet item one\n- Bullet item two\n\n1. First numbered item\n2. Second numbered item\n',
    );

    final imported = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Import Standard Markdown'),
          content: SizedBox(
            width: double.maxFinite,
            child: TextField(
              controller: controller,
              maxLines: 12,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Paste Markdown text here...',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('Import'),
            ),
          ],
        );
      },
    );
    controller.dispose();

    if (imported == null) return;
    final doc = MarkdownCodec.importMarkdown(
      imported,
      imagesDirectoryPath: imagesDir,
    );
    _mountDocument(doc, statusMessage: 'Imported Markdown (${doc.length} nodes)');
  }

  void _showDiagnosticsDialog() {
    final report = _deletionCoordinator?.lastReport;
    final metrics = _metricsIndex;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Editor & Deletion Diagnostics'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Words: $_cachedWordCount · Nodes: ${_document?.length ?? 0}'),
              if (metrics != null)
                Text(
                  'Measured Nodes: ${metrics.exactMeasuredCount} / ${_document?.length ?? 0} '
                  '(Total layout height: ${metrics.totalHeight.toStringAsFixed(0)} px)',
                ),
              const Divider(height: 20),
              if (report == null)
                const Text('No selection deletion recorded yet in this session.')
              else ...[
                Text('Last Deletion Scenario: ${report.scenario.name}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('Visibility flags: U=${report.u}, L=${report.l}, T=${report.t}'),
                Text('preScroll: ${report.preScroll.toStringAsFixed(1)} px'),
                Text('finalScroll: ${report.finalScroll.toStringAsFixed(1)} px'),
                Text(
                  'Spacers: top=${report.topSpacer.toStringAsFixed(1)} px, '
                  'bottom=${report.bottomSpacer.toStringAsFixed(1)} px',
                ),
                Text('Animation duration: ${report.durationMs} ms'),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  // --- Formatting Helpers ---

  LocalImageNode? _selectedImageNode() {
    final doc = _document;
    final sel = _composer?.selection;
    if (doc == null || sel == null) return null;
    if (sel.base.nodeId == sel.extent.nodeId) {
      final node = doc.getNodeById(sel.extent.nodeId);
      if (node is LocalImageNode) return node;
    }
    return null;
  }

  TextNode? _currentTextNode() {
    final doc = _document;
    final sel = _composer?.selection;
    if (doc == null || sel == null) return null;
    final node = doc.getNodeById(sel.extent.nodeId);
    return node is TextNode ? node : null;
  }

  bool _isAttributionActive(Attribution attribution) {
    final composer = _composer;
    final doc = _document;
    if (composer == null || doc == null) return false;
    final sel = composer.selection;
    if (sel == null) return false;
    if (sel.isCollapsed) {
      return composer.preferences.currentAttributions.contains(attribution);
    }
    final normal = sel.normalize(doc);
    final node = doc.getNodeById(normal.start.nodeId);
    if (node is! TextNode || normal.start.nodePosition is! TextNodePosition) {
      return false;
    }
    final offset = (normal.start.nodePosition as TextNodePosition).offset;
    if (offset >= node.text.length) return false;
    return node.text.getAllAttributionsAt(offset).contains(attribution);
  }

  void _toggleInlineAttribution(Attribution attribution) {
    final editor = _editor;
    final composer = _composer;
    if (editor == null || composer == null) return;
    final sel = composer.selection;
    if (sel == null) return;

    if (sel.isCollapsed) {
      composer.preferences.toggleStyle(attribution);
      setState(() {});
      return;
    }

    editor.execute([
      ToggleTextAttributionsRequest(
        documentRange: DocumentRange(start: sel.base, end: sel.extent),
        attributions: {attribution},
      ),
    ]);
  }

  void _setExclusiveAttribution(String attributionId, Attribution? newAttr) {
    final editor = _editor;
    final composer = _composer;
    if (editor == null || composer == null) return;
    final sel = composer.selection;
    if (sel == null) return;

    if (sel.isCollapsed) {
      final toRemove = composer.preferences.currentAttributions
          .where((a) => a.id == attributionId)
          .toSet();
      composer.preferences.removeStyles(toRemove);
      if (newAttr != null) {
        composer.preferences.addStyle(newAttr);
      }
      setState(() {});
      return;
    }

    editor.execute([
      SetExclusiveTextAttributionRequest(
        documentRange: DocumentRange(start: sel.base, end: sel.extent),
        attributionId: attributionId,
        newAttribution: newAttr,
      ),
    ]);
  }

  void _setBlockType(Attribution blockType) {
    final editor = _editor;
    final doc = _document;
    final sel = _composer?.selection;
    if (editor == null || doc == null || sel == null) return;
    final node = doc.getNodeById(sel.extent.nodeId);
    if (node == null) return;

    if (node is ListItemNode) {
      editor.execute([
        ConvertListItemToParagraphRequest(
          nodeId: node.id,
          paragraphMetadata: {NodeMetadata.blockType: blockType},
        ),
      ]);
    } else if (node is ParagraphNode) {
      editor.execute([
        ChangeParagraphBlockTypeRequest(
          nodeId: node.id,
          blockType: blockType,
        ),
      ]);
    }
  }

  void _toggleList(ListItemType listType) {
    final editor = _editor;
    final doc = _document;
    final sel = _composer?.selection;
    if (editor == null || doc == null || sel == null) return;
    final node = doc.getNodeById(sel.extent.nodeId);
    if (node == null) return;

    if (node is ListItemNode) {
      if (node.type == listType) {
        editor.execute([ConvertListItemToParagraphRequest(nodeId: node.id)]);
      } else {
        editor.execute([ChangeListItemTypeRequest(nodeId: node.id, newType: listType)]);
      }
    } else if (node is ParagraphNode) {
      editor.execute([ConvertParagraphToListItemRequest(nodeId: node.id, type: listType)]);
    }
  }

  Future<void> _promptInsertLink() async {
    final sel = _composer?.selection;
    if (sel == null || sel.isCollapsed) {
      _showSnack('Select text first to attach a link.');
      return;
    }
    final controller = TextEditingController(text: 'https://');
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apply Link'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'URL',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop('');
            },
            child: const Text('Remove Link'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null) return;
    _setExclusiveAttribution(
      'link',
      url.isEmpty ? null : LinkAttribution(url),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final editor = _editor;
    final doc = _document;
    final composer = _composer;
    final metricsIndex = _metricsIndex;
    final coordinator = _deletionCoordinator;

    return Scaffold(
      backgroundColor: const Color(0xFFFAF9F6),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 12,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Scribe SuperEditor Prototype',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            Text(
              '$_cachedWordCount words · ${doc?.length ?? 0} nodes',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo, size: 20),
            onPressed: editor != null && editor.history.isNotEmpty
                ? () => editor.undo()
                : null,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo, size: 20),
            onPressed: editor != null && editor.future.isNotEmpty
                ? () => editor.redo()
                : null,
          ),
          IconButton(
            tooltip: 'Insert Local Image',
            icon: const Icon(Icons.image_outlined, size: 20),
            onPressed: _isLoading ? null : _pickAndInsertLocalImage,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'save':
                  _saveDocumentToDisk();
                case 'reopen':
                  _reopenSavedDocument();
                case 'sample50k':
                  _load50kSample();
                case 'blank':
                  _createBlankDocument();
                case 'export_md':
                  _showExportMarkdownDialog();
                case 'import_md':
                  _showImportMarkdownDialog();
                case 'diagnostics':
                  _showDiagnosticsDialog();
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'save', child: Text('Save Document (JSON)')),
              PopupMenuItem(value: 'reopen', child: Text('Reopen Saved Document')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'sample50k', child: Text('Load 50,000+ Word Sample')),
              PopupMenuItem(value: 'blank', child: Text('New Blank Document')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'export_md', child: Text('Export Markdown + Loss Report')),
              PopupMenuItem(value: 'import_md', child: Text('Import Markdown')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'diagnostics', child: Text('Deletion A-E & Perf Info')),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE2E8F0)),
        ),
      ),
      body: _isLoading ||
              editor == null ||
              doc == null ||
              composer == null ||
              metricsIndex == null ||
              coordinator == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 14),
                    Text(_loadSummary, textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                _buildFormattingToolbar(),
                Expanded(
                  child: ScribeSuperEditor(
                    key: _scribeEditorKey,
                    editor: editor,
                    document: doc,
                    composer: composer,
                    stylesheet: _stylesheet,
                    focusNode: _editorFocusNode,
                    scrollController: _scrollController,
                    viewportKey: _viewportKey,
                    deletionCoordinator: coordinator,
                    metricsIndex: metricsIndex,
                    splitState: _splitState,
                    onLayoutReady: (resolver) {
                      _getDocumentLayout = resolver;
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildFormattingToolbar() {
    final selectedImage = _selectedImageNode();
    final activeNode = _currentTextNode();
    final blockAttr = activeNode?.getMetadataValue(NodeMetadata.blockType);
    final isListItem = activeNode is ListItemNode;

    return Container(
      height: 46,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: FocusScope(
        canRequestFocus: false,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          children: [
            if (selectedImage != null) ...[
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    'Image Size:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              for (final pct in [25, 50, 75, 100])
                _ToolbarChip(
                  label: '$pct%',
                  selected: (selectedImage.widthFraction * 100).round() == pct,
                  onTap: () {
                    _editor?.execute([
                      ResizeLocalImageRequest(
                        nodeId: selectedImage.id,
                        widthFraction: pct / 100.0,
                      ),
                    ]);
                  },
                ),
              const SizedBox(width: 6),
              _ToolbarChip(
                label: 'Delete Image',
                isDestructive: true,
                onTap: () {
                  _deletionCoordinator?.requestAuthoritativeDeleteSelection(
                    affinity: TextAffinity.upstream,
                  );
                },
              ),
            ] else ...[
              _ToolbarIconButton(
                icon: Icons.format_bold,
                tooltip: 'Bold',
                selected: _isAttributionActive(boldAttribution),
                onTap: () => _toggleInlineAttribution(boldAttribution),
              ),
              _ToolbarIconButton(
                icon: Icons.format_italic,
                tooltip: 'Italic',
                selected: _isAttributionActive(italicsAttribution),
                onTap: () => _toggleInlineAttribution(italicsAttribution),
              ),
              const VerticalDivider(width: 10, indent: 6, endIndent: 6),
              _ToolbarChip(
                label: 'P',
                selected: !isListItem &&
                    (blockAttr == null || blockAttr == paragraphAttribution),
                onTap: () => _setBlockType(paragraphAttribution),
              ),
              _ToolbarChip(
                label: 'H1',
                selected: blockAttr == header1Attribution,
                onTap: () => _setBlockType(header1Attribution),
              ),
              _ToolbarChip(
                label: 'H2',
                selected: blockAttr == header2Attribution,
                onTap: () => _setBlockType(header2Attribution),
              ),
              _ToolbarChip(
                label: 'H3',
                selected: blockAttr == header3Attribution,
                onTap: () => _setBlockType(header3Attribution),
              ),
              _ToolbarIconButton(
                icon: Icons.format_list_bulleted,
                tooltip: 'Bulleted List',
                selected: activeNode is ListItemNode &&
                    activeNode.type == ListItemType.unordered,
                onTap: () => _toggleList(ListItemType.unordered),
              ),
              _ToolbarIconButton(
                icon: Icons.format_list_numbered,
                tooltip: 'Numbered List',
                selected: activeNode is ListItemNode &&
                    activeNode.type == ListItemType.ordered,
                onTap: () => _toggleList(ListItemType.ordered),
              ),
              const VerticalDivider(width: 10, indent: 6, endIndent: 6),
              PopupMenuButton<String?>(
                tooltip: 'Font Family',
                onSelected: (family) {
                  _setExclusiveAttribution(
                    'font_family',
                    family == null ? null : FontFamilyAttribution(family),
                  );
                },
                itemBuilder: (ctx) => [
                  for (final entry in kSupportedFontFamilies.entries)
                    PopupMenuItem<String?>(
                      value: entry.value,
                      child: Text(
                        entry.key,
                        style: TextStyle(fontFamily: entry.value),
                      ),
                    ),
                ],
                child: const _ToolbarDropdownLabel(label: 'Font'),
              ),
              PopupMenuButton<double>(
                tooltip: 'Font Size',
                onSelected: (size) {
                  _setExclusiveAttribution('font_size', FontSizeAttribution(size));
                },
                itemBuilder: (ctx) => [
                  for (final sz in kSupportedFontSizes)
                    PopupMenuItem<double>(
                      value: sz,
                      child: Text('${sz.toInt()} px'),
                    ),
                ],
                child: const _ToolbarDropdownLabel(label: 'Size'),
              ),
              PopupMenuButton<int>(
                tooltip: 'Text Color',
                onSelected: (idx) {
                  final col = kSupportedTextColors[idx].color;
                  _setExclusiveAttribution(
                    'color',
                    col == null ? null : ColorAttribution(col),
                  );
                },
                itemBuilder: (ctx) => [
                  for (int i = 0; i < kSupportedTextColors.length; i++)
                    PopupMenuItem<int>(
                      value: i,
                      child: Row(
                        children: [
                          Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: kSupportedTextColors[i].color ?? const Color(0xFF1E293B),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(kSupportedTextColors[i].label),
                        ],
                      ),
                    ),
                ],
                child: const _ToolbarDropdownLabel(
                  label: 'Color',
                  icon: Icons.format_color_text,
                ),
              ),
              PopupMenuButton<int>(
                tooltip: 'Highlight',
                onSelected: (idx) {
                  final col = kSupportedHighlightColors[idx].color;
                  _setExclusiveAttribution(
                    'background_color',
                    col == null ? null : BackgroundColorAttribution(col),
                  );
                },
                itemBuilder: (ctx) => [
                  for (int i = 0; i < kSupportedHighlightColors.length; i++)
                    PopupMenuItem<int>(
                      value: i,
                      child: Row(
                        children: [
                          Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: kSupportedHighlightColors[i].color ?? Colors.transparent,
                              border: Border.all(color: const Color(0xFF94A3B8)),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(kSupportedHighlightColors[i].label),
                        ],
                      ),
                    ),
                ],
                child: const _ToolbarDropdownLabel(
                  label: 'Mark',
                  icon: Icons.highlight,
                ),
              ),
              _ToolbarIconButton(
                icon: Icons.link,
                tooltip: 'Link',
                selected: false,
                onTap: _promptInsertLink,
              ),
            ],
          ],
        ),
      ),
    );
  }
}


class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 34,
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFDBEAFE) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            icon,
            size: 19,
            color: selected ? const Color(0xFF1D4ED8) : const Color(0xFF334155),
          ),
        ),
      ),
    );
  }
}

class _ToolbarChip extends StatelessWidget {
  const _ToolbarChip({
    required this.label,
    this.selected = false,
    this.isDestructive = false,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool isDestructive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = isDestructive
        ? const Color(0xFFFEE2E2)
        : (selected ? const Color(0xFFDBEAFE) : Colors.transparent);
    final fg = isDestructive
        ? const Color(0xFFB91C1C)
        : (selected ? const Color(0xFF1D4ED8) : const Color(0xFF334155));
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 34,
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: fg),
        ),
      ),
    );
  }
}

class _ToolbarDropdownLabel extends StatelessWidget {
  const _ToolbarDropdownLabel({
    required this.label,
    this.icon,
  });

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: const Color(0xFF334155)),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF334155),
            ),
          ),
          const Icon(Icons.arrow_drop_down, size: 16, color: Color(0xFF64748B)),
        ],
      ),
    );
  }
}
