import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_viewer/data/pdf_assets.dart';
import '../../pdf_viewer/data/pdf_event_log.dart';
import '../data/imported_pdf_store.dart';
import 'pdf_asset_picker_state.dart';

class PdfAssetPickerCubit extends Cubit<PdfAssetPickerState> {
  PdfAssetPickerCubit({
    ImportedPdfStore? store,
    Future<BundledDocumentAssets> Function()? loadAssets,
  }) : _loadAssets = loadAssets ?? loadBundledDocumentAssets,
       _store = store ?? ImportedPdfStore(),
       super(const PdfAssetPickerState());

  final Future<BundledDocumentAssets> Function() _loadAssets;
  final ImportedPdfStore _store;

  void selectAsset(String assetKey) {
    logPdfEvent('asset_tap', <String, Object?>{'asset': assetKey});
  }

  Future<void> loadDocuments() async {
    try {
      final BundledDocumentAssets assets = await _loadAssets();
      final List<ImportedPdf> imported = await _store.list();
      if (isClosed) return;
      emit(
        state.copyWith(
          pdfAssets: assets.pdf,
          hwpAssets: assets.hwp,
          imported: imported,
          clearError: true,
        ),
      );
    } on Object catch (error) {
      if (isClosed) return;
      emit(state.copyWith(error: 'Không đọc được danh sách tài liệu: $error'));
    }
  }

  Future<void> loadImported() async {
    try {
      final List<ImportedPdf> imported = await _store.list();
      if (isClosed) return;
      emit(state.copyWith(imported: imported, clearError: true));
    } on Object catch (error) {
      if (isClosed) return;
      emit(state.copyWith(error: 'Không đọc được danh sách tài liệu: $error'));
    }
  }

  /// Presents the system file picker. Returns the imported document, or null
  /// when the user cancelled or the import failed.
  Future<ImportedPdf?> importFromFiles() async {
    if (state.importing) return null;
    emit(state.copyWith(importing: true, clearError: true));
    logPdfEvent('document_import_request');

    try {
      final ImportedPdf? document = await _store.importFromFiles();
      if (isClosed) return null;
      emit(state.copyWith(importing: false));
      if (document == null) return null;
      await loadImported();
      return document;
    } on Object catch (error) {
      if (isClosed) return null;
      emit(
        state.copyWith(importing: false, error: 'Không mở được tệp đó: $error'),
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
    await loadImported();
  }
}
