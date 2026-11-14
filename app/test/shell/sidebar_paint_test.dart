import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../support/test_fonts.dart' show withTestFonts;
import 'adaptive/support.dart';

class _PaintCounter extends CustomPainter {
  _PaintCounter(this.changes) : super(repaint: changes);

  final ValueNotifier<int> changes;
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = changes.value.isEven ? Colors.blue : Colors.green);
  }

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppBackdrop.snapshotCaching = true;
  });
  tearDown(() => AppBackdrop.snapshotCaching = false);
  for (final fluid in [false, true]) {
    testWidgets('side panel motion does not repaint unchanged chat content (fluid=$fluid)', (tester) async {
      usePhoneView(tester);
      final changes = ValueNotifier(0);
      addTearDown(changes.dispose);
      final painter = _PaintCounter(changes);
      late VoidCallback openDrawer;
      await tester.pumpWidget(
        testApp(
          Theme(
            data: withTestFonts(buildLightTheme(fluid: fluid)),
            child: HomeShell(
              chatBuilder: (open) {
                openDrawer = open;
                return CustomPaint(
                  painter: painter,
                  child: const Align(
                    alignment: Alignment.topCenter,
                    child: GlassSurface(
                      key: ValueKey('chat-chrome'),
                      tier: GlassTier.chrome,
                      child: SizedBox(width: 80, height: 40),
                    ),
                  ),
                );
              },
            ),
          ),
          overrides: homeOverrides(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      openDrawer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      final before = painter.paints;
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(painter.paints, before, reason: 'static chat paint count at drawer frame $frame');
      }
      bool sampling() => tester
          .widget<BackdropFilter>(
            find.descendant(of: find.byKey(const ValueKey('chat-chrome')), matching: find.byType(BackdropFilter)),
          )
          .enabled;
      expect(sampling(), isFalse);
      changes.value++;
      await tester.pump(const Duration(milliseconds: 20));
      expect(painter.paints, before + 1, reason: 'new content is drawn during motion, not frozen in a snapshot');
      await tester.pump(const Duration(seconds: 1));
      expect(sampling(), isFalse, reason: 'covered chat chrome stays suspended while the drawer covers the page');

      await Navigator.of(tester.element(find.byType(HomeShell))).maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(sampling(), isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(sampling(), isTrue, reason: 'sampling resumes once the drawer closes');

      // The opposite panel shares the policy, including a held and cancelled
      // drag. Content can still repaint while the finger is stationary.
      final finger = await tester.startGesture(const Offset(280, 400));
      await finger.moveBy(const Offset(-20, 0));
      await tester.pump();
      await finger.moveBy(const Offset(-80, 0));
      await tester.pump();
      expect(sampling(), isFalse);
      final held = painter.paints;
      changes.value++;
      await tester.pump(const Duration(milliseconds: 100));
      expect(painter.paints, held + 1);
      expect(sampling(), isFalse);
      await finger.cancel();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(sampling(), isTrue, reason: 'a cancelled right-panel drag restores sampling');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
