import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/question_card.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';
import 'turn_settle_test.dart' show state;

Future<Finder> _openQuestion(
  WidgetTester tester, {
  required bool multi,
  required int options,
  required bool fluid,
}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final request = UserQuestionRequest(
    eventId: 'keyboard-question',
    sessionId: 's1',
    questions: [
      UserQuestion(
        id: 'choice',
        question: '请选择下一步要执行的检查',
        multiSelect: multi,
        options: [for (var i = 1; i <= options; i++) QuestionOption('检查项目 $i', '合成选项说明')],
      ),
    ],
  );
  final harness = ChatHarness(
    session: 's1',
    states: {
      's1': ChatState(loading: false, running: true, questions: [request]),
    },
  );
  await tester.pumpWidget(
    testApp(
      AppMotionScope(fluid: fluid, child: const ChatScreen()),
      overrides: harness.overrides,
    ),
  );
  await pumpFrames(tester);
  final card = find.byType(QuestionCard);
  final other = find.descendant(of: card, matching: find.text('其他回答'));
  expect(other.hitTestable(), findsOneWidget);
  await tester.tap(other);
  await pumpFrames(tester);
  final field = find.descendant(of: card, matching: find.byType(TextField));
  expect(field.hitTestable(), findsOneWidget);
  await tester.tap(field);
  await tester.enterText(field, '可见的自定义回答');
  await pumpFrames(tester, 2);
  return field;
}

void _expectVisibleCaret(WidgetTester tester, Finder field) {
  final editable = tester.state<EditableTextState>(find.descendant(of: field, matching: find.byType(EditableText)));
  final render = editable.renderEditable;
  final caret = render
      .getLocalRectForCaret(editable.widget.controller.selection.extent)
      .shift(render.localToGlobal(Offset.zero));
  final list = tester.getRect(find.byType(ChatList));
  final header = tester.getRect(find.byType(ChatHeader));
  final bottomInset = tester.widget<ChatList>(find.byType(ChatList)).bottomInset;
  expect(editable.widget.focusNode.hasFocus, isTrue);
  expect(tester.testTextInput.isVisible, isTrue);
  expect(caret.top, greaterThanOrEqualTo(header.bottom));
  // The accessory strip above Composer also covers chat: use the list's
  // actual clip, not just the smaller Composer widget's rectangle.
  expect(caret.bottom, lessThanOrEqualTo(list.bottom - bottomInset));
  expect(tester.takeException(), isNull);
}

Future<void> _keyboard(WidgetTester tester, double height) async {
  tester.view.padding = const FakeViewPadding(top: 48);
  tester.view.viewInsets = FakeViewPadding(bottom: height * tester.view.devicePixelRatio);
  // Like EditableText's own reveal, the list measures after layout and the
  // following frame paints the corrected position.
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  setUpAll(loadTestFonts);
  for (final fluid in [false, true]) {
    final tier = fluid ? 'fluid' : 'standard';
    for (final multi in [false, true]) {
      for (final options in [3, 5]) {
        testWidgets('$tier $options-option question keeps custom caret visible, multi=$multi', (tester) async {
          final field = await _openQuestion(tester, multi: multi, options: options, fluid: fluid);
          for (final height in [80.0, 160.0, 240.0, 320.0]) {
            await _keyboard(tester, height);
            _expectVisibleCaret(tester, field);
          }
          const text = '第一行自定义回答\n第二行检查说明\n第三行检查说明\n第四行继续输入\n第五行光标仍可见';
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
              composing: TextRange(start: text.length - 3, end: text.length),
            ),
          );
          await pumpFrames(tester, 4);
          _expectVisibleCaret(tester, field);
          final editor = tester.widget<TextField>(field).controller!;
          expect(editor.text, text);
          expect(editor.value.composing, TextRange(start: text.length - 3, end: text.length));
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(text: text, selection: TextSelection.collapsed(offset: 0)),
          );
          await pumpFrames(tester, 4);
          _expectVisibleCaret(tester, field);
          for (final height in [240.0, 160.0, 80.0, 0.0]) {
            await _keyboard(tester, height);
            _expectVisibleCaret(tester, field);
          }
          expect(editor.text, text);
        });
      }
    }

    testWidgets('$tier composer focus preserves history while the viewport resizes', (tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final harness = ChatHarness(session: 's1', states: {'s1': state(longHistory: true)});
      await tester.pumpWidget(
        testApp(
          AppMotionScope(fluid: fluid, child: const ChatScreen()),
          overrides: harness.overrides,
        ),
      );
      await pumpFrames(tester, 40);
      final history = find.byKey(const ValueKey('u0'));
      final viewport = tester.getRect(find.byType(ChatList));
      for (var drag = 0; drag < 12; drag++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
        await pumpFrames(tester, 35);
        if (history.evaluate().isNotEmpty && tester.getBottomRight(history).dy > viewport.bottom + 100) break;
      }
      expect(tester.getTopLeft(history).dy, lessThan(100));
      expect(tester.getBottomRight(history).dy, greaterThan(viewport.bottom + 100));
      final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
      await tester.showKeyboard(field);
      await pumpFrames(tester, 2);
      final before = tester.getTopLeft(history).dy;
      for (final height in [80.0, 160.0, 240.0, 320.0, 160.0, 0.0]) {
        await _keyboard(tester, height);
        expect(tester.getTopLeft(history).dy, closeTo(before, 1));
        expect(tester.widget<Composer>(find.byType(Composer)).focusNode!.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('an inline reveal does not take the list from a resting finger', (tester) async {
    final field = await _openQuestion(tester, multi: false, options: 5, fluid: false);
    await _keyboard(tester, 240);
    await pumpFrames(tester, 3);
    _expectVisibleCaret(tester, field);
    // Leave the bottom before testing the reader's anchor. A pinned list
    // intentionally follows the bottom edge as its viewport resizes.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 60));
    await pumpFrames(tester, 3);
    await tester.tap(field);
    await pumpFrames(tester, 3);
    _expectVisibleCaret(tester, field);
    final option = find.text('检查项目 5');
    final before = tester.getRect(option);
    expect(before.top, greaterThan(tester.getBottomRight(find.byType(ChatHeader)).dy));
    expect(before.bottom, lessThan(400));
    final position = tester
        .state<ScrollableState>(find.descendant(of: find.byType(ChatList), matching: find.byType(Scrollable)).first)
        .position;
    expect(position.extentAfter, greaterThan(24));
    final gesture = await tester.startGesture(const Offset(220, 200));
    await _keyboard(tester, 320);
    expect(tester.getRect(option).top, closeTo(before.top, 1));
    // The first move wins the drag arena; subsequent movement scrolls.
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    final pixels = position.pixels;
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(position.pixels, lessThan(pixels - 30), reason: 'The same gesture still controls the list.');
    await gesture.up();
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving a focused question during keyboard resize does not act on the next page', (tester) async {
    await _openQuestion(tester, multi: false, options: 5, fluid: false);
    tester.view.viewInsets = const FakeViewPadding(bottom: 640);
    await tester.pumpWidget(
      KeyedSubtree(
        key: const ValueKey('next-page'),
        child: testApp(const Scaffold(body: Text('已离开询问'))),
      ),
    );
    await pumpFrames(tester);
    expect(find.text('已离开询问'), findsOneWidget);
    expect(find.byType(QuestionCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping SelectableText inside an expanded tool detail does not jump the centered chat list', (
    tester,
  ) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final items = <ChatItem>[
      user(1, '排查卡顿'),
      for (var i = 0; i < 6; i++)
        tool('c$i', 'read', {'file_path': '/Users/yehan_pan/dsh-Go/app/lib/ui/chat/chat_screen_$i.dart'}, result: '1: a\n2: b'),
      tool(
        'edit1',
        'edit',
        {'file_path': '/Users/yehan_pan/dsh-Go/app/lib/ui/chat/chat_screen.dart', 'old_string': 'a', 'new_string': 'b'},
        result: 'updated',
      ),
      for (var i = 0; i < 8; i++)
        assistant(11 + i, '后续流式段落 $i：${'这是一段足够撑开视口高度的正文内容。' * 4}', streaming: i == 7),
    ];
    final harness = ChatHarness(
      session: 's1',
      states: {'s1': ChatState(loading: false, running: true, items: items)},
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester, 6);

    final scrollable = find.descendant(of: find.byType(ChatList), matching: find.byType(Scrollable)).first;
    final position = tester.state<ScrollableState>(scrollable).position;

    // Scroll up to inspect the earlier tool group / edit tool, just like in the user's recording!
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 520));
    await pumpFrames(tester, 4);
    expect(position.extentAfter, greaterThan(200));

    // Expand the tool group, then expand the edit ToolRow to expose its SelectableText file path!
    await tester.tap(find.byType(ToolGroup).first);
    await pumpFrames(tester, 8);
    final editRow = find.widgetWithText(ToolRow, '编辑');
    await tester.tap(editRow);
    await pumpFrames(tester, 8);

    final selectable = find.descendant(of: find.byType(ToolDetail), matching: find.byType(SelectableText)).first;
    expect(selectable, findsOneWidget);
    final pixelsBeforeTap = position.pixels;

    // Tap the SelectableText path inside ToolDetail: list MUST stay rock-steady!
    await tester.tap(selectable);
    await pumpFrames(tester, 6);
    expect(position.pixels, closeTo(pixelsBeforeTap, 0.5), reason: 'tapping SelectableText must not jump the chat list');
    expect(tester.takeException(), isNull);
  });
}
