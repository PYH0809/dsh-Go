import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _ContentPainter extends CustomPainter {
  _ContentPainter(this.frame, this.paints);

  final int frame;
  final List<int> paints;

  @override
  void paint(Canvas canvas, Size size) {
    paints.add(frame);
    canvas.drawRect(Offset.zero & size, Paint()..color = frame.isEven ? Colors.blue : Colors.red);
  }

  @override
  bool shouldRepaint(_ContentPainter old) => old.frame != frame;
}

final _shadowBoundary = find.descendant(of: find.byType(GlassSurface), matching: find.byType(RepaintBoundary));
final _shadowSnapshot = find.descendant(of: find.byType(GlassSurface), matching: find.byType(SnapshotWidget));
const _captureKey = ValueKey('capture');

List<ui.Image> _watchImages() {
  final images = <ui.Image>[];
  final previous = ui.Image.onCreate;
  ui.Image.onCreate = (image) {
    images.add(image);
    previous?.call(image);
  };
  addTearDown(() => ui.Image.onCreate = previous);
  return images;
}

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

void main() {
  setUp(() => GlassSurface.shadowCaching = true);
  tearDown(() => GlassSurface.shadowCaching = false);

  for (final tier in [GlassTier.sheet, GlassTier.chrome]) {
    testWidgets('$tier content and fill repaint without repainting its shadow', (tester) async {
      final oldDisableShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        final frame = ValueNotifier(0);
        addTearDown(frame.dispose);
        final paints = <int>[];
        final images = _watchImages();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLightTheme(),
            home: Center(
              child: ValueListenableBuilder<int>(
                valueListenable: frame,
                builder: (context, value, _) => GlassSurface(
                  tier: tier,
                  settled: value / 10,
                  child: SizedBox(width: 120, height: 140, child: CustomPaint(painter: _ContentPainter(value, paints))),
                ),
              ),
            ),
          ),
        );
        expect(_shadowBoundary, findsOneWidget);
        final boundary = tester.renderObject<RenderRepaintBoundary>(_shadowBoundary);
        final picture = (boundary.debugLayer! as OffsetLayer).firstChild;
        expect(picture, isA<PictureLayer>());
        final snapshot = tester.widget<SnapshotWidget>(_shadowSnapshot);
        expect(snapshot.controller.allowSnapshotting, isTrue);
        expect(snapshot.autoresize, isTrue);
        expect((snapshot.child! as CustomPaint).child, isNull, reason: 'only the shadow is snapshotted');
        expect(images, hasLength(1));
        final image = images.single;
        for (var i = 1; i <= 10; i++) {
          frame.value = i;
          await tester.pump();
          expect(paints.last, i, reason: 'the foreground really repainted');
          expect(images, hasLength(1), reason: 'content/fill updates reuse the same shadow texture');
          expect(image.debugDisposed, isFalse);
          expect(
            (boundary.debugLayer! as OffsetLayer).firstChild,
            same(picture),
            reason: 'the shadow retained its recorded picture at frame $i',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(image.debugDisposed, isTrue, reason: 'removing the surface releases its texture');
        expect(tester.takeException(), isNull);
      } finally {
        debugDisableShadows = oldDisableShadows;
      }
    });

    testWidgets('$tier shadow paint bounds include its overflow and follow content size', (tester) async {
      final oldDisableShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        final size = ValueNotifier(const Size(120, 140));
        addTearDown(size.dispose);
        final images = _watchImages();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLightTheme(),
            home: Center(
              child: ValueListenableBuilder<Size>(
                valueListenable: size,
                builder: (context, value, _) => GlassSurface(
                  tier: tier,
                  child: SizedBox.fromSize(size: value),
                ),
              ),
            ),
          ),
        );
        // Original outside clip: 2 * blurRadius + offset.distance + 2.
        final extent = tier == GlassTier.sheet ? 74.0 : 58.0;
        expect(images, hasLength(1));
        final original = images.single;
        for (final next in [const Size(120, 140), const Size(170, 90)]) {
          size.value = next;
          await tester.pump();
          final glass = tester.getRect(find.byType(GlassSurface));
          expect(glass.size, next, reason: 'the shadow must not affect layout');
          expect(tester.getRect(_shadowBoundary), glass.inflate(extent));
          final boundary = tester.renderObject<RenderRepaintBoundary>(_shadowBoundary);
          expect(boundary.paintBounds.size, Size(next.width + 2 * extent, next.height + 2 * extent));
          final dpr = MediaQuery.devicePixelRatioOf(tester.element(_shadowBoundary));
          expect(images.last.width, ((next.width + 2 * extent) * dpr).ceil());
          expect(images.last.height, ((next.height + 2 * extent) * dpr).ceil());
        }
        expect(images, hasLength(2), reason: 'a size change creates one replacement texture');
        expect(original.debugDisposed, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        debugDisableShadows = oldDisableShadows;
      }
    });

    testWidgets('$tier refreshes its texture for theme, shape, direction and DPR changes', (tester) async {
      final oldDisableShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        final images = _watchImages();
        var theme = buildLightTheme();
        BorderRadiusGeometry radius = const BorderRadius.all(Radius.circular(28));
        var direction = TextDirection.ltr;
        var dpr = 1.0;
        Widget scene() => MaterialApp(
          theme: theme,
          themeAnimationDuration: Duration.zero,
          home: MediaQuery(
            data: MediaQueryData(devicePixelRatio: dpr),
            child: Directionality(
              textDirection: direction,
              child: Center(
                child: GlassSurface(tier: tier, borderRadius: radius, child: const SizedBox(width: 120, height: 140)),
              ),
            ),
          ),
        );
        await tester.pumpWidget(scene());
        expect(images, hasLength(1));
        final controller = tester.widget<SnapshotWidget>(_shadowSnapshot).controller;
        var current = images.single;
        for (final change in <VoidCallback>[
          () => theme = buildDarkTheme(),
          () => radius = const BorderRadiusDirectional.only(topStart: Radius.circular(28), bottomEnd: Radius.circular(6)),
          () => direction = TextDirection.rtl,
          () => dpr = 2,
        ]) {
          final before = images.length;
          change();
          await tester.pumpWidget(scene());
          expect(images, hasLength(before + 1));
          expect(current.debugDisposed, isTrue, reason: 'invalidating the texture releases the old image');
          current = images.last;
          expect(tester.widget<SnapshotWidget>(_shadowSnapshot).controller, same(controller));
          final size = tester.getSize(_shadowBoundary);
          expect(current.width, (size.width * dpr).ceil());
          expect(current.height, (size.height * dpr).ceil());
        }
        final before = images.length;
        await tester.pumpWidget(scene());
        expect(images, hasLength(before), reason: 'an equivalent painter must keep its texture');
        await tester.pumpWidget(const SizedBox.shrink());
        expect(current.debugDisposed, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        debugDisableShadows = oldDisableShadows;
      }
    });
  }
  for (final tier in [GlassTier.sheet, GlassTier.chrome]) {
    for (final shape in ['rounded', 'stadium', 'circle']) {
      testWidgets('$tier cached $shape shadow matches uncached pixels outside the shape', (tester) async {
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
          Future<Uint8List> render(GlassTier tier) async {
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
            return _pixels(tester);
          }

          // Small circular buttons draw directly without allocating per-button
          // shadow textures; superellipse and stadium panels cache their shadow.
          final uncached = await render(GlassTier.card);
          expect(_shadowBoundary, findsNothing);
          final cached = await render(tier);
          expect(_shadowBoundary, shape == 'circle' ? findsNothing : findsOneWidget);
          expect(cached, orderedEquals(uncached), reason: 'cache bounds must not crop or move the original shadow');
          int alpha(int x, int y) => cached[(y * 360 + x) * 4 + 3];
          expect(alpha(180, 255), greaterThan(0), reason: 'soft shadow still paints below the 250px shape bottom');
          expect(alpha(180, 180), 0, reason: 'the shadow never paints through the shape interior');
          expect(alpha(0, 0), 0);
          expect(tester.takeException(), isNull);
        } finally {
          debugDisableShadows = oldDisableShadows;
        }
      });
    }
  }
}
