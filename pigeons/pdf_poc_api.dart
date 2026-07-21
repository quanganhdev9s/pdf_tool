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

class PdfOcrRequest {
  PdfOcrRequest({
    required this.pageIndexes,
    required this.recognitionLanguages,
    required this.accurateRecognition,
  });

  List<int> pageIndexes;
  List<String> recognitionLanguages;
  bool accurateRecognition;
}

class PdfOcrBlock {
  PdfOcrBlock({
    required this.pageIndex,
    required this.text,
    required this.confidence,
    required this.normalizedBoundingBox,
  });

  int pageIndex;
  String text;
  double confidence;
  PdfRect normalizedBoundingBox;
}

enum PdfCompressionMode { preserve, rasterized }

class PdfCompressionRequest {
  PdfCompressionRequest({
    required this.mode,
    required this.rasterDpi,
    required this.jpegQuality,
  });

  PdfCompressionMode mode;
  int rasterDpi;
  double jpegQuality;
}

class PdfCompressionResult {
  PdfCompressionResult({
    required this.outputPath,
    required this.inputBytes,
    required this.outputBytes,
    required this.compressionRatio,
    required this.durationMilliseconds,
    required this.textSelectable,
    required this.annotationsEditable,
    required this.linksFunctional,
    required this.formsFunctional,
    required this.visualQualityNotes,
    required this.warning,
  });

  String outputPath;
  int inputBytes;
  int outputBytes;
  double compressionRatio;
  int durationMilliseconds;
  bool textSelectable;
  bool annotationsEditable;
  bool linksFunctional;
  bool formsFunctional;
  String visualQualityNotes;
  String warning;
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

  void runOcr(PdfOcrRequest request);

  void cancelOcr();

  void showOcrResult(PdfOcrBlock block);

  void compress(PdfCompressionRequest request);

  void cancelCompression();

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

  void onOcrProgress(String operationId, int completedPages, int totalPages);

  void onOcrResult(String operationId, PdfOcrBlock block);

  void onOcrCompleted(String operationId, bool cancelled);

  void onCompressionProgress(
    String operationId,
    int completedPages,
    int totalPages,
  );

  void onCompressionCompleted(
    String operationId,
    PdfCompressionResult? result,
    bool cancelled,
  );

  void onOperationFailed(
    String operationId,
    String code,
    String message,
    String? details,
  );
}
