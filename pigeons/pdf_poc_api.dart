import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/pdf_poc_api.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Runner/PdfPoc/Bridge/PdfPocApi.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'pdf_tool',
  ),
)
class PdfRect {
  PdfRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  double x;
  double y;
  double width;
  double height;
}

class PdfColor {
  PdfColor({required this.argb});

  int argb;
}

class PdfDocumentInfo {
  PdfDocumentInfo({
    required this.workingPath,
    required this.pageCount,
    required this.currentPageIndex,
    required this.hasSearchableText,
    required this.isDirty,
  });

  String workingPath;
  int pageCount;
  int currentPageIndex;
  bool hasSearchableText;
  bool isDirty;
}

class PdfSearchRequest {
  PdfSearchRequest({
    required this.query,
    required this.caseSensitive,
    required this.wholeWord,
  });

  String query;
  bool caseSensitive;
  bool wholeWord;
}

class PdfSearchState {
  PdfSearchState({
    required this.query,
    required this.totalResults,
    required this.activeResultIndex,
    this.activeResultText,
  });

  String query;
  int totalResults;
  int activeResultIndex;
  String? activeResultText;
}

enum PdfMarkupType { highlight, underline, strikeout }

class PdfFreeTextRequest {
  PdfFreeTextRequest({
    required this.pageIndex,
    required this.text,
    required this.bounds,
    required this.fontSize,
    required this.textColor,
  });

  int pageIndex;
  String text;
  PdfRect bounds;
  double fontSize;
  PdfColor textColor;
}

class PdfFreeTextAreaSelection {
  PdfFreeTextAreaSelection({required this.pageIndex, required this.bounds});

  int pageIndex;
  PdfRect bounds;
}

class PdfExportResult {
  PdfExportResult({
    required this.outputPath,
    required this.pageCount,
    required this.fileSizeBytes,
  });

  String outputPath;
  int pageCount;
  int fileSizeBytes;
}

@HostApi()
abstract class PdfPocHostApi {
  PdfDocumentInfo openAssetWorkingCopy(String assetKey, Uint8List assetBytes);

  void closeDocument();

  PdfDocumentInfo resetWorkingCopy(String assetKey, Uint8List assetBytes);

  void goToPage(int pageIndex);

  void goToNextPage();

  void goToPreviousPage();

  PdfSearchState search(PdfSearchRequest request);

  PdfSearchState goToNextSearchResult();

  PdfSearchState goToPreviousSearchResult();

  void clearSearch();

  String? getSelectedText();

  void copySelectedText();

  void addMarkupFromCurrentSelection(PdfMarkupType type);

  void addFreeText(PdfFreeTextRequest request);

  void beginFreeTextAreaSelection();

  void setInkModeEnabled(bool enabled);

  void clearCurrentInkInput();

  void commitCurrentInkToPdf();

  void deleteSelectedAnnotation();

  void captureElectronicSignature();

  void clearElectronicSignatureCapture();

  void confirmElectronicSignatureCapture();

  void beginSignaturePlacement();

  void resizeSignaturePlacement(double scale);

  void commitSignaturePlacement();

  void cancelSignaturePlacement();

  void deleteSelectedSignature();

  PdfExportResult exportFlattenedCopy();

  void rotatePages(List<int> pageIndexes, int degrees);

  void deletePages(List<int> pageIndexes);

  void duplicatePage(int pageIndex, int destinationIndex);

  void movePage(int fromIndex, int toIndex);

  void cropPage(int pageIndex, PdfRect pageBounds);

  void cropPageToInset(int pageIndex, double insetPoints);

  void commitPendingPageReorder();

  void cancelPendingPageReorder();

  PdfExportResult savePageOperationsCopy();

  PdfDocumentInfo save();
}

@FlutterApi()
abstract class PdfPocFlutterApi {
  void onDocumentOpened(PdfDocumentInfo info);

  void onDocumentClosed();

  void onCurrentPageChanged(int pageIndex, int pageCount);

  void onDirtyStateChanged(bool isDirty);

  void onSearchStateChanged(PdfSearchState state);

  void onSelectionChanged(String? selectedText);

  void onFreeTextAreaSelected(PdfFreeTextAreaSelection selection);

  void onOperationFailed(
    String operationId,
    String code,
    String message,
    String? details,
  );
}
