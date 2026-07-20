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
