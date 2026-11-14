import 'package:dsh_app/ui/common/expand_reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Draft extends StatefulWidget {
  const _Draft();

  @override
  State<_Draft> createState() => _DraftState();
}

class _DraftState extends State<_Draft> {
  final controller = TextEditingController(text: 'draft');

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(height: 80, child: TextField(controller: controller));
}

Widget _app(Widget child) => MaterialApp(
  home: Material(
    child: Center(child: SizedBox(width: 160, child: child)),
  ),
);

final _clip = find.descendant(of: find.byType(ExpandReveal), matching: find.byType(ClipRect)).first;

void main() {
  testWidgets('ExpandReveal keeps clipping by default and preserves its original sizing', (tester) async {
    final open = ValueNotifier(true);
    addTearDown(open.dispose);
    await tester.pumpWidget(
      _app(
        ValueListenableBuilder<bool>(
          valueListenable: open,
          builder: (context, value, _) => ExpandReveal(
            open: value,
            duration: const Duration(milliseconds: 200),
            curve: Curves.linear,
            child: const SizedBox(height: 80),
          ),
        ),
      ),
    );
    expect(tester.widget<ClipRect>(_clip).clipBehavior, Clip.hardEdge);
    expect(tester.getSize(find.byType(ExpandReveal)), const Size(160, 80));
    open.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<ClipRect>(_clip).clipBehavior, Clip.hardEdge);
    expect(tester.getSize(find.byType(ExpandReveal)), const Size(160, 40));
    await tester.pump(const Duration(milliseconds: 101));
    expect(tester.getSize(find.byType(ExpandReveal)), const Size(160, 0));
    expect(find.descendant(of: find.byType(ExpandReveal), matching: find.byType(FadeTransition)), findsNothing);
  });

  testWidgets('unclipping the expanded child preserves State, draft and selection through reversal', (tester) async {
    final controls = ValueNotifier((open: true, clip: false));
    addTearDown(controls.dispose);
    await tester.pumpWidget(
      _app(
        ValueListenableBuilder<({bool open, bool clip})>(
          valueListenable: controls,
          builder: (context, value, _) => ExpandReveal(
            open: value.open,
            clipWhenExpanded: value.clip,
            duration: const Duration(milliseconds: 200),
            curve: Curves.linear,
            child: const _Draft(),
          ),
        ),
      ),
    );
    final clipElement = tester.element(_clip);
    final state = tester.state<_DraftState>(find.byType(_Draft));
    state.controller.value = const TextEditingValue(
      text: 'live draft',
      selection: TextSelection(baseOffset: 2, extentOffset: 7),
    );
    expect(tester.widget<ClipRect>(_clip).clipBehavior, Clip.none);

    controls.value = (open: false, clip: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<ClipRect>(_clip).clipBehavior, Clip.hardEdge);
    expect(tester.getSize(find.byType(ExpandReveal)).height, 40);
    expect(tester.state<_DraftState>(find.byType(_Draft)), same(state));

    controls.value = (open: true, clip: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 101));
    expect(tester.widget<ClipRect>(_clip).clipBehavior, Clip.none);
    for (final clip in [true, false]) {
      controls.value = (open: true, clip: clip);
      await tester.pump();
      expect(tester.widget<ClipRect>(_clip).clipBehavior, clip ? Clip.hardEdge : Clip.none);
      expect(tester.element(_clip), same(clipElement));
      expect(tester.state<_DraftState>(find.byType(_Draft)), same(state));
      expect(state.controller.text, 'live draft');
      expect(state.controller.selection, const TextSelection(baseOffset: 2, extentOffset: 7));
    }

    controls.value = (open: false, clip: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 201));
    expect(find.byType(_Draft), findsNothing, reason: 'fully dismissed content is still unmounted, as before');
    expect(state.mounted, isFalse);
    expect(tester.getSize(find.byType(ExpandReveal)).height, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keepState retains the subtree offstage at zero height after the first open', (tester) async {
    final open = ValueNotifier(false);
    addTearDown(open.dispose);
    await tester.pumpWidget(
      _app(
        ValueListenableBuilder<bool>(
          valueListenable: open,
          builder: (context, value, _) => ExpandReveal(
            open: value,
            keepState: true,
            duration: const Duration(milliseconds: 200),
            curve: Curves.linear,
            child: const _Draft(),
          ),
        ),
      ),
    );
    expect(find.byType(_Draft, skipOffstage: false), findsNothing, reason: 'not built before the first open');

    open.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 201));
    final state = tester.state<_DraftState>(find.byType(_Draft));
    expect(tester.getSize(find.byType(ExpandReveal)).height, 80);

    open.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 201));
    expect(tester.getSize(find.byType(ExpandReveal)).height, 0);
    expect(find.byType(_Draft), findsNothing, reason: 'offstage when closed');
    expect(find.byType(_Draft, skipOffstage: false), findsOneWidget, reason: 'state kept offstage');
    expect(tester.state<_DraftState>(find.byType(_Draft, skipOffstage: false)), same(state));
    expect(TickerMode.valuesOf(tester.element(find.byType(_Draft, skipOffstage: false))).enabled, isFalse);

    open.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 201));
    expect(tester.state<_DraftState>(find.byType(_Draft)), same(state));
    expect(tester.takeException(), isNull);
  });
}
