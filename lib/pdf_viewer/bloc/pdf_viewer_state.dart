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
  });

  final PdfDocumentInfo? documentInfo;
  final PdfSearchState? searchState;
  final PdfFreeTextAreaSelection? pendingFreeTextArea;
  final String? selectedText;
  final String status;
  final bool busy;
  final bool openedOnce;

  bool get hasSelection => selectedText?.trim().isNotEmpty ?? false;

  PdfViewerState copyWith({
    Object? documentInfo = _unset,
    Object? searchState = _unset,
    Object? pendingFreeTextArea = _unset,
    Object? selectedText = _unset,
    String? status,
    bool? busy,
    bool? openedOnce,
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
    );
  }
}
