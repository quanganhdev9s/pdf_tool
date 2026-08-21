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

class PdfPageRange {
  PdfPageRange({required this.startPageIndex, required this.endPageIndex});

  int startPageIndex;
  int endPageIndex;
}

class PdfSplitRequest {
  PdfSplitRequest({required this.ranges});

  List<PdfPageRange> ranges;
}

class PdfSplitOutput {
  PdfSplitOutput({required this.outputPath, required this.pageCount});

  String outputPath;
  int pageCount;
}

class PdfSplitResult {
  PdfSplitResult({required this.outputs, required this.durationMilliseconds});

  List<PdfSplitOutput> outputs;
  int durationMilliseconds;
}

class PdfMergeRequest {
  PdfMergeRequest({required this.inputPaths});

  List<String> inputPaths;
}

class PdfMergeResult {
  PdfMergeResult({
    required this.outputPath,
    required this.inputDocumentCount,
    required this.pageCount,
    required this.durationMilliseconds,
  });

  String outputPath;
  int inputDocumentCount;
  int pageCount;
  int durationMilliseconds;
}

/// Output resolution and compression for images rendered into a PDF.
enum PdfScanQuality { standard, high }

enum PdfConvertPageSize { a4, letter }

class PdfConvertToPdfRequest {
  PdfConvertToPdfRequest({
    required this.outputPath,
    required this.pageSize,
    required this.imageQuality,
  });

  String outputPath;
  PdfConvertPageSize pageSize;

  /// Only used when the picked source file is an image. Document sources are
  /// paginated by the native print renderer instead of re-encoded as JPEG.
  PdfScanQuality imageQuality;
}

class PdfConvertToPdfResult {
  PdfConvertToPdfResult({
    required this.outputPath,
    required this.sourceFileName,
    required this.sourceFormat,
    required this.pageCount,
    required this.fileSizeBytes,
    required this.durationMilliseconds,
  });

  String outputPath;
  String sourceFileName;
  String sourceFormat;
  int pageCount;
  int fileSizeBytes;
  int durationMilliseconds;
}

class PdfConvertUrlRequest {
  PdfConvertUrlRequest({
    required this.url,
    required this.outputPath,
    required this.pageSize,
  });

  String url;
  String outputPath;
  PdfConvertPageSize pageSize;
}

/// A document picked for viewing. It is a local copy owned by the app, never
/// the user's original file.
class PdfViewableDocument {
  PdfViewableDocument({
    required this.path,
    required this.fileName,
    required this.fileFormat,
    required this.fileSizeBytes,
  });

  String path;
  String fileName;
  String fileFormat;
  int fileSizeBytes;
}

/// A PDF produced by an earlier operation (convert, scan, split, merge,
/// compress) and still present in the native working directory.
class PdfGeneratedOutput {
  PdfGeneratedOutput({
    required this.path,
    required this.fileName,
    required this.fileSizeBytes,
    required this.modifiedEpochMilliseconds,
    required this.pageCount,
  });

  String path;
  String fileName;
  int fileSizeBytes;
  int modifiedEpochMilliseconds;
  int pageCount;
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

  void splitPdf(PdfSplitRequest request);

  void cancelSplit();

  void mergePdfs(PdfMergeRequest request);

  void cancelMerge();

  void pickFileForPdfConversion(PdfConvertToPdfRequest request);

  void convertUrlToPdf(PdfConvertUrlRequest request);

  /// Picks a document to view. The result arrives through
  /// `onDocumentForViewingPicked`; nothing is converted and no output is
  /// written. Flutter then hosts the native viewer platform view.
  void pickDocumentForViewing();

  /// Loads a picked document into the embedded viewer platform view.
  void loadDocumentIntoViewer(String path);

  /// Chuyển trình xem tài liệu sang chế độ sửa, hoặc quay lại chế độ xem.
  ///
  /// Chỉ áp dụng cho HWP. Tắt sẽ **bỏ mọi thay đổi chưa lưu** — chúng chỉ nằm
  /// trong trình soạn thảo, không nằm trong tệp.
  void setDocumentEditingEnabled(bool enabled);

  /// Ghi tài liệu đang sửa đè lên tệp đang mở.
  ///
  /// Trả về ngay; việc xuất chạy bất đồng bộ trong trình soạn thảo và kết quả
  /// hiện trong log.
  void saveDocumentEdits();

  /// Releases the embedded viewer and deletes the local copy.
  void closeDocumentViewer();

  /// Finds the next or previous match in the embedded viewer. Returns whether
  /// a match was found and selected.
  @async
  bool findInViewer(String query, bool forward);

  void clearViewerSearch();

  /// Shares the document currently open in the embedded viewer.
  void shareViewerDocument();

  void cancelPdfConversion();

  List<PdfGeneratedOutput> listGeneratedOutputs();

  PdfDocumentInfo openGeneratedOutput(String path);

  /// Opens a PDF from an arbitrary path as a fresh working copy. Unlike
  /// [openGeneratedOutput] this needs no document already open and accepts
  /// paths outside the native working directory.
  PdfDocumentInfo openExternalDocument(String path);

  void shareGeneratedOutput(String path);

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

  void onSplitProgress(String operationId, int completedPages, int totalPages);

  void onSplitCompleted(
    String operationId,
    PdfSplitResult? result,
    bool cancelled,
  );

  void onMergeProgress(String operationId, int completedPages, int totalPages);

  void onMergeCompleted(
    String operationId,
    PdfMergeResult? result,
    bool cancelled,
  );

  void onPdfConversionProgress(
    String operationId,
    int completedPages,
    int totalPages,
  );

  void onPdfConversionCompleted(
    String operationId,
    PdfConvertToPdfResult? result,
    bool cancelled,
  );

  void onDocumentForViewingPicked(PdfViewableDocument document);

  void onDocumentForViewingCancelled();

  void onOperationFailed(
    String operationId,
    String code,
    String message,
    String? details,
  );
}
