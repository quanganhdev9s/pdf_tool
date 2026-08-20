import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../pdf_viewer/data/pdf_event_log.dart';

/// A PDF the user brought in from Files, as it sits on disk.
class ImportedPdf {
  const ImportedPdf({
    required this.path,
    required this.fileName,
    required this.fileSizeBytes,
    required this.modifiedAt,
  });

  final String path;

  /// Without the extension: it is the same for every entry and only makes the
  /// list harder to scan.
  final String fileName;

  final int fileSizeBytes;
  final DateTime modifiedAt;
}

/// The imported-PDF directory, and the operations over it.
///
/// All Dart: picking a file, copying it somewhere the app owns and listing that
/// directory are things the platform channels give nothing extra for, so this
/// stays out of the native side entirely — `file_picker` presents the same
/// `UIDocumentPickerViewController` underneath.
class ImportedPdfStore {
  /// Where imported files live.
  ///
  /// Documents, so they survive the system reclaiming caches, and a directory
  /// of their own so they are never confused with the scans the app produced —
  /// deleting all your scans must not delete the documents you brought in.
  Future<Directory> directory() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    final Directory imported = Directory('${documents.path}/Imported');
    if (!imported.existsSync()) {
      await imported.create(recursive: true);
    }
    return imported;
  }

  /// Newest first. The filesystem is the source of truth: a file can arrive or
  /// vanish through the Files app without this app being involved.
  Future<List<ImportedPdf>> list() async {
    final Directory imported = await directory();
    final List<ImportedPdf> results = <ImportedPdf>[];

    for (final FileSystemEntity entity in imported.listSync()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.pdf')) {
        continue;
      }
      final FileStat stat = entity.statSync();
      results.add(
        ImportedPdf(
          path: entity.path,
          fileName: _baseName(entity.path),
          fileSizeBytes: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }

    results.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return results;
  }

  /// Presents the system file picker and keeps a copy of what was chosen.
  /// Returns null when the user cancelled.
  ///
  /// Copied rather than opened where it lies: a file in Files, iCloud Drive or
  /// another app's container is not this app's to hold open, and the picker's
  /// own copy sits in a temporary inbox the system may clear. The copy in
  /// [directory] is what makes an import still be there next launch.
  Future<ImportedPdf?> importFromFiles() async {
    logPdfEvent('pdf_import_pick_present');
    final PlatformFile? picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: <String>['pdf'],
    );

    final String? sourcePath = picked?.path;
    if (sourcePath == null) {
      logPdfEvent('pdf_import_pick_cancelled');
      return null;
    }

    final File source = File(sourcePath);
    final String destinationPath = await _freePath(for_: sourcePath);
    await source.copy(destinationPath);

    final FileStat stat = File(destinationPath).statSync();
    logPdfEvent('pdf_import_success', <String, Object?>{
      'file': _baseName(destinationPath),
      'bytes': stat.size,
    });
    return ImportedPdf(
      path: destinationPath,
      fileName: _baseName(destinationPath),
      fileSizeBytes: stat.size,
      modifiedAt: stat.modified,
    );
  }

  Future<void> delete(ImportedPdf document) async {
    final File file = File(document.path);
    if (file.existsSync()) {
      await file.delete();
      logPdfEvent('pdf_import_delete', <String, Object?>{'file': document.fileName});
    }
  }

  /// Keeps the name the user knows the file by, and only disambiguates when
  /// that name is already taken.
  Future<String> _freePath({required String for_}) async {
    final Directory imported = await directory();
    final String base = _baseName(for_).isEmpty ? 'Imported' : _baseName(for_);

    String candidate = '${imported.path}/$base.pdf';
    int suffix = 2;
    while (File(candidate).existsSync()) {
      candidate = '${imported.path}/$base ($suffix).pdf';
      suffix += 1;
    }
    return candidate;
  }

  static String _baseName(String path) {
    final String last = path.split('/').last;
    return last.toLowerCase().endsWith('.pdf')
        ? last.substring(0, last.length - 4)
        : last;
  }
}
