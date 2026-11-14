import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/chat/dock/dock_pill.dart';
import 'package:dsh_app/ui/common/expand_reveal.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _capture = ValueKey('capture');

Future<Uint8List> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_capture));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  setUp(() => DockSlot.unclipSettledShadow = true);
  tearDown(() => DockSlot.unclipSettledShadow = false);

  testWidgets('DockSlot clips its shadow during motion and removes dismissed content', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Center(
          child: RepaintBoundary(
            key: _capture,
            child: SizedBox.square(
              dimension: 360,
              child: Center(
                child: SizedBox(
                  width: 180,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: shown,
                    builder: (context, value, _) => DockSlot(
                      child: value
                          ? const GlassBackdropScope(
                              enabled: false,
                              child: GlassSurface(
                                tier: GlassTier.chrome,
                                borderRadius: DockMetrics.shape,
                                child: SizedBox(height: DockMetrics.height),
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final glass = tester.element(find.byType(GlassSurface));
    final clip = find.descendant(of: find.byType(ExpandReveal), matching: find.byType(ClipRect)).first;
    expect(tester.widget<ClipRect>(clip).clipBehavior, Clip.none);
    shown.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.widget<ClipRect>(clip).clipBehavior, Clip.hardEdge);
    final bounds = tester.getRect(find.byType(DockSlot)).shift(-tester.getTopLeft(find.byKey(_capture)));
    expect(bounds.height, inExclusiveRange(0, DockMetrics.height + DockMetrics.gap));
    final moving = await _pixels(tester);
    var visible = false;
    var outside = 0;
    for (var y = 0; y < 360; y++) {
      for (var x = 0; x < 360; x++) {
        final alpha = moving[(y * 360 + x) * 4 + 3];
        if (alpha == 0) continue;
        visible = true;
        if (x < bounds.left.floor() || x >= bounds.right.ceil() || y < bounds.top.floor() || y >= bounds.bottom.ceil()) {
          outside++;
        }
      }
    }
    expect(visible, isTrue, reason: 'the closing frame still paints its live content');
    expect(outside, 0, reason: 'no shadow may escape the animated height');
    expect(tester.element(find.byType(GlassSurface)), same(glass));
    shown.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<ClipRect>(clip).clipBehavior, Clip.none);
    expect(
      tester.element(find.byType(GlassSurface)),
      same(glass),
      reason: 'reversing the reveal does not remount content',
    );
    shown.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(GlassSurface), findsNothing);
    expect(tester.getSize(find.byType(DockSlot)).height, 0);
    final hidden = await _pixels(tester);
    expect(hidden.where((channel) => channel != 0), isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('a fully shown DockSlot keeps the complete glass shadow (dark=$dark)', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final oldDisableShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        Future<Uint8List> render({required bool slot}) async {
          const glass = GlassBackdropScope(
            enabled: false,
            child: GlassSurface(
              tier: GlassTier.chrome,
              borderRadius: DockMetrics.shape,
              child: SizedBox(height: DockMetrics.height),
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? buildDarkTheme() : buildLightTheme(),
              home: Center(
                child: RepaintBoundary(
                  key: _capture,
                  child: SizedBox.square(
                    dimension: 360,
                    child: Center(
                      child: SizedBox(
                        width: 180,
                        child: slot
                            ? const DockSlot(child: glass)
                            : const Padding(
                                padding: EdgeInsets.only(bottom: DockMetrics.gap),
                                child: glass,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          return _pixels(tester);
        }

        final reference = await render(slot: false);
        final actual = await render(slot: true);
        expect(tester.getSize(find.byType(DockSlot)), const Size(180, DockMetrics.height + DockMetrics.gap));
        // This is beyond the slot's right edge (270) and glass bottom (195):
        // the old SizeTransition cut it off into a rectangular grey band.
        const outsideCorner = (198 * 360 + 273) * 4 + 3;
        expect(reference[outsideCorner], greaterThan(0));
        expect(
          actual[outsideCorner],
          reference[outsideCorner],
          reason: 'the outer corner shadow must survive DockSlot',
        );
        var differentChannels = 0;
        for (var i = 0; i < actual.length; i++) {
          if (actual[i] != reference[i]) differentChannels++;
        }
        expect(
          differentChannels,
          0,
          reason: 'the settled slot must match the unclipped glass, including its soft shadow',
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugDisableShadows = oldDisableShadows;
      }
    });
  }
}
