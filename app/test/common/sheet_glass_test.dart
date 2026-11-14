// A sheet's glass blurs only at rest: the rise, the fall and a drag show an opaque
// fill, and the blur clears in once it stops, without the content noticing.
//
//   flutter test test/common/sheet_glass_test.dart

import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/discard_guard.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Counted extends StatefulWidget {
  const _Counted(this.inits);

  final List<int> inits;

  @override
  State<_Counted> createState() => _CountedState();
}

class _CountedState extends State<_Counted> {
  @override
  void initState() {
    super.initState();
    widget.inits.add(1);
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 240);
}

Future<void> _open(WidgetTester tester, Widget Function(BuildContext) builder) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAppSheet<void>(context, builder: builder),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pump();
}

final _sheetBlur = find.descendant(of: find.byType(BottomSheet), matching: find.byType(BackdropFilter));

bool _blurring(WidgetTester tester) => tester.widget<BackdropFilter>(_sheetBlur).enabled;

double _settled(WidgetTester tester) => tester
    .widget<GlassSurface>(find.descendant(of: find.byType(BottomSheet), matching: find.byType(GlassSurface)))
    .settled!;

void main() {
  testWidgets('no blur on the way up; at rest it clears in over a short fade', (tester) async {
    final inits = <int>[];
    await _open(tester, (_) => _Counted(inits));
    for (var t = 0; t < AppMotion.sheetIn.inMilliseconds - 40; t += 40) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(_blurring(tester), isFalse, reason: 'at $t ms');
    }
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 60));
    expect(_blurring(tester), isTrue);
    expect(_settled(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_settled(tester), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(inits.length, 1, reason: 'the blur coming on does not rebuild what is in the sheet');
  });

  testWidgets('a drag stops the blur at once, and letting go brings it back', (tester) async {
    await _open(tester, (_) => const SizedBox(height: 240, child: Text('内容')));
    await tester.pumpAndSettle();
    expect(_blurring(tester), isTrue);
    final finger = await tester.startGesture(tester.getCenter(find.text('内容')));
    await finger.moveBy(const Offset(0, 30));
    await tester.pump();
    await finger.moveBy(const Offset(0, 10));
    await tester.pump();
    expect(_blurring(tester), isFalse);
    await finger.up();
    await tester.pumpAndSettle();
    expect(_blurring(tester), isTrue);
    expect(_settled(tester), 1);
  });

  testWidgets('going down it does not blur either', (tester) async {
    await _open(tester, (_) => const SizedBox(height: 240, child: Text('内容')));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('内容'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(_blurring(tester), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('内容'), findsNothing);
  });

  testWidgets('a held sheet under the finger does not blur either', (tester) async {
    final draft = TextEditingController(text: '未保存');
    addTearDown(draft.dispose);
    await _open(
      tester,
      (_) => DiscardGuard(
        listenable: draft,
        isDirty: () => draft.text.isNotEmpty,
        child: const SizedBox(height: 240, child: Text('内容')),
      ),
    );
    await tester.pumpAndSettle();
    expect(_blurring(tester), isTrue);
    final finger = await tester.startGesture(tester.getCenter(find.text('内容')));
    await finger.moveBy(const Offset(0, 30));
    await tester.pump();
    await finger.moveBy(const Offset(0, 10));
    await tester.pump();
    expect(_blurring(tester), isFalse);
    await finger.up();
    await tester.pumpAndSettle();
    expect(_blurring(tester), isTrue);
    expect(_settled(tester), 1);
  });

  testWidgets('remove animations: glass from the first frame', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _open(tester, (_) => const SizedBox(height: 240, child: Text('内容')));
    expect(_blurring(tester), isTrue);
    expect(_settled(tester), 1);
  });

  testWidgets('at rest the glass is the plain glass', (tester) async {
    await _open(tester, (_) => const SizedBox(height: 240, child: Text('内容')));
    await tester.pumpAndSettle();
    final glass = DshSurfaces.of(tester.element(find.text('内容'))).glass(GlassTier.sheet);
    final fill = find.descendant(of: find.byType(GlassSurface), matching: find.byType(DecoratedBox));
    final decoration = tester.widgetList<DecoratedBox>(fill).first.decoration as ShapeDecoration;
    expect(decoration.color, glass.fill);
  });

  testWidgets('IME keyboard rise lifts the sheet outside GlassSurface without resizing glass or rebuilding content', (
    tester,
  ) async {
    GlassSurface.shadowCaching = true;
    addTearDown(() {
      GlassSurface.shadowCaching = false;
      tester.view.resetViewInsets();
    });
    final oldDisableShadows = debugDisableShadows;
    debugDisableShadows = false;
    try {
      var contentBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAppSheet<void>(
                  context,
                  isScrollControlled: true,
                  builder: (sheetContext) => Padding(
                    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
                    child: Builder(
                      builder: (context) {
                        contentBuilds++;
                        return const SizedBox(height: 220, child: Text('邮箱输入'));
                      },
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(_blurring(tester), isTrue);
      final glassFinder = find.descendant(of: find.byType(BottomSheet), matching: find.byType(GlassSurface));
      final restingRect = tester.getRect(glassFinder);
      final buildsAtRest = contentBuilds;

      // Simulate 10 consecutive Android IME animation frames (0 -> 260dp):
      final dpr = tester.view.devicePixelRatio;
      for (var step = 1; step <= 10; step++) {
        final insetDp = 26.0 * step;
        tester.view.viewInsets = FakeViewPadding(bottom: insetDp * dpr);
        await tester.pump(const Duration(milliseconds: 16));
        expect(_blurring(tester), isFalse, reason: 'blur suspended during IME frame $step');
        final rect = tester.getRect(glassFinder);
        expect(rect.height, restingRect.height, reason: 'GlassSurface height stays fixed instead of stretching behind IME');
        expect(rect.bottom, closeTo(restingRect.bottom - insetDp, 0.5), reason: 'sheet rises cleanly above IME');
      }
      expect(contentBuilds, buildsAtRest, reason: 'inner sheet content is shielded from per-frame viewInsets rebuilds');

      await tester.pumpAndSettle();
      expect(_blurring(tester), isTrue, reason: 'blur fades back in once IME settles');
      expect(_settled(tester), 1);
    } finally {
      debugDisableShadows = oldDisableShadows;
    }
  });

  testWidgets('DraggableScrollableSheet resize suspends blur while dragging up and fades back in at rest', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAppSheet<void>(
                context,
                isScrollControlled: true,
                builder: (_) => DraggableScrollableSheet(
                  expand: false,
                  initialChildSize: 0.5,
                  minChildSize: 0.3,
                  maxChildSize: 0.9,
                  builder: (context, controller) => ListView.builder(
                    controller: controller,
                    itemCount: 30,
                    itemBuilder: (context, index) => SizedBox(height: 48, child: Text('步骤 $index')),
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(_blurring(tester), isTrue);

    final gesture = await tester.startGesture(tester.getCenter(find.text('步骤 2')));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(_blurring(tester), isFalse, reason: 'blur suspended while DraggableScrollableSheet expands');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_blurring(tester), isTrue, reason: 'blur resumes once DraggableScrollableSheet settles');
    expect(_settled(tester), 1);
  });

  testWidgets('sheet glass keeps real BackdropFilter enabled at rest even when AppBackdrop.snapshotCaching is true', (
    tester,
  ) async {
    final oldSnapshotCaching = AppBackdrop.snapshotCaching;
    AppBackdrop.snapshotCaching = true;
    addTearDown(() => AppBackdrop.snapshotCaching = oldSnapshotCaching);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: AppBackdrop(
          child: Builder(
            builder: (context) => Scaffold(
              backgroundColor: Colors.transparent,
              body: Column(
                children: [
                  const Text('底层抽屉文字不应清晰直透'),
                  TextButton(
                    onPressed: () => showAppSheet<void>(
                      context,
                      builder: (_) => const SizedBox(height: 240, child: Text('工作区弹层')),
                    ),
                    child: const Text('打开'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(_blurring(tester), isTrue, reason: 'resting modal sheet must sample real sigma=24 backdrop blur in production');
    expect(_settled(tester), 1);
  });
}
