// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scribe_supereditor_prototype/src/editor/authoritative_scroll.dart';
import 'package:scribe_supereditor_prototype/src/editor/deletion_coordinator.dart';
import 'package:scribe_supereditor_prototype/src/editor/deletion_geometry.dart';
import 'package:scribe_supereditor_prototype/src/editor/document_attributions.dart';
import 'package:scribe_supereditor_prototype/src/editor/local_image_node.dart';
import 'package:scribe_supereditor_prototype/src/editor/scribe_super_editor.dart';
import 'package:scribe_supereditor_prototype/src/editor/split_seam_content_layers.dart';
import 'package:scribe_supereditor_prototype/src/editor/virtualized_document_layout.dart';
import 'package:super_editor/super_editor.dart';

void main() {
  testWidgets('ScribeSuperEditor mounts, scrolls, and executes Scenario C deletion without errors',
      (tester) async {
    final doc = MutableDocument(
      nodes: [
        for (int i = 0; i < 30; i++)
          ParagraphNode(
            id: 'p_$i',
            text: AttributedText(
              'Paragraph $i contains enough sample prose to wrap cleanly inside the Android mobile viewport during selection deletion tests.',
            ),
          ),
      ],
    );
    final composer = MutableDocumentComposer();
    final editor = Editor(
      editables: {
        Editor.documentKey: doc,
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
    final stylesheet = buildPrototypeStylesheet();
    final metricsIndex = DocumentMetricsIndex(document: doc, stylesheet: stylesheet);
    final scrollController = AuthoritativeScrollController();
    final splitState = SplitSeamRenderState();
    final focusNode = FocusNode();
    final viewportKey = GlobalKey();
    final scribeKey = GlobalKey<ScribeSuperEditorState>();
    DocumentLayout? Function()? layoutResolver;

    final coordinator = DeletionCoordinator(
      vsync: tester,
      editor: editor,
      document: doc,
      composer: composer,
      scrollController: scrollController,
      metricsIndex: metricsIndex,
      getDocumentLayout: () => layoutResolver?.call(),
      viewportKey: viewportKey,
      getControlsController: () => scribeKey.currentState?.controlsController,
      splitState: splitState,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: ScribeSuperEditor(
              key: scribeKey,
              editor: editor,
              document: doc,
              composer: composer,
              stylesheet: stylesheet,
              focusNode: focusNode,
              scrollController: scrollController,
              viewportKey: viewportKey,
              deletionCoordinator: coordinator,
              metricsIndex: metricsIndex,
              splitState: splitState,
              onLayoutReady: (resolver) => layoutResolver = resolver,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Select within the visible region (nodes p_1 .. p_2).
    editor.execute([
      ChangeSelectionRequest(
        const DocumentSelection(
          base: DocumentPosition(nodeId: 'p_1', nodePosition: TextNodePosition(offset: 10)),
          extent: DocumentPosition(nodeId: 'p_2', nodePosition: TextNodePosition(offset: 15)),
        ),
        SelectionChangeType.expandSelection,
        SelectionReason.userInteraction,
      ),
    ]);
    await tester.pumpAndSettle();

    final handled = coordinator.requestAuthoritativeDeleteSelection();
    expect(handled, isTrue);
    expect(coordinator.lastReport?.scenario, DeletionScenario.C);

    await tester.pump(const Duration(milliseconds: 130));
    expect(splitState.isActive, isTrue);

    await tester.pumpAndSettle();
    expect(splitState.isActive, isFalse);
    expect(doc.length, 29);

    coordinator.dispose();
    metricsIndex.dispose();
    scrollController.dispose();
    splitState.dispose();
    focusNode.dispose();
    composer.dispose();
    editor.dispose();
    doc.dispose();
  });
}
