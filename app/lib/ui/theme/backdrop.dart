// Concept derived from PiPilot (https://github.com/CikeSeven/pi_pilot), MIT, Copyright (c) 2026 CikeSeven. See THIRD_PARTY_NOTICES.md.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'backdrop_frame.dart';
import 'surfaces.dart';

/// 全屏页面背景:**竖向雾蓝渐变 + 两团极淡的光**。
///
/// - 底层:`backdropTop → backdropBottom` 竖向渐变(浅色彩度 ≤ 0.019)。
/// - 右上:主色光晕(跟随 accent)。左下:暮紫光晕。透明度都在 0.25–0.42,
///   画在大半径径向渐变里,肉眼只觉得"有点透亮",看不出是两个圆。
/// - 光晕的作用是给玻璃一点可"透"的颜色;纯平背景上的玻璃看起来只是白块。
///
/// **同一主题内所有页共用同一张背景**,
/// 切 tab 时背景不动,只有前景内容在变 —— 切换顺滑的关键。
///
/// 内部自带一个透明 `Material`:子树里的 `InkWell` 水波画在背景**之上**。
/// (若水波宿主是背景下面的 Scaffold,不透明的渐变会把水波整个盖住。)
///
/// 给了 [picture](自定义壁纸,lib/ui/wallpaper/wallpaper_backdrop.dart)就画那张
/// 预先烘好的图,不画渐变;子树里的 [BackdropVeil] 跟着画同一张图。
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key, required this.child, this.glow = true, this.picture});

  final Widget child;

  /// 是否画光晕。全屏 WebView、安装页等自带背景的场景可以关掉。
  final bool glow;

  /// A picture in place of the gradient; null: the gradient.
  final BackdropPicture? picture;

  @override
  Widget build(BuildContext context) {
    final s = DshSurfaces.of(context);
    final painter = _BackdropPainter(
      top: s.backdropTop,
      bottom: s.backdropBottom,
      glowPrimary: glow ? s.glowPrimary : null,
      glowSecondary: glow ? s.glowSecondary : null,
      picture: picture,
    );
    return _BackdropScope(
      picture: picture,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: picture == null && !debugDisableShadows
                    ? _CachedGradient(painter: painter)
                    : CustomPaint(painter: painter),
              ),
            ),
          ),
          RepaintBoundary(
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ],
      ),
    );
  }
}

// An explicit image avoids re-running the three static gradient shaders on
// backends without a raster cache. Covered routes release the ~18 MiB texture
// and recapture it when revealed. Wallpapers, ink and page content stay live.
class _CachedGradient extends StatefulWidget {
  const _CachedGradient({required this.painter});

  final _BackdropPainter painter;

  @override
  State<_CachedGradient> createState() => _CachedGradientState();
}

class _CachedGradientState extends State<_CachedGradient> {
  final _controller = SnapshotController(allowSnapshotting: true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Release the ~18 MiB texture when a full-screen route covers this page
    // (ModalRoute sets Offstage/TickerMode=false once covered by an opaque route).
    final active = TickerMode.valuesOf(context).enabled;
    if (_controller.allowSnapshotting != active) {
      _controller.allowSnapshotting = active;
      if (!active) _controller.clear();
    }
  }

  @override
  void didUpdateWidget(_CachedGradient oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.painter.shouldRepaint(oldWidget.painter)) _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SnapshotWidget(
    controller: _controller,
    // Size and MediaQuery DPR changes invalidate the image inside SnapshotWidget.
    autoresize: true,
    child: CustomPaint(painter: widget.painter),
  );
}

/// What [AppBackdrop] paints instead of its gradient: [image], baked to the screen's size (the
/// custom wallpaper), faded in at [fade] over [from] (the picture it replaces; null: the
/// gradient). [image] null fades back to the gradient. The images belong to whoever made this;
/// they must outlive it.
@immutable
class BackdropPicture {
  const BackdropPicture({required this.image, this.from, this.fade = kAlwaysCompleteAnimation});

  final ui.Image? image;
  final ui.Image? from;
  final Animation<double> fade;

  @override
  bool operator ==(Object other) =>
      other is BackdropPicture && other.image == image && other.from == from && other.fade == fade;

  @override
  int get hashCode => Object.hash(image, from, fade);
}

/// The picture of the nearest [AppBackdrop], for the [BackdropVeil]s over it.
class _BackdropScope extends InheritedWidget {
  const _BackdropScope({required this.picture, required super.child});

  final BackdropPicture? picture;

  static BackdropPicture? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_BackdropScope>()?.picture;

  @override
  bool updateShouldNotify(_BackdropScope old) => old.picture != picture;
}

/// [AppBackdrop] 的一角:同一张背景,只画底部 [solidHeight] + [feather] 这一条,
/// 底部 [solidHeight] 实心,往上 [feather] 缓缓淡出。
///
/// 叠在滚动内容之上、浮动控件(输入条、思考胶囊)之下:内容滑到控件后面时
/// 淡出,控件之间的缝里只露背景,底色不跟着滚动内容闪、也不出现割裂的缝。
/// 不用遮罩去裁内容本身,是因为列表里的玻璃卡片要采样真背景做模糊。
///
/// 渐变和光晕按整屏尺寸算(与 [AppBackdrop] 相同),从页面顶端画起、只留
/// 这一条,所以和真背景严丝合缝;键盘弹起页面变矮时也对得上。要求铺满
/// 整页、和页面左上角对齐。分栏布局里的一栏(宽屏的聊天栏、详情栏)由
/// [BackdropFrame] 告知它在整张背景里的位置,照样对得上。
class BackdropVeil extends StatelessWidget {
  const BackdropVeil({super.key, required this.solidHeight, this.feather = defaultFeather, this.glow = true})
    : fromTop = false;

  static const defaultFeather = 14.0;

  /// 顶部版:从顶边往下 [height] 实心,再往下 [feather] 缓缓淡出(页面顶栏
  /// 后面)。同样要铺满整页、和页面左上角对齐。
  BackdropVeil.top({super.key, required double height, this.feather = defaultFeather, this.glow = true})
    : solidHeight = _FixedHeight(height),
      fromTop = true;

  /// 从底边往上实心的高度。由页面布局在排好浮动控件时写入:遮罩画在布局
  /// 之后,不经过重建,这一帧就按新高度画,和控件严丝合缝。
  final ValueListenable<double> solidHeight;

  /// 实心区之外(底部版在上、顶部版在下)的淡出高度。
  final double feather;
  final bool glow;

  /// 顶部版([BackdropVeil.top])。
  final bool fromTop;

  @override
  Widget build(BuildContext context) {
    final s = DshSurfaces.of(context);
    final frame = BackdropFrame.maybeOf(context);
    final picture = _BackdropScope.of(context);
    final area = frame?.area ?? MediaQuery.sizeOf(context);
    final origin = frame?.origin ?? Offset.zero;
    final backdrop = _BackdropPainter(
      top: s.backdropTop,
      bottom: s.backdropBottom,
      glowPrimary: glow ? s.glowPrimary : null,
      glowSecondary: glow ? s.glowSecondary : null,
      area: area,
      origin: origin,
      picture: picture,
    );
    final bandPainter = _BandVeilPainter(
      solidHeight: solidHeight,
      feather: feather,
      fromTop: fromTop,
      pageHeight: area.height,
      backdrop: backdrop,
    );
    if (picture != null) {
      return IgnorePointer(
        child: CustomPaint(
          size: Size.infinite,
          painter: _VeilPainter(solidHeight: solidHeight, feather: feather, fromTop: fromTop, backdrop: backdrop),
        ),
      );
    }
    return IgnorePointer(
      child: _VeilBandLayout(
        solidHeight: solidHeight,
        feather: feather,
        fromTop: fromTop,
        child: debugDisableShadows
            ? CustomPaint(size: Size.infinite, painter: bandPainter)
            : _CachedBandVeil(painter: bandPainter),
      ),
    );
  }
}

class _VeilBandLayout extends SingleChildRenderObjectWidget {
  const _VeilBandLayout({
    required this.solidHeight,
    required this.feather,
    required this.fromTop,
    required super.child,
  });

  final ValueListenable<double> solidHeight;
  final double feather;
  final bool fromTop;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderVeilBandLayout(solidHeight, feather, fromTop);

  @override
  void updateRenderObject(BuildContext context, _RenderVeilBandLayout renderObject) {
    renderObject
      ..solidHeight = solidHeight
      ..feather = feather
      ..fromTop = fromTop;
  }
}

class _RenderVeilBandLayout extends RenderShiftedBox {
  _RenderVeilBandLayout(this._solidHeight, this._feather, this._fromTop) : super(null);

  ValueListenable<double> _solidHeight;
  set solidHeight(ValueListenable<double> value) {
    if (identical(_solidHeight, value)) return;
    if (attached) _solidHeight.removeListener(_scheduleMarkNeedsLayout);
    _solidHeight = value;
    if (attached) _solidHeight.addListener(_scheduleMarkNeedsLayout);
    markNeedsLayout();
  }

  double _feather;
  set feather(double value) {
    if (_feather == value) return;
    _feather = value;
    markNeedsLayout();
  }

  bool _fromTop;
  set fromTop(bool value) {
    if (_fromTop == value) return;
    _fromTop = value;
    markNeedsLayout();
  }

  bool _postFrameScheduled = false;

  void _scheduleMarkNeedsLayout() {
    if (!attached) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_postFrameScheduled) return;
      _postFrameScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _postFrameScheduled = false;
        if (attached) markNeedsLayout();
      });
      return;
    }
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _solidHeight.addListener(_scheduleMarkNeedsLayout);
  }

  @override
  void detach() {
    _solidHeight.removeListener(_scheduleMarkNeedsLayout);
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final c = child;
    if (c == null) return;
    final band = (_solidHeight.value + _feather).clamp(0.0, size.height);
    c.layout(BoxConstraints.tight(Size(size.width, band)), parentUsesSize: true);
    final data = c.parentData! as BoxParentData;
    data.offset = Offset(0, _fromTop ? 0 : size.height - band);
  }
}

class _CachedBandVeil extends StatefulWidget {
  const _CachedBandVeil({required this.painter});

  final _BandVeilPainter painter;

  @override
  State<_CachedBandVeil> createState() => _CachedBandVeilState();
}

class _CachedBandVeilState extends State<_CachedBandVeil> {
  final _controller = SnapshotController(allowSnapshotting: true);

  void _sync() {
    final active = TickerMode.valuesOf(context).enabled;
    if (_controller.allowSnapshotting != active) {
      _controller.allowSnapshotting = active;
      if (!active) _controller.clear();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_CachedBandVeil oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.painter.shouldRepaint(oldWidget.painter)) {
      _controller.clear();
    }
    _sync();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SnapshotWidget(
    controller: _controller,
    autoresize: true,
    child: CustomPaint(painter: widget.painter),
  );
}

class _BandVeilPainter extends CustomPainter {
  _BandVeilPainter({
    required this.solidHeight,
    required this.feather,
    required this.fromTop,
    required this.pageHeight,
    required this.backdrop,
  }) : super(repaint: solidHeight);

  final ValueListenable<double> solidHeight;
  final double feather;
  final bool fromTop;
  final double pageHeight;
  final _BackdropPainter backdrop;

  @override
  void paint(Canvas canvas, Size size) {
    final band = size.height;
    if (band <= 0 || size.isEmpty) return;
    final rect = Offset.zero & size;
    final fade = (feather / band).clamp(0.0, 1.0);
    const samples = 8;
    final stops = <double>[];
    final colors = <Color>[];
    if (fromTop) {
      stops.add(0);
      colors.add(Colors.black);
    }
    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      stops.add(fromTop ? 1 - fade + fade * t : fade * t);
      final alpha = Curves.easeInOutCubic.transform(t);
      colors.add(Colors.black.withValues(alpha: fromTop ? 1 - alpha : alpha));
    }
    if (!fromTop) {
      stops.add(1);
      colors.add(Colors.black);
    }

    canvas.saveLayer(rect, Paint());
    canvas.clipRect(rect);
    final dy = fromTop ? 0.0 : -(pageHeight - band);
    canvas.save();
    canvas.translate(0, dy);
    backdrop.paint(canvas, Size(size.width, pageHeight));
    canvas.restore();
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
          stops: stops,
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BandVeilPainter old) =>
      old.solidHeight != solidHeight ||
      old.feather != feather ||
      old.fromTop != fromTop ||
      old.pageHeight != pageHeight ||
      backdrop.shouldRepaint(old.backdrop);
}

/// A fixed height for [BackdropVeil.top].
class _FixedHeight implements ValueListenable<double> {
  const _FixedHeight(this.value);

  @override
  final double value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  bool operator ==(Object other) => other is _FixedHeight && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// [BackdropVeil] 的一条:底部实心,往上缓缓淡出(顶部版反过来)。
class _VeilPainter extends CustomPainter {
  _VeilPainter({required this.solidHeight, required this.feather, required this.backdrop, this.fromTop = false})
    : super(repaint: backdrop.picture == null ? solidHeight : Listenable.merge([solidHeight, backdrop.picture!.fade]));

  final ValueListenable<double> solidHeight;
  final double feather;
  final _BackdropPainter backdrop;
  final bool fromTop;

  @override
  void paint(Canvas canvas, Size size) {
    final band = (solidHeight.value + feather).clamp(0.0, size.height);
    if (band <= 0) return;
    final rect = fromTop
        ? Rect.fromLTWH(0, 0, size.width, band)
        : Rect.fromLTWH(0, size.height - band, size.width, band);
    final fade = (feather / band).clamp(0.0, 1.0);
    // Eased ramp: a linear one reads as a crease at both ends.
    const samples = 8;
    final stops = <double>[];
    final colors = <Color>[];
    if (fromTop) {
      stops.add(0);
      colors.add(Colors.black);
    }
    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      stops.add(fromTop ? 1 - fade + fade * t : fade * t);
      final alpha = Curves.easeInOutCubic.transform(t);
      colors.add(Colors.black.withValues(alpha: fromTop ? 1 - alpha : alpha));
    }
    if (!fromTop) {
      stops.add(1);
      colors.add(Colors.black);
    }

    canvas.saveLayer(rect, Paint());
    canvas.clipRect(rect);
    // The whole backdrop from the page's top, so the band lines up with it.
    backdrop.paint(canvas, size);
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
          stops: stops,
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VeilPainter old) =>
      old.solidHeight != solidHeight ||
      old.feather != feather ||
      old.fromTop != fromTop ||
      backdrop.shouldRepaint(old.backdrop);
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.top,
    required this.bottom,
    this.glowPrimary,
    this.glowSecondary,
    this.area,
    this.origin = Offset.zero,
    this.picture,
  }) : super(repaint: picture?.fade);

  final Color top;
  final Color bottom;
  final Color? glowPrimary;
  final Color? glowSecondary;

  /// The whole backdrop's size when this paints only a band of it.
  final Size? area;

  /// Where the canvas sits inside [area] (a column of a split layout).
  final Offset origin;

  /// A picture in place of the gradient.
  final BackdropPicture? picture;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final size = area ?? canvasSize;
    if (area != null) {
      // Only the band: CustomPaint does not clip what is drawn outside it.
      canvas.save();
      canvas.clipRect(Offset.zero & canvasSize);
      canvas.translate(-origin.dx, -origin.dy);
    }
    final picture = this.picture;
    if (picture == null) {
      _gradient(canvas, size);
    } else {
      final t = picture.fade.value;
      if (t < 1) _layer(canvas, size, picture.from);
      if (t > 0) {
        final fading = t < 1;
        if (fading) canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(0, 0, 0, t));
        _layer(canvas, size, picture.image);
        if (fading) canvas.restore();
      }
    }
    if (area != null) canvas.restore();
  }

  void _layer(Canvas canvas, Size size, ui.Image? image) {
    if (image == null) {
      _gradient(canvas, size);
      return;
    }
    // Baked to the screen's shape; covers whatever else this is asked to fill.
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    final scale = size.isEmpty ? 1.0 : (w / size.width < h / size.height ? w / size.width : h / size.height);
    final src = Rect.fromCenter(center: Offset(w / 2, h / 2), width: size.width * scale, height: size.height * scale);
    canvas.drawImageRect(image, src, Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
  }

  void _gradient(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ).createShader(rect),
    );
    final longest = size.longestSide;
    if (glowPrimary case final color?) {
      _glow(canvas, Offset(size.width * 0.92, 0), longest * 0.62, color);
    }
    if (glowSecondary case final color?) {
      _glow(canvas, Offset(0, size.height), longest * 0.55, color);
    }
  }

  void _glow(Canvas canvas, Offset center, double radius, Color color) {
    final bounds = Rect.fromCircle(center: center, radius: radius);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
          stops: const [0, 1],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.top != top ||
      old.bottom != bottom ||
      old.glowPrimary != glowPrimary ||
      old.glowSecondary != glowSecondary ||
      old.area != area ||
      old.origin != origin ||
      old.picture != picture;
}
