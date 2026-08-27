import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_scan_api.g.dart';

/// [documents] is `null` until the first listing comes back: that is "still
/// loading", not "no scans yet".
class ScanLibraryState {
  const ScanLibraryState({this.documents, this.error});

  final List<PdfScanExportedDocument>? documents;
  final String? error;

  bool get loading => documents == null && error == null;

  ScanLibraryState copyWith({
    List<PdfScanExportedDocument>? documents,
    String? error,
    bool clearError = false,
  }) {
    return ScanLibraryState(
      documents: documents ?? this.documents,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Reads the exports directory directly rather than mirroring it in
/// `ScanReviewBloc`: files can appear or vanish through the Files app without
/// this screen being involved.
///
/// Thao tác trên một tệp trả về thông báo lỗi thay vì đẩy vào state — đó là
/// tin nhắn một lần cho snackbar.
class ScanLibraryCubit extends Cubit<ScanLibraryState> {
  ScanLibraryCubit({PdfScanHostApi? api})
    : _api = api ?? PdfScanHostApi(),
      super(const ScanLibraryState());

  final PdfScanHostApi _api;

  Future<void> reload() async {
    try {
      final List<PdfScanExportedDocument> documents = await _api.listExportedScans();
      if (isClosed) return;
      emit(ScanLibraryState(documents: documents));
    } on PlatformException catch (error) {
      if (isClosed) return;
      emit(state.copyWith(error: error.message ?? 'Không đọc được danh sách PDF.'));
    }
  }

  /// Trả về thông báo lỗi, `null` nếu chạy được.
  Future<String?> quickLook(String path) => _run(() => _api.openExportedScan(path));

  Future<String?> share(String path) => _run(() => _api.shareExportedScan(path));

  Future<String?> delete(String path) => _run(() => _api.deleteExportedScan(path));

  Future<String?> _run(Future<void> Function() body) async {
    try {
      await body();
      return null;
    } on PlatformException catch (error) {
      return error.message ?? 'Thao tác thất bại.';
    }
  }
}
