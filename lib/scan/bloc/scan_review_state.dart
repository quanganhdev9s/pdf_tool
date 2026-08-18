import 'package:flutter/foundation.dart';

import '../../pdf_scan_api.g.dart';

enum ScanReviewStatus { idle, capturing, reviewing, processing, exporting }

/// Mirrors the native session. Page *pixels* never cross the bridge — the
/// review canvas is a platform view — so this holds only the metadata the
/// Flutter chrome needs to render its controls.
@immutable
class ScanReviewState {
  const ScanReviewState({
    this.status = ScanReviewStatus.idle,
    this.sessionId,
    this.source,
    this.pages = const <PdfScanPageInfo>[],
    this.currentPageIndex = 0,
    this.isComparingOriginal = false,
    this.activeOperationId,
    this.completedUnits = 0,
    this.totalUnits = 0,
    this.exportResult,
    this.errorMessage,
  });

  final ScanReviewStatus status;
  final String? sessionId;
  final PdfScanSource? source;
  final List<PdfScanPageInfo> pages;
  final int currentPageIndex;
  final bool isComparingOriginal;
  final String? activeOperationId;
  final int completedUnits;
  final int totalUnits;
  final PdfScanExportResult? exportResult;
  final String? errorMessage;

  bool get hasSession => sessionId != null && pages.isNotEmpty;

  /// Also covers work the native side started on its own — the default preset
  /// is applied as soon as capture lands, without Flutter asking for it.
  bool get isBusy =>
      status == ScanReviewStatus.processing ||
      status == ScanReviewStatus.exporting ||
      status == ScanReviewStatus.capturing ||
      (totalUnits > 0 && completedUnits < totalUnits);

  PdfScanPageInfo? get currentPage =>
      currentPageIndex >= 0 && currentPageIndex < pages.length
          ? pages[currentPageIndex]
          : null;

  double? get progress =>
      totalUnits > 0 ? (completedUnits / totalUnits).clamp(0.0, 1.0) : null;

  ScanReviewState copyWith({
    ScanReviewStatus? status,
    String? sessionId,
    PdfScanSource? source,
    List<PdfScanPageInfo>? pages,
    int? currentPageIndex,
    bool? isComparingOriginal,
    String? activeOperationId,
    int? completedUnits,
    int? totalUnits,
    PdfScanExportResult? exportResult,
    String? errorMessage,
    bool clearSession = false,
    bool clearOperation = false,
    bool clearExportResult = false,
    bool clearError = false,
  }) {
    return ScanReviewState(
      status: status ?? this.status,
      sessionId: clearSession ? null : (sessionId ?? this.sessionId),
      source: clearSession ? null : (source ?? this.source),
      pages: clearSession ? const <PdfScanPageInfo>[] : (pages ?? this.pages),
      currentPageIndex: clearSession ? 0 : (currentPageIndex ?? this.currentPageIndex),
      isComparingOriginal:
          clearSession ? false : (isComparingOriginal ?? this.isComparingOriginal),
      activeOperationId:
          clearOperation ? null : (activeOperationId ?? this.activeOperationId),
      completedUnits: clearOperation ? 0 : (completedUnits ?? this.completedUnits),
      totalUnits: clearOperation ? 0 : (totalUnits ?? this.totalUnits),
      exportResult: clearExportResult ? null : (exportResult ?? this.exportResult),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
