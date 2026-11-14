import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/remote/network_details_sheet.dart';
import 'package:dsh_app/ui/theme/theme.dart' show AppBackdrop, GlassBackdropScope;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

const _host = HostRef.relay('route-fixture');

class _Lease {
  _Lease(this.allowed);
  final bool Function() allowed;
  bool released = false;
}

class _Chat extends FakeChatController {
  _Chat(String id)
    : super(id, ChatState(loading: false, items: [user(1, 'route fixture'), assistant(2, 'stable reply')]));

  final leases = <_Lease>[];

  @override
  VoidCallback beginInteraction(bool Function() allowed) {
    final lease = _Lease(allowed);
    leases.add(lease);
    return () {
      expect(lease.released, isFalse, reason: 'each acquired interaction is released once');
      lease.released = true;
    };
  }

  void retitle() => emit(ChatState(items: state.items, title: 'still live', loading: false));
}

Future<Map<String, _Chat>> _pump(WidgetTester tester) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(session: 's1');
  final chats = <String, _Chat>{};
  final overrides = harness.overrides;
  await tester.pumpWidget(
    testApp(
      const ChatScreen(),
      overrides: [
        ...overrides.take(overrides.length - 1),
        chatProvider.overrideWith2((id) => chats[id] = _Chat(id)),
        // The generic harness leaves skills/list unfaked. Its HTTP failure
        // retries rebuild slashCommandsProvider independently of navigation.
        skillsProvider.overrideWith((ref, id) async => []),
        hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(const HostLinkStatus(HostLinkPhase.connected))),
        hostNameProvider.overrideWith((ref, host) => 'Test workstation'),
      ],
    ),
  );
  await pumpFrames(tester, 10);
  expect(find.byType(ChatList), findsOneWidget);
  expect(find.text('route fixture'), findsOneWidget);
  expect(chats['s1']!.leases.single.allowed(), isTrue);
  return chats;
}

Future<Map<String, int>> _builds(Future<void> Function() action) async {
  final counts = <String, int>{};
  final previous = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    previous?.call(element, builtOnce);
    if (element.widget is ChatScreen || element.widget is ChatList) {
      counts.update(element.widget.runtimeType.toString(), (count) => count + 1, ifAbsent: () => 1);
    }
  };
  try {
    await action();
  } finally {
    debugOnRebuildDirtyWidget = previous;
  }
  return counts;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppBackdrop.snapshotCaching = true;
  });
  tearDown(() => AppBackdrop.snapshotCaching = false);

  testWidgets('network sheet push and pop do not rebuild the underlying chat page or list', (tester) async {
    final chats = await _pump(tester);
    final context = tester.element(find.byType(ChatScreen));
    final navigator = Navigator.of(context);
    for (var cycle = 0; cycle < 3; cycle++) {
      final opening = await _builds(() async {
        unawaited(showRemoteNetworkDetails(context, _host));
        await tester.pump();
      });
      expect(opening, isEmpty, reason: 'push $cycle must not rebuild the underlying page');
      expect(find.byType(RemoteNetworkDetailsSheet), findsOneWidget);
      expect(
        tester.widgetList<GlassBackdropScope>(find.byType(GlassBackdropScope)).first.enabled,
        isFalse,
        reason: 'covered chat suspends backdrop scope while a modal sheet is open',
      );
      expect(await _builds(() => pumpFrames(tester, 6)), isEmpty);
      final closing = await _builds(() async {
        navigator.pop();
        await tester.pump();
      });
      expect(closing, isEmpty, reason: 'pop $cycle must not rebuild the underlying page');
      expect(await _builds(() => pumpFrames(tester, 6)), isEmpty);
      expect(find.byType(RemoteNetworkDetailsSheet), findsNothing);
      expect(
        tester.widgetList<GlassBackdropScope>(find.byType(GlassBackdropScope)).first.enabled,
        isTrue,
        reason: 'chat scope resumes once the sheet is popped',
      );
    }
    // Positive control: the same instrumentation must see real state changes.
    final updated = await _builds(() async {
      chats['s1']!.retitle();
      await tester.pump();
    });
    expect(updated['ChatScreen'], greaterThan(0));
    expect(updated['ChatList'], greaterThan(0));
    expect(find.text('still live'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('covering sheets revoke interaction before the next frame and restore only the current session', (
    tester,
  ) async {
    final chats = await _pump(tester);
    final context = tester.element(find.byType(ChatScreen));
    final navigator = Navigator.of(context);
    final container = ProviderScope.containerOf(context);
    final a = chats['s1']!;
    final lease = a.leases.single;

    unawaited(showRemoteNetworkDetails(context, _host));
    expect(lease.allowed(), isFalse, reason: 'push must deny activation before observer delivery');
    await tester.pump();
    expect(lease.released, isTrue);
    await pumpFrames(tester);
    expect(a.leases, hasLength(1));

    unawaited(showRemoteNetworkDetails(context, _host));
    await pumpFrames(tester);
    navigator.pop();
    await pumpFrames(tester);
    expect(find.byType(RemoteNetworkDetailsSheet), findsOneWidget);
    expect(a.leases, hasLength(1), reason: 'popping the top sheet leaves the chat covered');

    container.read(currentSessionProvider.notifier).select('s2');
    await pumpFrames(tester);
    final b = chats['s2']!;
    expect(b.leases, isEmpty, reason: 'selection under a sheet must stay passive');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpFrames(tester);
    expect(b.leases, isEmpty, reason: 'resume must not activate a covered conversation');

    navigator.pop();
    await tester.pump();
    expect(b.leases.single.allowed(), isTrue, reason: 'the newly current session regains interaction');
    expect(lease.allowed(), isFalse, reason: 'the previous session stays unauthorized');
    await pumpFrames(tester);
    expect(b.leases, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(b.leases.single.released, isTrue);
    expect(b.leases.single.allowed(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-frame sheet push and pop do not duplicate interaction leases', (tester) async {
    final chats = await _pump(tester);
    final context = tester.element(find.byType(ChatScreen));
    final chat = chats['s1']!;
    final lease = chat.leases.single;
    unawaited(showRemoteNetworkDetails(context, _host));
    expect(lease.allowed(), isFalse);
    Navigator.of(context).pop();
    await pumpFrames(tester);
    expect(chat.leases, hasLength(1));
    expect(lease.released, isFalse);
    expect(lease.allowed(), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(lease.released, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('upright IME keyboard animation does not rebuild ChatScreen or ChatList', (tester) async {
    addTearDown(tester.view.resetViewInsets);
    await _pump(tester);
    final dpr = tester.view.devicePixelRatio;
    final rising = await _builds(() async {
      for (var step = 1; step <= 8; step++) {
        tester.view.viewInsets = FakeViewPadding(bottom: 32.0 * step * dpr);
        await tester.pump(const Duration(milliseconds: 16));
      }
    });
    expect(rising, isEmpty, reason: 'upright IME rise only rebuilds Composer, never ChatScreen or ChatList');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
