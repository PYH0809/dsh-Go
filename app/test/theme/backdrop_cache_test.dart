import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/common/scroll_edge_fade.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _capture = ValueKey('capture');
final _snapshot = find.descendant(of: find.byType(AppBackdrop), matching: find.byType(SnapshotWidget));

Widget _scene({
  ThemeData? theme,
  bool glow = true,
  Size size = const Size(120, 160),
  double dpr = 1,
  BackdropPicture? picture,
  Widget child = const SizedBox.expand(),
}) => MaterialApp(
  theme: theme ?? buildLightTheme(),
  themeAnimationDuration: Duration.zero,
  home: MediaQuery(
    data: MediaQueryData(devicePixelRatio: dpr),
    child: Center(
      child: RepaintBoundary(
        key: _capture,
        child: SizedBox.fromSize(
          size: size,
          child: AppBackdrop(glow: glow, picture: picture, child: child),
        ),
      ),
    ),
  ),
);

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
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_capture));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
}

ui.Image _solid(Color color) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return picture.toImageSync(4, 4);
  } finally {
    picture.dispose();
  }
}

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

Future<void> _withRealShadows(Future<void> Function() body) async {
  final old = debugDisableShadows;
  debugDisableShadows = false;
  try {
    await body();
  } finally {
    debugDisableShadows = old;
  }
}

void main() {
  testWidgets('a static gradient retains one texture while content and ink stay live', (tester) => _withRealShadows(() async {
    final images = _watchImages();
    final paints = <int>[];
    var taps = 0;
    Widget scene(int frame) => _scene(
      child: InkWell(
        splashFactory: InkRipple.splashFactory,
        onTap: () => taps++,
        child: CustomPaint(painter: _ContentPainter(frame, paints)),
      ),
    );
    await tester.pumpWidget(scene(0));
    expect(_snapshot, findsOneWidget);
    final snapshot = tester.widget<SnapshotWidget>(_snapshot);
    expect(snapshot.controller.allowSnapshotting, isTrue);
    expect(snapshot.autoresize, isTrue);
    expect((snapshot.child! as CustomPaint).child, isNull, reason: 'only the gradient painter is captured');
    expect(find.descendant(of: _snapshot, matching: find.byType(Material)), findsNothing);
    expect(images, hasLength(1));
    final image = images.single;
    for (var frame = 1; frame <= 8; frame++) {
      await tester.pumpWidget(scene(frame));
      expect(paints.last, frame, reason: 'foreground content is not frozen');
      expect(images, hasLength(1));
      expect(image.debugDisposed, isFalse);
    }
    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(images, hasLength(1), reason: 'ink animations must not invalidate the background texture');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(image.debugDisposed, isTrue);
    expect(tester.takeException(), isNull);
  }));

  testWidgets('opaque full-screen routes release covered gradient textures and restore on pop', (tester) => _withRealShadows(() async {
    final images = _watchImages();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const AppBackdrop(child: Text('home-page')),
      ),
    );
    expect(images, hasLength(1));
    final homeImage = images.single;
    expect(homeImage.debugDisposed, isFalse);

    Navigator.of(tester.element(find.text('home-page'))).push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('pushed-page'))),
    );
    await tester.pumpAndSettle();
    expect(homeImage.debugDisposed, isTrue, reason: 'covered route releases its ~18 MiB gradient texture');

    Navigator.of(tester.element(find.text('pushed-page'))).pop();
    await tester.pumpAndSettle();
    expect(images, hasLength(2), reason: 'revealed route recaptures its gradient texture');
    expect(images.last.debugDisposed, isFalse);
    expect(tester.takeException(), isNull);
  }));

  testWidgets('ScrollEdgeFade omits ShaderMaskLayer at rest and fades accurately at non-zero offset', (tester) async {
    final key = GlobalKey();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: Column(
              children: [
                const SizedBox(height: 120),
                SizedBox(
                  width: 100,
                  height: 100,
                  child: ScrollEdgeFade(
                    topExtent: 20,
                    bottomExtent: 20,
                    child: ListView.builder(
                      controller: controller,
                      itemCount: 20,
                      itemExtent: 20,
                      itemBuilder: (_, _) => const ColoredBox(color: Color(0xFFFF0000)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // At top (extentBefore == 0, extentAfter > 0) at canvas y=120:
    Future<Uint8List> capture() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      return (await tester.runAsync(() async {
        final img = await boundary.toImage(pixelRatio: 1);
        try {
          return (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        } finally {
          img.dispose();
        }
      }))!;
    }

    final atTop = await capture();
    expect(atTop[((120 + 2) * 100 + 50) * 4 + 3], 255, reason: 'top edge unmasked when extentBefore == 0');
    expect(atTop[((120 + 99) * 100 + 50) * 4 + 3], lessThan(40), reason: 'bottom edge faded at non-zero y=120 offset');

    controller.jumpTo(100);
    await tester.pumpAndSettle();
    final mid = await capture();
    expect(mid[((120 + 0) * 100 + 50) * 4 + 3], lessThan(30), reason: 'top edge faded at non-zero y=120 offset');
    expect(mid[((120 + 50) * 100 + 50) * 4 + 3], 255, reason: 'middle remains solid');
    expect(mid[((120 + 99) * 100 + 50) * 4 + 3], lessThan(40), reason: 'bottom edge faded at non-zero y=120 offset');
  });

  testWidgets('theme colors, each glow, glow visibility, size and DPR invalidate the gradient', (tester) => _withRealShadows(() async {
    final images = _watchImages();
    var theme = buildLightTheme();
    var glow = true;
    var size = const Size(120, 160);
    var dpr = 1.0;
    DshSurfaces surfaces() => theme.extension<DshSurfaces>()!;
    void replaceSurfaces(DshSurfaces next) {
      theme = theme.copyWith(
        extensions: [
          for (final extension in theme.extensions.values)
            if (extension is! DshSurfaces) extension,
          next,
        ],
      );
    }

    Widget scene() => _scene(theme: theme, glow: glow, size: size, dpr: dpr);
    await tester.pumpWidget(scene());
    expect(images, hasLength(1));
    final controller = tester.widget<SnapshotWidget>(_snapshot).controller;
    var current = images.single;
    for (final change in <VoidCallback>[
      () => theme = buildDarkTheme(),
      () => replaceSurfaces(surfaces().copyWith(backdropTop: Colors.indigo)),
      () => replaceSurfaces(surfaces().copyWith(backdropBottom: Colors.teal)),
      () => replaceSurfaces(surfaces().copyWith(glowPrimary: Colors.orange)),
      () => replaceSurfaces(surfaces().copyWith(glowSecondary: Colors.purple)),
      () => glow = false,
      () => glow = true,
      () => size = const Size(180, 140),
      () => dpr = 2,
    ]) {
      final before = images.length;
      change();
      await tester.pumpWidget(scene());
      expect(images, hasLength(before + 1));
      expect(current.debugDisposed, isTrue);
      current = images.last;
      expect(current.width, (size.width * dpr).ceil());
      expect(current.height, (size.height * dpr).ceil());
      expect(tester.widget<SnapshotWidget>(_snapshot).controller, same(controller));
    }
    final before = images.length;
    await tester.pumpWidget(scene());
    expect(images, hasLength(before), reason: 'equivalent styles keep their image');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(current.debugDisposed, isTrue);
    expect(tester.takeException(), isNull);
  }));

  testWidgets('picture crossfades and fading back to the gradient are never cached', (tester) => _withRealShadows(() async {
    final red = _solid(const Color(0xffff0000));
    final blue = _solid(const Color(0xff0000ff));
    addTearDown(red.dispose);
    addTearDown(blue.dispose);
    final fade = AnimationController(vsync: tester, value: 0);
    addTearDown(fade.dispose);
    final images = _watchImages();
    await tester.pumpWidget(_scene());
    expect(images, hasLength(1));
    final gradientImage = images.single;
    final gradientPixels = await _pixels(tester);
    final beforePicture = images.length;
    await tester.pumpWidget(
      _scene(
        picture: BackdropPicture(image: blue, from: red, fade: fade),
      ),
    );
    expect(_snapshot, findsNothing);
    expect(gradientImage.debugDisposed, isTrue);
    expect(images, hasLength(beforePicture));
    const center = (80 * 120 + 60) * 4;
    for (final t in [0.0, 0.5, 1.0]) {
      final before = images.length;
      fade.value = t;
      await tester.pump();
      expect(images, hasLength(before), reason: 'wallpaper animation must paint directly, not allocate snapshots');
      final pixels = await _pixels(tester);
      expect(pixels[center], closeTo(255 * (1 - t), 1));
      expect(pixels[center + 1], 0);
      expect(pixels[center + 2], closeTo(255 * t, 1));
      expect(pixels[center + 3], 255);
    }

    fade.value = 0;
    await tester.pumpWidget(
      _scene(
        picture: BackdropPicture(image: null, from: blue, fade: fade),
      ),
    );
    expect(_snapshot, findsNothing, reason: 'picture.image == null can still be an active fade');
    final starting = await _pixels(tester);
    expect(starting[center + 2], 255);
    fade.value = 1;
    await tester.pump();
    final ending = await _pixels(tester);
    expect(ending, orderedEquals(gradientPixels));
    final beforeGradient = images.length;
    await tester.pumpWidget(_scene());
    expect(_snapshot, findsOneWidget);
    expect(images, hasLength(beforeGradient + 1));
    final replacement = images.last;
    expect(red.debugDisposed, isFalse, reason: 'wallpaper images remain owned by their caller');
    expect(blue.debugDisposed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(replacement.debugDisposed, isTrue);
    expect(tester.takeException(), isNull);
  }));

  for (final dark in [false, true]) {
    for (final glow in [false, true]) {
      testWidgets('cached gradient matches all original pixels (dark=$dark, glow=$glow)', (tester) => _withRealShadows(() async {
        final theme = dark ? buildDarkTheme() : buildLightTheme();
        await tester.pumpWidget(_scene(theme: theme, glow: glow, picture: const BackdropPicture(image: null)));
        expect(_snapshot, findsNothing);
        final reference = await _pixels(tester);
        await tester.pumpWidget(_scene(theme: theme, glow: glow));
        expect(_snapshot, findsOneWidget);
        final cached = await _pixels(tester);
        var differentChannels = 0;
        for (var i = 0; i < cached.length; i++) {
          if (cached[i] != reference[i]) differentChannels++;
        }
        expect(differentChannels, 0, reason: 'cache the original three gradients without changing their pixels');
        expect(tester.takeException(), isNull);
      }));
    }
  }
}
