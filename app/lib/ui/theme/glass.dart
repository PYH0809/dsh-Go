import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../common/pressable.dart';
import '../common/ui_trace.dart';

import 'motion.dart';
import 'shapes.dart';
import 'surfaces.dart';

/// Controls backdrop sampling locally without changing the theme. Unlike an
/// InheritedTheme, this is not captured by sheets opened from inside the scope.
/// Their glass still follows the user's transparency setting.
class GlassBackdropScope extends InheritedWidget {
  const GlassBackdropScope({
    super.key,
    required this.enabled,
    this.translucentWhenDisabled = false,
    this.animationsEnabled,
    required super.child,
  });

  final bool enabled;

  /// True when the backdrop behind this scope is already a smooth solid-gradient
  /// veil (no sharp text or custom picture), so skipping `BackdropFilter` can
  /// keep the translucent `s.fill` instead of switching to opaque `fallbackFill`.
  final bool translucentWhenDisabled;

  /// Whether leaf visual tickers (`WhaleTail`, `StatusDot`, `ThinkGlyph`,
  /// `PetSprite`, `LiveElapsed`) should run inside this scope. Defaults to
  /// `enabled || translucentWhenDisabled`.
  final bool? animationsEnabled;

  static bool enabledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassBackdropScope>()?.enabled ?? true;

  static bool translucentWhenDisabledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassBackdropScope>()?.translucentWhenDisabled ?? false;

  /// True while the surface is uncovered and active.
  static bool animationsEnabledOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GlassBackdropScope>();
    if (scope == null) return true;
    return scope.animationsEnabled ?? (scope.enabled || scope.translucentWhenDisabled);
  }

  @override
  bool updateShouldNotify(GlassBackdropScope oldWidget) =>
      enabled != oldWidget.enabled ||
      translucentWhenDisabled != oldWidget.translucentWhenDisabled ||
      animationsEnabled != oldWidget.animationsEnabled;
}

/// 玻璃表面:**模糊背后的内容 → 叠半透明填充 → 发丝描边 + 顶边高光 → 外投影**。
///
/// ```dart
/// GlassSurface(
///   tier: GlassTier.chrome,
///   stadium: true,
///   onTap: openSessions,
///   padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
///   child: Text('修复登录重复提交'),
/// )
/// ```
///
/// ## 性能约定
///
/// - 只有 [GlassTier.chrome] / [GlassTier.sheet] 默认真模糊;同屏真模糊的
///   元素控制在 3 个以内(顶栏、输入条、弹层)。
/// - 同屏多个**互不重叠**的模糊件(顶栏左圆钮 + 标题胶囊 + 右圆钮)放进同一个
///   `BackdropGroup`,并传 [grouped] = true,用非 bounded 的 `ui.ImageFilter.blur`
///   让组内滤镜参数完全一致,引擎才能真正合并成单次背景采样与单次模糊(见 Flutter
///   #191207 / PR #191613)。单独使用的玻璃用 `bounded: true` 防止邻界渗色。
/// - 降级:主题里 `DshSurfaces.blurEnabled == false`(设置"减少透明效果"/
///   低端机)或系统高对比度时,不创建 `BackdropFilter`,改用近乎不透明的
///   `fallbackFill` —— 观感是"磨砂纸",可读性不降。
///
/// ## 为什么阴影要单独画
///
/// 玻璃内部是半透明的,普通 `BoxShadow` 画在形状下方会透过玻璃、又被模糊
/// 一次,玻璃中间发灰。这里用 even-odd 裁剪,只在形状**外部**画投影。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    this.tier = GlassTier.card,
    this.borderRadius,
    this.circle = false,
    this.stadium = false,
    this.padding,
    this.blur,
    this.grouped = false,
    this.settled,
    this.style,
    this.onTap,
    this.onLongPress,
    this.child,
  }) : assert(!(circle && stadium), 'circle 与 stadium 只能二选一' /* l10n:keep developer-only assertion */);

  /// 材质层级,决定默认的填充 / 模糊 / 阴影 / 圆角。
  final GlassTier tier;

  /// 连续圆角半径。缺省按层级:chrome / sheet 用 xl(28)、card 用 md(14)、
  /// pill 用胶囊。
  final BorderRadiusGeometry? borderRadius;

  /// 圆形(顶栏圆钮、发送键底座)。
  final bool circle;

  /// 胶囊(半径永远等于高度一半)。
  final bool stadium;

  final EdgeInsetsGeometry? padding;

  /// 强制开 / 关模糊。null = 跟随层级默认值与主题总开关。
  final bool? blur;

  /// 与同一 `BackdropGroup` 下的其他玻璃共享一次背景采样。
  final bool grouped;

  /// 会动的玻璃(升起、被拖动的弹层)。0 = 在动:不采样背景,用不透明填充。
  /// 停稳后走向 1:模糊立刻开,藏在近乎不透明的填充后面,填充渐变回玻璃,所以
  /// 模糊出现时不跳。和 `blur: false` 不同,切换时模糊层留在树里,子树不重建。
  /// null = 一直是玻璃。
  final double? settled;

  /// 覆盖主题给的材质(极少用;例如审批卡要换警示色描边)。
  final GlassStyle? style;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? child;

  BorderRadiusGeometry get _radius =>
      borderRadius ??
      switch (tier) {
        GlassTier.chrome || GlassTier.sheet => AppShape.radiusXl,
        GlassTier.card => AppShape.radiusMd,
        GlassTier.pill => AppShape.radiusLg,
      };

  bool get _isStadium => stadium || (!circle && borderRadius == null && tier == GlassTier.pill);

  /// Whether rectangular/stadium `sheet` and `chrome` outer shadows cache into
  /// GPU textures via [SnapshotWidget]. Disabled in `flutter_test_config.dart`
  /// so existing vector golden images match without ±1 LSB 8-bit quantization.
  static bool shadowCaching = true;

  ShapeBorder get _shape {
    if (circle) return const CircleBorder();
    if (_isStadium) return const StadiumBorder();
    return RoundedSuperellipseBorder(borderRadius: _radius);
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = DshSurfaces.of(context);
    final s = style ?? surfaces.glass(tier);
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final sampleBackdrop = GlassBackdropScope.enabledOf(context);
    final keepTranslucent = GlassBackdropScope.translucentWhenDisabledOf(context);
    final reduce = !surfaces.blurEnabled || highContrast || uiTraceNoBlur;
    final useBlur = !reduce && (blur ?? s.blurs);
    if (uiTraceEnabled) {
      uiTrace('glass', 'build', {'tier': tier.name, 'blur': useBlur, 'grouped': grouped});
    }
    final fill = useBlur
        ? Color.lerp(s.fallbackFill, s.fill, (sampleBackdrop || keepTranslucent) ? (settled ?? 1) : 0)!
        : (reduce || s.blurs ? s.fallbackFill : s.fill);
    final shape = _shape;
    final textDirection = Directionality.maybeOf(context);

    Widget content = child ?? const SizedBox.shrink();
    if (padding != null) content = Padding(padding: padding!, child: content);
    if (onTap != null || onLongPress != null) {
      // Press feedback on the content, not the glass: scaling a surface that
      // blurs would re-sample what is behind it at a new size every frame.
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Pressable(behavior: HitTestBehavior.translucent, child: content),
        ),
      );
    }

    content = CustomPaint(
      foregroundPainter: _GlassEdgePainter(
        shape: shape,
        hairline: s.hairline,
        hairlineWidth: s.hairlineWidth,
        rim: s.rim,
        textDirection: textDirection,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape, color: fill),
        child: content,
      ),
    );

    if (useBlur) {
      // Grouped filters must resolve to identical parameters across siblings so
      // Impeller's BackdropGroup collapses them into a single blur pass instead
      // of running 3n separate offscreen passes per frame.
      final config = _filterFor(s.blurs ? s.blurSigma : 14, s.saturation, bounded: !grouped || !shadowCaching);
      // Keep the filter and content mounted while a moving ancestor suspends
      // sampling. Inserting/removing it would reset unkeyed content State.
      final sampling = sampleBackdrop && settled != 0;
      content = grouped
          ? BackdropFilter.grouped(filterConfig: config, enabled: sampling, child: content)
          : BackdropFilter(filterConfig: config, enabled: sampling, child: content);
      content = _clip(content);
    }

    if (s.shadows.isNotEmpty) {
      if ((tier == GlassTier.sheet || tier == GlassTier.chrome) && !circle && shadowCaching) {
        // Cache only the static shadow on rectangular/pill chrome & sheet panels
        // (small 44dp circular buttons draw directly via CustomPaint). Impeller
        // does not raster-cache a RepaintBoundary on all backends. Include the
        // outer shadow in the snapshot's size so the image cannot cut it off.
        final extent = _GlassShadowPainter.extentOf(s.shadows);
        content = _ShadowStack(
          extent: extent,
          shadow: IgnorePointer(
            child: RepaintBoundary(
              child: _CachedGlassShadow(
                painter: _GlassShadowPainter(
                  shape: shape,
                  shadows: s.shadows,
                  textDirection: textDirection,
                  inset: extent,
                ),
              ),
            ),
          ),
          child: content,
        );
      } else {
        content = CustomPaint(
          painter: _GlassShadowPainter(shape: shape, shadows: s.shadows, textDirection: textDirection),
          child: content,
        );
      }
    }
    return content;
  }

  Widget _clip(Widget child) {
    if (circle) return ClipOval(child: child);
    if (_isStadium) {
      return ClipRRect(borderRadius: const BorderRadius.all(Radius.circular(999)), child: child);
    }
    return ClipRSuperellipse(borderRadius: _radius, child: child);
  }

  static ImageFilterConfig _filterFor(double sigma, double saturation, {required bool bounded}) {
    final blur = ImageFilterConfig.blur(sigmaX: sigma, sigmaY: sigma, bounded: bounded);
    if (saturation == 1) return blur;
    return ImageFilterConfig.compose(outer: ImageFilterConfig(ColorFilter.matrix(_saturate(saturation))), inner: blur);
  }

  /// 保亮度的饱和度矩阵(Rec. 709 权重)。
  static List<double> _saturate(double s) {
    final r = 0.2126 * (1 - s);
    final g = 0.7152 * (1 - s);
    final b = 0.0722 * (1 - s);
    return <double>[
      r + s, g, b, 0, 0, //
      r, g + s, b, 0, 0, //
      r, g, b + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }
}

class _ShadowStack extends RenderObjectWidget {
  const _ShadowStack({required this.extent, required this.shadow, required this.child});

  final double extent;
  final Widget shadow;
  final Widget child;

  @override
  RenderObjectElement createElement() => _ShadowStackElement(this);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderShadowStack(extent);

  @override
  void updateRenderObject(BuildContext context, _RenderShadowStack renderObject) => renderObject.extent = extent;
}

class _ShadowStackElement extends RenderObjectElement {
  _ShadowStackElement(_ShadowStack super.widget);

  Element? _shadow;
  Element? _child;

  @override
  _ShadowStack get widget => super.widget as _ShadowStack;

  @override
  _RenderShadowStack get renderObject => super.renderObject as _RenderShadowStack;

  @override
  void visitChildren(ElementVisitor visitor) {
    if (_shadow != null) visitor(_shadow!);
    if (_child != null) visitor(_child!);
  }

  @override
  void forgetChild(Element child) {
    if (child == _shadow) _shadow = null;
    if (child == _child) _child = null;
    super.forgetChild(child);
  }

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    _shadow = updateChild(_shadow, widget.shadow, 0);
    _child = updateChild(_child, widget.child, 1);
  }

  @override
  void update(_ShadowStack newWidget) {
    super.update(newWidget);
    _shadow = updateChild(_shadow, widget.shadow, 0);
    _child = updateChild(_child, widget.child, 1);
  }

  @override
  void insertRenderObjectChild(RenderBox child, int slot) {
    if (slot == 0) {
      renderObject.shadow = child;
    } else {
      renderObject.child = child;
    }
  }

  @override
  void moveRenderObjectChild(RenderBox child, int oldSlot, int newSlot) {}

  @override
  void removeRenderObjectChild(RenderBox child, int slot) {
    if (slot == 0) {
      if (renderObject.shadow == child) renderObject.shadow = null;
    } else {
      if (renderObject.child == child) renderObject.child = null;
    }
  }
}

class _RenderShadowStack extends RenderBox {
  _RenderShadowStack(this._extent);

  double _extent;
  set extent(double value) {
    if (_extent == value) return;
    _extent = value;
    markNeedsLayout();
  }

  RenderBox? _shadow;
  RenderBox? get shadow => _shadow;
  set shadow(RenderBox? value) {
    if (_shadow == value) return;
    if (_shadow != null) dropChild(_shadow!);
    _shadow = value;
    if (_shadow != null) {
      _shadow!.parentData = BoxParentData();
      adoptChild(_shadow!);
    }
  }

  RenderBox? _child;
  RenderBox? get child => _child;
  set child(RenderBox? value) {
    if (_child == value) return;
    if (_child != null) dropChild(_child!);
    _child = value;
    if (_child != null) {
      _child!.parentData = BoxParentData();
      adoptChild(_child!);
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _shadow?.attach(owner);
    _child?.attach(owner);
  }

  @override
  void detach() {
    super.detach();
    _shadow?.detach();
    _child?.detach();
  }

  @override
  void visitChildren(RenderObjectVisitor visitor) {
    if (_shadow != null) visitor(_shadow!);
    if (_child != null) visitor(_child!);
  }

  @override
  void redepthChildren() {
    if (_shadow != null) redepthChild(_shadow!);
    if (_child != null) redepthChild(_child!);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) => _child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) => _child?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) => _child?.getMaxIntrinsicHeight(width) ?? 0;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _child?.getDistanceToActualBaseline(baseline);

  @override
  double? computeDryBaseline(covariant BoxConstraints constraints, TextBaseline baseline) =>
      _child?.getDryBaseline(constraints, baseline);

  @override
  Size computeDryLayout(BoxConstraints constraints) => _child?.getDryLayout(constraints) ?? constraints.smallest;

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = (child.parentData! as BoxParentData).offset;
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }

  @override
  void performLayout() {
    final c = _child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    c.layout(constraints, parentUsesSize: true);
    size = c.size;
    (c.parentData! as BoxParentData).offset = Offset.zero;
    final s = _shadow;
    if (s != null) {
      s.layout(BoxConstraints.tight(Size(size.width + 2 * _extent, size.height + 2 * _extent)));
      (s.parentData! as BoxParentData).offset = Offset(-_extent, -_extent);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _child?.hitTest(result, position: position) ?? false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final s = _shadow;
    if (s != null) context.paintChild(s, offset + (s.parentData! as BoxParentData).offset);
    final c = _child;
    if (c != null) context.paintChild(c, offset);
  }
}

class _CachedGlassShadow extends StatefulWidget {
  const _CachedGlassShadow({required this.painter});

  final _GlassShadowPainter painter;

  @override
  State<_CachedGlassShadow> createState() => _CachedGlassShadowState();
}

class _CachedGlassShadowState extends State<_CachedGlassShadow> {
  final _controller = SnapshotController(allowSnapshotting: true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (_controller.allowSnapshotting != active) {
      _controller.allowSnapshotting = active;
      if (!active) _controller.clear();
    }
  }

  @override
  void didUpdateWidget(_CachedGlassShadow oldWidget) {
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
    // SnapshotWidget also invalidates its image when MediaQuery's DPR changes.
    autoresize: true,
    child: CustomPaint(painter: widget.painter),
  );
}

/// 发丝描边 + 顶边高光。描边画在形状内侧,裁剪时不会被切掉一半。
class _GlassEdgePainter extends CustomPainter {
  _GlassEdgePainter({
    required this.shape,
    required this.hairline,
    required this.hairlineWidth,
    required this.rim,
    required this.textDirection,
  });

  final ShapeBorder shape;
  final Color hairline;
  final double hairlineWidth;
  final Color rim;
  final TextDirection? textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final width = math.max(hairlineWidth, 0.5);
    final path = shape.getOuterPath(rect.deflate(width / 2), textDirection: textDirection);
    if (hairline.a > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = hairline,
      );
    }
    if (rim.a > 0) {
      final highlight = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(width, 0.8)
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [rim, rim.withValues(alpha: 0)],
          stops: const [0, 0.45],
        ).createShader(rect);
      canvas.drawPath(path, highlight);
    }
  }

  @override
  bool shouldRepaint(_GlassEdgePainter old) =>
      old.shape != shape ||
      old.hairline != hairline ||
      old.hairlineWidth != hairlineWidth ||
      old.rim != rim ||
      old.textDirection != textDirection;
}

/// 只在形状外部画的投影。
class _GlassShadowPainter extends CustomPainter {
  _GlassShadowPainter({required this.shape, required this.shadows, required this.textDirection, this.inset = 0});

  final ShapeBorder shape;
  final List<BoxShadow> shadows;
  final TextDirection? textDirection;
  final double inset;

  static double extentOf(List<BoxShadow> shadows) {
    var extent = 0.0;
    for (final s in shadows) {
      extent = math.max(extent, s.blurRadius * 2 + s.spreadRadius.abs() + s.offset.distance);
    }
    return extent + 2;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(inset);
    if (rect.isEmpty) return;
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(extentOf(shadows)))
      ..addPath(shape.getOuterPath(rect, textDirection: textDirection), Offset.zero);
    canvas.save();
    canvas.clipPath(outside);
    for (final s in shadows) {
      canvas.drawPath(
        shape.getOuterPath(rect.shift(s.offset).inflate(s.spreadRadius), textDirection: textDirection),
        s.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassShadowPainter old) =>
      old.shape != shape ||
      old.inset != inset ||
      !_sameShadows(old.shadows, shadows) ||
      old.textDirection != textDirection;

  static bool _sameShadows(List<BoxShadow> a, List<BoxShadow> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The glass of a panel that slides in and out on [motion] (0..1): an opaque fill while it
/// moves, since a moving blur re-samples what is behind it every frame, and glass at rest.
/// Once it stops, the opaque fill clears into glass over [AppMotion.glassIn]. Moving uses
/// the opaque fill immediately so disabling the blur cannot expose sharp background text.
/// The blur stays in the tree throughout, so the panel's content is not rebuilt either.
class SlidingGlass extends StatefulWidget {
  const SlidingGlass({super.key, required this.motion, required this.tier, required this.borderRadius, this.child});

  final Animation<double> motion;
  final GlassTier tier;
  final BorderRadiusGeometry borderRadius;
  final Widget? child;

  @override
  State<SlidingGlass> createState() => _SlidingGlassState();
}

class _SlidingGlassState extends State<SlidingGlass> with SingleTickerProviderStateMixin {
  late final AnimationController _settled = AnimationController(
    vsync: this,
    duration: AppMotion.glassIn,
    value: widget.motion.value == 1 ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    widget.motion.addListener(_sync);
  }

  @override
  void didUpdateWidget(SlidingGlass old) {
    super.didUpdateWidget(old);
    if (identical(old.motion, widget.motion)) return;
    old.motion.removeListener(_sync);
    widget.motion.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    widget.motion.removeListener(_sync);
    _settled.dispose();
    super.dispose();
  }

  void _sync() {
    final value = widget.motion.value;
    if (value == 0) {
      // Out of sight: nothing to fade, and no reason to keep sampling.
      if (_settled.value != 0) _settled.value = 0;
    } else if (AppMotion.reduced(context)) {
      _settled.value = value == 1 ? 1 : 0;
    } else if (value == 1) {
      if (!_settled.isForwardOrCompleted) _settled.forward();
    } else if (_settled.isForwardOrCompleted) {
      _settled.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _settled,
    builder: (context, child) =>
        GlassSurface(tier: widget.tier, borderRadius: widget.borderRadius, settled: _settled.value, child: child),
    child: widget.child,
  );
}

/// [child]'s glass without its blur, for chrome floating over a web page: the page is a
/// native view, which a backdrop filter can't see. It would blur whatever Flutter drew
/// underneath instead, and show it through the key as a band.
class GlassOverNativeView extends StatelessWidget {
  const GlassOverNativeView({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = DshSurfaces.of(context);
    if (!surfaces.blurEnabled) return child;
    return Theme(
      data: theme.copyWith(
        extensions: [
          for (final e in theme.extensions.values)
            if (e is! DshSurfaces) e,
          surfaces.copyWith(blurEnabled: false),
        ],
      ),
      child: child,
    );
  }
}
