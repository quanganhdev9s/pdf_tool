import '../../pdf_poc_api.g.dart';

const Object _unset = Object();

class PdfViewerState {
  PdfViewerState({
    this.documentInfo,
    this.searchState,
    this.pendingFreeTextArea,
    this.selectedText,
    this.status = 'Đang chuẩn bị viewer...',
    this.busy = false,
    this.openedOnce = false,
    this.inkModeEnabled = false,
    this.ocrRunning = false,
    this.ocrCompletedPages = 0,
    this.ocrTotalPages = 0,
    this.ocrResults = const <PdfOcrBlock>[],
    this.compressionRunning = false,
    this.compressionCompletedPages = 0,
    this.compressionTotalPages = 0,
    this.compressionResult,
  });

  final PdfDocumentInfo? documentInfo;
  final PdfSearchState? searchState;
  final PdfFreeTextAreaSelection? pendingFreeTextArea;
  final String? selectedText;
  final String status;
  final bool busy;
  final bool openedOnce;
  final bool inkModeEnabled;
  final bool ocrRunning;
  final int ocrCompletedPages;
  final int ocrTotalPages;
  final List<PdfOcrBlock> ocrResults;
  final bool compressionRunning;
  final int compressionCompletedPages;
  final int compressionTotalPages;
  final PdfCompressionResult? compressionResult;

  bool get hasSelection => selectedText?.trim().isNotEmpty ?? false;

  PdfViewerState copyWith({
    Object? documentInfo = _unset,
    Object? searchState = _unset,
    Object? pendingFreeTextArea = _unset,
    Object? selectedText = _unset,
    String? status,
    bool? busy,
    bool? openedOnce,
    bool? inkModeEnabled,
    bool? ocrRunning,
    int? ocrCompletedPages,
    int? ocrTotalPages,
    List<PdfOcrBlock>? ocrResults,
    bool? compressionRunning,
    int? compressionCompletedPages,
    int? compressionTotalPages,
    Object? compressionResult = _unset,
  }) {
    return PdfViewerState(
      documentInfo: documentInfo == _unset
          ? this.documentInfo
          : documentInfo as PdfDocumentInfo?,
      searchState: searchState == _unset
          ? this.searchState
          : searchState as PdfSearchState?,
      pendingFreeTextArea: pendingFreeTextArea == _unset
          ? this.pendingFreeTextArea
          : pendingFreeTextArea as PdfFreeTextAreaSelection?,
      selectedText: selectedText == _unset
          ? this.selectedText
          : selectedText as String?,
      status: status ?? this.status,
      busy: busy ?? this.busy,
      openedOnce: openedOnce ?? this.openedOnce,
      inkModeEnabled: inkModeEnabled ?? this.inkModeEnabled,
      ocrRunning: ocrRunning ?? this.ocrRunning,
      ocrCompletedPages: ocrCompletedPages ?? this.ocrCompletedPages,
      ocrTotalPages: ocrTotalPages ?? this.ocrTotalPages,
      ocrResults: ocrResults ?? this.ocrResults,
      compressionRunning: compressionRunning ?? this.compressionRunning,
      compressionCompletedPages:
          compressionCompletedPages ?? this.compressionCompletedPages,
      compressionTotalPages:
          compressionTotalPages ?? this.compressionTotalPages,
      compressionResult: compressionResult == _unset
          ? this.compressionResult
          : compressionResult as PdfCompressionResult?,
    );
  }
}
