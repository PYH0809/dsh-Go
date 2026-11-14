// The bars above the composer as one deck (lib/ui/chat/dock/dock_stack.dart):
// folded into the front card's row with the others peeking above, a tap to
// spread, the fold button beside the top card to fold, the choice remembered; a swipe brings another card
// forward; one card is never a deck; the
// accessory beside the front card answers on the folded deck too; a card
// growing in moves the deck smoothly.

import 'package:dsh_app/ui/chat/dock/dock_pill.dart';
import 'package:dsh_app/ui/chat/dock/dock_stack.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';

const _bar = DockMetrics.height + DockMetrics.gap;

/// A bar's slot: a bar of glass, the dock gap under it.
class _Card extends StatelessWidget {
  const _Card(this.label, {this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DockMetrics.gap),
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        key: ValueKey(label),
        height: DockMetrics.height,
        alignment: Alignment.center,
        decoration: const ShapeDecoration(color: Color(0xFFDDE4F0), shape: StadiumBorder()),
        child: Text(label),
      ),
    ),
  );
}

/// Uses the real chrome material rather than the solid geometry fixture.
/// Its State must survive folding just as an open TodoBar's State does.
class _GlassCard extends StatefulWidget {
  const _GlassCard(this.label, {super.key, this.editable = false});

  final String label;
  final bool editable;

  @override
  State<_GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<_GlassCard> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DockMetrics.gap),
    child: GlassSurface(
      key: ValueKey('glass-${widget.label}'),
      tier: GlassTier.chrome,
      grouped: true,
      stadium: true,
      child: SizedBox(
        height: DockMetrics.height,
        child: widget.editable ? TextField(controller: controller) : Center(child: Text(widget.label)),
      ),
    ),
  );
}

const _dockSurfaces = ['glass-todo', 'glass-goal', 'glass-strip', 'glass-accessory', 'dock-fold'];

void _expectDockSampling(WidgetTester tester, {required bool enabled}) {
  for (final label in _dockSurfaces) {
    final surface = find.byKey(ValueKey(label));
    expect(surface, findsOneWidget, reason: label);
    expect(tester.widget(surface), isA<GlassSurface>(), reason: '$label retains its chrome material');
    final filter = find.descendant(of: surface, matching: find.byType(BackdropFilter));
    expect(filter, findsOneWidget);
    expect(
      tester.widget<BackdropFilter>(filter).enabled,
      enabled,
      reason: '$label samples at rest, unless an ancestor already suspended sampling',
    );
    final style = DshSurfaces.of(tester.element(surface)).chrome;
    final fill = tester
        .widgetList<DecoratedBox>(find.descendant(of: surface, matching: find.byType(DecoratedBox)))
        .map((box) => box.decoration)
        .whereType<ShapeDecoration>()
        .single
        .color;
    expect(fill, enabled ? style.fill : style.fallbackFill, reason: '$label restores its original fill at rest');
  }
  final outside = find.descendant(
    of: find.byKey(const ValueKey('outside-chrome')),
    matching: find.byType(BackdropFilter),
  );
  expect(outside, findsOneWidget, reason: 'the dock must not disable blur elsewhere on the page');
  expect(tester.widget<BackdropFilter>(outside).enabled, isTrue);
}

/// A bar that rises in on its own, like the activity strip.
class _Rising extends StatefulWidget {
  const _Rising();

  static var mounts = 0;

  @override
  State<_Rising> createState() => _RisingState();
}

class _RisingState extends State<_Rising> with SingleTickerProviderStateMixin {
  late final AnimationController _rise = AnimationController(vsync: this, duration: const Duration(milliseconds: 240))
    ..forward();

  @override
  void initState() {
    super.initState();
    _Rising.mounts++;
  }

  @override
  void dispose() {
    _rise.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _rise,
    builder: (context, child) => ClipRect(
      child: Align(alignment: Alignment.topCenter, heightFactor: _rise.value, child: child),
    ),
    child: const _Card('rising'),
  );
}

Widget _deck(List<Widget> cards, {Widget? accessory, PreferredSizeWidget? appBar, bool backdropEnabled = true}) =>
    testApp(
      Scaffold(
        appBar: appBar,
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 80),
            // As on ChatScreen, the dock inherits a shared backdrop group.
            child: BackdropGroup(
              child: GlassBackdropScope(
                enabled: backdropEnabled,
                child: DockStack(cards: cards, accessory: accessory),
              ),
            ),
          ),
        ),
      ),
    );

Widget _glassDeck({bool backdropEnabled = true}) => _deck(
  const [
    _GlassCard('todo', key: ValueKey('state-todo')),
    _GlassCard('goal', key: ValueKey('state-goal'), editable: true),
    _GlassCard('strip', key: ValueKey('state-strip')),
  ],
  backdropEnabled: backdropEnabled,
  accessory: const GlassSurface(
    key: ValueKey('glass-accessory'),
    tier: GlassTier.chrome,
    grouped: true,
    circle: true,
    child: SizedBox.square(dimension: DockMetrics.height),
  ),
  appBar: const PreferredSize(
    preferredSize: Size.fromHeight(DockMetrics.height),
    child: GlassSurface(
      key: ValueKey('outside-chrome'),
      tier: GlassTier.chrome,
      child: SizedBox(height: DockMetrics.height),
    ),
  ),
);

double _deckHeight(WidgetTester tester) => tester.getSize(find.byType(DockStack)).height;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('three bars fold into one row; a tap spreads them, the fold button folds them, and it is remembered', (
    tester,
  ) async {
    usePhoneView(tester);
    var taps = 0;
    await tester.pumpWidget(_deck([const _Card('todo'), const _Card('goal'), _Card('strip', onTap: () => taps++)]));
    await pumpFrames(tester);

    // Folded by default: the front card's row and two peeks.
    expect(_deckHeight(tester), 2 * DockStackMetrics.peek + _bar);
    final front = tester.getRect(find.byKey(const ValueKey('strip')));
    final goal = tester.getRect(find.byKey(const ValueKey('goal')));
    final todo = tester.getRect(find.byKey(const ValueKey('todo')));
    expect(front.top - goal.top, DockStackMetrics.peek);
    expect(goal.top - todo.top, DockStackMetrics.peek);
    // Further back, smaller, centred.
    expect(goal.width, lessThan(front.width));
    expect(todo.width, lessThan(goal.width));
    expect(goal.center.dx, moreOrLessEquals(front.center.dx, epsilon: 0.01));
    expect(find.byKey(const ValueKey('dock-fold')).hitTestable(), findsNothing);

    // The folded deck takes the tap: the front card's own doesn't fire.
    await tester.tap(find.byKey(const ValueKey('strip')));
    await pumpFrames(tester);
    expect(taps, 0);
    expect(_deckHeight(tester), 3 * _bar);
    expect(
      tester.getRect(find.byKey(const ValueKey('goal'))).top - tester.getRect(find.byKey(const ValueKey('todo'))).top,
      _bar,
    );
    // The fold button beside the top card: no row of its own.
    final fold = tester.getRect(find.byKey(const ValueKey('dock-fold')));
    final top = tester.getRect(find.byKey(const ValueKey('todo')));
    expect(fold.top, top.top);
    expect(fold.size, const Size.square(DockStackMetrics.foldSize));
    expect(fold.left - top.right, DockStackMetrics.accessoryGap);
    expect(fold.right, tester.getRect(find.byKey(const ValueKey('strip'))).right);
    expect(find.byKey(const ValueKey('dock-fold')).hitTestable(), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool(DockFoldController.key), isFalse);

    // Spread, the cards answer for themselves.
    await tester.tap(find.byKey(const ValueKey('strip')));
    await tester.pump();
    expect(taps, 1);

    await tester.tap(find.byKey(const ValueKey('dock-fold')));
    await pumpFrames(tester);
    expect(_deckHeight(tester), 2 * DockStackMetrics.peek + _bar);
    expect((await SharedPreferences.getInstance()).getBool(DockFoldController.key), isTrue);
  });

  testWidgets('dock samples at rest, suspends during motion, and preserves State, draft and selection', (tester) async {
    usePhoneView(tester);
    final builds = <String, int>{};
    final previousRebuild = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previousRebuild?.call(element, builtOnce);
      final widget = element.widget;
      final key = widget.key;
      if (widget is GlassSurface && key is ValueKey<String> && _dockSurfaces.contains(key.value)) {
        builds.update(key.value, (count) => count + 1, ifAbsent: () => 1);
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previousRebuild);
    await tester.pumpWidget(_glassDeck());
    await pumpFrames(tester);
    _expectDockSampling(tester, enabled: true);
    expect(builds.keys, unorderedEquals(_dockSurfaces));
    final states = {
      for (final label in ['todo', 'goal', 'strip'])
        label: tester.state<_GlassCardState>(find.byKey(ValueKey('state-$label'))),
    };
    final filters = {
      for (final label in _dockSurfaces)
        label: tester.element(find.descendant(of: find.byKey(ValueKey(label)), matching: find.byType(BackdropFilter))),
    };
    final field = tester.element(find.byType(TextField));
    const draft = TextEditingValue(text: 'live draft', selection: TextSelection(baseOffset: 2, extentOffset: 7));
    states['goal']!.controller.value = draft;
    await tester.pump();

    void checkIdentity() {
      for (final entry in states.entries) {
        expect(tester.state<_GlassCardState>(find.byKey(ValueKey('state-${entry.key}'))), same(entry.value));
      }
      for (final entry in filters.entries) {
        expect(
          tester.element(find.descendant(of: find.byKey(ValueKey(entry.key)), matching: find.byType(BackdropFilter))),
          same(entry.value),
        );
      }
      expect(tester.element(find.byType(TextField)), same(field));
      expect(states['goal']!.controller.value, draft);
    }

    Future<void> checkMotion() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      _expectDockSampling(tester, enabled: false);
      final before = Map<String, int>.of(builds);
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 30));
        _expectDockSampling(tester, enabled: false);
        expect(builds, before, reason: 'geometry-only ticks do not rebuild glass');
        checkIdentity();
      }
      // The completion tick itself restores sampling; no unrelated rebuild is needed.
      await tester.pump(const Duration(milliseconds: 400));
      _expectDockSampling(tester, enabled: true);
      checkIdentity();
      expect(tester.takeException(), isNull);
    }

    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('glass-strip'))));
    await checkMotion();
    expect(_deckHeight(tester), 3 * _bar);
    await tester.tap(find.byKey(const ValueKey('dock-fold')));
    await checkMotion();
    expect(_deckHeight(tester), 2 * DockStackMetrics.peek + _bar);

    // A held fractional drag has no running controller, but is not a settled card.
    final drag = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('glass-strip'))));
    await drag.moveBy(const Offset(0, 20));
    await drag.moveBy(const Offset(0, 12));
    await tester.pump();
    final render = tester.allRenderObjects.whereType<RenderDockStack>().toSet().single;
    expect(render.turn, greaterThan(0));
    expect(render.turn, lessThan(1));
    _expectDockSampling(tester, enabled: false);
    await tester.pump(const Duration(milliseconds: 500));
    _expectDockSampling(tester, enabled: false);
    checkIdentity();
    await drag.up();
    await checkMotion();
    expect(render.turn, render.turn.roundToDouble());
  });

  testWidgets('dock never overrides an ancestor suspension, including at stable endpoints', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_glassDeck(backdropEnabled: false));
    await pumpFrames(tester);
    _expectDockSampling(tester, enabled: false);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('glass-strip'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    _expectDockSampling(tester, enabled: false);
    // The ancestor can resume while the deck is still moving; it must stay suspended.
    await tester.pumpWidget(_glassDeck());
    _expectDockSampling(tester, enabled: false);
    await tester.pump(const Duration(milliseconds: 400));
    _expectDockSampling(tester, enabled: true);
    await tester.pumpWidget(_glassDeck(backdropEnabled: false));
    _expectDockSampling(tester, enabled: false);
    await tester.tap(find.byKey(const ValueKey('dock-fold')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    _expectDockSampling(tester, enabled: false);
    await tester.pump(const Duration(milliseconds: 400));
    _expectDockSampling(tester, enabled: false);
    await tester.pumpWidget(_glassDeck());
    _expectDockSampling(tester, enabled: true);
  });

  testWidgets('reduced motion lands on sampling endpoints without a later animation tick', (tester) async {
    usePhoneView(tester);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_glassDeck());
    await pumpFrames(tester);
    _expectDockSampling(tester, enabled: true);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('glass-strip'))));
    await tester.pump();
    _expectDockSampling(tester, enabled: true);
    expect(_deckHeight(tester), 3 * _bar);
    await tester.tap(find.byKey(const ValueKey('dock-fold')));
    await tester.pump();
    _expectDockSampling(tester, enabled: true);
    expect(_deckHeight(tester), 2 * DockStackMetrics.peek + _bar);
  });

  testWidgets('solid cards still declare compositing for the deck opacity layers', (tester) async {
    usePhoneView(tester);
    final base = buildLightTheme(glassBlur: false);
    final surfaces = base.extension<DshSurfaces>()!;
    final solidTheme = base.copyWith(
      extensions: [
        ...base.extensions.values,
        surfaces.copyWith(chrome: surfaces.chrome.copyWith(shadows: const [])),
      ],
    );
    await tester.pumpWidget(
      testApp(
        Theme(
          data: solidTheme,
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: DockStack(cards: const [_Card('todo'), _Card('goal'), _Card('strip')]),
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester);
    expect(find.byType(BackdropFilter), findsNothing);
    final deck = tester.allRenderObjects.whereType<RenderDockStack>().toSet().single;
    final children = <RenderObject>[];
    deck.visitChildren(children.add);
    expect(children.every((child) => !child.needsCompositing), isTrue, reason: 'no descendant supplies compositing');
    expect(
      children.any((child) {
        final data = child.parentData! as DockStackParentData;
        return data.depth != null && data.opacity > 0 && data.opacity < 1;
      }),
      isTrue,
      reason: 'the folded deck actually needs to push an opacity layer',
    );
    expect(deck.needsCompositing, isTrue, reason: 'its clips and transforms must also apply to pushOpacity layers');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the fold moves, it does not jump', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck(const [_Card('todo'), _Card('goal'), _Card('strip')]));
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('strip')));
    final heights = <double>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      heights.add(_deckHeight(tester));
    }
    expect(heights.first, lessThan(3 * _bar));
    for (var i = 1; i < heights.length; i++) {
      expect(heights[i], greaterThanOrEqualTo(heights[i - 1]));
    }
    await pumpFrames(tester);
    expect(_deckHeight(tester), 3 * _bar);
  });

  testWidgets('a swipe on the folded deck brings another card to the front, and back', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck(const [_Card('todo'), _Card('goal'), _Card('strip')]));
    await pumpFrames(tester);
    double top(String key) => tester.getRect(find.byKey(ValueKey(key))).top;
    final frontTop = top('strip');

    // Down: the next one behind comes forward, the front one goes to the back.
    await tester.drag(find.byKey(const ValueKey('strip')), const Offset(0, 60));
    await pumpFrames(tester);
    expect(top('goal'), frontTop);
    expect(top('todo'), frontTop - DockStackMetrics.peek);
    expect(top('strip'), frontTop - 2 * DockStackMetrics.peek);
    // Drawn full size in front, smaller behind.
    expect(
      tester.getRect(find.byKey(const ValueKey('goal'))).width,
      greaterThan(tester.getRect(find.byKey(const ValueKey('todo'))).width),
    );
    // Still folded: a swipe never spreads it.
    expect(_deckHeight(tester), 2 * DockStackMetrics.peek + _bar);

    // A short slow drag (past the touch slop, so not a tap) changes nothing.
    await tester.timedDrag(find.byKey(const ValueKey('goal')), const Offset(0, 26), const Duration(milliseconds: 400));
    await pumpFrames(tester);
    expect(top('goal'), frontTop);

    // Up: back the way it came.
    await tester.drag(find.byKey(const ValueKey('goal')), const Offset(0, -60));
    await pumpFrames(tester);
    expect(top('strip'), frontTop);
    expect(top('goal'), frontTop - DockStackMetrics.peek);
  });

  testWidgets('a card coming or going puts the lowest one in front again', (tester) async {
    usePhoneView(tester);
    final strip = ValueNotifier(true);
    addTearDown(strip.dispose);
    await tester.pumpWidget(
      _deck([
        const _Card('todo'),
        const _Card('goal'),
        ValueListenableBuilder<bool>(
          valueListenable: strip,
          builder: (context, on, _) => on ? const _Card('strip') : const SizedBox(width: double.infinity),
        ),
      ]),
    );
    await pumpFrames(tester);
    await tester.drag(find.byKey(const ValueKey('strip')), const Offset(0, 60));
    await pumpFrames(tester);
    final goalFront = tester.getRect(find.byKey(const ValueKey('goal'))).top;
    strip.value = false;
    await pumpFrames(tester);
    // The goal bar is the lowest one now, and in front (turned once more, the todo bar would be).
    expect(_deckHeight(tester), DockStackMetrics.peek + _bar);
    expect(tester.getRect(find.byKey(const ValueKey('goal'))).top, goalFront);
    expect(
      tester.getRect(find.byKey(const ValueKey('goal'))).top - tester.getRect(find.byKey(const ValueKey('todo'))).top,
      DockStackMetrics.peek,
    );
  });

  testWidgets('folding keeps the cards mounted: a bar rising in is not started over', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck(const [_Card('todo'), _Rising()]));
    // A deck once the rising bar has height: the fold must not restart it.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(_Rising.mounts, 1);
    expect(_deckHeight(tester), DockStackMetrics.peek + _bar);
  });

  testWidgets('one bar is never a deck', (tester) async {
    usePhoneView(tester);
    var taps = 0;
    await tester.pumpWidget(
      _deck([const SizedBox(width: double.infinity), _Card('strip', onTap: () => taps++), const SizedBox.shrink()]),
    );
    await pumpFrames(tester);
    expect(_deckHeight(tester), _bar);
    await tester.tap(find.byKey(const ValueKey('strip')));
    await tester.pump();
    expect(taps, 1);
    expect(find.byKey(const ValueKey('dock-fold')).hitTestable(), findsNothing);
  });

  testWidgets('a card regains the full width when its accessory disappears', (tester) async {
    usePhoneView(tester);
    const cards = [_Card('todo')];
    await tester.pumpWidget(_deck(cards, accessory: const SizedBox(width: 60, height: DockMetrics.height)));
    await pumpFrames(tester);
    final width = tester.getSize(find.byType(DockStack)).width;
    expect(tester.getSize(find.byKey(const ValueKey('todo'))).width, width - 60 - DockStackMetrics.accessoryGap);

    await tester.pumpWidget(_deck(cards));
    await pumpFrames(tester);
    expect(tester.getSize(find.byKey(const ValueKey('todo'))).width, width);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the accessory sits right of the front card and answers on the folded deck', (tester) async {
    usePhoneView(tester);
    var off = 0;
    await tester.pumpWidget(
      _deck(
        const [_Card('goal'), _Card('strip')],
        accessory: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => off++,
          child: const SizedBox(key: ValueKey('chip'), width: 60, height: DockMetrics.height),
        ),
      ),
    );
    await pumpFrames(tester);
    final front = tester.getRect(find.byKey(const ValueKey('strip')));
    final chip = tester.getRect(find.byKey(const ValueKey('chip')));
    final goal = tester.getRect(find.byKey(const ValueKey('goal')));
    expect(chip.top, front.top);
    expect(chip.left - front.right, DockStackMetrics.accessoryGap);
    expect(chip.right, moreOrLessEquals(goal.right + goal.width * DockStackMetrics.shrink / 2, epsilon: 0.5));
    await tester.tap(find.byKey(const ValueKey('chip')));
    await pumpFrames(tester);
    expect(off, 1);
    // Still folded.
    expect(_deckHeight(tester), DockStackMetrics.peek + _bar);
  });

  testWidgets('the accessory clips while rising but releases its shadow at full height', (tester) async {
    DockSlot.debugUnclipSettledShadow = true;
    addTearDown(() => DockSlot.debugUnclipSettledShadow = false);
    usePhoneView(tester);
    final height = ValueNotifier<double>(12);
    addTearDown(height.dispose);
    await tester.pumpWidget(
      _deck([
        ValueListenableBuilder<double>(
          valueListenable: height,
          builder: (context, h, _) => SizedBox(width: double.infinity, height: h),
        ),
      ], accessory: const SizedBox(key: ValueKey('shadow-accessory'), width: 36, height: 36)),
    );
    await pumpFrames(tester);
    final accessory = tester.renderObject(find.byKey(const ValueKey('shadow-accessory')));
    expect((accessory.parentData! as DockStackParentData).clipHeight, 12);
    height.value = _bar;
    await tester.pump();
    expect((accessory.parentData! as DockStackParentData).clipHeight, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a card growing in at the front slides over the one behind, without a jump', (tester) async {
    usePhoneView(tester);
    final grow = ValueNotifier<double>(0);
    addTearDown(grow.dispose);
    await tester.pumpWidget(
      _deck([
        const _Card('goal'),
        ValueListenableBuilder<double>(
          valueListenable: grow,
          builder: (context, h, _) => h == 0
              ? const SizedBox(width: double.infinity)
              : ClipRect(
                  child: Align(alignment: Alignment.topCenter, heightFactor: h, child: const _Card('strip')),
                ),
        ),
      ]),
    );
    await pumpFrames(tester);
    var last = _deckHeight(tester);
    expect(last, _bar);
    for (var i = 1; i <= 20; i++) {
      grow.value = i / 20;
      await tester.pump();
      final now = _deckHeight(tester);
      expect((now - last).abs(), lessThan(DockStackMetrics.peek), reason: 'step $i');
      last = now;
    }
    expect(last, DockStackMetrics.peek + _bar);
  });
}
