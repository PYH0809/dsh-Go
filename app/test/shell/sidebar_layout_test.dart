import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'adaptive/support.dart';

Finder get _drawer =>
    find.byWidgetPredicate((widget) => widget is SessionsDrawer && widget.drawerMotion != null, skipOffstage: false);

Map<String, RenderObject> _renderTree(RenderObject root) {
  final objects = <String, RenderObject>{};
  void visit(RenderObject object) {
    // The suffix changes with dirty flags and relayout-boundary depth.
    objects[object.toStringShort().split(' ').first] = object;
    object.visitChildren(visit);
  }

  visit(root);
  return objects;
}

/// Count real render layouts, not layout() calls that return immediately. This
/// distinguishes actual descendant work from an Offstage wrapper changing size.
Future<({Map<String, int> layouts, Map<String, int> builds})> _work(
  Map<String, RenderObject> objects,
  Future<void> Function() action,
) async {
  final layouts = <String, int>{};
  final builds = <String, int>{};
  final previousPrint = debugPrint;
  final previousLayouts = debugPrintLayouts;
  final previousBuilds = debugOnRebuildDirtyWidget;
  debugPrintLayouts = true;
  debugPrint = (message, {wrapWidth}) {
    if (message != null && message.startsWith('Laying out ')) {
      for (final name in objects.keys) {
        if (message.contains(name)) layouts.update(name, (count) => count + 1, ifAbsent: () => 1);
      }
    } else {
      previousPrint(message, wrapWidth: wrapWidth);
    }
  };
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    previousBuilds?.call(element, builtOnce);
    final type = element.widget.runtimeType.toString();
    if (const {
      'HomeShell',
      'ChatScreen',
      'ChatList',
      'SessionsDrawer',
      'AssistantMessage',
      'MarkdownBody',
    }.contains(type)) {
      builds.update(type, (count) => count + 1, ifAbsent: () => 1);
    }
  };
  try {
    await action();
  } finally {
    debugPrint = previousPrint;
    debugPrintLayouts = previousLayouts;
    debugOnRebuildDirtyWidget = previousBuilds;
  }
  return (layouts: layouts, builds: builds);
}

Future<void> _close(WidgetTester tester) async {
  await Navigator.of(tester.element(find.byType(HomeShell))).maybePop();
  await tester.pump();
  await pumpFrames(tester, 10);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
  });
  tearDown(thawClocks);

  testWidgets('reopening the drawer does not rebuild the page or relayout unchanged drawer content', (tester) async {
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
    // Let the drawer's one-time AnimatedSize entrances finish too. Its hidden
    // tickers were correctly muted during initial layout.
    openDrawer();
    await tester.pump();
    await pumpFrames(tester, 10);
    await _close(tester);
    expect(
      find.descendant(of: _drawer, matching: find.text('修复登录重复提交', skipOffstage: false), skipOffstage: false),
      findsOneWidget,
      reason: 'the lazy session row must be materialized before measuring its retained subtree',
    );
    final root = tester.element(_drawer).findRenderObject()!;
    final objects = _renderTree(root);
    expect(objects.length, greaterThan(100), reason: 'observe the real populated drawer, not a placeholder');

    // Positive control: make sure the diagnostic catches a genuine layout.
    final forced = await _work(objects, () async {
      root.markNeedsLayout();
      await tester.pump();
    });
    expect(forced.layouts[root.toStringShort().split(' ').first], greaterThan(0));
    await pumpFrames(tester, 2);
    final idle = await _work(objects, () => pumpFrames(tester, 2));
    expect(idle.layouts, isEmpty, reason: 'initial provider/layout work must finish before measurement');

    for (var cycle = 0; cycle < 3; cycle++) {
      final opening = await _work(objects, () async {
        openDrawer();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
      });
      final motion = tester.widget<SessionsDrawer>(_drawer).drawerMotion!;
      expect(motion.value, greaterThan(0));
      expect(motion.value, lessThan(1));
      expect(opening.builds, isEmpty, reason: 'the first visible frame updates gates, not the chat/drawer widgets');
      expect(opening.layouts, isEmpty, reason: 'opening only translates already laid-out drawer content');
      await pumpFrames(tester, 10);
      final closing = await _work(objects, () => _close(tester));
      expect(motion.value, 0);
      expect(closing.builds, isEmpty, reason: 'reaching zero must not rebuild the page either');
      expect(closing.layouts, isEmpty);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a retained hidden drawer stays silent and excluded from focus, hits and semantics', (tester) async {
    usePhoneView(tester);
    final semantics = tester.ensureSemantics();
    try {
      late VoidCallback openDrawer;
      var chatTaps = 0;
      await tester.pumpWidget(
        testApp(
          HomeShell(
            chatBuilder: (open) {
              openDrawer = open;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => chatTaps++,
                child: const Center(child: Text('chat-control')),
              );
            },
          ),
          overrides: homeOverrides(),
        ),
      );
      await pumpFrames(tester, 10);
      // Materialize the lazy session rows before testing their retained hidden
      // state: the initially muted entrance animations have not settled yet.
      openDrawer();
      await tester.pump();
      await pumpFrames(tester, 10);
      await _close(tester);
      const title = '修复登录重复提交';
      final label = find.descendant(of: _drawer, matching: find.text(title, skipOffstage: false), skipOffstage: false);
      expect(label, findsOneWidget, reason: 'inspect the real retained session title, not a placeholder');
      final focus = Focus.of(tester.element(label));
      final dot = find
          .descendant(
            of: _drawer,
            matching: find.byWidgetPredicate(
              (widget) => widget is StatusDot && widget.tone == StatusTone.busy,
              skipOffstage: false,
            ),
            skipOffstage: false,
          )
          .first;
      final opacity = tester
          .widget<FadeTransition>(
            find.descendant(of: dot, matching: find.byType(FadeTransition, skipOffstage: false), skipOffstage: false),
          )
          .opacity;
      var ticks = 0;
      void onTick() => ticks++;
      opacity.addListener(onTick);
      addTearDown(() => opacity.removeListener(onTick));

      void expectHidden() {
        expect(_drawer, findsOneWidget, reason: 'state is retained');
        expect(label.hitTestable(), findsNothing);
        expect(focus.canRequestFocus, isFalse);
        expect(focus.hasFocus, isFalse);
        expect(find.semantics.byLabel(RegExp(title)), findsNothing);
        expect(find.semantics.byLabel('chat-control'), findsOne);
      }

      expectHidden();
      await pumpFrames(tester, 3);
      expect(ticks, 0);
      for (var cycle = 0; cycle < 3; cycle++) {
        openDrawer();
        await tester.pump();
        await pumpFrames(tester, 10);
        expect(label.hitTestable(), findsOneWidget);
        expect(find.semantics.byLabel(RegExp(title)), findsOne);
        expect(find.semantics.byLabel('chat-control'), findsNothing);
        expect(focus.canRequestFocus, isTrue);
        focus.requestFocus();
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        final before = ticks;
        await pumpFrames(tester, 3);
        expect(ticks, greaterThan(before), reason: 'visible busy indicator still animates');
        final position = tester.getCenter(label);

        await _close(tester);
        expectHidden();
        final stopped = ticks;
        focus.requestFocus();
        await pumpFrames(tester, 3);
        expect(focus.hasFocus, isFalse);
        expect(ticks, stopped, reason: 'hidden busy indicator must not tick');
        await tester.tapAt(position);
        await tester.pump();
        expect(chatTaps, cycle + 1, reason: 'the hidden drawer and scrim do not intercept the chat');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      semantics.dispose();
    }
  });
}
