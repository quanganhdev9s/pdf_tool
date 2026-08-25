import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/hwp_direct_caret.dart';

class HwpPageSurface extends StatefulWidget {
  const HwpPageSurface({
    required this.pageIndex,
    required this.pageNumber,
    required this.pageCount,
    required this.svg,
    required this.editing,
    required this.caret,
    required this.onNeedRender,
    required this.onTapPage,
    super.key,
  });

  final int pageIndex;
  final int pageNumber;
  final int pageCount;
  final String? svg;
  final bool editing;
  final HwpDirectCaret? caret;
  final Future<void> Function(int pageIndex) onNeedRender;
  final Future<void> Function({
    required int pageIndex,
    required Offset localPosition,
    required Size pageSize,
    required String svg,
  })
  onTapPage;

  @override
  State<HwpPageSurface> createState() => _HwpPageSurfaceState();
}

class _HwpPageSurfaceState extends State<HwpPageSurface> {
  final TransformationController _transformController =
      TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _requestRenderIfNeeded();
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HwpPageSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageIndex != widget.pageIndex) {
      _resetZoom();
    }
    _requestRenderIfNeeded();
  }

  void _syncZoomState() {
    final bool nextZoomed =
        _transformController.value.getMaxScaleOnAxis() > 1.01;
    if (nextZoomed != _zoomed && mounted) {
      setState(() {
        _zoomed = nextZoomed;
      });
    }
  }

  void _resetZoom() {
    _transformController.value = Matrix4.identity();
    if (_zoomed && mounted) {
      setState(() {
        _zoomed = false;
      });
    } else {
      _zoomed = false;
    }
  }

  void _settleZoom() {
    if (_transformController.value.getMaxScaleOnAxis() <= 1.01) {
      _resetZoom();
    } else {
      _syncZoomState();
    }
  }

  void _requestRenderIfNeeded() {
    if (widget.svg != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.svg == null) {
        unawaited(widget.onNeedRender(widget.pageIndex));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final String? pageSvg = widget.svg;
    final _SvgViewport viewport = _SvgViewport.fromSvg(pageSvg);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Trang ${widget.pageNumber}/${widget.pageCount}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(
                color: widget.editing
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).dividerColor,
              ),
              borderRadius: BorderRadius.circular(6),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AspectRatio(
                aspectRatio: viewport.aspectRatio,
                child: InteractiveViewer(
                  transformationController: _transformController,
                  minScale: 1,
                  maxScale: 5,
                  panEnabled: pageSvg != null && _zoomed,
                  scaleEnabled: pageSvg != null,
                  boundaryMargin: EdgeInsets.zero,
                  onInteractionUpdate: (_) => _syncZoomState(),
                  onInteractionEnd: (_) => _settleZoom(),
                  child: LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                          final Size pageSize = Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          );
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: widget.editing && pageSvg != null
                                ? (TapUpDetails details) => unawaited(
                                    widget.onTapPage(
                                      pageIndex: widget.pageIndex,
                                      localPosition: details.localPosition,
                                      pageSize: pageSize,
                                      svg: pageSvg,
                                    ),
                                  )
                                : null,
                            child: Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                if (pageSvg == null)
                                  const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                else
                                  SvgPicture.string(
                                    pageSvg,
                                    fit: BoxFit.contain,
                                    placeholderBuilder: (_) => const Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  ),
                                if (widget.editing && widget.caret != null)
                                  _CaretPainter(
                                    caret: widget.caret!,
                                    viewport: viewport,
                                    pageSize: pageSize,
                                  ),
                              ],
                            ),
                          );
                        },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaretPainter extends StatelessWidget {
  const _CaretPainter({
    required this.caret,
    required this.viewport,
    required this.pageSize,
  });

  final HwpDirectCaret caret;
  final _SvgViewport viewport;
  final Size pageSize;

  @override
  Widget build(BuildContext context) {
    final double left =
        (caret.x - viewport.x) / viewport.width * pageSize.width;
    final double top =
        (caret.y - viewport.y) / viewport.height * pageSize.height;
    final double height = caret.height / viewport.height * pageSize.height;
    return Positioned(
      left: left.clamp(0, pageSize.width - 2),
      top: top.clamp(0, pageSize.height),
      child: Container(
        width: 2,
        height: math.max(2, height),
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

class _SvgViewport {
  const _SvgViewport({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory _SvgViewport.fromSvg(String? svg) {
    final String? value = svg;
    if (value == null) {
      return const _SvgViewport(x: 0, y: 0, width: 210, height: 297);
    }
    final RegExpMatch? match = RegExp(
      r'viewBox="[^"]*?([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)"',
    ).firstMatch(value);
    final double? x = double.tryParse(match?.group(1) ?? '');
    final double? y = double.tryParse(match?.group(2) ?? '');
    final double? width = double.tryParse(match?.group(3) ?? '');
    final double? height = double.tryParse(match?.group(4) ?? '');
    if (x == null ||
        y == null ||
        width == null ||
        height == null ||
        width <= 0 ||
        height <= 0) {
      return const _SvgViewport(x: 0, y: 0, width: 210, height: 297);
    }
    return _SvgViewport(x: x, y: y, width: width, height: height);
  }

  final double x;
  final double y;
  final double width;
  final double height;

  double get aspectRatio => width / height;
}
