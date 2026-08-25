import 'package:flutter/services.dart';

import '../data/hwp_event_log.dart';
import '../data/hwp_working_document_store.dart';
import '../../hwp_api.g.dart';

class HwpSaveEditOutcome {
  const HwpSaveEditOutcome({
    required this.result,
    required this.info,
    required this.createdWorkingCopy,
  });

  final HwpSaveResult result;
  final HwpDocumentInfo info;
  final bool createdWorkingCopy;
}

class HwpDocumentService {
  HwpDocumentService({HwpHostApi? api, HwpWorkingDocumentStore? workingStore})
    : _api = api ?? HwpHostApi(),
      _workingStore = workingStore ?? HwpWorkingDocumentStore();

  final HwpHostApi _api;
  final HwpWorkingDocumentStore _workingStore;

  Future<HwpDocumentInfo> openAsset(String assetKey) async {
    logHwpEvent('open_asset_start', <String, Object?>{'asset': assetKey});
    final ByteData data = await rootBundle.load(assetKey);
    final Uint8List bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final HwpDocumentInfo info = await _api.openHwpAsset(assetKey, bytes);
    logHwpEvent('open_asset_success', <String, Object?>{
      'file': info.fileName,
      'pages': info.pageCount,
      'editable': info.canOverwriteSource,
    });
    return info;
  }

  Future<HwpDocumentInfo> openFile(String path) async {
    logHwpEvent('open_file_start', <String, Object?>{'path': path});
    final HwpDocumentInfo info = await _api.openHwpFile(path);
    logHwpEvent('open_file_success', <String, Object?>{
      'file': info.fileName,
      'pages': info.pageCount,
      'editable': info.canOverwriteSource,
    });
    return info;
  }

  Future<HwpDocumentInfo> currentInfo() => _api.currentHwpDocumentInfo();

  Future<void> close() => _api.closeHwpDocument();

  Future<String> extractText() => _api.extractHwpText();

  Future<String> renderPageSvg(int pageIndex) async =>
      _sanitizeSvgForFlutter(await _api.renderHwpPageSvg(pageIndex));

  Future<String> hitTestPage({
    required int pageIndex,
    required double x,
    required double y,
  }) => _api.hitTestHwpPage(pageIndex, x, y);

  Future<String> getCursorRect({
    required int sectionIndex,
    required int paragraphIndex,
    required int charOffset,
  }) => _api.getHwpCursorRect(sectionIndex, paragraphIndex, charOffset);

  Future<String> insertText({
    required int sectionIndex,
    required int paragraphIndex,
    required int charOffset,
    required String text,
  }) => _api.insertHwpText(sectionIndex, paragraphIndex, charOffset, text);

  Future<String> deleteText({
    required int sectionIndex,
    required int paragraphIndex,
    required int charOffset,
    required int count,
  }) => _api.deleteHwpText(sectionIndex, paragraphIndex, charOffset, count);

  Future<String> splitParagraph({
    required int sectionIndex,
    required int paragraphIndex,
    required int charOffset,
  }) => _api.splitHwpParagraph(sectionIndex, paragraphIndex, charOffset);

  Future<String> mergeParagraph({
    required int sectionIndex,
    required int paragraphIndex,
  }) => _api.mergeHwpParagraph(sectionIndex, paragraphIndex);

  Future<HwpEditResult> replaceText({
    required String find,
    required String replacement,
    bool caseSensitive = false,
    bool replaceAll = true,
  }) {
    return _api.replaceHwpText(
      HwpReplaceTextRequest(
        find: find,
        replacement: replacement,
        caseSensitive: caseSensitive,
        replaceAll: replaceAll,
      ),
    );
  }

  Future<HwpEditHistoryState> editHistoryState() => _api.hwpEditHistoryState();

  Future<HwpEditHistoryState> undoEdit() => _api.undoHwpEdit();

  Future<HwpEditHistoryState> redoEdit() => _api.redoHwpEdit();

  Future<HwpSaveResult> save() async {
    logHwpEvent('save_start');
    final HwpSaveResult result = await _api.saveHwp();
    logHwpEvent('save_success', <String, Object?>{
      'path': result.outputPath,
      'bytes': result.fileSizeBytes,
    });
    return result;
  }

  Future<HwpSaveResult> exportCopy(String outputPath) =>
      _api.exportHwpCopy(outputPath);

  Future<HwpSaveEditOutcome> saveEditedDocument(HwpDocumentInfo current) async {
    final bool isWorkingCopy = await _workingStore.isWorkingCopyPath(
      current.sourcePath,
    );
    if (current.canOverwriteSource && isWorkingCopy) {
      logHwpEvent('save_edit_overwrite_working_copy', <String, Object?>{
        'path': current.sourcePath,
      });
      final HwpSaveResult result = await save();
      return HwpSaveEditOutcome(
        result: result,
        info: await currentInfo(),
        createdWorkingCopy: false,
      );
    }

    final String outputPath = await _workingStore.createSaveDestinationPath(
      suggestedFileName: current.fileName,
    );
    logHwpEvent('save_edit_export_copy_start', <String, Object?>{
      'source': current.sourcePath,
      'output': outputPath,
    });
    final HwpSaveResult result = await exportCopy(outputPath);
    logHwpEvent('save_edit_export_copy_done', <String, Object?>{
      'output': result.outputPath,
      'bytes': result.fileSizeBytes,
    });
    final HwpDocumentInfo info = await openFile(outputPath);
    return HwpSaveEditOutcome(
      result: result,
      info: info,
      createdWorkingCopy: true,
    );
  }

  String _sanitizeSvgForFlutter(String svg) {
    final String withoutClosedImages = svg.replaceAll(
      RegExp(
        r'''<image\b(?=[^>]*(?:href|xlink:href)=["']data:image/svg\+xml)[^>]*>.*?</image>''',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    );
    return withoutClosedImages.replaceAll(
      RegExp(
        r'''<image\b[^>]*(?:href|xlink:href)=["']data:image/svg\+xml[^"']*["'][^>]*/?>''',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    );
  }
}
