import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StatefulContent extends StatefulWidget {
  const _StatefulContent();

  @override
  State<_StatefulContent> createState() => _StatefulContentState();
}

class _StatefulContentState extends State<_StatefulContent> {
  final controller = TextEditingController(text: 'draft');

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(controller: controller);
}

void main() {
  for (final policy in [
    (name: 'global blur off', globalBlur: false, contrast: false, blur: null, settled: null),
    (name: 'high contrast', globalBlur: true, contrast: true, blur: null, settled: null),
    (name: 'surface blur off', globalBlur: true, contrast: false, blur: false, settled: null),
    (name: 'unsettled surface', globalBlur: true, contrast: false, blur: null, settled: 0.0),
  ]) {
    testWidgets('resuming a scope respects ${policy.name}', (tester) async {
      final enabled = ValueNotifier(false);
      addTearDown(enabled.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(glassBlur: policy.globalBlur),
          home: MediaQuery(
            data: MediaQueryData(highContrast: policy.contrast),
            child: ValueListenableBuilder<bool>(
              valueListenable: enabled,
              builder: (context, value, child) => GlassBackdropScope(enabled: value, child: child!),
              child: GlassSurface(
                tier: GlassTier.chrome,
                blur: policy.blur,
                settled: policy.settled,
                child: const SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      );
      for (final value in [true, false, true]) {
        enabled.value = value;
        await tester.pump();
        expect(
          tester.widgetList<BackdropFilter>(find.byType(BackdropFilter)).where((filter) => filter.enabled),
          isEmpty,
        );
      }
    });
  }
  testWidgets('stopping local backdrop sampling preserves the filter and content State', (tester) async {
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (context, value, child) => GlassBackdropScope(enabled: value, child: child!),
            child: const GlassSurface(tier: GlassTier.chrome, child: _StatefulContent()),
          ),
        ),
      ),
    );
    final state = tester.state<_StatefulContentState>(find.byType(_StatefulContent));
    state.controller.selection = const TextSelection(baseOffset: 1, extentOffset: 4);
    final filter = tester.element(find.byType(BackdropFilter));
    for (final value in [false, true, false, true]) {
      enabled.value = value;
      await tester.pump();
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(tester.element(find.byType(BackdropFilter)), same(filter));
      expect(tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled, value);
      expect(tester.state<_StatefulContentState>(find.byType(_StatefulContent)), same(state));
      expect(state.controller.text, 'draft');
      expect(state.controller.selection, const TextSelection(baseOffset: 1, extentOffset: 4));
    }
    expect(tester.takeException(), isNull);
  });
}
