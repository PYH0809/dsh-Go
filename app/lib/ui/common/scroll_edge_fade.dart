// Soft edges on a sheet's scrolling body: an edge fades only while there is
// more to scroll past it, so content at rest is never dimmed.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({
    super.key,
    required this.child,
    this.topExtent = extent,
    this.bottomExtent = extent,
  });

  final Widget child;
  final double topExtent;
  final double bottomExtent;

  /// Whether to omit [ShaderMaskLayer] when neither edge is scrolled (`_top == 0 && _bottom == 0`).
  /// Disabled in `flutter_test_config.dart` so existing vector golden images match
  /// the 8-bit `saveLayer` quantization of Flutter's `ShaderMask`.
  static bool skipLayerAtRest = true;
  static const extent = 12.0;

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  double _top = 0;
  double _bottom = 0;

  bool _onScroll(ScrollMetrics metrics, int depth) {
    if (depth != 0 || metrics.axis != Axis.vertical) return false;
    final minThreshold = ScrollEdgeFade.skipLayerAtRest ? 0.5 : 0.0;
    final top = metrics.extentBefore < minThreshold ? 0.0 : metrics.extentBefore.clamp(0.0, widget.topExtent);
    final bottom = metrics.extentAfter < minThreshold ? 0.0 : metrics.extentAfter.clamp(0.0, widget.bottomExtent);
    if (top != _top || bottom != _bottom) {
      setState(() {
        _top = top;
        _bottom = bottom;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollMetricsNotification>(
    onNotification: (n) => _onScroll(n.metrics, n.depth),
    child: NotificationListener<ScrollNotification>(
      onNotification: (n) => _onScroll(n.metrics, n.depth),
      // Always in the tree: the child keeps its state as the edges change,
      // and with nothing hidden it draws directly without a ShaderMaskLayer.
      child: _VerticalEdgeMask(top: _top, bottom: _bottom, child: widget.child),
    ),
  );
}

class _VerticalEdgeMask extends SingleChildRenderObjectWidget {
  const _VerticalEdgeMask({required this.top, required this.bottom, super.child});

  final double top;
  final double bottom;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderVerticalEdgeMask(top, bottom);

  @override
  void updateRenderObject(BuildContext context, _RenderVerticalEdgeMask renderObject) =>
      renderObject.update(top, bottom);
}

class _RenderVerticalEdgeMask extends RenderProxyBox {
  _RenderVerticalEdgeMask(this._top, this._bottom);

  double _top;
  double _bottom;
  final _mask = LayerHandle<ShaderMaskLayer>();

  @override
  bool get alwaysNeedsCompositing => !ScrollEdgeFade.skipLayerAtRest || _top > 0 || _bottom > 0;

  void update(double top, double bottom) {
    if (top == _top && bottom == _bottom) return;
    final composited = alwaysNeedsCompositing;
    _top = top;
    _bottom = bottom;
    if (composited != alwaysNeedsCompositing) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!alwaysNeedsCompositing || size.isEmpty) {
      _mask.layer = null;
      super.paint(context, offset);
      return;
    }
    final h = size.height;
    // Matches Flutter's own `RenderShaderMask.paint` (`proxy_box.dart:1183`):
    // `ShaderMaskLayer.shader` is evaluated in the maskRect's local `(0, 0)`
    // origin while `maskRect = offset & size` positions the mask in canvas space.
    _mask.layer = (_mask.layer ?? ShaderMaskLayer())
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          _top > 0 ? const Color(0x00000000) : const Color(0xFF000000),
          const Color(0xFF000000),
          const Color(0xFF000000),
          _bottom > 0 ? const Color(0x00000000) : const Color(0xFF000000),
        ],
        stops: [0, (_top / h).clamp(0.0, 0.5), 1 - (_bottom / h).clamp(0.0, 0.5), 1],
      ).createShader(Offset.zero & size)
      ..maskRect = offset & size
      ..blendMode = BlendMode.dstIn;
    context.pushLayer(_mask.layer!, super.paint, offset);
  }

  @override
  void dispose() {
    _mask.layer = null;
    super.dispose();
  }
}
