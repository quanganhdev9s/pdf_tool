import 'package:flutter/material.dart';

import '../../pdf_poc_api.g.dart';

/// Thanh lật trang của trình xem HWP.
///
/// Trang vỏ chỉ dựng một trang mỗi lúc, nên đây là đường duy nhất để đọc phần
/// còn lại — thanh này hiện cả khi chỉ xem. `pageCount` đổi được ngay trong lúc
/// gõ, nên đọc thẳng từ [state] chứ không nhớ lại.
class HwpPageBar extends StatelessWidget {
  const HwpPageBar({super.key, required this.state, required this.onGoToPage});

  final HwpEditorState? state;
  final ValueChanged<int> onGoToPage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editor = state;
    // Chưa có trạng thái: coi như một trang thay vì hiện thanh trống.
    final count = editor?.pageCount ?? 1;
    final index = editor?.pageIndex ?? 0;

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SizedBox(
        height: 44,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Trang trước',
              onPressed: index > 0 ? () => onGoToPage(index - 1) : null,
            ),
            ConstrainedBox(
              // Chốt bề rộng để nhãn không nhảy khi số trang lên hai chữ số.
              constraints: const BoxConstraints(minWidth: 76),
              child: Text(
                '${index + 1} / $count',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Trang sau',
              onPressed: index < count - 1 ? () => onGoToPage(index + 1) : null,
            ),
          ],
        ),
      ),
    );
  }
}
