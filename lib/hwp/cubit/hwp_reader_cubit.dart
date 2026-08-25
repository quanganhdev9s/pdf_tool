import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../hwp_api.g.dart';
import '../data/hwp_event_log.dart';
import '../models/hwp_direct_caret.dart';
import '../services/hwp_document_service.dart';
import 'hwp_reader_state.dart';

class HwpReaderCubit extends Cubit<HwpReaderState> {
  HwpReaderCubit({HwpDocumentService? service})
    : _service = service ?? HwpDocumentService(),
      super(const HwpReaderState());

  final HwpDocumentService _service;
  final Set<int> _renderingPages = <int>{};
  Future<void> _directEditQueue = Future<void>.value();

  Future<void> openDocument({
    String? assetKey,
    String? filePath,
    int initialPageIndex = 0,
  }) async {
    await _run(() async {
      logHwpEvent('open_document_start', <String, Object?>{
        'asset': assetKey,
        'file': filePath,
      });
      emit(state.copyWith(status: 'Đang mở HWP...'));
      final HwpDocumentInfo info = assetKey != null
          ? await _service.openAsset(assetKey)
          : await _service.openFile(filePath!);

      emit(state.copyWith(status: 'Đang trích xuất text...'));
      final String text = await _service.extractText();
      final int initialPage = _clampPageIndex(initialPageIndex, info.pageCount);
      emit(
        state.copyWith(
          info: info,
          text: text,
          caret: null,
          canUndo: false,
          canRedo: false,
          currentPageIndex: initialPage,
          pageSvgs: List<String?>.filled(info.pageCount, null),
          status: info.pageCount > 0
              ? 'Đang dựng trang ${initialPage + 1}/${info.pageCount}'
              : 'Đã mở ${info.fileName}',
        ),
      );
      await renderPage(
        initialPage,
        force: true,
        reason: 'render_initial_page',
        loadingStatus: info.pageCount > 0
            ? 'Đang dựng trang ${initialPage + 1}/${info.pageCount}'
            : null,
        finalStatus: 'Đã mở ${info.fileName}',
      );
      logHwpEvent('open_document_done', <String, Object?>{
        'file': info.fileName,
        'pages': info.pageCount,
      });
    });
  }

  @override
  Future<void> close() async {
    await _service.close();
    return super.close();
  }

  Future<void> closeDocument() => _service.close();

  void setCurrentPage(int pageIndex) {
    final int currentPage = _clampPageIndex(pageIndex, state.pageCount);
    if (currentPage == state.currentPageIndex) {
      return;
    }
    emit(state.copyWith(currentPageIndex: currentPage));
  }

  Future<void> renderPage(
    int pageIndex, {
    bool force = false,
    String reason = 'render_page',
    String? loadingStatus,
    String? finalStatus,
  }) async {
    if (pageIndex < 0 || pageIndex >= state.pageSvgs.length) {
      if (finalStatus != null) {
        emit(state.copyWith(status: finalStatus));
      }
      return;
    }
    if (!force && state.pageSvgs[pageIndex] != null) {
      if (finalStatus != null) {
        emit(state.copyWith(status: finalStatus));
      }
      logHwpEvent('${reason}_cache_hit', <String, Object?>{
        'page': pageIndex + 1,
        'pages': state.pageSvgs.length,
      });
      return;
    }
    if (_renderingPages.contains(pageIndex)) {
      return;
    }

    _renderingPages.add(pageIndex);
    if (loadingStatus != null) {
      emit(state.copyWith(status: loadingStatus));
    }
    logHwpEvent('${reason}_start', <String, Object?>{
      'page': pageIndex + 1,
      'pages': state.pageSvgs.length,
    });
    try {
      final String svg = await _service.renderPageSvg(pageIndex);
      if (isClosed) {
        return;
      }
      logHwpEvent('${reason}_done', <String, Object?>{
        'page': pageIndex + 1,
        'bytes': svg.length,
      });
      final List<String?> pages = List<String?>.from(state.pageSvgs);
      if (pageIndex < pages.length) {
        pages[pageIndex] = svg;
      }
      emit(
        state.copyWith(pageSvgs: pages, status: finalStatus ?? state.status),
      );
    } finally {
      _renderingPages.remove(pageIndex);
    }
  }

  Future<void> beginEdit() async {
    final HwpDocumentInfo? info = state.info;
    if (state.busy || info == null) {
      return;
    }
    await _run(() async {
      logHwpEvent('edit_prepare_start', <String, Object?>{
        'file': info.fileName,
        'source': info.sourcePath,
      });
      emit(state.copyWith(status: 'Đang vào chế độ chỉnh sửa...'));
      final int activePage = _clampPageIndex(
        state.currentPageIndex,
        info.pageCount,
      );
      emit(
        state.copyWith(
          editing: true,
          caret: null,
          canUndo: false,
          canRedo: false,
          currentPageIndex: activePage,
          status: 'Chạm vào nội dung để đặt con trỏ',
        ),
      );
      logHwpEvent('edit_prepare_done', <String, Object?>{
        'file': info.fileName,
        'source': info.sourcePath,
        'page': activePage + 1,
        'copyCreated': false,
      });
    });
  }

  Future<void> cancelEdit({String? assetKey, String? filePath}) async {
    if (state.busy) {
      return;
    }
    final int currentPage = state.currentPageIndex;
    logHwpEvent('edit_cancel');
    emit(
      state.copyWith(
        editing: false,
        caret: null,
        canUndo: false,
        canRedo: false,
        currentPageIndex: currentPage,
        status: 'Đã huỷ chỉnh sửa',
      ),
    );
    await openDocument(
      assetKey: assetKey,
      filePath: filePath,
      initialPageIndex: currentPage,
    );
  }

  Future<void> undo() async {
    if (state.busy || !state.canUndo) {
      return;
    }
    await _runDirectEdit(() async {
      logHwpEvent('undo_edit_start');
      emit(state.copyWith(status: 'Đang undo...'));
      final HwpEditHistoryState history = await _service.undoEdit();
      await _refreshAfterHistoryChange(history, status: 'Đã undo');
      logHwpEvent('undo_edit_done', <String, Object?>{
        'canUndo': history.canUndo,
        'canRedo': history.canRedo,
        'undoDepth': history.undoDepth,
        'redoDepth': history.redoDepth,
      });
    });
  }

  Future<void> redo() async {
    if (state.busy || !state.canRedo) {
      return;
    }
    await _runDirectEdit(() async {
      logHwpEvent('redo_edit_start');
      emit(state.copyWith(status: 'Đang redo...'));
      final HwpEditHistoryState history = await _service.redoEdit();
      await _refreshAfterHistoryChange(history, status: 'Đã redo');
      logHwpEvent('redo_edit_done', <String, Object?>{
        'canUndo': history.canUndo,
        'canRedo': history.canRedo,
        'undoDepth': history.undoDepth,
        'redoDepth': history.redoDepth,
      });
    });
  }

  Future<void> showEditPage(int pageIndex) async {
    if (state.busy || state.pageSvgs.isEmpty) {
      return;
    }
    final int target = _clampPageIndex(pageIndex, state.pageSvgs.length);
    emit(
      state.copyWith(
        currentPageIndex: target,
        caret: state.caret?.pageIndex == target ? state.caret : null,
        status: state.pageSvgs[target] == null
            ? 'Đang dựng trang ${target + 1}/${state.pageSvgs.length}'
            : 'Chạm vào nội dung để đặt con trỏ',
      ),
    );
    await renderPage(
      target,
      reason: 'edit_page_render',
      loadingStatus: 'Đang dựng trang ${target + 1}/${state.pageSvgs.length}',
      finalStatus: 'Chạm vào nội dung để đặt con trỏ',
    );
  }

  Future<void> saveEdit() async {
    final HwpDocumentInfo? info = state.info;
    if (info == null || state.busy) {
      return;
    }
    await _run(() async {
      logHwpEvent('save_edit_start', <String, Object?>{'file': info.fileName});
      emit(state.copyWith(status: 'Đang lưu HWP...'));
      final HwpSaveEditOutcome save = await _service.saveEditedDocument(info);
      final HwpDocumentInfo savedInfo = save.info;
      emit(state.copyWith(status: 'Đang trích xuất text sau khi lưu...'));
      final String text = await _service.extractText();
      final int currentPage = _clampPageIndex(
        state.currentPageIndex,
        savedInfo.pageCount,
      );
      emit(
        state.copyWith(
          info: savedInfo,
          editing: false,
          caret: null,
          canUndo: false,
          canRedo: false,
          currentPageIndex: currentPage,
          text: text,
          pageSvgs: List<String?>.filled(savedInfo.pageCount, null),
          status: savedInfo.pageCount > 0
              ? 'Đang dựng trang ${currentPage + 1}/${savedInfo.pageCount}'
              : 'Đã lưu ${save.result.fileSizeBytes} bytes',
        ),
      );
      final String finalStatus = save.createdWorkingCopy
          ? 'Đã lưu bản chỉnh sửa: ${savedInfo.fileName}'
          : 'Đã lưu ${save.result.fileSizeBytes} bytes';
      await renderPage(
        currentPage,
        force: true,
        reason: 'save_render_initial_page',
        loadingStatus: savedInfo.pageCount > 0
            ? 'Đang dựng trang ${currentPage + 1}/${savedInfo.pageCount}'
            : null,
        finalStatus: finalStatus,
      );
      logHwpEvent('save_edit_done', <String, Object?>{
        'file': savedInfo.fileName,
        'bytes': save.result.fileSizeBytes,
        'copyCreated': save.createdWorkingCopy,
      });
    });
  }

  Future<bool> placeCaret({
    required int pageIndex,
    required Offset localPosition,
    required Size pageSize,
    required String svg,
  }) async {
    bool didPlaceCaret = false;
    await _runDirectEdit(() async {
      if (state.busy || !state.editing) {
        return;
      }
      final _SvgViewport viewport = _SvgViewport.fromSvg(svg);
      final double x =
          viewport.x + localPosition.dx / pageSize.width * viewport.width;
      final double y =
          viewport.y + localPosition.dy / pageSize.height * viewport.height;
      logHwpEvent('hit_test_start', <String, Object?>{
        'page': pageIndex + 1,
        'x': x.toStringAsFixed(2),
        'y': y.toStringAsFixed(2),
      });
      emit(state.copyWith(status: 'Đang đặt con trỏ...'));
      final String hitJson = await _service.hitTestPage(
        pageIndex: pageIndex,
        x: x,
        y: y,
      );
      final Map<String, dynamic> hit = _decodeObject(hitJson);
      final int? sectionIndex = _readInt(hit, 'sectionIndex', 'sec');
      final int? paragraphIndex = _readInt(hit, 'paragraphIndex', 'para');
      final int? charOffset = _readInt(hit, 'charOffset', 'offset');
      if (sectionIndex == null ||
          paragraphIndex == null ||
          charOffset == null) {
        throw StateError('Vị trí này chưa hỗ trợ chỉnh sửa trực tiếp.');
      }

      final HwpDirectCaret caret = await _cursorFor(
        sectionIndex: sectionIndex,
        paragraphIndex: paragraphIndex,
        charOffset: charOffset,
        fallbackPageIndex: pageIndex,
      );
      emit(
        state.copyWith(
          caret: caret,
          currentPageIndex: caret.pageIndex,
          status: 'Đang chỉnh sửa',
        ),
      );
      didPlaceCaret = true;
      logHwpEvent('hit_test_done', <String, Object?>{
        'page': caret.pageIndex + 1,
        'section': caret.sectionIndex,
        'paragraph': caret.paragraphIndex,
        'offset': caret.charOffset,
      });
    });
    return didPlaceCaret;
  }

  Future<void> insertAtCaret(String text) async {
    final HwpDirectCaret? caret = state.caret;
    if (caret == null || text.isEmpty) {
      return;
    }
    if (text.contains('\n')) {
      await _insertTextWithParagraphBreaks(text);
      return;
    }
    await _runDirectEdit(() async {
      logHwpEvent('insert_text_start', <String, Object?>{
        'section': caret.sectionIndex,
        'paragraph': caret.paragraphIndex,
        'offset': caret.charOffset,
        'chars': text.runes.length,
      });
      emit(state.copyWith(status: 'Đang nhập text...'));
      final String editJson = await _service.insertText(
        sectionIndex: caret.sectionIndex,
        paragraphIndex: caret.paragraphIndex,
        charOffset: caret.charOffset,
        text: text,
      );
      final int nextOffset =
          _readInt(_decodeObject(editJson), 'charOffset') ??
          caret.charOffset + text.runes.length;
      await _refreshAfterDirectEdit(caret.copyWith(charOffset: nextOffset));
      logHwpEvent('insert_text_done', <String, Object?>{
        'nextOffset': nextOffset,
      });
    });
  }

  Future<void> splitParagraphAtCaret() async {
    final HwpDirectCaret? caret = state.caret;
    if (caret == null) {
      return;
    }
    await _runDirectEdit(() async {
      logHwpEvent('split_paragraph_start', <String, Object?>{
        'section': caret.sectionIndex,
        'paragraph': caret.paragraphIndex,
        'offset': caret.charOffset,
      });
      emit(state.copyWith(status: 'Đang xuống dòng...'));
      final String editJson = await _service.splitParagraph(
        sectionIndex: caret.sectionIndex,
        paragraphIndex: caret.paragraphIndex,
        charOffset: caret.charOffset,
      );
      final Map<String, dynamic> edit = _decodeObject(editJson);
      final int nextParagraphIndex =
          _readInt(edit, 'paraIdx', 'paragraphIndex') ??
          caret.paragraphIndex + 1;
      final int nextOffset = _readInt(edit, 'charOffset') ?? 0;
      await _refreshAfterDirectEdit(
        caret.copyWith(
          paragraphIndex: nextParagraphIndex,
          charOffset: nextOffset,
        ),
      );
      logHwpEvent('split_paragraph_done', <String, Object?>{
        'paragraph': nextParagraphIndex,
        'offset': nextOffset,
      });
    });
  }

  Future<void> deleteBackward() async {
    final HwpDirectCaret? caret = state.caret;
    if (caret == null) {
      return;
    }
    if (caret.charOffset <= 0) {
      await _mergeParagraphAtCaret();
      return;
    }
    await _runDirectEdit(() async {
      final int nextOffset = math.max(0, caret.charOffset - 1);
      logHwpEvent('delete_text_start', <String, Object?>{
        'section': caret.sectionIndex,
        'paragraph': caret.paragraphIndex,
        'offset': nextOffset,
      });
      emit(state.copyWith(status: 'Đang xoá text...'));
      final String editJson = await _service.deleteText(
        sectionIndex: caret.sectionIndex,
        paragraphIndex: caret.paragraphIndex,
        charOffset: nextOffset,
        count: 1,
      );
      await _refreshAfterDirectEdit(
        caret.copyWith(
          charOffset:
              _readInt(_decodeObject(editJson), 'charOffset') ?? nextOffset,
        ),
      );
      logHwpEvent('delete_text_done', <String, Object?>{'offset': nextOffset});
    });
  }

  Future<void> _insertTextWithParagraphBreaks(String text) async {
    final List<String> parts = text.split('\n');
    for (int index = 0; index < parts.length; index += 1) {
      final String part = parts[index];
      if (part.isNotEmpty) {
        await insertAtCaret(part);
      }
      if (index < parts.length - 1) {
        await splitParagraphAtCaret();
      }
    }
  }

  Future<void> _mergeParagraphAtCaret() async {
    final HwpDirectCaret? caret = state.caret;
    if (caret == null || caret.paragraphIndex <= 0) {
      return;
    }
    await _runDirectEdit(() async {
      logHwpEvent('merge_paragraph_start', <String, Object?>{
        'section': caret.sectionIndex,
        'paragraph': caret.paragraphIndex,
      });
      emit(state.copyWith(status: 'Đang gộp dòng...'));
      final String editJson = await _service.mergeParagraph(
        sectionIndex: caret.sectionIndex,
        paragraphIndex: caret.paragraphIndex,
      );
      final Map<String, dynamic> edit = _decodeObject(editJson);
      final int mergedParagraphIndex =
          _readInt(edit, 'paraIdx', 'paragraphIndex') ??
          caret.paragraphIndex - 1;
      final int mergedOffset = _readInt(edit, 'charOffset') ?? 0;
      await _refreshAfterDirectEdit(
        caret.copyWith(
          paragraphIndex: mergedParagraphIndex,
          charOffset: mergedOffset,
        ),
      );
      logHwpEvent('merge_paragraph_done', <String, Object?>{
        'paragraph': mergedParagraphIndex,
        'offset': mergedOffset,
      });
    });
  }

  Future<void> _refreshAfterDirectEdit(HwpDirectCaret caret) async {
    logHwpEvent('edit_refresh_start', <String, Object?>{
      'section': caret.sectionIndex,
      'paragraph': caret.paragraphIndex,
      'offset': caret.charOffset,
    });
    emit(state.copyWith(status: 'Đang cập nhật trang...'));
    final HwpDirectCaret updatedCaret = await _cursorFor(
      sectionIndex: caret.sectionIndex,
      paragraphIndex: caret.paragraphIndex,
      charOffset: caret.charOffset,
      fallbackPageIndex: caret.pageIndex,
    );
    final HwpDocumentInfo info = await _service.currentInfo();
    final HwpEditHistoryState history = await _service.editHistoryState();
    final int activePage = _clampPageIndex(
      updatedCaret.pageIndex,
      info.pageCount,
    );
    final List<String?> pages = List<String?>.filled(info.pageCount, null);
    if (pages.isNotEmpty) {
      logHwpEvent('edit_invalidate_page_cache', <String, Object?>{
        'allPages': true,
        'pages': pages.length,
      });
      logHwpEvent('edit_render_active_page_start', <String, Object?>{
        'page': activePage + 1,
        'pages': info.pageCount,
      });
      pages[activePage] = await _service.renderPageSvg(activePage);
      logHwpEvent('edit_render_active_page_done', <String, Object?>{
        'page': activePage + 1,
        'bytes': pages[activePage]?.length,
      });
    }
    emit(
      state.copyWith(
        info: info,
        caret: updatedCaret,
        canUndo: history.canUndo,
        canRedo: history.canRedo,
        currentPageIndex: activePage,
        pageSvgs: pages,
        status: 'Đang chỉnh sửa',
      ),
    );
    logHwpEvent('edit_refresh_done', <String, Object?>{
      'page': activePage + 1,
      'pages': info.pageCount,
      'caretOffset': updatedCaret.charOffset,
      'canUndo': history.canUndo,
      'canRedo': history.canRedo,
    });
  }

  Future<void> _refreshAfterHistoryChange(
    HwpEditHistoryState history, {
    required String status,
  }) async {
    final HwpDocumentInfo info = await _service.currentInfo();
    final int activePage = state.activePageIndex(info.pageCount);
    final List<String?> pages = List<String?>.filled(info.pageCount, null);
    logHwpEvent('edit_invalidate_page_cache', <String, Object?>{
      'allPages': true,
      'pages': pages.length,
      'reason': 'history',
    });
    if (pages.isNotEmpty) {
      logHwpEvent('edit_render_active_page_start', <String, Object?>{
        'page': activePage + 1,
        'pages': info.pageCount,
        'reason': 'history',
      });
      pages[activePage] = await _service.renderPageSvg(activePage);
      logHwpEvent('edit_render_active_page_done', <String, Object?>{
        'page': activePage + 1,
        'bytes': pages[activePage]?.length,
        'reason': 'history',
      });
    }
    emit(
      state.copyWith(
        info: info,
        caret: null,
        canUndo: history.canUndo,
        canRedo: history.canRedo,
        currentPageIndex: activePage,
        pageSvgs: pages,
        status: status,
      ),
    );
  }

  Future<HwpDirectCaret> _cursorFor({
    required int sectionIndex,
    required int paragraphIndex,
    required int charOffset,
    required int fallbackPageIndex,
  }) async {
    final String rectJson = await _service.getCursorRect(
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset,
    );
    final Map<String, dynamic> rect = _decodeObject(rectJson);
    return HwpDirectCaret(
      pageIndex: _readInt(rect, 'pageIndex') ?? fallbackPageIndex,
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset,
      x: _readDouble(rect, 'x') ?? 0,
      y: _readDouble(rect, 'y') ?? 0,
      height: _readDouble(rect, 'height') ?? 16,
    );
  }

  Future<void> _runDirectEdit(Future<void> Function() action) async {
    _directEditQueue = _directEditQueue.then((_) async {
      try {
        await action();
      } on PlatformException catch (error) {
        logHwpEvent('direct_edit_failed', <String, Object?>{
          'code': error.code,
          'message': error.message,
        });
        emit(
          state.copyWith(
            status: '${error.code}: ${error.message ?? 'Thao tác thất bại'}',
          ),
        );
      } catch (error) {
        logHwpEvent('direct_edit_failed', <String, Object?>{'error': error});
        emit(state.copyWith(status: error.toString()));
      }
    });
    await _directEditQueue;
  }

  Future<void> _run(Future<void> Function() action) async {
    emit(state.copyWith(busy: true));
    try {
      await action();
    } on PlatformException catch (error) {
      logHwpEvent('operation_failed', <String, Object?>{
        'code': error.code,
        'message': error.message,
      });
      emit(
        state.copyWith(
          status: '${error.code}: ${error.message ?? 'Thao tác thất bại'}',
        ),
      );
    } catch (error) {
      logHwpEvent('operation_failed', <String, Object?>{'error': error});
      emit(state.copyWith(status: error.toString()));
    } finally {
      if (!isClosed) {
        emit(state.copyWith(busy: false));
      }
    }
  }

  int _clampPageIndex(int pageIndex, int pageCount) {
    if (pageCount <= 0) {
      return 0;
    }
    return math.min(math.max(pageIndex, 0), pageCount - 1);
  }

  Map<String, dynamic> _decodeObject(String json) {
    final Object? decoded = jsonDecode(json);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{};
  }

  int? _readInt(Map<String, dynamic> value, String key, [String? fallback]) {
    final Object? raw =
        value[key] ?? (fallback == null ? null : value[fallback]);
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    if (raw is String) {
      return int.tryParse(raw);
    }
    return null;
  }

  double? _readDouble(Map<String, dynamic> value, String key) {
    final Object? raw = value[key];
    if (raw is num) {
      return raw.toDouble();
    }
    if (raw is String) {
      return double.tryParse(raw);
    }
    return null;
  }
}

class _SvgViewport {
  const _SvgViewport({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory _SvgViewport.fromSvg(String svg) {
    final RegExpMatch? match = RegExp(
      r'viewBox="[^"]*?([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)"',
    ).firstMatch(svg);
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
}
