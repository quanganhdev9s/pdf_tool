import 'package:flutter/material.dart';

enum PdfControlPanelMode {
  pages,
  search,
  ink,
  freeText,
  signature,
  pageOperations,
  ocr,
  compression,
  status,
}

class PdfBottomToolBar extends StatelessWidget {
  const PdfBottomToolBar({
    super.key,
    required this.activeMode,
    required this.busy,
    required this.onModePressed,
  });

  final PdfControlPanelMode? activeMode;
  final bool busy;
  final ValueChanged<PdfControlPanelMode> onModePressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (busy) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: constraints.maxWidth,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: <Widget>[
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.pages,
                            activeMode: activeMode,
                            tooltip: 'Page controls',
                            icon: Icons.menu_book_outlined,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.search,
                            activeMode: activeMode,
                            tooltip: 'Search',
                            icon: Icons.search,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.ink,
                            activeMode: activeMode,
                            tooltip: 'Ink',
                            icon: Icons.draw_outlined,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.freeText,
                            activeMode: activeMode,
                            tooltip: 'Free text',
                            icon: Icons.text_fields,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.signature,
                            activeMode: activeMode,
                            tooltip: 'Electronic signature',
                            icon: Icons.gesture,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.pageOperations,
                            activeMode: activeMode,
                            tooltip: 'Page operations',
                            icon: Icons.auto_stories_outlined,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.ocr,
                            activeMode: activeMode,
                            tooltip: 'OCR',
                            icon: Icons.document_scanner_outlined,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.compression,
                            activeMode: activeMode,
                            tooltip: 'Compression',
                            icon: Icons.compress,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.status,
                            activeMode: activeMode,
                            tooltip: 'Status',
                            icon: Icons.info_outline,
                            onPressed: onModePressed,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarIcon extends StatelessWidget {
  const _ToolbarIcon({
    required this.mode,
    required this.activeMode,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final PdfControlPanelMode mode;
  final PdfControlPanelMode? activeMode;
  final String tooltip;
  final IconData icon;
  final ValueChanged<PdfControlPanelMode> onPressed;

  @override
  Widget build(BuildContext context) {
    final selected = activeMode == mode;
    final child = Icon(icon);
    if (selected) {
      return IconButton.filledTonal(
        tooltip: tooltip,
        onPressed: () => onPressed(mode),
        icon: child,
      );
    }
    return IconButton(
      tooltip: tooltip,
      onPressed: () => onPressed(mode),
      icon: child,
    );
  }
}
