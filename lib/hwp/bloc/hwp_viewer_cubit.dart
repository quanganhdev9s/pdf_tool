import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../common/event_log.dart';
import '../hwp_api.g.dart';

/// Trạng thái màn xem HWP: ảnh chụp con trỏ mà trang vỏ đẩy lên, cộng trạng
/// thái điều khiển của màn hình.
class HwpViewerState {
  const HwpViewerState({
    this.editor,
    this.editing = false,
    this.busy = false,
    this.searching = false,
    this.showDetails = false,
    this.lastSearchFound,
  });

  final HwpEditorState? editor;

  /// Tắt là **bỏ mọi thay đổi chưa lưu**.
  final bool editing;

  /// Có lệnh đang chạy dưới native; khoá nút trong lúc đó.
  final bool busy;
  final bool searching;
  final bool showDetails;

  /// `null` là chưa tìm lần nào.
  final bool? lastSearchFound;

  bool get dirty => editor?.dirty ?? false;

  HwpViewerState copyWith({
    HwpEditorState? editor,
    bool clearEditor = false,
    bool? editing,
    bool? busy,
    bool? searching,
    bool? showDetails,
    bool? lastSearchFound,
    bool clearLastSearchFound = false,
  }) {
    return HwpViewerState(
      editor: clearEditor ? null : (editor ?? this.editor),
      editing: editing ?? this.editing,
      busy: busy ?? this.busy,
      searching: searching ?? this.searching,
      showDetails: showDetails ?? this.showDetails,
      lastSearchFound: clearLastSearchFound
          ? null
          : (lastSearchFound ?? this.lastSearchFound),
    );
  }

  @override
  bool operator ==(Object other) {
    // `HwpEditorState` do Pigeon sinh nên không có `==`; mỗi lần trang vỏ báo
    // về là một đối tượng mới nên so tham chiếu là đủ.
    return other is HwpViewerState &&
        identical(other.editor, editor) &&
        other.editing == editing &&
        other.busy == busy &&
        other.searching == searching &&
        other.showDetails == showDetails &&
        other.lastSearchFound == lastSearchFound;
  }

  @override
  int get hashCode => Object.hash(
    identityHashCode(editor),
    editing,
    busy,
    searching,
    showDetails,
    lastSearchFound,
  );
}

/// Nối màn hình HWP với trình xem native.
///
/// Là `HwpFlutterApi`, tức đầu nhận mọi callback từ native. Chỉ đăng ký được
/// một cái mỗi lúc, nên vòng đời của nó phải trùng với vòng đời của route.
class HwpViewerCubit extends Cubit<HwpViewerState> implements HwpFlutterApi {
  HwpViewerCubit({required this.document, HwpHostApi? api})
    : _api = api ?? HwpHostApi(),
      super(const HwpViewerState()) {
    logPdfEvent('hwp_cubit_init', <String, Object?>{
      'file': document.fileName,
      'bytes': document.fileSizeBytes,
    });
    HwpFlutterApi.setUp(this);
  }

  final HwpDocument document;
  final HwpHostApi _api;

  /// Đợi kết quả của lần lưu đang chạy, nếu có.
  Completer<HwpSaveResult>? _pendingSave;

  /// Màn hình gọi khi platform view đã lên. Trước đó không có gì để nạp vào.
  Future<void> loadIntoViewer() async {
    logPdfEvent('hwp_load_into_viewer', <String, Object?>{
      'path': document.path,
      'sourceIsAsset': document.sourceIsAsset,
    });
    await _api.loadDocument(document.path, document.sourceIsAsset);
    // Từ đây trở đi là việc của native, nó có đồng hồ riêng.
    stopPdfEventClock();
  }

  /// Bật/tắt chế độ sửa.
  ///
  /// Tắt sẽ **bỏ mọi thay đổi chưa lưu** — chúng chỉ nằm trong trình soạn thảo.
  /// Lỗi chỉ ghi log: không emit `editing` là giữ nguyên trạng thái cũ.
  Future<void> setEditing(bool enabled) async {
    logPdfEvent('hwp_set_editing', <String, Object?>{'enabled': enabled});
    emit(state.copyWith(busy: true));
    try {
      await _api.setEditingEnabled(enabled);
      if (!isClosed) emit(state.copyWith(editing: enabled));
    } on PlatformException catch (error) {
      logPdfEvent('hwp_set_editing_failed', <String, Object?>{
        'code': error.code,
        'message': error.message,
      });
    } finally {
      if (!isClosed) emit(state.copyWith(busy: false));
    }
  }

  /// Ghi bản đang sửa, ưu tiên đè lên tệp đang mở, và **đợi kết quả thật**.
  ///
  /// `saveEdits` bên native trả về ngay — việc xuất chạy bất đồng bộ trong
  /// trang vỏ. Kết quả về sau, qua `onEditsSaved`; chỗ này nối hai đầu đó lại
  /// để màn hình biết nó đã lưu xong hay hỏng, thay vì đoán.
  Future<HwpSaveResult> saveEdits() async {
    emit(state.copyWith(busy: true));
    try {
      final Completer<HwpSaveResult> completer = Completer<HwpSaveResult>();
      _pendingSave = completer;
      try {
        await _api.saveEdits();
      } on PlatformException catch (error) {
        logPdfEvent('hwp_save_failed', <String, Object?>{
          'code': error.code,
          'message': error.message,
        });
        _pendingSave = null;
        rethrow;
      }
      return await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _pendingSave = null;
          logPdfEvent('hwp_save_timeout');
          return HwpSaveResult(ok: false, error: 'Quá thời gian chờ lưu tệp.');
        },
      );
    } finally {
      if (!isClosed) emit(state.copyWith(busy: false));
    }
  }

  Future<void> applyCharFormat(HwpCharFormat format) => _ignoringClosedViewer(
    'hwp_apply_char_format',
    () => _api.applyCharFormat(format),
  );

  Future<void> applyParaFormat(HwpParaFormat format) => _ignoringClosedViewer(
    'hwp_apply_para_format',
    () => _api.applyParaFormat(format),
  );

  Future<void> undo() => _ignoringClosedViewer('hwp_undo', _api.undo);

  Future<void> redo() => _ignoringClosedViewer('hwp_redo', _api.redo);

  /// Lật tới trang [pageIndex], đếm từ 0.
  ///
  /// Không tự cập nhật state: trang vỏ mới là nơi biết nó dừng ở trang nào sau
  /// khi kẹp chỉ số, và nó báo ngược lên qua `onEditorStateChanged`.
  Future<void> goToPage(int pageIndex) =>
      _ignoringClosedViewer('hwp_go_to_page', () => _api.goToPage(pageIndex));

  /// Báo phần đáy web view mà thanh công cụ Flutter đang che.
  Future<void> setChromeInset(double pixels) => _ignoringClosedViewer(
    'hwp_set_chrome_inset',
    () => _api.setChromeInset(pixels),
  );

  Future<void> clearSearch() =>
      _ignoringClosedViewer('hwp_clear_search', _api.clearSearch);

  Future<void> share() => _ignoringClosedViewer('hwp_share', _api.share);

  void startSearch() => emit(state.copyWith(searching: true));

  /// Đóng ô tìm kiếm và xoá cả vệt tô trong tài liệu.
  void stopSearch() {
    clearSearch();
    emit(state.copyWith(searching: false, clearLastSearchFound: true));
  }

  void toggleDetails() => emit(state.copyWith(showDetails: !state.showDetails));

  /// Kết quả về qua `state.lastSearchFound`.
  Future<void> find(String query, {bool forward = true}) async {
    bool found;
    try {
      found = await _api.find(query, forward);
    } on PlatformException catch (error) {
      logPdfEvent('hwp_find_failed', <String, Object?>{
        'code': error.code,
        'message': error.message,
      });
      found = false;
    }
    if (!isClosed) emit(state.copyWith(lastSearchFound: found));
  }

  Future<void> closeViewer() async {
    emit(state.copyWith(clearEditor: true));
    await _ignoringClosedViewer('hwp_close', _api.close);
  }

  /// Lệnh gửi tới một trình xem đã đóng thì không có gì để làm — người dùng đã
  /// rời màn hình, và nó **không** phải lỗi đáng báo lên giao diện.
  Future<void> _ignoringClosedViewer(
    String event,
    Future<void> Function() body,
  ) async {
    try {
      await body();
    } on PlatformException catch (error) {
      logPdfEvent('${event}_ignored', <String, Object?>{'code': error.code});
    }
  }

  @override
  void onEditorStateChanged(HwpEditorState state) {
    // Không log: cái này bắn ra sau mỗi lần con trỏ nhúc nhích.
    if (!isClosed) emit(this.state.copyWith(editor: state));
  }

  @override
  void onEditsSaved(HwpSaveResult result) {
    logPdfEvent('hwp_edits_saved', <String, Object?>{
      'ok': result.ok,
      'contentLoss': result.contentLoss?.length ?? 0,
      'error': result.error,
      'savedPath': result.savedPath,
      'savedAsFallback': result.savedAsFallback,
    });
    final Completer<HwpSaveResult>? pending = _pendingSave;
    _pendingSave = null;
    if (pending != null && !pending.isCompleted) pending.complete(result);

    // Ghi xong thì không còn thay đổi chưa lưu. Trang vỏ cũng gửi state mới,
    // nhưng nó tới sau và màn hình không nên nhấp nháy "chưa lưu" ở giữa.
    final HwpEditorState? editor = state.editor;
    if (result.ok && editor != null && !isClosed) {
      emit(state.copyWith(editor: _withDirty(editor, false)));
    }
  }

  /// `HwpEditorState` do Pigeon sinh nên không có `copyWith`.
  static HwpEditorState _withDirty(HwpEditorState from, bool dirty) {
    return HwpEditorState(
      hasCaret: from.hasCaret,
      hasSelection: from.hasSelection,
      bold: from.bold,
      italic: from.italic,
      underline: from.underline,
      strikethrough: from.strikethrough,
      fontSizePt: from.fontSizePt,
      alignment: from.alignment,
      lineSpacing: from.lineSpacing,
      canUndo: from.canUndo,
      canRedo: from.canRedo,
      dirty: dirty,
      pageIndex: from.pageIndex,
      pageCount: from.pageCount,
    );
  }

  @override
  Future<void> close() async {
    logPdfEvent('hwp_cubit_dispose', <String, Object?>{
      'file': document.fileName,
    });
    // Nhả kênh callback, nếu không cubit sau sẽ không đăng ký được.
    HwpFlutterApi.setUp(null);
    await super.close();
  }
}
