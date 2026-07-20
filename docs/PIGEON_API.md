# Pigeon API Draft

This document defines the intended API shape.

Codex may refine names and nullability, but must preserve the architecture boundaries.

## Principles

- Expose use cases, not PDFKit objects.
- Use typed requests and typed results.
- Use stable typed error codes.
- Use asynchronous operations for search, OCR, save, and compression when necessary.
- Use callback events for page changes, progress, and dirty-state changes.
- Use zero-based page indexes everywhere across Dart and Swift.
- Use normalized or explicitly documented coordinates.

## Shared models

```dart
class PdfRect {
  double x;
  double y;
  double width;
  double height;
}

class PdfColor {
  int argb;
}

class PdfOperationError {
  String code;
  String message;
  String? details;
}

class PdfDocumentInfo {
  String workingPath;
  int pageCount;
  int currentPageIndex;
  bool hasSearchableText;
  bool isDirty;
}

class PdfSearchRequest {
  String query;
  bool caseSensitive;
  bool wholeWord;
}

class PdfSearchState {
  String query;
  int totalResults;
  int activeResultIndex;
  String? activeResultText;
}

enum PdfMarkupType {
  highlight,
  underline,
}

class PdfFreeTextRequest {
  int pageIndex;
  String text;
  PdfRect bounds;
  double fontSize;
  PdfColor textColor;
}

class PdfSaveRequest {
  String outputPath;
  bool flattenAnnotations;
}

class PdfOcrRequest {
  List<int> pageIndexes;
  List<String> recognitionLanguages;
  bool accurateRecognition;
}

class PdfOcrBlock {
  int pageIndex;
  String text;
  double confidence;
  PdfRect normalizedBoundingBox;
}

enum PdfCompressionMode {
  preserve,
  rasterized,
}

class PdfCompressionRequest {
  String outputPath;
  PdfCompressionMode mode;
  int? rasterDpi;
  double? jpegQuality;
}

class PdfCompressionResult {
  String outputPath;
  int inputBytes;
  int outputBytes;
  double compressionRatio;
  int durationMilliseconds;
}
```

## Host API

The exact method signatures may be adapted to Pigeon version constraints.

```dart
@HostApi()
abstract class PdfPocHostApi {
  PdfDocumentInfo openAssetWorkingCopy(String assetKey);

  void closeDocument();

  void resetWorkingCopy(String assetKey);

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

  void save(PdfSaveRequest request);

  void setInkModeEnabled(bool enabled);

  void clearCurrentInkInput();

  void commitCurrentInkToPdf();

  void deleteSelectedAnnotation();

  void beginSignatureCapture();

  void placeSavedSignature(int pageIndex, PdfRect bounds);

  void rotatePages(List<int> pageIndexes, int degrees);

  void deletePages(List<int> pageIndexes);

  void duplicatePage(int pageIndex, int destinationIndex);

  void movePage(int fromIndex, int toIndex);

  void cropPage(int pageIndex, PdfRect pageBounds);

  void runOcr(PdfOcrRequest request);

  void cancelOcr();

  PdfCompressionResult compress(PdfCompressionRequest request);

  void cancelCompression();
}
```

## Flutter callback API

```dart
@FlutterApi()
abstract class PdfPocFlutterApi {
  void onDocumentOpened(PdfDocumentInfo info);

  void onDocumentClosed();

  void onCurrentPageChanged(int pageIndex, int pageCount);

  void onDirtyStateChanged(bool isDirty);

  void onSearchStateChanged(PdfSearchState state);

  void onSelectionChanged(String? selectedText);

  void onOperationProgress(
    String operationId,
    int completedUnits,
    int totalUnits,
  );

  void onOcrResult(PdfOcrBlock block);

  void onOperationCompleted(String operationId);

  void onOperationFailed(
    String operationId,
    PdfOperationError error,
  );
}
```

## Platform-view identity

If the POC may display more than one native viewer, every command must be associated with a platform-view or session identifier.

For a single-view POC, one active session may be acceptable, but this limitation must be documented.

## Coordinate contract

For `PdfFreeTextRequest.bounds` and page-operation rectangles:

- Coordinates must be PDF page coordinates.
- The origin convention must be documented.
- Rotation handling must be documented.
- Crop-box versus media-box reference must be documented.

For OCR bounding boxes:

- Return normalized coordinates in the range 0 to 1.
- State whether the origin is top-left or bottom-left.
- Provide a native conversion helper to map OCR bounds to PDF page coordinates.

## Error codes

Use stable codes such as:

```text
asset_not_found
asset_copy_failed
invalid_pdf
password_required
open_failed
document_not_open
page_out_of_range
no_searchable_text
no_text_selection
invalid_annotation_bounds
annotation_creation_failed
save_failed
ocr_failed
operation_cancelled
compression_failed
unsupported_operation
internal_error
```

## Versioning

Treat the Pigeon API as an internal contract.

When changing a model or method:

1. Update this document.
2. Regenerate Dart and Swift code.
3. Update both implementations in the same change.
4. Run format, analyze, tests, and iOS build validation.
