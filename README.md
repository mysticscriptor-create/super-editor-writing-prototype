# Scribe SuperEditor Prototype

Standalone, minimal Android writing-editor prototype built on **`super_editor: 0.3.0-dev.52`** (`attributed_text: 0.4.7`, `super_text_layout: 0.1.20`, `follow_the_leader: 0.5.3`) to evaluate SuperEditor for a 50,000+ word WYSIWYG writing editor with deterministic selection-deletion geometry and animation behavior (**Scenarios A–E**).

## Architecture Overview

- **Document Model & Editing**: Uses SuperEditor's real `MutableDocument`, `Editor`, `MutableDocumentComposer`, `ParagraphNode`, `ListItemNode`, and custom `LocalImageNode` (`BlockNode` subclass storing local filename, resolved path, aspect ratio, and resize fraction).
- **Virtualization (`lib/src/editor/virtualized_document_layout.dart`)**:
  - `VirtualizedSingleColumnDocumentLayout` implements SuperEditor's `DocumentLayout` over `SliverVariedExtentList.builder`, avoiding full-document `Column` layout and `O(N)` presenter rebuilds per keystroke.
  - `DocumentMetricsIndex` measures the initial viewport synchronously, continues exact `TextPainter` measurement in 4 ms/frame background slices, re-measures edited nodes incrementally, and supplies offscreen geometry fallbacks so `AndroidHandlesDocumentLayer` never dereferences null offscreen rects.
- **WYSIWYG Formatting & Persistence**:
  - Bold, italic, H1–H3, normal paragraph, bulleted & numbered lists, font family (`Sans`, `Serif`, `Mono`), font size (`14–32 px`), text color, highlight color, links, and local image insertion/selection/deletion/aspect-preserving resize.
  - Structured JSON persistence (`DocumentJsonCodec`) preserves all formatting and local image references across save/reopen.
  - Real AST Markdown import/export (`MarkdownCodec`) built on SuperEditor's `serializeDocumentToMarkdown` / `deserializeMarkdownToDocument` with an explicit `MarkdownLossReport` detailing attributes not representable in standard Markdown.
- **Selection Deletion Scenarios A–E (`deletion_geometry.dart`, `deletion_coordinator.dart`, `split_seam_content_layers.dart`, `authoritative_scroll.dart`)**:
  - Captures clipped screen-space handle rects (`U`, `L`) and selection intersection (`T`) relative to the usable editor viewport (excluding AppBar, formatting toolbar, and IME keyboard insets) strictly before mutating the document.
  - Intercepts Gboard IME deletion deltas (`AuthoritativeImeInterceptor`), Android floating toolbar `Delete`/`Cut`, and hardware `Backspace`/`Delete` keys into a single-shot mutation and single animation clock.
  - Suppresses competing `DragHandleAutoScroller` jumps (`AuthoritativeScrollPosition`) during active transitions.
  - Uses boundary spacers + GPU clip/translate layers (`RenderSliverSplitSeamContentLayers`) for Scenarios **A–D** and continuous document-level glide for **Scenario E**, clearing temporary transforms only when normal rendering matches the final screen position.

## Building via GitHub Actions

Push to `main` (or trigger `Android Debug APK` manually) to run:
1. `flutter pub get`
2. `flutter analyze`
3. `flutter test`
4. `flutter build apk --debug` (artifact `app-debug-apk` uploaded per workflow run)

## Physical Android + Gboard Manual Verification Checklist

Install `app-debug.apk` on an Android device with Gboard enabled and verify:

1. **50,000+ Word Load & Responsiveness**:
   - Launch app (loads 50,000+ word sample with 6 inline local PNGs) and check load time SnackBar.
   - Scroll rapidly from start to end; verify headings, wrapped paragraphs, lists, rich spans, and inline PNGs render cleanly without stalls.
   - Type with Gboard near the beginning, middle, and end of the document; verify responsive input and cursor tracking.
2. **WYSIWYG Formatting, Images & Persistence**:
   - Select text and toggle Bold, Italic, H1–H3/P, Bullet/Numbered lists, Font Family, Font Size, Text Color, Highlight Color, and Link.
   - Insert a device image via the AppBar photo icon; tap the image to select it, drag the corner handle or tap `25%`/`50%`/`75%`/`100%`, verify aspect ratio is preserved.
   - Open menu -> `Save Document (JSON)` -> close/reopen or tap `Reopen Saved Document` -> verify all formatting and local images restore.
   - Open menu -> `Export Markdown + Loss Report` -> verify AST Markdown output and explicit report of non-Markdown attributes (font family/size/colors/highlights/custom image widths).
3. **Selection Deletion Scenarios A–E (with real Android handles + Gboard Backspace & toolbar Delete)**:
   - **Scenario A (`U=true, L=false`)**: Drag downstream handle below keyboard/bottom viewport; keep upper handle visible; press Gboard Backspace -> upper surviving text stays stationary on screen while lower content glides up to close the gap (including near end of document).
   - **Scenario B (`U=false, L=true`)**: Scroll down so upper handle leaves top of usable viewport while lower handle remains visible; press Gboard Backspace -> lower surviving text stays stationary while upper content glides down (including when close to top of document).
   - **Scenario C (`U=true, L=true`)**: Select across lines/paragraphs with both handles inside usable viewport; delete -> lower text stays stationary and upper text glides smoothly down.
   - **Scenario D (`U=false, L=false, T=true`)**: Make a multi-page selection and scroll into its middle so neither handle is visible; delete -> upper and lower surviving content converge around the vertical center of the usable viewport.
   - **Scenario E (`U=false, L=false, T=false`)**: Scroll completely away from an active selection; press Gboard Backspace -> no split seam; single continuous document glide until the resulting caret is visible (and verify dragging stops the glide immediately).
   - Open menu -> `Deletion A-E & Perf Info` after each test to confirm logged `(U, L, T)` classification and scenario match `A`–`E`.
