import '../../pdf_poc_api.g.dart';

sealed class PdfViewerEvent {
  const PdfViewerEvent();
}

final class PdfViewerOpenRequested extends PdfViewerEvent {
  const PdfViewerOpenRequested();
}

final class PdfViewerResetRequested extends PdfViewerEvent {
  const PdfViewerResetRequested();
}

final class PdfViewerPreviousPageRequested extends PdfViewerEvent {
  const PdfViewerPreviousPageRequested();
}

final class PdfViewerNextPageRequested extends PdfViewerEvent {
  const PdfViewerNextPageRequested();
}

final class PdfViewerJumpToPageRequested extends PdfViewerEvent {
  const PdfViewerJumpToPageRequested(this.pageText);

  final String pageText;
}

final class PdfViewerSearchRequested extends PdfViewerEvent {
  const PdfViewerSearchRequested(this.query);

  final String query;
}

final class PdfViewerPreviousSearchResultRequested extends PdfViewerEvent {
  const PdfViewerPreviousSearchResultRequested();
}

final class PdfViewerNextSearchResultRequested extends PdfViewerEvent {
  const PdfViewerNextSearchResultRequested();
}

final class PdfViewerClearSearchRequested extends PdfViewerEvent {
  const PdfViewerClearSearchRequested();
}

final class PdfViewerCopySelectionRequested extends PdfViewerEvent {
  const PdfViewerCopySelectionRequested();
}

final class PdfViewerMarkupSelectionRequested extends PdfViewerEvent {
  const PdfViewerMarkupSelectionRequested(this.type);

  final PdfMarkupType type;
}

final class PdfViewerAddFixedFreeTextRequested extends PdfViewerEvent {
  const PdfViewerAddFixedFreeTextRequested({
    required this.pageText,
    required this.text,
  });

  final String pageText;
  final String text;
}

final class PdfViewerBeginFreeTextAreaSelectionRequested
    extends PdfViewerEvent {
  const PdfViewerBeginFreeTextAreaSelectionRequested();
}

final class PdfViewerCommitSelectedFreeTextAreaRequested
    extends PdfViewerEvent {
  const PdfViewerCommitSelectedFreeTextAreaRequested(this.text);

  final String text;
}

final class PdfViewerCancelSelectedFreeTextAreaRequested
    extends PdfViewerEvent {
  const PdfViewerCancelSelectedFreeTextAreaRequested();
}

final class PdfViewerSaveRequested extends PdfViewerEvent {
  const PdfViewerSaveRequested();
}

final class PdfViewerInkModeChanged extends PdfViewerEvent {
  const PdfViewerInkModeChanged(this.enabled);

  final bool enabled;
}

final class PdfViewerClearInkRequested extends PdfViewerEvent {
  const PdfViewerClearInkRequested();
}

final class PdfViewerCommitInkRequested extends PdfViewerEvent {
  const PdfViewerCommitInkRequested();
}

final class PdfViewerDeleteSelectedAnnotationRequested extends PdfViewerEvent {
  const PdfViewerDeleteSelectedAnnotationRequested();
}

final class PdfViewerCaptureSignatureRequested extends PdfViewerEvent {
  const PdfViewerCaptureSignatureRequested();
}

final class PdfViewerClearSignatureCaptureRequested extends PdfViewerEvent {
  const PdfViewerClearSignatureCaptureRequested();
}

final class PdfViewerConfirmSignatureCaptureRequested extends PdfViewerEvent {
  const PdfViewerConfirmSignatureCaptureRequested();
}

final class PdfViewerBeginSignaturePlacementRequested extends PdfViewerEvent {
  const PdfViewerBeginSignaturePlacementRequested();
}

final class PdfViewerResizeSignaturePlacementRequested extends PdfViewerEvent {
  const PdfViewerResizeSignaturePlacementRequested(this.scale);

  final double scale;
}

final class PdfViewerCommitSignaturePlacementRequested extends PdfViewerEvent {
  const PdfViewerCommitSignaturePlacementRequested();
}

final class PdfViewerCancelSignaturePlacementRequested extends PdfViewerEvent {
  const PdfViewerCancelSignaturePlacementRequested();
}

final class PdfViewerDeleteSelectedSignatureRequested extends PdfViewerEvent {
  const PdfViewerDeleteSelectedSignatureRequested();
}

final class PdfViewerExportFlattenedCopyRequested extends PdfViewerEvent {
  const PdfViewerExportFlattenedCopyRequested();
}

final class PdfViewerRotateCurrentPageRequested extends PdfViewerEvent {
  const PdfViewerRotateCurrentPageRequested(this.degrees);

  final int degrees;
}

final class PdfViewerDeleteCurrentPageRequested extends PdfViewerEvent {
  const PdfViewerDeleteCurrentPageRequested();
}

final class PdfViewerDuplicateCurrentPageRequested extends PdfViewerEvent {
  const PdfViewerDuplicateCurrentPageRequested();
}

final class PdfViewerMoveCurrentPageRequested extends PdfViewerEvent {
  const PdfViewerMoveCurrentPageRequested(this.delta);

  final int delta;
}

final class PdfViewerCommitPendingPageReorderRequested extends PdfViewerEvent {
  const PdfViewerCommitPendingPageReorderRequested();
}

final class PdfViewerCancelPendingPageReorderRequested extends PdfViewerEvent {
  const PdfViewerCancelPendingPageReorderRequested();
}

final class PdfViewerCropCurrentPageRequested extends PdfViewerEvent {
  const PdfViewerCropCurrentPageRequested();
}

final class PdfViewerSavePageOperationsCopyRequested extends PdfViewerEvent {
  const PdfViewerSavePageOperationsCopyRequested();
}

final class PdfViewerRunOcrCurrentPageRequested extends PdfViewerEvent {
  const PdfViewerRunOcrCurrentPageRequested();
}

final class PdfViewerRunOcrAllPagesRequested extends PdfViewerEvent {
  const PdfViewerRunOcrAllPagesRequested();
}

final class PdfViewerCancelOcrRequested extends PdfViewerEvent {
  const PdfViewerCancelOcrRequested();
}

final class PdfViewerShowOcrResultRequested extends PdfViewerEvent {
  const PdfViewerShowOcrResultRequested(this.block);

  final PdfOcrBlock block;
}

final class PdfViewerRunPreservationCompressionRequested
    extends PdfViewerEvent {
  const PdfViewerRunPreservationCompressionRequested();
}

final class PdfViewerRunRasterizedCompressionRequested extends PdfViewerEvent {
  const PdfViewerRunRasterizedCompressionRequested({
    required this.dpi,
    required this.jpegQuality,
  });

  final int dpi;
  final double jpegQuality;
}

final class PdfViewerCancelCompressionRequested extends PdfViewerEvent {
  const PdfViewerCancelCompressionRequested();
}

final class PdfViewerNativePageChanged extends PdfViewerEvent {
  const PdfViewerNativePageChanged({
    required this.pageIndex,
    required this.pageCount,
  });

  final int pageIndex;
  final int pageCount;
}

final class PdfViewerNativeDirtyStateChanged extends PdfViewerEvent {
  const PdfViewerNativeDirtyStateChanged(this.isDirty);

  final bool isDirty;
}

final class PdfViewerNativeDocumentClosed extends PdfViewerEvent {
  const PdfViewerNativeDocumentClosed();
}

final class PdfViewerNativeDocumentOpened extends PdfViewerEvent {
  const PdfViewerNativeDocumentOpened(this.info);

  final PdfDocumentInfo info;
}

final class PdfViewerNativeOperationFailed extends PdfViewerEvent {
  const PdfViewerNativeOperationFailed({
    required this.operationId,
    required this.code,
    required this.message,
    this.details,
  });

  final String operationId;
  final String code;
  final String message;
  final String? details;
}

final class PdfViewerNativeSearchStateChanged extends PdfViewerEvent {
  const PdfViewerNativeSearchStateChanged(this.searchState);

  final PdfSearchState searchState;
}

final class PdfViewerNativeSelectionChanged extends PdfViewerEvent {
  const PdfViewerNativeSelectionChanged(this.selectedText);

  final String? selectedText;
}

final class PdfViewerNativeFreeTextAreaSelected extends PdfViewerEvent {
  const PdfViewerNativeFreeTextAreaSelected(this.selection);

  final PdfFreeTextAreaSelection selection;
}

final class PdfViewerNativeOcrProgress extends PdfViewerEvent {
  const PdfViewerNativeOcrProgress({
    required this.operationId,
    required this.completedPages,
    required this.totalPages,
  });

  final String operationId;
  final int completedPages;
  final int totalPages;
}

final class PdfViewerNativeOcrResult extends PdfViewerEvent {
  const PdfViewerNativeOcrResult({
    required this.operationId,
    required this.block,
  });

  final String operationId;
  final PdfOcrBlock block;
}

final class PdfViewerNativeOcrCompleted extends PdfViewerEvent {
  const PdfViewerNativeOcrCompleted({
    required this.operationId,
    required this.cancelled,
  });

  final String operationId;
  final bool cancelled;
}

final class PdfViewerNativeCompressionProgress extends PdfViewerEvent {
  const PdfViewerNativeCompressionProgress({
    required this.operationId,
    required this.completedPages,
    required this.totalPages,
  });

  final String operationId;
  final int completedPages;
  final int totalPages;
}

final class PdfViewerNativeCompressionCompleted extends PdfViewerEvent {
  const PdfViewerNativeCompressionCompleted({
    required this.operationId,
    required this.result,
    required this.cancelled,
  });

  final String operationId;
  final PdfCompressionResult? result;
  final bool cancelled;
}
