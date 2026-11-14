import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/ui/notify/chat_alert_host.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _alert = ChatAlert(
  host: HostRef.local,
  sessionId: 'test',
  kind: AlertKind.done,
  key: 'test',
  title: '',
  text: '',
);

class _Alerts extends ChatAlertsController {
  @override
  ChatAlert? build() => null;

  void show() => state = _alert;

  @override
  void dismissBanner(ChatAlert alert) => state = null;
}

class _Stripes extends CustomPainter {
  const _Stripes();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.white, BlendMode.src);
    final paint = Paint()..color = Colors.black;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 4, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => false;
}

Future<int> _backgroundContrast(WidgetTester tester) async {
  final rect = tester.getRect(find.byType(AlertBanner));
  final view = tester.binding.renderViews.first;
  late ui.Image image;
  late ByteData data;
  await tester.runAsync(() async {
    image = await (view.debugLayer! as OffsetLayer).toImage(view.paintBounds);
    data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  });
  // Empty title/body leave the centre clear: only the glass and backdrop are
  // painted here. A real blur removes the 4px black/white stripe contrast.
  final y = (rect.bottom - 8).floor();
  final values = [for (var x = 160; x < 224; x++) data.getUint8((y * image.width + x) * 4)];
  image.dispose();
  values.sort();
  return values.last - values.first;
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('banner keeps its backdrop blurred throughout transitions: $brightness', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 240);
      tester.view.viewPadding = const FakeViewPadding(top: 48);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatAlertsProvider.overrideWith(_Alerts.new)],
          child: MaterialApp(
            theme: brightness == Brightness.light ? buildLightTheme() : buildDarkTheme(),
            home: const Stack(
              children: [
                Positioned.fill(child: CustomPaint(painter: _Stripes())),
                AlertBannerLayer(),
              ],
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(AlertBannerLayer)));
      final alerts = container.read(chatAlertsProvider.notifier) as _Alerts;
      alerts.show();
      await tester.pump();
      expect(
        tester.getRect(find.byType(AlertBanner)).bottom,
        closeTo(0, 0.01),
        reason: 'the card must start above the screen, including the safe-area inset',
      );
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        await _backgroundContrast(tester),
        lessThan(12),
        reason: 'entering glass must not expose sharp background',
      );
      await tester.pumpAndSettle();
      expect(await _backgroundContrast(tester), lessThan(12), reason: 'settled glass must blur its entire surface');
      alerts.dismissBanner(_alert);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(await _backgroundContrast(tester), lessThan(12), reason: 'exiting glass must not expose sharp background');
      await tester.pumpAndSettle();
      expect(find.byType(AlertBanner), findsNothing);
    });
  }
}
