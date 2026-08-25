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
    this.splitRunning = false,
    this.splitCompletedPages = 0,
    this.splitTotalPages = 0,
    this.splitResult,
    this.mergeRunning = false,
    this.mergeCompletedPages = 0,
    this.mergeTotalPages = 0,
    this.mergeResult,
    this.conversionRunning = false,
    this.conversionCompletedPages = 0,
    this.conversionTotalPages = 0,
    this.conversionResult,
    this.generatedOutputs = const <PdfGeneratedOutput>[],
    this.generatedOutputsLoading = false,
    this.viewableDocument,
    this.viewablePickPending = false,
    this.hwpEditor,
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
  final bool splitRunning;
  final int splitCompletedPages;
  final int splitTotalPages;
  final PdfSplitResult? splitResult;
  final bool mergeRunning;
  final int mergeCompletedPages;
  final int mergeTotalPages;
  final PdfMergeResult? mergeResult;
  final bool conversionRunning;
  final int conversionCompletedPages;
  final int conversionTotalPages;
  final PdfConvertToPdfResult? conversionResult;
  final List<PdfGeneratedOutput> generatedOutputs;
  final bool generatedOutputsLoading;
  final PdfViewableDocument? viewableDocument;
  final bool viewablePickPending;

  /// Con trỏ và định dạng trong trình soạn thảo HWP. `null` khi chưa bật chế
  /// độ sửa, hoặc khi tệp đang mở không phải HWP.
  final HwpEditorState? hwpEditor;

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
    bool? splitRunning,
    int? splitCompletedPages,
    int? splitTotalPages,
    Object? splitResult = _unset,
    bool? mergeRunning,
    int? mergeCompletedPages,
    int? mergeTotalPages,
    Object? mergeResult = _unset,
    bool? conversionRunning,
    int? conversionCompletedPages,
    int? conversionTotalPages,
    Object? conversionResult = _unset,
    List<PdfGeneratedOutput>? generatedOutputs,
    bool? generatedOutputsLoading,
    Object? viewableDocument = _unset,
    bool? viewablePickPending,
    Object? hwpEditor = _unset,
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
      splitRunning: splitRunning ?? this.splitRunning,
      splitCompletedPages: splitCompletedPages ?? this.splitCompletedPages,
      splitTotalPages: splitTotalPages ?? this.splitTotalPages,
      splitResult: splitResult == _unset
          ? this.splitResult
          : splitResult as PdfSplitResult?,
      mergeRunning: mergeRunning ?? this.mergeRunning,
      mergeCompletedPages: mergeCompletedPages ?? this.mergeCompletedPages,
      mergeTotalPages: mergeTotalPages ?? this.mergeTotalPages,
      mergeResult: mergeResult == _unset
          ? this.mergeResult
          : mergeResult as PdfMergeResult?,
      conversionRunning: conversionRunning ?? this.conversionRunning,
      conversionCompletedPages:
          conversionCompletedPages ?? this.conversionCompletedPages,
      conversionTotalPages: conversionTotalPages ?? this.conversionTotalPages,
      conversionResult: conversionResult == _unset
          ? this.conversionResult
          : conversionResult as PdfConvertToPdfResult?,
      generatedOutputs: generatedOutputs ?? this.generatedOutputs,
      generatedOutputsLoading:
          generatedOutputsLoading ?? this.generatedOutputsLoading,
      viewableDocument: viewableDocument == _unset
          ? this.viewableDocument
          : viewableDocument as PdfViewableDocument?,
      viewablePickPending: viewablePickPending ?? this.viewablePickPending,
      hwpEditor: hwpEditor == _unset
          ? this.hwpEditor
          : hwpEditor as HwpEditorState?,
    );
  }
}
