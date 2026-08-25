import 'package:flutter/foundation.dart';

import '../../hwp/data/hwp_working_document_store.dart';
import '../data/imported_pdf_store.dart';

/// What the picker shows: the PDFs bundled with the build, and the ones the
/// user brought in from Files.
@immutable
class PdfAssetPickerState {
  const PdfAssetPickerState({
    this.assets = const <String>[],
    this.hwpAssets = const <String>[],
    this.imported = const <ImportedPdf>[],
    this.hwpDocuments = const <HwpWorkingDocument>[],
    this.importing = false,
    this.loading = false,
    this.error,
  });

  final List<String> assets;
  final List<String> hwpAssets;

  /// Newest first.
  final List<ImportedPdf> imported;
  final List<HwpWorkingDocument> hwpDocuments;

  final bool loading;

  /// True while the file picker is up or a chosen file is being copied in. The
  /// picker runs in its own presented view controller, so the only thing this
  /// gates is a second import being started behind it.
  final bool importing;

  final String? error;

  PdfAssetPickerState copyWith({
    List<String>? assets,
    List<String>? hwpAssets,
    List<ImportedPdf>? imported,
    List<HwpWorkingDocument>? hwpDocuments,
    bool? importing,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return PdfAssetPickerState(
      assets: assets ?? this.assets,
      hwpAssets: hwpAssets ?? this.hwpAssets,
      imported: imported ?? this.imported,
      hwpDocuments: hwpDocuments ?? this.hwpDocuments,
      importing: importing ?? this.importing,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
