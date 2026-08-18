import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/pdf_scan_api.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Runner/PdfPoc/Bridge/PdfScanApi.g.swift',
    // The app links one Swift module, so the second generated file must not
    // redeclare PigeonError alongside PdfPocApi.g.swift.
    swiftOptions: SwiftOptions(includeErrorClass: false),
    dartPackageName: 'pdf_tool',
  ),
)
/// Where the pages of a scan session came from. Capture is split by source
/// because the two paths have different guarantees: the camera screen detects
/// the page and corrects its perspective, the photo picker gives whatever the
/// user shot.
enum PdfScanSource { scanner, photoPicker }

/// Enhancement applied to a page. Kept as a closed set rather than a bag of
/// generic photo knobs: each preset is tuned against fixture images, so it can
/// be regression-tested.
///
/// Uneven lighting is not a preset and not a control: the pipeline detects
/// under-lit regions itself and corrects only those, with the gain bounded. It
/// is deliberately not exposed — a global knob moved parts of the capture that
/// were already correct, and a manual one made the user do the detector's job.
enum PdfScanPreset { original, enhancedColor, cleanGrayscale, blackAndWhite }

/// Output resolution and compression for the exported PDF.
enum PdfScanExportQuality { standard, high }

class PdfScanSessionInfo {
  PdfScanSessionInfo({
    required this.sessionId,
    required this.pageCount,
    required this.source,
  });

  String sessionId;
  int pageCount;
  PdfScanSource source;
}

class PdfScanPageInfo {
  PdfScanPageInfo({
    required this.pageId,
    required this.index,
    required this.preset,
    required this.rotationDegrees,
  });

  String pageId;
  int index;
  PdfScanPreset preset;

  /// Stored as metadata and applied at render/export time only, so rotating a
  /// page never invalidates its processed-image cache.
  int rotationDegrees;
}

class PdfScanExportRequest {
  PdfScanExportRequest({
    required this.sessionId,
    required this.quality,
    required this.outputPath,
  });

  String sessionId;
  PdfScanExportQuality quality;

  /// Empty means "let the native side choose a path in the session directory".
  String outputPath;
}

class PdfScanExportResult {
  PdfScanExportResult({
    required this.outputPath,
    required this.pageCount,
    required this.fileSizeBytes,
    required this.durationMilliseconds,
    required this.presetSummary,
  });

  String outputPath;
  int pageCount;
  int fileSizeBytes;
  int durationMilliseconds;

  /// Human-readable tally of the presets that produced this file, e.g.
  /// "enhancedColor x3, original x1". Surfaced in the export confirmation.
  String presetSummary;
}

/// A PDF the scanner has already produced. Lives in Documents, so it outlives
/// the session that made it.
class PdfScanExportedDocument {
  PdfScanExportedDocument({
    required this.path,
    required this.fileName,
    required this.pageCount,
    required this.fileSizeBytes,
    required this.createdAtEpochMs,
  });

  String path;
  String fileName;
  int pageCount;
  int fileSizeBytes;
  int createdAtEpochMs;
}

@HostApi()
abstract class PdfScanHostApi {
  /// Presents the app's own capture screen — live edge detection, auto-capture
  /// and perspective correction, but no colour processing, which the pipeline
  /// does instead. Pages land in a new session; no PDF is produced here.
  void startDocumentCapture();

  /// Presents `PHPickerViewController`. Selected images are copied into a new
  /// session in the order they were picked.
  void pickScanImages();

  List<PdfScanPageInfo> getScanPages(String sessionId);

  void rotateScanPage(String sessionId, String pageId, int degrees);

  void deleteScanPage(String sessionId, String pageId);

  void reorderScanPages(String sessionId, List<String> pageIds);

  /// Reprocesses from the original capture every time, so switching presets
  /// never compounds one enhancement on top of another.
  void applyPreset(String sessionId, String pageId, PdfScanPreset preset);

  void applyPresetToAll(String sessionId, PdfScanPreset preset);

  /// Toggles the review canvas between the original capture and the processed
  /// result. Cheap because both are already cached.
  void setComparingOriginal(String sessionId, bool comparing);

  void showScanPage(String sessionId, String pageId);

  void exportScanSessionToPdf(PdfScanExportRequest request);

  void cancelScanOperation(String operationId);

  /// Deletes the session directory. Sessions not discarded explicitly are
  /// swept on next launch by age.
  void discardScanSession(String sessionId);

  /// Everything the scanner has exported, newest first.
  List<PdfScanExportedDocument> listExportedScans();

  /// Presents the file in Quick Look. Self-contained so the scan library does
  /// not have to reach into the PDF workspace.
  void openExportedScan(String path);

  void shareExportedScan(String path);

  void deleteExportedScan(String path);
}

@FlutterApi()
abstract class PdfScanFlutterApi {
  void onScanSessionCreated(PdfScanSessionInfo info);

  void onScanSessionCancelled();

  void onScanPagesChanged(String sessionId, List<PdfScanPageInfo> pages);

  void onScanCurrentPageChanged(String sessionId, int pageIndex, int pageCount);

  void onScanPageProcessed(String sessionId, PdfScanPageInfo page);

  void onScanProgress(String operationId, int completedPages, int totalPages);

  void onScanExportCompleted(
    String operationId,
    PdfScanExportResult? result,
    bool cancelled,
  );

  void onScanOperationFailed(
    String operationId,
    String code,
    String message,
    String? details,
  );
}
