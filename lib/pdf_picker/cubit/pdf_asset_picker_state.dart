import 'package:flutter/foundation.dart';

import '../data/imported_pdf_store.dart';

/// What the picker shows: the PDFs bundled with the build, and the ones the
/// user brought in from Files.
@immutable
class PdfAssetPickerState {
  const PdfAssetPickerState({
    this.pdfAssets = const <String>[],
    this.hwpAssets = const <String>[],
    this.imported = const <ImportedPdf>[],
    this.importing = false,
    this.error,
  });

  final List<String> pdfAssets;

  final List<String> hwpAssets;

  /// Newest first.
  final List<ImportedPdf> imported;

  /// True while the file picker is up or a chosen file is being copied in. The
  /// picker runs in its own presented view controller, so the only thing this
  /// gates is a second import being started behind it.
  final bool importing;

  final String? error;

  PdfAssetPickerState copyWith({
    List<String>? pdfAssets,
    List<String>? hwpAssets,
    List<ImportedPdf>? imported,
    bool? importing,
    String? error,
    bool clearError = false,
  }) {
    return PdfAssetPickerState(
      pdfAssets: pdfAssets ?? this.pdfAssets,
      hwpAssets: hwpAssets ?? this.hwpAssets,
      imported: imported ?? this.imported,
      importing: importing ?? this.importing,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
