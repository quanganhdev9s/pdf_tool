import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_scan_api.g.dart';
import 'scan_review_event.dart';
import 'scan_review_state.dart';

export 'scan_review_event.dart';
export 'scan_review_state.dart';

/// Owns the Flutter-side view of a scan session and is the single
/// `PdfScanFlutterApi` receiver.
///
/// Kept separate from `PdfViewerBloc` on purpose: that one is already past
/// 2,300 lines, and a scan session has an independent lifecycle — it exists
/// before any document does.
class ScanReviewBloc extends Bloc<ScanReviewEvent, ScanReviewState>
    implements PdfScanFlutterApi {
  ScanReviewBloc({PdfScanHostApi? hostApi})
      : _hostApi = hostApi ?? PdfScanHostApi(),
        super(const ScanReviewState()) {
    PdfScanFlutterApi.setUp(this);

    on<ScanCaptureRequested>(_onCaptureRequested);
    on<ScanImagesPickRequested>(_onImagesPickRequested);
    on<ScanPageRotateRequested>(_onRotateRequested);
    on<ScanPageDeleteRequested>(_onDeleteRequested);
    on<ScanPresetSelected>(_onPresetSelected);
    on<ScanComparisonToggled>(_onComparisonToggled);
    on<ScanExportRequested>(_onExportRequested);
    on<ScanSessionDiscardRequested>(_onDiscardRequested);
    on<ScanOperationCancelRequested>(_onCancelRequested);

    on<ScanSessionReported>(_onSessionReported);
    on<ScanSessionCancelledReported>(_onSessionCancelledReported);
    on<ScanPagesReported>(_onPagesReported);
    on<ScanCurrentPageReported>(_onCurrentPageReported);
    on<ScanPageProcessedReported>(_onPageProcessedReported);
    on<ScanProgressReported>(_onProgressReported);
    on<ScanExportCompletedReported>(_onExportCompletedReported);
    on<ScanFailureReported>(_onFailureReported);
  }

  final PdfScanHostApi _hostApi;

  // MARK: - User intent

  Future<void> _onCaptureRequested(
    ScanCaptureRequested event,
    Emitter<ScanReviewState> emit,
  ) async {
    emit(_startingCapture());
    await _guard(emit, () => _hostApi.startDocumentCapture());
  }

  Future<void> _onImagesPickRequested(
    ScanImagesPickRequested event,
    Emitter<ScanReviewState> emit,
  ) async {
    emit(_startingCapture());
    await _guard(emit, () => _hostApi.pickScanImages());
  }

  /// Clears everything the previous session left behind.
  ///
  /// This bloc is provided above the navigator so it can receive
  /// `onScanSessionCreated` while the capture sheet is up, which means its state
  /// outlives any one scan. A stale `exportResult` here made the review screen
  /// bounce straight to the library the moment the next capture started.
  ScanReviewState _startingCapture() => state.copyWith(
        status: ScanReviewStatus.capturing,
        clearSession: true,
        clearOperation: true,
        clearExportResult: true,
        clearError: true,
      );

  Future<void> _onRotateRequested(
    ScanPageRotateRequested event,
    Emitter<ScanReviewState> emit,
  ) async {
    final String? sessionId = state.sessionId;
    if (sessionId == null) return;
    await _guard(
      emit,
      () => _hostApi.rotateScanPage(sessionId, event.pageId, event.degrees),
    );
  }

  Future<void> _onDeleteRequested(
    ScanPageDeleteRequested event,
    Emitter<ScanReviewState> emit,
  ) async {
    final String? sessionId = state.sessionId;
    if (sessionId == null) return;
    await _guard(emit, () => _hostApi.deleteScanPage(sessionId, event.pageId));
  }

  Future<void> _onPresetSelected(
    ScanPresetSelected event,
    Emitter<ScanReviewState> emit,
  ) async {
    final String? sessionId = state.sessionId;
    if (sessionId == null) return;

    final int total = event.applyToAll ? state.pages.length : 1;
    emit(state.copyWith(
      status: ScanReviewStatus.processing,
      completedUnits: 0,
      totalUnits: total,
      clearError: true,
    ));

    await _guard(emit, () {
      if (event.applyToAll) {
        return _hostApi.applyPresetToAll(sessionId, event.preset);
      }
      final PdfScanPageInfo? page = state.currentPage;
      if (page == null) return Future<void>.value();
      return _hostApi.applyPreset(sessionId, page.pageId, event.preset);
    });
  }

  Future<void> _onComparisonToggled(
    ScanComparisonToggled event,
    Emitter<ScanReviewState> emit,
  ) async {
    final String? sessionId = state.sessionId;
    if (sessionId == null) return;
    emit(state.copyWith(isComparingOriginal: event.comparing));
    await _guard(
      emit,
      () => _hostApi.setComparingOriginal(sessionId, event.comparing),
    );
  }

  Future<void> _onExportRequested(
    ScanExportRequested event,
    Emitter<ScanReviewState> emit,
  ) async {
    final String? sessionId = state.sessionId;
    if (sessionId == null) return;

    emit(state.copyWith(
      status: ScanReviewStatus.exporting,
      completedUnits: 0,
      totalUnits: state.pages.length,
      clearExportResult: true,
      clearError: true,
    ));

    await _guard(
      emit,
      () => _hostApi.exportScanSessionToPdf(
        PdfScanExportRequest(
          sessionId: sessionId,
          quality: event.quality,
          outputPath: '',
        ),
      ),
    );
  }

  Future<void> _onDiscardRequested(
    ScanSessionDiscardRequested event,
    Emitter<ScanReviewState> emit,
  ) async {
    final String? sessionId = state.sessionId;
    emit(const ScanReviewState());
    if (sessionId == null) return;
    await _hostApi.discardScanSession(sessionId);
  }

  Future<void> _onCancelRequested(
    ScanOperationCancelRequested event,
    Emitter<ScanReviewState> emit,
  ) async {
    final String? operationId = state.activeOperationId;
    if (operationId == null) return;
    await _hostApi.cancelScanOperation(operationId);
  }

  // MARK: - Native reports

  void _onSessionReported(
    ScanSessionReported event,
    Emitter<ScanReviewState> emit,
  ) {
    emit(state.copyWith(
      status: ScanReviewStatus.reviewing,
      sessionId: event.info.sessionId,
      source: event.info.source,
      clearError: true,
    ));
    // Page metadata arrives separately; ask for it now so the toolbar has
    // something to render before the first mutation.
    _refreshPages(event.info.sessionId);
  }

  void _onSessionCancelledReported(
    ScanSessionCancelledReported event,
    Emitter<ScanReviewState> emit,
  ) {
    emit(state.copyWith(status: ScanReviewStatus.idle, clearOperation: true));
  }

  void _onPagesReported(
    ScanPagesReported event,
    Emitter<ScanReviewState> emit,
  ) {
    if (state.sessionId != null && state.sessionId != event.sessionId) return;
    emit(state.copyWith(
      pages: event.pages,
      status: event.pages.isEmpty
          ? ScanReviewStatus.idle
          : ScanReviewStatus.reviewing,
    ));
  }

  void _onCurrentPageReported(
    ScanCurrentPageReported event,
    Emitter<ScanReviewState> emit,
  ) {
    emit(state.copyWith(currentPageIndex: event.pageIndex));
  }

  void _onPageProcessedReported(
    ScanPageProcessedReported event,
    Emitter<ScanReviewState> emit,
  ) {
    final List<PdfScanPageInfo> updated = state.pages
        .map((PdfScanPageInfo page) =>
            page.pageId == event.page.pageId ? event.page : page)
        .toList(growable: false);
    emit(state.copyWith(pages: updated));
  }

  void _onProgressReported(
    ScanProgressReported event,
    Emitter<ScanReviewState> emit,
  ) {
    emit(state.copyWith(
      activeOperationId: event.operationId,
      completedUnits: event.completed,
      totalUnits: event.total,
    ));
    // Clear regardless of status: auto-applied presets report progress while
    // the bloc still thinks it is merely reviewing, and a stale operation would
    // leave the progress bar pinned at full.
    if (event.completed >= event.total) {
      emit(state.copyWith(
        status: state.status == ScanReviewStatus.exporting
            ? ScanReviewStatus.exporting
            : ScanReviewStatus.reviewing,
        clearOperation: true,
      ));
    }
  }

  void _onExportCompletedReported(
    ScanExportCompletedReported event,
    Emitter<ScanReviewState> emit,
  ) {
    emit(state.copyWith(
      status: ScanReviewStatus.reviewing,
      exportResult: event.result,
      clearOperation: true,
    ));
  }

  void _onFailureReported(
    ScanFailureReported event,
    Emitter<ScanReviewState> emit,
  ) {
    emit(state.copyWith(
      status: state.hasSession
          ? ScanReviewStatus.reviewing
          : ScanReviewStatus.idle,
      errorMessage: event.message,
      clearOperation: true,
    ));
  }

  Future<void> _refreshPages(String sessionId) async {
    try {
      final List<PdfScanPageInfo> pages = await _hostApi.getScanPages(sessionId);
      add(ScanPagesReported(sessionId, pages));
    } on PlatformException catch (error) {
      add(ScanFailureReported(
        error.code,
        error.message ?? 'Could not read the scanned pages.',
        error.details?.toString(),
      ));
    }
  }

  Future<void> _guard(
    Emitter<ScanReviewState> emit,
    Future<void> Function() body,
  ) async {
    try {
      await body();
    } on PlatformException catch (error) {
      emit(state.copyWith(
        status: state.hasSession
            ? ScanReviewStatus.reviewing
            : ScanReviewStatus.idle,
        errorMessage: error.message ?? 'The scan operation failed.',
        clearOperation: true,
      ));
    }
  }

  // MARK: - PdfScanFlutterApi

  @override
  void onScanSessionCreated(PdfScanSessionInfo info) =>
      add(ScanSessionReported(info));

  @override
  void onScanSessionCancelled() => add(const ScanSessionCancelledReported());

  @override
  void onScanPagesChanged(String sessionId, List<PdfScanPageInfo> pages) =>
      add(ScanPagesReported(sessionId, pages));

  @override
  void onScanCurrentPageChanged(
    String sessionId,
    int pageIndex,
    int pageCount,
  ) =>
      add(ScanCurrentPageReported(pageIndex, pageCount));

  @override
  void onScanPageProcessed(String sessionId, PdfScanPageInfo page) =>
      add(ScanPageProcessedReported(page));

  @override
  void onScanProgress(String operationId, int completedPages, int totalPages) =>
      add(ScanProgressReported(operationId, completedPages, totalPages));

  @override
  void onScanExportCompleted(
    String operationId,
    PdfScanExportResult? result,
    bool cancelled,
  ) =>
      add(ScanExportCompletedReported(result, cancelled: cancelled));

  @override
  void onScanOperationFailed(
    String operationId,
    String code,
    String message,
    String? details,
  ) =>
      add(ScanFailureReported(code, message, details));
}
