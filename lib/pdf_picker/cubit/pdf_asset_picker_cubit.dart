import 'package:flutter_bloc/flutter_bloc.dart';

import '../../hwp/data/hwp_working_document_store.dart';
import '../../pdf_viewer/data/pdf_event_log.dart';
import '../data/document_asset_store.dart';
import '../data/imported_pdf_store.dart';
import 'pdf_asset_picker_state.dart';

class PdfAssetPickerCubit extends Cubit<PdfAssetPickerState> {
  PdfAssetPickerCubit({
    ImportedPdfStore? store,
    HwpWorkingDocumentStore? hwpStore,
    DocumentAssetStore? assetStore,
  }) : _store = store ?? ImportedPdfStore(),
       _hwpStore = hwpStore ?? HwpWorkingDocumentStore(),
       _assetStore = assetStore ?? DocumentAssetStore(),
       super(const PdfAssetPickerState());

  final ImportedPdfStore _store;
  final HwpWorkingDocumentStore _hwpStore;
  final DocumentAssetStore _assetStore;

  void selectAsset(String assetKey) {
    logPdfEvent('asset_tap', <String, Object?>{'asset': assetKey});
  }

  Future<void> loadDocuments() async {
    emit(state.copyWith(loading: true, clearError: true));
    final List<String> errors = <String>[];
    try {
      List<String> assets = const <String>[];
      List<String> hwpAssets = const <String>[];
      List<ImportedPdf> imported = const <ImportedPdf>[];
      List<HwpWorkingDocument> hwpDocuments = const <HwpWorkingDocument>[];

      try {
        assets = await _assetStore.listPdfAssets();
      } on Object catch (error) {
        errors.add('PDF assets: $error');
      }
      try {
        hwpAssets = await _assetStore.listHwpAssets();
      } on Object catch (error) {
        errors.add('HWP assets: $error');
      }
      if (!isClosed) {
        emit(
          state.copyWith(
            assets: assets,
            hwpAssets: hwpAssets,
            loading: true,
            error: errors.isEmpty ? null : errors.join('\n'),
            clearError: errors.isEmpty,
          ),
        );
      }
      try {
        imported = await _store.list();
      } on Object catch (error) {
        errors.add('PDF của bạn: $error');
      }
      try {
        hwpDocuments = await _hwpStore.list();
      } on Object catch (error) {
        errors.add('HWP đang chỉnh sửa: $error');
      }

      if (isClosed) return;
      emit(
        state.copyWith(
          assets: assets,
          hwpAssets: hwpAssets,
          imported: imported,
          hwpDocuments: hwpDocuments,
          loading: false,
          error: errors.isEmpty ? null : errors.join('\n'),
          clearError: errors.isEmpty,
        ),
      );
    } on Object catch (error) {
      if (isClosed) return;
      emit(
        state.copyWith(
          loading: false,
          error: 'Không đọc được danh sách tài liệu: $error',
        ),
      );
    }
  }

  Future<void> loadImported() => loadDocuments();

  /// Presents the system file picker. Returns the imported document, or null
  /// when the user cancelled or the import failed.
  Future<ImportedPdf?> importFromFiles() async {
    if (state.importing) return null;
    emit(state.copyWith(importing: true, clearError: true));
    logPdfEvent('pdf_import_request');

    try {
      final ImportedPdf? document = await _store.importFromFiles();
      if (isClosed) return null;
      emit(state.copyWith(importing: false));
      if (document == null) return null;
      await loadDocuments();
      return document;
    } on Object catch (error) {
      if (isClosed) return null;
      emit(
        state.copyWith(
          importing: false,
          error: 'Không mở được tệp PDF đó: $error',
        ),
      );
      return null;
    }
  }

  Future<void> deleteImported(ImportedPdf document) async {
    try {
      await _store.delete(document);
    } on Object catch (error) {
      if (isClosed) return;
      emit(state.copyWith(error: 'Không xoá được tệp: $error'));
    }
    await loadDocuments();
  }

  Future<void> deleteHwpDocument(HwpWorkingDocument document) async {
    try {
      await _hwpStore.delete(document);
    } on Object catch (error) {
      if (isClosed) return;
      emit(state.copyWith(error: 'Không xoá được HWP: $error'));
    }
    await loadDocuments();
  }
}
