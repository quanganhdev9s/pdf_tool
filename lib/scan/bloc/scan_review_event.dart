import 'package:flutter/foundation.dart';

import '../../pdf_scan_api.g.dart';

@immutable
sealed class ScanReviewEvent {
  const ScanReviewEvent();
}

/// Opens the Apple document scanner. No session exists until capture finishes.
class ScanCaptureRequested extends ScanReviewEvent {
  const ScanCaptureRequested();
}

class ScanPageRotateRequested extends ScanReviewEvent {
  const ScanPageRotateRequested(this.pageId, {this.degrees = 90});

  final String pageId;
  final int degrees;
}

class ScanPageDeleteRequested extends ScanReviewEvent {
  const ScanPageDeleteRequested(this.pageId);

  final String pageId;
}

class ScanPresetSelected extends ScanReviewEvent {
  const ScanPresetSelected(this.preset, {required this.applyToAll});

  final PdfScanPreset preset;
  final bool applyToAll;
}

class ScanComparisonToggled extends ScanReviewEvent {
  const ScanComparisonToggled(this.comparing);

  final bool comparing;
}

class ScanExportRequested extends ScanReviewEvent {
  const ScanExportRequested({this.quality = PdfScanExportQuality.high});

  final PdfScanExportQuality quality;
}

class ScanSessionDiscardRequested extends ScanReviewEvent {
  const ScanSessionDiscardRequested();
}

class ScanOperationCancelRequested extends ScanReviewEvent {
  const ScanOperationCancelRequested();
}

/// Emitted by the platform callbacks below, folded into state by the bloc so
/// native and user-driven changes take the same path.
class ScanSessionReported extends ScanReviewEvent {
  const ScanSessionReported(this.info);

  final PdfScanSessionInfo info;
}

class ScanSessionCancelledReported extends ScanReviewEvent {
  const ScanSessionCancelledReported();
}

class ScanPagesReported extends ScanReviewEvent {
  const ScanPagesReported(this.sessionId, this.pages);

  final String sessionId;
  final List<PdfScanPageInfo> pages;
}

class ScanCurrentPageReported extends ScanReviewEvent {
  const ScanCurrentPageReported(this.pageIndex, this.pageCount);

  final int pageIndex;
  final int pageCount;
}

class ScanPageProcessedReported extends ScanReviewEvent {
  const ScanPageProcessedReported(this.page);

  final PdfScanPageInfo page;
}

class ScanProgressReported extends ScanReviewEvent {
  const ScanProgressReported(this.operationId, this.completed, this.total);

  final String operationId;
  final int completed;
  final int total;
}

class ScanExportCompletedReported extends ScanReviewEvent {
  const ScanExportCompletedReported(this.result, {required this.cancelled});

  final PdfScanExportResult? result;
  final bool cancelled;
}

class ScanFailureReported extends ScanReviewEvent {
  const ScanFailureReported(this.code, this.message, this.details);

  final String code;
  final String message;
  final String? details;
}
