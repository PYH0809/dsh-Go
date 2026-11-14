import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/adaptive/support.dart';

const _captureKey = ValueKey('capture');

Future<Uint8List> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
}

void _expectNoAncestorRepaintBoundary(Iterable<RenderBackdropFilter> filters, {required RenderObject stopAt}) {
  expect(filters, isNotEmpty);
  for (final filter in filters) {
    RenderObject? node = filter.parent;
    while (node != null && !identical(node, stopAt)) {
      expect(
        node,
        isNot(isA<RenderRepaintBoundary>()),
        reason: 'RenderBackdropFilter (${filter.debugCreator}) has an ancestor RenderRepaintBoundary '
            '(${node.debugCreator}), which isolates BackdropFilter into an empty offscreen layer on Impeller OpenGLES',
      );
      node = node.parent;
    }
  }
}

void main() {
  setUpAll(loadTestFonts);

  for (final tier in [GlassTier.sheet, GlassTier.chrome]) {
    for (final shape in ['rounded', 'stadium', 'circle']) {
      testWidgets('$tier $shape vector outer shadow paints strictly outside the shape without SnapshotWidget', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        final oldDisableShadows = debugDisableShadows;
        debugDisableShadows = false;
        try {
          final theme = buildLightTheme();
          final style = theme
              .extension<DshSurfaces>()!
              .glass(tier)
              .copyWith(
                fill: Colors.transparent,
                fallbackFill: Colors.transparent,
                hairline: Colors.transparent,
                rim: Colors.transparent,
                blurSigma: 0,
              );
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Center(
                child: RepaintBoundary(
                  key: _captureKey,
                  child: SizedBox.square(
                    dimension: 360,
                    child: Center(
                      child: GlassSurface(
                        tier: tier,
                        style: style,
                        borderRadius: const BorderRadius.all(Radius.circular(28)),
                        stadium: shape == 'stadium',
                        circle: shape == 'circle',
                        child: const SizedBox(width: 120, height: 140),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(find.descendant(of: find.byType(GlassSurface), matching: find.byType(SnapshotWidget)), findsNothing);
          expect(find.descendant(of: find.byType(GlassSurface), matching: find.byType(RepaintBoundary)), findsNothing);
          final bytes = await _pixels(tester);
          int alpha(int x, int y) => bytes[(y * 360 + x) * 4 + 3];
          expect(alpha(180, 255), greaterThan(0), reason: 'soft shadow paints below the 250px shape bottom');
          expect(alpha(180, 180), 0, reason: 'outer shadow never paints inside the glass interior');
          expect(alpha(0, 0), 0);
          expect(tester.takeException(), isNull);
        } finally {
          debugDisableShadows = oldDisableShadows;
        }
      });
    }
  }

  testWidgets('every active GlassSurface BackdropFilter in HomeShell, ChatScreen, Drawer, and Sheet has no ancestor RepaintBoundary', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
    final oldSnapshotCaching = AppBackdrop.snapshotCaching;
    AppBackdrop.snapshotCaching = true;
    addTearDown(() {
      AppBackdrop.snapshotCaching = oldSnapshotCaching;
      thawClocks();
    });

    usePhoneView(tester);
    late VoidCallback openDrawer;
    await tester.pumpWidget(
      testApp(
        HomeShell(
          chatBuilder: (open) {
            openDrawer = open;
            return ChatScreen(onOpenDrawer: open, backdrop: false);
          },
        ),
        overrides: homeOverrides(),
      ),
    );
    await pumpFrames(tester, 10);

    final shellRoot = tester.renderObject(find.byType(HomeShell));

    // 1. ChatScreen chrome (header + composer + dock):
    final chatFilters = tester.renderObjectList<RenderBackdropFilter>(find.byType(BackdropFilter));
    _expectNoAncestorRepaintBoundary(chatFilters, stopAt: shellRoot);

    // 2. Open SessionsDrawer:
    openDrawer();
    await tester.pump();
    await pumpFrames(tester, 12);
    final drawerFilters = tester.renderObjectList<RenderBackdropFilter>(find.byType(BackdropFilter));
    _expectNoAncestorRepaintBoundary(drawerFilters, stopAt: shellRoot);

    // 3. Open modal sheet over the open drawer (like ModeSheet / WorkspaceSheet):
    final shellContext = tester.element(find.byType(HomeShell));
    // ignore: unawaited_futures
    showAppSheet<void>(shellContext, builder: (_) => const SizedBox(height: 280, child: Text('弹层内容')));
    await tester.pumpAndSettle();
    final bottomSheetRoot = tester.renderObject(find.byType(BottomSheet));
    final sheetFilters = tester.renderObjectList<RenderBackdropFilter>(
      find.descendant(of: find.byType(BottomSheet), matching: find.byType(BackdropFilter)),
    );
    _expectNoAncestorRepaintBoundary(sheetFilters, stopAt: bottomSheetRoot);
    expect(sheetFilters.single.enabled, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
