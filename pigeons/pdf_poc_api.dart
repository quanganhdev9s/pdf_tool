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

/// Trạng thái con trỏ trong trình soạn thảo HWP, đủ để vẽ thanh công cụ.
///
/// Con trỏ và vùng chọn sống trong trang vỏ chứ không trong tài liệu — rhwp
/// không giữ chúng — nên đây là ảnh chụp đẩy ngược lên, không phải nguồn sự
/// thật để ghi xuống.
class HwpEditorState {
  HwpEditorState({
    required this.hasCaret,
    required this.hasSelection,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.strikethrough,
    required this.fontSizePt,
    required this.alignment,
    required this.lineSpacing,
    required this.canUndo,
    required this.canRedo,
    required this.dirty,
    required this.pageIndex,
    required this.pageCount,
  });

  bool hasCaret;
  bool hasSelection;
  bool bold;
  bool italic;
  bool underline;
  bool strikethrough;

  /// Cỡ chữ theo **điểm**. rhwp lưu theo HWPUNIT (pt × 100); phép chia nằm ở
  /// trang vỏ để bên Flutter không phải biết đơn vị của định dạng tệp.
  double? fontSizePt;

  /// `left`, `center`, `right`, `justify` hoặc `distribute`.
  String? alignment;
  double? lineSpacing;
  bool canUndo;
  bool canRedo;

  /// Có thay đổi chưa ghi xuống tệp. Tắt chế độ sửa khi đang bật cờ này là mất
  /// thay đổi.
  bool dirty;

  /// Trang đang hiển thị, đếm từ 0. Trình xem dựng đúng một trang mỗi lúc.
  int pageIndex;

  /// Tổng số trang, luôn ít nhất là 1.
  ///
  /// Đổi được **trong lúc sửa**: gõ thêm chữ có thể làm tài liệu nở ra hoặc co
  /// lại một trang, nên thanh lật trang phải đọc lại con số này chứ không nhớ
  /// giá trị lúc mở tệp.
  int pageCount;
}

/// Định dạng chữ cần áp. Khoá nào `null` thì giữ nguyên — bật đậm không được
/// phép lặng lẽ đặt lại cỡ chữ.
class HwpCharFormat {
  HwpCharFormat({
    this.bold,
    this.italic,
    this.underline,
    this.strikethrough,
    this.fontSizePt,
  });

  bool? bold;
  bool? italic;
  bool? underline;
  bool? strikethrough;
  double? fontSizePt;
}

/// Định dạng đoạn cần áp. Cùng quy ước `null` là giữ nguyên như
/// [HwpCharFormat].
class HwpParaFormat {
  HwpParaFormat({this.alignment, this.lineSpacing});

  String? alignment;
  double? lineSpacing;
}

/// Kết quả một lần ghi tài liệu HWP xuống đĩa.
class HwpSaveResult {
  HwpSaveResult({required this.ok, this.contentLoss, this.error});

  bool ok;

  /// Báo cáo phần nội dung trình xuất phải bỏ đi, lấy từ
  /// `exportHwpWithReport`. Không rỗng nghĩa là tệp ghi ra **không** giữ đủ
  /// tài liệu ban đầu, kể cả khi [ok].
  String? contentLoss;

  String? error;
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
  /// về qua `onHwpEditsSaved`.
  void saveDocumentEdits();

  /// Áp định dạng chữ lên vùng đang chọn.
  ///
  /// Không có vùng chọn thì định dạng được giữ lại và áp cho đoạn chữ gõ tiếp
  /// theo, giống mọi trình soạn thảo khác.
  void applyHwpCharFormat(HwpCharFormat format);

  /// Áp định dạng lên đoạn văn đang chứa con trỏ, hoặc mọi đoạn mà vùng chọn
  /// chạm tới.
  void applyHwpParaFormat(HwpParaFormat format);

  /// Cho trình soạn thảo biết Flutter đang che mất bao nhiêu điểm ở đáy web
  /// view — tức chiều cao thanh công cụ nổi.
  ///
  /// Bàn phím thì native tự đo được; chỗ này chỉ nói về phần giao diện của
  /// Flutter, thứ native không nhìn thấy. Con trỏ phải tránh cả hai.
  void setViewerChromeInset(double pixels);

  /// Hoàn tác bước sửa gần nhất. Ngăn xếp nằm trong trang vỏ và mất khi tắt
  /// chế độ sửa.
  void hwpUndo();

  void hwpRedo();

  /// Lật tới trang `pageIndex` (đếm từ 0) trong trình xem HWP.
  ///
  /// Dùng được cả khi **không** ở chế độ sửa: trình xem chỉ dựng đúng một trang
  /// mỗi lúc, nên đây là đường duy nhất để đọc phần còn lại của tài liệu.
  /// Chỉ số ngoài phạm vi bị kẹp về đầu hoặc cuối chứ không báo lỗi.
  void hwpGoToPage(int pageIndex);

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

  /// Con trỏ, vùng chọn hoặc nội dung trong trình soạn thảo HWP vừa đổi.
  void onHwpEditorStateChanged(HwpEditorState state);

  /// Một lần ghi tài liệu HWP đã xong — thành công hay không.
  void onHwpEditsSaved(HwpSaveResult result);

  void onOperationFailed(
    String operationId,
    String code,
    String message,
    String? details,
  );
}
