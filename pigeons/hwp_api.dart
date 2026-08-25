import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/hwp_api.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Runner/Hwp/Bridge/HwpApi.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'HwpPigeonError'),
    dartPackageName: 'pdf_tool',
  ),
)
class HwpDocumentInfo {
  HwpDocumentInfo({
    required this.sessionId,
    required this.sourcePath,
    required this.fileName,
    required this.fileFormat,
    required this.fileSizeBytes,
    required this.pageCount,
    required this.isDirty,
    required this.canOverwriteSource,
    required this.engineVersion,
  });

  String sessionId;
  String sourcePath;
  String fileName;
  String fileFormat;
  int fileSizeBytes;
  int pageCount;
  bool isDirty;
  bool canOverwriteSource;
  String engineVersion;
}

class HwpReplaceTextRequest {
  HwpReplaceTextRequest({
    required this.find,
    required this.replacement,
    required this.caseSensitive,
    required this.replaceAll,
  });

  String find;
  String replacement;
  bool caseSensitive;
  bool replaceAll;
}

class HwpEditResult {
  HwpEditResult({required this.replacementCount, required this.isDirty});

  int replacementCount;
  bool isDirty;
}

class HwpEditHistoryState {
  HwpEditHistoryState({
    required this.canUndo,
    required this.canRedo,
    required this.undoDepth,
    required this.redoDepth,
    required this.pageCount,
  });

  bool canUndo;
  bool canRedo;
  int undoDepth;
  int redoDepth;
  int pageCount;
}

class HwpSaveResult {
  HwpSaveResult({
    required this.outputPath,
    required this.fileSizeBytes,
    required this.overwroteSource,
    required this.validated,
  });

  String outputPath;
  int fileSizeBytes;
  bool overwroteSource;
  bool validated;
}

@HostApi()
abstract class HwpHostApi {
  HwpDocumentInfo openHwpAsset(String assetKey, Uint8List assetBytes);

  HwpDocumentInfo openHwpFile(String path);

  HwpDocumentInfo currentHwpDocumentInfo();

  void closeHwpDocument();

  String extractHwpText();

  String renderHwpPageSvg(int pageIndex);

  String hitTestHwpPage(int pageIndex, double x, double y);

  String getHwpCursorRect(int sectionIndex, int paragraphIndex, int charOffset);

  String insertHwpText(
    int sectionIndex,
    int paragraphIndex,
    int charOffset,
    String text,
  );

  String deleteHwpText(
    int sectionIndex,
    int paragraphIndex,
    int charOffset,
    int count,
  );

  String splitHwpParagraph(
    int sectionIndex,
    int paragraphIndex,
    int charOffset,
  );

  String mergeHwpParagraph(int sectionIndex, int paragraphIndex);

  HwpEditResult replaceHwpText(HwpReplaceTextRequest request);

  HwpEditHistoryState hwpEditHistoryState();

  HwpEditHistoryState undoHwpEdit();

  HwpEditHistoryState redoHwpEdit();

  HwpSaveResult saveHwp();

  HwpSaveResult exportHwpCopy(String outputPath);
}
