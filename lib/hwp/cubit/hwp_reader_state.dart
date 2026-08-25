import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../hwp_api.g.dart';
import '../models/hwp_direct_caret.dart';

const Object _unset = Object();

@immutable
class HwpReaderState {
  const HwpReaderState({
    this.info,
    this.text = '',
    this.pageSvgs = const <String?>[],
    this.status = 'Đang mở HWP...',
    this.busy = false,
    this.editing = false,
    this.canUndo = false,
    this.canRedo = false,
    this.currentPageIndex = 0,
    this.dirtyPages = const <int>{},
    this.visiblePageIndexes = const <int>{},
    this.renderingPages = const <int>{},
    this.renderRevision = 0,
    this.caret,
  });

  final HwpDocumentInfo? info;
  final String text;
  final List<String?> pageSvgs;
  final String status;
  final bool busy;
  final bool editing;
  final bool canUndo;
  final bool canRedo;
  final int currentPageIndex;

  // Những trang có SVG cache có thể đã cũ sau khi document reflow/paginate.
  // Page dirty vẫn có thể hiển thị SVG cũ tạm thời, nhưng phải render lại khi
  // nó đang visible hoặc sắp visible.
  final Set<int> dirtyPages;

  // Các trang đang nằm trong viewport, do widget layer đo bằng GlobalKey rồi
  // báo xuống Cubit. Cubit dùng tập này để ưu tiên render dirty page trước.
  final Set<int> visiblePageIndexes;

  // Các trang đang có request render native chạy. Field này giúp tránh bắn
  // nhiều request render trùng một trang trong lúc user scroll/gõ nhanh.
  final Set<int> renderingPages;

  // Tăng sau mỗi edit làm layout thay đổi. Kết quả render cũ mang revision thấp
  // sẽ bị bỏ qua để tránh ghi đè SVG mới khi người dùng gõ nhanh.
  final int renderRevision;

  final HwpDirectCaret? caret;

  int get pageCount => info?.pageCount ?? pageSvgs.length;

  int activePageIndex([int? count]) {
    final int pageCount = count ?? pageSvgs.length;
    if (pageCount <= 0) {
      return 0;
    }
    return math.min(math.max(currentPageIndex, 0), pageCount - 1);
  }

  HwpReaderState copyWith({
    Object? info = _unset,
    String? text,
    List<String?>? pageSvgs,
    String? status,
    bool? busy,
    bool? editing,
    bool? canUndo,
    bool? canRedo,
    int? currentPageIndex,
    Set<int>? dirtyPages,
    Set<int>? visiblePageIndexes,
    Set<int>? renderingPages,
    int? renderRevision,
    Object? caret = _unset,
  }) {
    return HwpReaderState(
      info: identical(info, _unset) ? this.info : info as HwpDocumentInfo?,
      text: text ?? this.text,
      pageSvgs: pageSvgs ?? this.pageSvgs,
      status: status ?? this.status,
      busy: busy ?? this.busy,
      editing: editing ?? this.editing,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
      currentPageIndex: currentPageIndex ?? this.currentPageIndex,
      dirtyPages: dirtyPages ?? this.dirtyPages,
      visiblePageIndexes: visiblePageIndexes ?? this.visiblePageIndexes,
      renderingPages: renderingPages ?? this.renderingPages,
      renderRevision: renderRevision ?? this.renderRevision,
      caret: identical(caret, _unset) ? this.caret : caret as HwpDirectCaret?,
    );
  }
}
