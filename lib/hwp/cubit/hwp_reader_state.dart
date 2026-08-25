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
      caret: identical(caret, _unset) ? this.caret : caret as HwpDirectCaret?,
    );
  }
}
