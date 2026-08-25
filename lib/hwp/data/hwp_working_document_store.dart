import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'hwp_event_log.dart';

class HwpWorkingDocument {
  const HwpWorkingDocument({
    required this.path,
    required this.fileName,
    required this.fileSizeBytes,
    required this.modifiedAt,
  });

  final String path;
  final String fileName;
  final int fileSizeBytes;
  final DateTime modifiedAt;
}

class HwpWorkingDocumentStore {
  Future<Directory> directory() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    final Directory directory = Directory('${documents.path}/HwpDocuments');
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<bool> isWorkingCopyPath(String path) async {
    final Directory dir = await directory();
    return _normalize(path).startsWith('${_normalize(dir.path)}/');
  }

  Future<List<HwpWorkingDocument>> list() async {
    final Directory dir = await directory();
    final List<HwpWorkingDocument> documents = <HwpWorkingDocument>[];
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !_isHwpPath(entity.path)) {
        continue;
      }
      final FileStat stat = entity.statSync();
      documents.add(
        HwpWorkingDocument(
          path: entity.path,
          fileName: entity.path.split('/').last,
          fileSizeBytes: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }
    documents.sort((HwpWorkingDocument a, HwpWorkingDocument b) {
      return b.modifiedAt.compareTo(a.modifiedAt);
    });
    return documents;
  }

  Future<File> createEditableCopy({
    required String sourcePath,
    required String suggestedFileName,
  }) async {
    if (await isWorkingCopyPath(sourcePath)) {
      logHwpEvent('working_copy_reuse', <String, Object?>{'path': sourcePath});
      return File(sourcePath);
    }

    final File source = File(sourcePath);
    final String destinationPath = await _freePath(
      suggestedFileName: suggestedFileName,
    );
    await source.copy(destinationPath);
    final File destination = File(destinationPath);
    final FileStat stat = destination.statSync();
    logHwpEvent('working_copy_created', <String, Object?>{
      'source': sourcePath,
      'path': destinationPath,
      'bytes': stat.size,
    });
    return destination;
  }

  Future<String> createSaveDestinationPath({
    required String suggestedFileName,
  }) {
    return _freePath(suggestedFileName: suggestedFileName);
  }

  Future<void> delete(HwpWorkingDocument document) async {
    final File file = File(document.path);
    if (file.existsSync()) {
      await file.delete();
      logHwpEvent('working_copy_delete', <String, Object?>{
        'file': document.fileName,
      });
    }
  }

  Future<String> _freePath({required String suggestedFileName}) async {
    final Directory dir = await directory();
    final String cleanName = suggestedFileName.split('/').last;
    final int dot = cleanName.lastIndexOf('.');
    final String ext = dot >= 0
        ? cleanName.substring(dot).toLowerCase()
        : '.hwp';
    final String stem = dot >= 0 ? cleanName.substring(0, dot) : cleanName;
    final String base = stem.trim().isEmpty ? 'HWP' : stem.trim();

    String candidate = '${dir.path}/$base - edit$ext';
    int suffix = 2;
    while (File(candidate).existsSync()) {
      candidate = '${dir.path}/$base - edit ($suffix)$ext';
      suffix += 1;
    }
    return candidate;
  }

  static bool _isHwpPath(String path) {
    final String lower = path.toLowerCase();
    return lower.endsWith('.hwp') || lower.endsWith('.hwpx');
  }

  static String _normalize(String path) => path.replaceAll(RegExp(r'/+$'), '');
}
