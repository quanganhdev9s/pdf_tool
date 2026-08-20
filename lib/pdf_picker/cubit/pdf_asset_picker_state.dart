import 'package:flutter/foundation.dart';

import '../../pdf_viewer/data/pdf_assets.dart';
import '../data/imported_pdf_store.dart';

/// What the picker shows: the PDFs bundled with the build, and the ones the
/// user brought in from Files.
@immutable
class PdfAssetPickerState {
  const PdfAssetPickerState({
    this.assets = pocPdfAssets,
    this.imported = const <ImportedPdf>[],
    this.importing = false,
    this.error,
  });

  final List<String> assets;

  /// Newest first.
  final List<ImportedPdf> imported;

  /// True while the file picker is up or a chosen file is being copied in. The
  /// picker runs in its own presented view controller, so the only thing this
  /// gates is a second import being started behind it.
  final bool importing;

  final String? error;

  PdfAssetPickerState copyWith({
    List<ImportedPdf>? imported,
    bool? importing,
    String? error,
    bool clearError = false,
  }) {
    return PdfAssetPickerState(
      assets: assets,
      imported: imported ?? this.imported,
      importing: importing ?? this.importing,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
