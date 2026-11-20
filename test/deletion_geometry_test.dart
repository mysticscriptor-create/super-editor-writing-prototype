import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scribe_supereditor_prototype/src/editor/authoritative_scroll.dart';
import 'package:scribe_supereditor_prototype/src/editor/deletion_geometry.dart';

void main() {
  const viewport = Rect.fromLTWH(0, 0, 400, 600);

  group('classifyDeletionGeometry', () {
    test('Scenario A when U=true and L=false (lower handle below IME/viewport)', () {
      final res = classifyDeletionGeometry(
        usableViewportLocal: viewport,
        upstreamRectVp: const Rect.fromLTWH(60, 120, 2, 24),
        downstreamRectVp: const Rect.fromLTWH(200, 740, 2, 24),
        selectionRectVp: const Rect.fromLTWH(20, 120, 360, 644),
      );
      expect(res.u, isTrue);
      expect(res.l, isFalse);
      expect(res.t, isTrue);
      expect(res.scenario, DeletionScenario.A);
    });

    test('Scenario B when U=false and L=true (upper handle scrolled above viewport)', () {
      final res = classifyDeletionGeometry(
        usableViewportLocal: viewport,
        upstreamRectVp: const Rect.fromLTWH(100, -180, 2, 24),
        downstreamRectVp: const Rect.fromLTWH(180, 220, 2, 24),
        selectionRectVp: const Rect.fromLTWH(20, -180, 360, 424),
      );
      expect(res.u, isFalse);
      expect(res.l, isTrue);
      expect(res.t, isTrue);
      expect(res.scenario, DeletionScenario.B);
    });

    test('Scenario C when U=true and L=true (both handles visible)', () {
      final res = classifyDeletionGeometry(
        usableViewportLocal: viewport,
        upstreamRectVp: const Rect.fromLTWH(80, 100, 2, 24),
        downstreamRectVp: const Rect.fromLTWH(240, 360, 2, 24),
        selectionRectVp: const Rect.fromLTWH(20, 100, 360, 284),
      );
      expect(res.u, isTrue);
      expect(res.l, isTrue);
      expect(res.t, isTrue);
      expect(res.scenario, DeletionScenario.C);
    });

    test('Scenario D when U=false, L=false, and T=true (wrapped selection spans viewport)', () {
      final res = classifyDeletionGeometry(
        usableViewportLocal: viewport,
        upstreamRectVp: const Rect.fromLTWH(80, -320, 2, 24),
        downstreamRectVp: const Rect.fromLTWH(240, 820, 2, 24),
        selectionRectVp: const Rect.fromLTWH(20, -320, 360, 1164),
      );
      expect(res.u, isFalse);
      expect(res.l, isFalse);
      expect(res.t, isTrue);
      expect(res.scenario, DeletionScenario.D);
    });

    test('Scenario E when U=false, L=false, and T=false (selection completely offscreen)', () {
      final res = classifyDeletionGeometry(
        usableViewportLocal: viewport,
        upstreamRectVp: const Rect.fromLTWH(80, -900, 2, 24),
        downstreamRectVp: const Rect.fromLTWH(240, -250, 2, 24),
        selectionRectVp: const Rect.fromLTWH(20, -900, 360, 674),
      );
      expect(res.u, isFalse);
      expect(res.l, isFalse);
      expect(res.t, isFalse);
      expect(res.scenario, DeletionScenario.E);
    });

    test('Uses actual clipped screen-space handle bounds over endpoint text rects', () {
      // Text line is at y=585 (inside viewport 600), so caret rect is inside,
      // but the teardrop handle hangs BELOW bottom (585+24 = 609 > 600) so L=false!
      final res = classifyDeletionGeometry(
        usableViewportLocal: viewport,
        upstreamRectVp: const Rect.fromLTWH(80, 140, 2, 24),
        downstreamRectVp: const Rect.fromLTWH(200, 585, 2, 24),
        selectionRectVp: const Rect.fromLTWH(20, 140, 360, 469),
        actualUpstreamHandleVp: const Rect.fromLTWH(60, 164, 20, 20),
        actualDownstreamHandleVp: const Rect.fromLTWH(200, 609, 20, 20),
      );
      expect(res.u, isTrue);
      expect(res.l, isFalse);
      expect(res.scenario, DeletionScenario.A);
    });
  });

  group('SplitSeamAnimationPlan & GlideAnimationPlan', () {
    test('Scenario A keeps upper stationary and preserves anchor even when postMaxScroll shrinks', () {
      const snapshot = DeletionSnapshot(
        usableViewportRectGlobal: Rect.fromLTWH(0, 100, 400, 600),
        preScroll: 1000,
        preMinScroll: 0,
        preMaxScroll: 3000,
        preTopSpacer: 0,
        preBottomSpacer: 0,
        upstreamRectDoc: Rect.fromLTWH(40, 1140, 2, 24),
        downstreamRectDoc: Rect.fromLTWH(140, 2200, 2, 24),
        selectionRectDoc: Rect.fromLTWH(20, 1140, 360, 1084),
        upstreamHandleVisible: true,
        downstreamHandleVisible: false,
        selectionIntersectsViewport: true,
        scenario: DeletionScenario.A,
      );

      // Post deletion shrank document so postBaseMaxScroll is only 850 (< idealScroll 1000).
      final plan = buildSplitSeamPlan(
        snapshot: snapshot,
        postCaretRectDoc: const Rect.fromLTWH(40, 1140, 2, 24),
        postBaseMaxScroll: 850,
      );

      expect(plan.upperStartVpY, closeTo(140, 0.01));
      expect(plan.upperEndVpY, closeTo(140, 0.01));
      expect(plan.finalBottomSpacer, closeTo(150, 0.01));
      expect(plan.finalScrollOffset, closeTo(1000, 0.01));

      final endTransforms = plan.evaluateAt(1.0);
      expect(endTransforms.upperTranslateY, closeTo(0.0, 0.001));
      expect(endTransforms.lowerTranslateY, closeTo(0.0, 0.001));
    });

    test('Scenario B keeps lower stationary and uses topSpacer when idealScroll < 0', () {
      const snapshot = DeletionSnapshot(
        usableViewportRectGlobal: Rect.fromLTWH(0, 100, 400, 600),
        preScroll: 1200,
        preMinScroll: 0,
        preMaxScroll: 4000,
        preTopSpacer: 0,
        preBottomSpacer: 0,
        upstreamRectDoc: Rect.fromLTWH(40, 120, 2, 24),
        downstreamRectDoc: Rect.fromLTWH(200, 1520, 2, 24),
        selectionRectDoc: Rect.fromLTWH(20, 120, 360, 1424),
        upstreamHandleVisible: false,
        downstreamHandleVisible: true,
        selectionIntersectsViewport: true,
        scenario: DeletionScenario.B,
      );

      // Merged caret is at docY=120, while lower content was at vpY=320 => idealScroll = -200!
      final plan = buildSplitSeamPlan(
        snapshot: snapshot,
        postCaretRectDoc: const Rect.fromLTWH(40, 120, 2, 24),
        postBaseMaxScroll: 2600,
      );

      expect(plan.lowerStartVpY, closeTo(320, 0.01));
      expect(plan.lowerEndVpY, closeTo(320, 0.01));
      expect(plan.upperEndVpY, closeTo(320, 0.01));
      expect(plan.finalScrollOffset, 0.0);
      expect(plan.finalTopSpacer, closeTo(200, 0.01));
      expect(plan.naturalVpY(120), closeTo(320, 0.01));

      final endTransforms = plan.evaluateAt(1.0);
      expect(endTransforms.upperTranslateY, closeTo(0.0, 0.001));
      expect(endTransforms.lowerTranslateY, closeTo(0.0, 0.001));
    });

    test('Scenario C keeps lower stationary and closes upper downward with zero end jump', () {
      const snapshot = DeletionSnapshot(
        usableViewportRectGlobal: Rect.fromLTWH(0, 100, 400, 600),
        preScroll: 400,
        preMinScroll: 0,
        preMaxScroll: 2000,
        preTopSpacer: 0,
        preBottomSpacer: 0,
        upstreamRectDoc: Rect.fromLTWH(40, 500, 2, 24),
        downstreamRectDoc: Rect.fromLTWH(220, 760, 2, 24),
        selectionRectDoc: Rect.fromLTWH(20, 500, 360, 284),
        upstreamHandleVisible: true,
        downstreamHandleVisible: true,
        selectionIntersectsViewport: true,
        scenario: DeletionScenario.C,
      );

      final plan = buildSplitSeamPlan(
        snapshot: snapshot,
        postCaretRectDoc: const Rect.fromLTWH(40, 500, 2, 24),
        postBaseMaxScroll: 1740,
      );

      expect(plan.upperStartVpY, closeTo(100, 0.01));
      expect(plan.upperEndVpY, closeTo(360, 0.01));
      expect(plan.lowerStartVpY, closeTo(360, 0.01));
      expect(plan.lowerEndVpY, closeTo(360, 0.01));
      expect(plan.finalScrollOffset, closeTo(140, 0.01));

      final midTransforms = plan.evaluateAt(0.5);
      expect(midTransforms.lowerTranslateY, closeTo(0.0, 0.001));
      expect(midTransforms.upperTranslateY, lessThan(0.0));

      final endTransforms = plan.evaluateAt(1.0);
      expect(endTransforms.upperTranslateY, closeTo(0.0, 0.001));
      expect(endTransforms.lowerTranslateY, closeTo(0.0, 0.001));
    });

    test('Scenario D converges at vertical center of usable viewport despite clamping', () {
      const snapshot = DeletionSnapshot(
        usableViewportRectGlobal: Rect.fromLTWH(0, 100, 400, 600),
        preScroll: 900,
        preMinScroll: 0,
        preMaxScroll: 3000,
        preTopSpacer: 0,
        preBottomSpacer: 0,
        upstreamRectDoc: Rect.fromLTWH(40, 60, 2, 24),
        downstreamRectDoc: Rect.fromLTWH(220, 1800, 2, 24),
        selectionRectDoc: Rect.fromLTWH(20, 60, 360, 1764),
        upstreamHandleVisible: false,
        downstreamHandleVisible: false,
        selectionIntersectsViewport: true,
        scenario: DeletionScenario.D,
      );

      // Usable viewport center = 300; caret height = 24 -> desiredSeamTopVpY = 288.
      // Caret docY = 60 -> idealScroll = -228 => compensated by topSpacer = 228.
      final plan = buildSplitSeamPlan(
        snapshot: snapshot,
        postCaretRectDoc: const Rect.fromLTWH(40, 60, 2, 24),
        postBaseMaxScroll: 1200,
      );

      expect(plan.upperEndVpY, closeTo(288, 0.01));
      expect(plan.lowerEndVpY, closeTo(288, 0.01));
      expect(plan.finalScrollOffset, 0.0);
      expect(plan.finalTopSpacer, closeTo(228, 0.01));

      final endTransforms = plan.evaluateAt(1.0);
      expect(endTransforms.upperTranslateY, closeTo(0.0, 0.001));
      expect(endTransforms.lowerTranslateY, closeTo(0.0, 0.001));
    });

    test('Scenario E produces continuous glide without jump when deleted block was above viewport', () {
      const snapshot = DeletionSnapshot(
        usableViewportRectGlobal: Rect.fromLTWH(0, 100, 400, 600),
        preScroll: 4000,
        preMinScroll: 0,
        preMaxScroll: 8000,
        preTopSpacer: 0,
        preBottomSpacer: 0,
        upstreamRectDoc: Rect.fromLTWH(40, 500, 2, 24),
        downstreamRectDoc: Rect.fromLTWH(200, 1500, 2, 24),
        selectionRectDoc: Rect.fromLTWH(20, 500, 360, 1024),
        upstreamHandleVisible: false,
        downstreamHandleVisible: false,
        selectionIntersectsViewport: false,
        scenario: DeletionScenario.E,
      );

      final glide = buildScenarioEGlidePlan(
        snapshot: snapshot,
        postCaretRectDoc: const Rect.fromLTWH(40, 500, 2, 24),
        postBaseMaxScroll: 7000,
      );

      // Deleted height above viewport was ~1000, so initialScroll shifts to 3000
      // (keeping currently viewed screen content rock-solid on frame 0),
      // then glides smoothly toward caret at docY=500.
      expect(glide.evaluateScroll(0.0), closeTo(3000, 0.01));
      expect(glide.evaluateScroll(1.0), lessThan(600));
      expect(glide.evaluateScroll(0.5), greaterThan(glide.evaluateScroll(1.0)));
      expect(glide.evaluateScroll(0.5), lessThan(glide.evaluateScroll(0.0)));
    });
  });

  testWidgets('AuthoritativeScrollPosition blocks competing jumpTo while locked', (tester) async {
    final controller = AuthoritativeScrollController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          height: 300,
          child: ListView.builder(
            controller: controller,
            itemCount: 50,
            itemBuilder: (_, i) => SizedBox(height: 100, child: Text('Item $i')),
          ),
        ),
      ),
    );

    final pos = controller.authoritativePosition!;
    pos.authoritativeJumpTo(500);
    expect(pos.pixels, 500);

    pos.suppressCompetingScrolls = true;
    controller.jumpTo(1200);
    expect(pos.pixels, 500); // blocked

    pos.authoritativeJumpTo(800);
    expect(pos.pixels, 800); // authoritative allowed

    pos.suppressCompetingScrolls = false;
    controller.jumpTo(1200);
    expect(pos.pixels, 1200);

    controller.dispose();
  });
}
