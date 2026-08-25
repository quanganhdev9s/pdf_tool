import 'package:flutter/material.dart';

import '../../pdf_poc_api.g.dart';

/// Thanh công cụ của trình soạn thảo HWP.
///
/// Native chỉ vẽ tài liệu; mọi thứ bấm được nằm ở đây. Trạng thái bật/tắt của
/// từng nút đến từ [state], là ảnh chụp con trỏ mà trang vỏ đẩy lên sau mỗi
/// lần nó nhúc nhích.
///
/// Không có nút màu chữ và nút đổi font. rhwp 0.8.4 đọc ra được màu chữ nhưng
/// không có đường ghi vào — `applyCharFormat` không nhận khoá `textColor`, và
/// `pasteHtml` cũng không nhận `color`. Font thì không có API nào liệt kê font
/// của tài liệu, mà đưa một danh sách bịa ra thì chữ sẽ lặng lẽ rơi về font
/// thay thế. Cả hai để lại thì chỉ là hứa suông.
class HwpEditorToolBar extends StatelessWidget {
  const HwpEditorToolBar({
    super.key,
    required this.state,
    required this.busy,
    required this.onCharFormat,
    required this.onParaFormat,
    required this.onUndo,
    required this.onRedo,
  });

  final HwpEditorState? state;
  final bool busy;
  final ValueChanged<HwpCharFormat> onCharFormat;
  final ValueChanged<HwpParaFormat> onParaFormat;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  /// Các cỡ chữ mà nút tăng/giảm nhảy qua. Cùng nấc với hộp cỡ chữ của Hancom.
  static const List<double> _sizes = <double>[
    8,
    9,
    10,
    11,
    12,
    14,
    16,
    18,
    20,
    22,
    24,
    28,
    32,
    36,
    48,
    72,
  ];

  bool get _enabled => !busy && (state?.hasCaret ?? false);

  @override
  Widget build(BuildContext context) {
    final editor = state;
    final size = editor?.fontSizePt;

    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (busy) const LinearProgressIndicator(),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _Button(
                    icon: Icons.undo,
                    tooltip: 'Hoàn tác',
                    onPressed: !busy && (editor?.canUndo ?? false)
                        ? onUndo
                        : null,
                  ),
                  _Button(
                    icon: Icons.redo,
                    tooltip: 'Làm lại',
                    onPressed: !busy && (editor?.canRedo ?? false)
                        ? onRedo
                        : null,
                  ),
                  const _Divider(),
                  _Button(
                    icon: Icons.format_bold,
                    tooltip: 'Đậm',
                    selected: editor?.bold ?? false,
                    onPressed: _enabled
                        ? () => onCharFormat(
                            HwpCharFormat(bold: !(editor?.bold ?? false)),
                          )
                        : null,
                  ),
                  _Button(
                    icon: Icons.format_italic,
                    tooltip: 'Nghiêng',
                    selected: editor?.italic ?? false,
                    onPressed: _enabled
                        ? () => onCharFormat(
                            HwpCharFormat(italic: !(editor?.italic ?? false)),
                          )
                        : null,
                  ),
                  _Button(
                    icon: Icons.format_underlined,
                    tooltip: 'Gạch chân',
                    selected: editor?.underline ?? false,
                    onPressed: _enabled
                        ? () => onCharFormat(
                            HwpCharFormat(
                              underline: !(editor?.underline ?? false),
                            ),
                          )
                        : null,
                  ),
                  _Button(
                    icon: Icons.format_strikethrough,
                    tooltip: 'Gạch ngang',
                    selected: editor?.strikethrough ?? false,
                    onPressed: _enabled
                        ? () => onCharFormat(
                            HwpCharFormat(
                              strikethrough: !(editor?.strikethrough ?? false),
                            ),
                          )
                        : null,
                  ),
                  const _Divider(),
                  _Button(
                    icon: Icons.remove,
                    tooltip: 'Nhỏ hơn',
                    onPressed: _enabled
                        ? () => onCharFormat(
                            HwpCharFormat(fontSizePt: _stepSize(size, -1)),
                          )
                        : null,
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      size == null ? '–' : _formatSize(size),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  _Button(
                    icon: Icons.add,
                    tooltip: 'Lớn hơn',
                    onPressed: _enabled
                        ? () => onCharFormat(
                            HwpCharFormat(fontSizePt: _stepSize(size, 1)),
                          )
                        : null,
                  ),
                  const _Divider(),
                  _Button(
                    icon: Icons.format_align_left,
                    tooltip: 'Canh trái',
                    selected: editor?.alignment == 'left',
                    onPressed: _enabled
                        ? () => onParaFormat(HwpParaFormat(alignment: 'left'))
                        : null,
                  ),
                  _Button(
                    icon: Icons.format_align_center,
                    tooltip: 'Canh giữa',
                    selected: editor?.alignment == 'center',
                    onPressed: _enabled
                        ? () => onParaFormat(HwpParaFormat(alignment: 'center'))
                        : null,
                  ),
                  _Button(
                    icon: Icons.format_align_right,
                    tooltip: 'Canh phải',
                    selected: editor?.alignment == 'right',
                    onPressed: _enabled
                        ? () => onParaFormat(HwpParaFormat(alignment: 'right'))
                        : null,
                  ),
                  _Button(
                    icon: Icons.format_align_justify,
                    tooltip: 'Canh đều',
                    selected: editor?.alignment == 'justify',
                    onPressed: _enabled
                        ? () =>
                              onParaFormat(HwpParaFormat(alignment: 'justify'))
                        : null,
                  ),
                  const _Divider(),
                  _LineSpacingButton(
                    value: editor?.lineSpacing,
                    onSelected: _enabled
                        ? (value) =>
                              onParaFormat(HwpParaFormat(lineSpacing: value))
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Nhảy sang nấc cỡ chữ kế tiếp. Cỡ hiện tại thường không nằm đúng trên một
  /// nấc, nên tìm nấc gần nhất rồi mới bước.
  static double _stepSize(double? current, int delta) {
    final from = current ?? 10;
    var index = 0;
    for (var i = 0; i < _sizes.length; i += 1) {
      if (_sizes[i] <= from) index = i;
    }
    if (delta > 0 && _sizes[index] < from) index += 1;
    final next = (index + delta).clamp(0, _sizes.length - 1);
    return _sizes[next];
  }

  static String _formatSize(double size) {
    return size == size.roundToDouble()
        ? size.round().toString()
        : size.toStringAsFixed(1);
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    final foreground = !enabled
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38)
        : selected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: selected && enabled
                  ? theme.colorScheme.secondaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, size: 22, color: foreground),
          ),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

/// Giãn dòng là phần trăm, đúng đơn vị rhwp dùng cho `lineSpacingType`
/// `Percent` — mặc định của HWP là 160.
class _LineSpacingButton extends StatelessWidget {
  const _LineSpacingButton({required this.value, required this.onSelected});

  final double? value;
  final ValueChanged<double>? onSelected;

  static const List<double> _options = <double>[100, 130, 160, 200, 250];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onSelected != null;

    return PopupMenuButton<double>(
      enabled: enabled,
      tooltip: 'Giãn dòng',
      onSelected: (selected) => onSelected?.call(selected),
      itemBuilder: (context) => <PopupMenuEntry<double>>[
        for (final option in _options)
          CheckedPopupMenuItem<double>(
            value: option,
            checked: value != null && (value! - option).abs() < 0.5,
            child: Text('${option.round()}%'),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.format_line_spacing,
              size: 22,
              color: enabled
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}
