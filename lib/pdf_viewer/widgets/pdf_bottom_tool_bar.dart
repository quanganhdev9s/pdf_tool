import 'package:flutter/material.dart';

enum PdfControlPanelMode {
  pages,
  search,
  ink,
  freeText,
  textEdit,
  signature,
  pageOperations,
  ocr,
  compression,
  splitMerge,
  convert,
  documentViewer,
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
                            label: 'Pages',
                            tooltip: 'Page controls',
                            icon: Icons.menu_book_outlined,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.search,
                            activeMode: activeMode,
                            label: 'Search',
                            tooltip: 'Search',
                            icon: Icons.search,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.ink,
                            activeMode: activeMode,
                            label: 'Ink',
                            tooltip: 'Ink',
                            icon: Icons.draw_outlined,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.freeText,
                            activeMode: activeMode,
                            label: 'Text',
                            tooltip: 'Free text',
                            icon: Icons.text_fields,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.textEdit,
                            activeMode: activeMode,
                            label: 'Edit text',
                            tooltip: 'Edit existing text',
                            icon: Icons.edit_note_outlined,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.signature,
                            activeMode: activeMode,
                            label: 'Sign',
                            tooltip: 'Electronic signature',
                            icon: Icons.gesture,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.pageOperations,
                            activeMode: activeMode,
                            label: 'Organize',
                            tooltip: 'Page operations',
                            icon: Icons.auto_stories_outlined,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.ocr,
                            activeMode: activeMode,
                            label: 'OCR',
                            tooltip: 'OCR',
                            icon: Icons.document_scanner_outlined,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.compression,
                            activeMode: activeMode,
                            label: 'Compress',
                            tooltip: 'Compression',
                            icon: Icons.compress,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.splitMerge,
                            activeMode: activeMode,
                            label: 'Split',
                            tooltip: 'Split/Merge',
                            icon: Icons.call_split,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.convert,
                            activeMode: activeMode,
                            label: 'Convert',
                            tooltip: 'Convert to PDF',
                            icon: Icons.file_present_outlined,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.documentViewer,
                            activeMode: activeMode,
                            label: 'Open',
                            tooltip: 'Open a document to view',
                            icon: Icons.folder_open_outlined,
                            onPressed: onModePressed,
                          ),
                          _ToolbarIcon(
                            mode: PdfControlPanelMode.status,
                            activeMode: activeMode,
                            label: 'Status',
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
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final PdfControlPanelMode mode;
  final PdfControlPanelMode? activeMode;

  /// Short caption under the icon. The full wording stays in [tooltip].
  final String label;
  final String tooltip;
  final IconData icon;
  final ValueChanged<PdfControlPanelMode> onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = activeMode == mode;
    final foreground = selected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onPressed(mode),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? theme.colorScheme.secondaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, size: 22, color: foreground),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
