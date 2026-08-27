import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../common/event_log.dart';

/// A document the user brought in from Files, as it sits on disk.
class ImportedPdf {
  const ImportedPdf({
    required this.path,
    required this.fileName,
    required this.fileSizeBytes,
    required this.modifiedAt,
  });

  final String path;

  /// Includes the extension because downstream viewers use it to choose the
  /// correct renderer/editor.
  final String fileName;

  final int fileSizeBytes;
  final DateTime modifiedAt;

  String get extension => ImportedPdfStore._extension(path);

  bool get isPdf => extension == 'pdf';

  bool get isHwp => extension == 'hwp' || extension == 'hwpx';
}

/// The imported-document directory, and the operations over it.
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
      if (entity is! File || !_supportedExtension(_extension(entity.path))) {
        continue;
      }
      final FileStat stat = entity.statSync();
      results.add(
        ImportedPdf(
          path: entity.path,
          fileName: _fileName(entity.path),
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
  /// [allowedExtensions] hẹp danh sách bộ chọn nhận — tab HWP chỉ muốn HWP.
  Future<ImportedPdf?> importFromFiles({
    List<String> allowedExtensions = const <String>['pdf', 'hwp', 'hwpx'],
  }) async {
    logPdfEvent('document_import_pick_present', <String, Object?>{
      'types': allowedExtensions.join(','),
    });
    final PlatformFile? picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );

    final String? sourcePath = picked?.path;
    if (sourcePath == null) {
      logPdfEvent('document_import_pick_cancelled');
      return null;
    }

    final File source = File(sourcePath);
    final String extension = _extension(sourcePath);
    if (!_supportedExtension(extension) ||
        !allowedExtensions.contains(extension)) {
      throw StateError('Unsupported document type: .$extension');
    }
    final String destinationPath = await _freePath(for_: sourcePath);
    await source.copy(destinationPath);

    final FileStat stat = File(destinationPath).statSync();
    logPdfEvent('document_import_success', <String, Object?>{
      'file': _fileName(destinationPath),
      'type': _extension(destinationPath),
      'bytes': stat.size,
    });
    return ImportedPdf(
      path: destinationPath,
      fileName: _fileName(destinationPath),
      fileSizeBytes: stat.size,
      modifiedAt: stat.modified,
    );
  }

  Future<void> delete(ImportedPdf document) async {
    final File file = File(document.path);
    if (file.existsSync()) {
      await file.delete();
      logPdfEvent('document_import_delete', <String, Object?>{
        'file': document.fileName,
      });
    }
  }

  /// Keeps the name the user knows the file by, and only disambiguates when
  /// that name is already taken.
  Future<String> _freePath({required String for_}) async {
    final Directory imported = await directory();
    return _freePathIn(imported, for_: for_);
  }

  static Future<String> _freePathIn(
    Directory directory, {
    required String for_,
  }) async {
    final String base = _baseName(for_).isEmpty ? 'Imported' : _baseName(for_);
    final String extension = _extension(for_);

    String candidate = '${directory.path}/$base.$extension';
    int suffix = 2;
    while (File(candidate).existsSync()) {
      candidate = '${directory.path}/$base ($suffix).$extension';
      suffix += 1;
    }
    return candidate;
  }

  static String _baseName(String path) {
    final String last = path.split('/').last;
    final String extension = _extension(last);
    return _supportedExtension(extension)
        ? last.substring(0, last.length - extension.length - 1)
        : last;
  }

  static String _fileName(String path) => path.split('/').last;

  static String _extension(String path) {
    final String last = path.split('/').last;
    final int dot = last.lastIndexOf('.');
    return dot < 0 ? '' : last.substring(dot + 1).toLowerCase();
  }

  static bool _supportedExtension(String extension) {
    return extension == 'pdf' || extension == 'hwp' || extension == 'hwpx';
  }
}
