import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:follow_the_leader/follow_the_leader.dart';
// ignore: implementation_imports
import 'package:super_editor/src/infrastructure/flutter/eager_pan_gesture_recognizer.dart';
// ignore: implementation_imports
import 'package:super_editor/src/infrastructure/platforms/android/selection_handles.dart';
import 'package:super_editor/super_editor.dart';

import 'authoritative_scroll.dart';
import 'deletion_coordinator.dart';
import 'local_image_node.dart';
import 'split_seam_content_layers.dart';
import 'virtualized_document_layout.dart';

/// Intercepts Gboard / Android IME text deltas so that deleting an active
/// expanded selection (including when Gboard finishes composing in the same batch)
/// always enters [DeletionCoordinator.requestAuthoritativeDeleteSelection]
/// and deletes the selected content exactly once.
class AuthoritativeImeInterceptor extends DeltaTextInputClientDecorator {
  AuthoritativeImeInterceptor({
    required this.composer,
    required this.deletionCoordinator,
  });

  final MutableDocumentComposer composer;
  final DeletionCoordinator deletionCoordinator;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    final activeSelection = composer.selection;
    if (activeSelection != null && !activeSelection.isCollapsed) {
      final hasSelectionDeletion = textEditingDeltas.any(
        (delta) =>
            delta is TextEditingDeltaDeletion ||
            (delta is TextEditingDeltaReplacement && delta.replacementText.isEmpty),
      );
      if (hasSelectionDeletion) {
        final handled = deletionCoordinator.requestAuthoritativeDeleteSelection(
          affinity: TextAffinity.upstream,
        );
        if (handled) {
          return;
        }
      }
    }
    super.updateEditingValueWithDeltas(textEditingDeltas);
  }
}

/// Clips an Android selection handle overlay widget strictly to the usable
/// editor viewport so handles never bleed over toolbars, app bar, or keyboard.
class _UsableViewportHandleClipper extends CustomClipper<Rect> {
  _UsableViewportHandleClipper({
    required this.viewportKey,
    required this.handleKey,
    required Listenable reclip,
  }) : super(reclip: reclip);

  final GlobalKey viewportKey;
  final GlobalKey handleKey;

  @override
  Rect getClip(Size size) {
    final vpCtx = viewportKey.currentContext;
    final hCtx = handleKey.currentContext;
    if (vpCtx == null || hCtx == null) return Offset.zero & size;
    final vpBox = vpCtx.findRenderObject() as RenderBox?;
    final hBox = hCtx.findRenderObject() as RenderBox?;
    if (vpBox == null || hBox == null || !vpBox.hasSize || !hBox.hasSize || !vpBox.attached || !hBox.attached) {
      return Offset.zero & size;
    }
    final vpGlobal = vpBox.localToGlobal(Offset.zero) & vpBox.size;
    final localTL = hBox.globalToLocal(vpGlobal.topLeft);
    final localBR = hBox.globalToLocal(vpGlobal.bottomRight);
    return Rect.fromPoints(localTL, localBR);
  }

  @override
  bool shouldReclip(covariant _UsableViewportHandleClipper oldClipper) {
    return oldClipper.viewportKey != viewportKey || oldClipper.handleKey != handleKey;
  }
}

/// Core writing editor built directly on SuperEditor's real Document, Editor,
/// Composer, IME, Android touch/handle gestures, and layout pipeline, extended with:
/// - Virtualized Sliver DocumentLayout for 50,000+ word responsiveness
/// - Split-region GPU deletion animation (Scenarios A-D) & continuous glide (Scenario E)
/// - Authoritative IME + toolbar + hardware keyboard deletion routing
class ScribeSuperEditor extends StatefulWidget {
  const ScribeSuperEditor({
    super.key,
    required this.editor,
    required this.document,
    required this.composer,
    required this.stylesheet,
    required this.focusNode,
    required this.scrollController,
    required this.viewportKey,
    required this.deletionCoordinator,
    required this.metricsIndex,
    required this.splitState,
    this.onLayoutReady,
  });

  final Editor editor;
  final MutableDocument document;
  final MutableDocumentComposer composer;
  final Stylesheet stylesheet;
  final FocusNode focusNode;
  final AuthoritativeScrollController scrollController;
  final GlobalKey viewportKey;
  final DeletionCoordinator deletionCoordinator;
  final DocumentMetricsIndex metricsIndex;
  final SplitSeamRenderState splitState;
  final ValueChanged<DocumentLayout Function()>? onLayoutReady;

  @override
  State<ScribeSuperEditor> createState() => ScribeSuperEditorState();
}

class ScribeSuperEditorState extends State<ScribeSuperEditor> implements SliverCoordinateHost {
  final GlobalKey _docLayoutKey = GlobalKey(debugLabel: 'scribe-doc-layout');
  final GlobalKey _sliverLayersKey = GlobalKey(debugLabel: 'scribe-sliver-layers');
  final GlobalKey _collapsedClipKey = GlobalKey(debugLabel: 'scribe-collapsed-clip');
  final GlobalKey _upstreamClipKey = GlobalKey(debugLabel: 'scribe-upstream-clip');
  final GlobalKey _downstreamClipKey = GlobalKey(debugLabel: 'scribe-downstream-clip');

  final _scrollChangeSignal = SignalNotifier();
  final _dragHandleAutoScroller = ValueNotifier<DragHandleAutoScroller?>(null);
  final _isImeConnected = ValueNotifier<bool>(false);
  final _softwareKeyboardController = SoftwareKeyboardController();
  final _selectionLinks = SelectionLayerLinks();
  final _scroller = DocumentScroller();

  late SuperEditorAndroidControlsController _androidControlsController;
  late SuperEditorContext _editContext;
  late DocumentLayoutEditable _documentLayoutEditable;
  late VirtualizedNodeViewModelFactory _viewModelFactory;
  late AuthoritativeImeInterceptor _imeInterceptor;
  late List<ComponentBuilder> _componentBuilders;
  late List<ContentTapDelegate> _contentTapHandlers;

  DocumentLayout? get documentLayout => _docLayoutKey.currentState as DocumentLayout?;
  SuperEditorAndroidControlsController get controlsController => _androidControlsController;

  @override
  RenderSliver? get sliverRenderObject =>
      _sliverLayersKey.currentContext?.findRenderObject() as RenderSliver?;

  @override
  double get currentScrollOffset =>
      widget.scrollController.hasClients ? widget.scrollController.position.pixels : 0.0;

  @override
  void initState() {
    super.initState();

    _componentBuilders = [
      LocalImageComponentBuilder(editor: widget.editor),
      ...defaultComponentBuilders,
    ];

    _viewModelFactory = VirtualizedNodeViewModelFactory(
      document: widget.document,
      composer: widget.composer,
      componentBuilders: _componentBuilders,
      stylesheet: widget.stylesheet,
      selectionStyles: defaultSelectionStyle,
    );

    _androidControlsController = SuperEditorAndroidControlsController(
      controlsColor: const Color(0xFF1D4ED8),
      collapsedHandleBuilder: _buildClippedCollapsedHandle,
      expandedHandlesBuilder: _buildClippedExpandedHandles,
      toolbarBuilder: _buildAndroidSelectionToolbar,
    );

    _imeInterceptor = AuthoritativeImeInterceptor(
      composer: widget.composer,
      deletionCoordinator: widget.deletionCoordinator,
    );

    _documentLayoutEditable = DocumentLayoutEditable(
      () => _docLayoutKey.currentState as DocumentLayout,
    );
    widget.editor.context.put(Editor.layoutKey, _documentLayoutEditable);

    _editContext = SuperEditorContext(
      editorFocusNode: widget.focusNode,
      editor: widget.editor,
      document: widget.document,
      composer: widget.composer,
      getDocumentLayout: () => _docLayoutKey.currentState as DocumentLayout,
      scroller: _scroller,
      commonOps: CommonEditorOperations(
        editor: widget.editor,
        document: widget.document,
        composer: widget.composer,
        documentLayoutResolver: () => _docLayoutKey.currentState as DocumentLayout,
      ),
    );

    _contentTapHandlers = [
      _LocalImageTapHandler(_editContext),
      superEditorLaunchLinkTapHandlerFactory(_editContext),
      superEditorAddEmptyParagraphTapHandlerFactory(_editContext),
    ];

    widget.deletionCoordinator.attachHandleKeys(
      upstream: _upstreamClipKey,
      downstream: _downstreamClipKey,
    );
    widget.scrollController.addListener(_onScrollChanged);
    widget.deletionCoordinator.addListener(_onDeletionCoordinatorChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (widget.scrollController.hasClients) {
          _scroller.attach(widget.scrollController.position);
        }
        widget.onLayoutReady?.call(() => _docLayoutKey.currentState as DocumentLayout);
      }
    });
  }

  @override
  void didUpdateWidget(ScribeSuperEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document || oldWidget.composer != widget.composer) {
      _viewModelFactory
        ..document = widget.document
        ..composer = widget.composer
        ..invalidateAll();
    }
    if (oldWidget.deletionCoordinator != widget.deletionCoordinator) {
      oldWidget.deletionCoordinator.removeListener(_onDeletionCoordinatorChanged);
      widget.deletionCoordinator.addListener(_onDeletionCoordinatorChanged);
    }
  }

  @override
  void dispose() {
    widget.deletionCoordinator.detachHandleKeys();
    widget.scrollController.removeListener(_onScrollChanged);
    widget.deletionCoordinator.removeListener(_onDeletionCoordinatorChanged);
    widget.editor.context.remove(Editor.layoutKey, _documentLayoutEditable);
    for (final h in _contentTapHandlers) {
      h.dispose();
    }
    _scroller.dispose();
    _androidControlsController.dispose();
    _dragHandleAutoScroller.dispose();
    _isImeConnected.dispose();
    _scrollChangeSignal.dispose();
    super.dispose();
  }

  void _onScrollChanged() {
    _scrollChangeSignal.notifyListeners();
    widget.deletionCoordinator.absorbSpacersOnScroll();
  }

  void _onDeletionCoordinatorChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _openSoftwareKeyboard() {
    if (!_softwareKeyboardController.hasDelegate) {
      return;
    }
    _softwareKeyboardController.open(viewId: View.of(context).viewId);
  }

  List<SuperEditorKeyboardAction> get _keyboardActions => [
        // Intercept hardware Backspace/Delete when selection is expanded so it
        // enters the exact same authoritative deletion transaction.
        ({required SuperEditorContext editContext, required KeyEvent keyEvent}) {
          if (keyEvent is! KeyDownEvent && keyEvent is! KeyRepeatEvent) {
            return ExecutionInstruction.continueExecution;
          }
          final sel = editContext.composer.selection;
          if (sel == null || sel.isCollapsed) {
            return ExecutionInstruction.continueExecution;
          }
          if (keyEvent.logicalKey == LogicalKeyboardKey.backspace) {
            widget.deletionCoordinator.requestAuthoritativeDeleteSelection(
              affinity: TextAffinity.upstream,
            );
            return ExecutionInstruction.haltExecution;
          }
          if (keyEvent.logicalKey == LogicalKeyboardKey.delete) {
            widget.deletionCoordinator.requestAuthoritativeDeleteSelection(
              affinity: TextAffinity.downstream,
            );
            return ExecutionInstruction.haltExecution;
          }
          return ExecutionInstruction.continueExecution;
        },
        ...defaultImeKeyboardActions,
      ];

  Widget _buildClippedCollapsedHandle(
    BuildContext context, {
    required Key handleKey,
    required LeaderLink focalPoint,
    required DocumentHandleGestureDelegate gestureDelegate,
    required bool shouldShow,
  }) {
    if (!shouldShow) {
      return const SizedBox.shrink();
    }
    final reclip = Listenable.merge([
      widget.scrollController,
      widget.composer.selectionNotifier,
      widget.deletionCoordinator,
    ]);
    final handleColor = _androidControlsController.controlsColor ?? Theme.of(context).primaryColor;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final gestureSettings = MediaQuery.maybeOf(context)?.gestureSettings;
    return SizedBox.expand(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Follower.withOffset(
            link: focalPoint,
            leaderAnchor: Alignment.bottomCenter,
            followerAnchor: Alignment.topCenter,
            showWhenUnlinked: false,
            offset: -Offset(0, AndroidSelectionHandle.defaultTouchRegionExpansion.top) * dpr,
            child: ClipRect(
              key: _collapsedClipKey,
              clipper: _UsableViewportHandleClipper(
                viewportKey: widget.viewportKey,
                handleKey: _collapsedClipKey,
                reclip: reclip,
              ),
              child: RawGestureDetector(
                behavior: HitTestBehavior.translucent,
                gestures: <Type, GestureRecognizerFactory>{
                  EagerPanGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<EagerPanGestureRecognizer>(
                    () => EagerPanGestureRecognizer(),
                    (instance) {
                      instance
                        ..shouldAccept = (() => true)
                        ..dragStartBehavior = DragStartBehavior.down
                        ..onStart = gestureDelegate.onPanStart
                        ..onUpdate = gestureDelegate.onPanUpdate
                        ..onEnd = gestureDelegate.onPanEnd
                        ..onCancel = gestureDelegate.onPanCancel
                        ..gestureSettings = gestureSettings;
                    },
                  ),
                },
                child: AndroidSelectionHandle(
                  key: handleKey,
                  handleType: HandleType.collapsed,
                  color: handleColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClippedExpandedHandles(
    BuildContext context, {
    required Key upstreamHandleKey,
    required LeaderLink upstreamFocalPoint,
    required DocumentHandleGestureDelegate upstreamGestureDelegate,
    required Key downstreamHandleKey,
    required LeaderLink downstreamFocalPoint,
    required DocumentHandleGestureDelegate downstreamGestureDelegate,
    required bool shouldShow,
  }) {
    if (!shouldShow) {
      return const SizedBox.shrink();
    }
    final reclip = Listenable.merge([
      widget.scrollController,
      widget.composer.selectionNotifier,
      widget.deletionCoordinator,
    ]);
    final handleColor = _androidControlsController.controlsColor ?? Theme.of(context).primaryColor;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final gestureSettings = MediaQuery.maybeOf(context)?.gestureSettings;

    return SizedBox.expand(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
        Follower.withOffset(
          link: upstreamFocalPoint,
          leaderAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topRight,
          showWhenUnlinked: false,
          offset: -AndroidSelectionHandle.defaultTouchRegionExpansion.topRight * dpr,
          child: ClipRect(
            key: _upstreamClipKey,
            clipper: _UsableViewportHandleClipper(
              viewportKey: widget.viewportKey,
              handleKey: _upstreamClipKey,
              reclip: reclip,
            ),
            child: RawGestureDetector(
              behavior: HitTestBehavior.translucent,
              gestures: <Type, GestureRecognizerFactory>{
                EagerPanGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<EagerPanGestureRecognizer>(
                  () => EagerPanGestureRecognizer(),
                  (instance) {
                    instance
                      ..shouldAccept = (() => true)
                      ..dragStartBehavior = DragStartBehavior.down
                      ..onStart = upstreamGestureDelegate.onPanStart
                      ..onUpdate = upstreamGestureDelegate.onPanUpdate
                      ..onEnd = upstreamGestureDelegate.onPanEnd
                      ..onCancel = upstreamGestureDelegate.onPanCancel
                      ..gestureSettings = gestureSettings;
                  },
                ),
              },
              child: AndroidSelectionHandle(
                key: upstreamHandleKey,
                handleType: HandleType.upstream,
                color: handleColor,
              ),
            ),
          ),
        ),
        Follower.withOffset(
          link: downstreamFocalPoint,
          leaderAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topLeft,
          showWhenUnlinked: false,
          offset: -AndroidSelectionHandle.defaultTouchRegionExpansion.topLeft * dpr,
          child: ClipRect(
            key: _downstreamClipKey,
            clipper: _UsableViewportHandleClipper(
              viewportKey: widget.viewportKey,
              handleKey: _downstreamClipKey,
              reclip: reclip,
            ),
            child: RawGestureDetector(
              behavior: HitTestBehavior.translucent,
              gestures: <Type, GestureRecognizerFactory>{
                EagerPanGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<EagerPanGestureRecognizer>(
                  () => EagerPanGestureRecognizer(),
                  (instance) {
                    instance
                      ..shouldAccept = (() => true)
                      ..dragStartBehavior = DragStartBehavior.down
                      ..onStart = downstreamGestureDelegate.onPanStart
                      ..onUpdate = downstreamGestureDelegate.onPanUpdate
                      ..onEnd = downstreamGestureDelegate.onPanEnd
                      ..onCancel = downstreamGestureDelegate.onPanCancel
                      ..gestureSettings = gestureSettings;
                  },
                ),
              },
              child: AndroidSelectionHandle(
                key: downstreamHandleKey,
                handleType: HandleType.downstream,
                color: handleColor,
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }

  Widget _buildAndroidSelectionToolbar(
    BuildContext overlayContext,
    Key floatingToolbarKey,
    LeaderLink focalPoint,
  ) {
    return ValueListenableBuilder<DocumentSelection?>(
      valueListenable: widget.composer.selectionNotifier,
      builder: (context, selection, _) {
        final isExpanded = selection != null && !selection.isCollapsed;
        final actions = <({String label, VoidCallback onPressed, bool isDestructive})>[
          if (isExpanded)
            (
              label: 'Cut',
              isDestructive: false,
              onPressed: () {
                _editContext.commonOps.copy();
                _androidControlsController.hideToolbar();
                widget.deletionCoordinator.requestAuthoritativeDeleteSelection(
                  affinity: TextAffinity.upstream,
                );
              },
            ),
          if (isExpanded)
            (
              label: 'Copy',
              isDestructive: false,
              onPressed: () {
                _editContext.commonOps.copy();
                _androidControlsController.hideToolbar();
              },
            ),
          (
            label: 'Paste',
            isDestructive: false,
            onPressed: () {
              _editContext.commonOps.paste();
              _androidControlsController.hideToolbar();
            },
          ),
          if (isExpanded)
            (
              label: 'Delete',
              isDestructive: true,
              onPressed: () {
                _androidControlsController.hideToolbar();
                widget.deletionCoordinator.requestAuthoritativeDeleteSelection(
                  affinity: TextAffinity.upstream,
                );
              },
            ),
          (
            label: 'Select All',
            isDestructive: false,
            onPressed: () {
              _editContext.commonOps.selectAll();
            },
          ),
        ];

        return Material(
          key: floatingToolbarKey,
          elevation: 6,
          borderRadius: BorderRadius.circular(10),
          color: const Color(0xFF1E293B),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final action in actions)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: action.onPressed,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      child: Text(
                        action.label,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: action.isDestructive ? FontWeight.w700 : FontWeight.w500,
                          color: action.isDestructive ? const Color(0xFFFCA5A5) : Colors.white,
                        ),
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

  void _focusEndOfDocument() {
    widget.focusNode.requestFocus();
    if (widget.document.isNotEmpty) {
      final last = widget.document.last;
      widget.editor.execute([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(nodeId: last.id, nodePosition: last.endPosition),
          ),
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
      ]);
    }
    _openSoftwareKeyboard();
  }

  @override
  Widget build(BuildContext context) {
    final topSpacer = widget.deletionCoordinator.topSpacer;
    final bottomSpacer = widget.deletionCoordinator.bottomSpacer;

    return NotificationListener<OverscrollNotification>(
      onNotification: (notification) {
        if (notification.overscroll < 0) {
          widget.deletionCoordinator.handleTopOverscroll(notification.overscroll);
        }
        return false;
      },
      child: ClipRect(
        key: widget.viewportKey,
        child: Scrollbar(
          controller: widget.scrollController,
          child: CustomScrollView(
            controller: widget.scrollController,
            scrollCacheExtent: const ScrollCacheExtent.pixels(1200.0),
            slivers: [
              if (topSpacer > 0.0)
                SliverToBoxAdapter(
                  child: SizedBox(height: topSpacer),
                ),
              SuperEditorAndroidControlsScope(
                controller: _androidControlsController,
                child: SuperEditorFocusDebugVisuals(
                  focusNode: widget.focusNode,
                  child: EditorSelectionAndFocusPolicy(
                    focusNode: widget.focusNode,
                    editor: widget.editor,
                    document: widget.document,
                    selection: widget.composer.selectionNotifier,
                    isDocumentLayoutAvailable: () =>
                        (_sliverLayersKey.currentContext?.findRenderObject() as RenderSliver?)
                            ?.geometry !=
                        null,
                    getDocumentLayout: () => _editContext.documentLayout,
                    placeCaretAtEndOfDocumentOnGainFocus: true,
                    restorePreviousSelectionOnGainFocus: true,
                    clearSelectionWhenEditorLosesFocus: false,
                    child: SuperEditorAndroidControlsOverlayManager(
                      document: _editContext.document,
                      getDocumentLayout: () => _docLayoutKey.currentState as DocumentLayout,
                      selection: widget.composer.selectionNotifier,
                      setSelection: (newSelection) {
                        if (newSelection == null) {
                          _editContext.editor.execute([
                            const ChangeSelectionRequest(
                              null,
                              SelectionChangeType.clearSelection,
                              SelectionReason.userInteraction,
                            ),
                          ]);
                          return;
                        }
                        _editContext.editor.execute([
                          ChangeSelectionRequest(
                            newSelection,
                            newSelection.isCollapsed
                                ? SelectionChangeType.pushCaret
                                : SelectionChangeType.expandSelection,
                            SelectionReason.userInteraction,
                          ),
                        ]);
                      },
                      isImeConnected: _isImeConnected,
                      scrollChangeSignal: _scrollChangeSignal,
                      dragHandleAutoScroller: _dragHandleAutoScroller,
                      child: SuperEditorImeInteractor(
                        focusNode: widget.focusNode,
                        autofocus: false,
                        editContext: _editContext,
                        clearSelectionWhenEditorLosesFocus: false,
                        clearSelectionWhenImeConnectionCloses: false,
                        softwareKeyboardController: _softwareKeyboardController,
                        imePolicies: const SuperEditorImePolicies(
                          openKeyboardOnSelectionChange: true,
                          closeKeyboardOnSelectionLost: false,
                        ),
                        imeConfiguration: SuperEditorImeConfiguration(
                          keyboardBrightness: Theme.of(context).brightness,
                          enableAutocorrect: true,
                          enableSuggestions: true,
                        ),
                        imeOverrides: _imeInterceptor,
                        hardwareKeyboardActions: _keyboardActions,
                        selectorHandlers: defaultEditorSelectorHandlers,
                        isImeConnected: _isImeConnected,
                        child: AndroidDocumentTouchInteractor(
                          focusNode: widget.focusNode,
                          editor: _editContext.editor,
                          document: _editContext.document,
                          getDocumentLayout: () => _editContext.documentLayout,
                          selection: widget.composer.selectionNotifier,
                          isImeConnected: _isImeConnected,
                          openKeyboardWhenTappingExistingSelection: true,
                          openKeyboardOnSelectionChange: true,
                          openSoftwareKeyboard: _openSoftwareKeyboard,
                          contentTapHandlers: _contentTapHandlers,
                          scrollController: widget.scrollController,
                          dragHandleAutoScroller: _dragHandleAutoScroller,
                          fillViewport: false,
                          child: SplitSeamSliverContentLayers(
                            key: _sliverLayersKey,
                            splitState: widget.splitState,
                            content: (onBuildScheduled) => VirtualizedSingleColumnDocumentLayout(
                              key: _docLayoutKey,
                              editor: widget.editor,
                              document: widget.document,
                              composer: widget.composer,
                              metricsIndex: widget.metricsIndex,
                              viewModelFactory: _viewModelFactory,
                              componentBuilders: _componentBuilders,
                              coordinateHost: this,
                              onBuildScheduled: onBuildScheduled,
                            ),
                            overlays: [
                              (context) => SelectionLeadersDocumentLayer(
                                    document: _editContext.document,
                                    selection: _editContext.composer.selectionNotifier,
                                    links: _selectionLinks,
                                  ),
                              (context) => AndroidToolbarFocalPointDocumentLayer(
                                    document: _editContext.document,
                                    selection: _editContext.composer.selectionNotifier,
                                    toolbarFocalPointLink:
                                        _androidControlsController.toolbarFocalPoint,
                                  ),
                              (context) => AndroidHandlesDocumentLayer(
                                    document: _editContext.document,
                                    documentLayout: _editContext.documentLayout,
                                    selection: _editContext.composer.selectionNotifier,
                                    changeSelection: (newSelection, changeType, reason) {
                                      _editContext.editor.execute([
                                        ChangeSelectionRequest(
                                          newSelection,
                                          changeType,
                                          reason,
                                        ),
                                      ]);
                                    },
                                  ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _focusEndOfDocument,
                  child: SizedBox(
                    height: math.max(bottomSpacer, 96.0),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class _LocalImageTapHandler extends ContentTapDelegate {
  _LocalImageTapHandler(this.editContext);

  final SuperEditorContext editContext;

  @override
  TapHandlingInstruction onTap(DocumentTapDetails details) {
    final pos = details.documentLayout.getDocumentPositionAtOffset(details.layoutOffset);
    if (pos == null) return TapHandlingInstruction.continueHandling;
    final node = editContext.document.getNodeById(pos.nodeId);
    if (node is! LocalImageNode) return TapHandlingInstruction.continueHandling;

    editContext.editor.execute([
      ChangeSelectionRequest(
        DocumentSelection(
          base: DocumentPosition(
            nodeId: node.id,
            nodePosition: const UpstreamDownstreamNodePosition.upstream(),
          ),
          extent: DocumentPosition(
            nodeId: node.id,
            nodePosition: const UpstreamDownstreamNodePosition.downstream(),
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);
    return TapHandlingInstruction.halt;
  }
}
