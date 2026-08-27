import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const List<String> _documentAssetRoots = <String>['assets/pdf/', 'assets/hwp/'];

const Set<String> _documentAssetExtensions = <String>{'pdf', 'hwp', 'hwpx'};

class BundledDocumentFile {
  const BundledDocumentFile({
    required this.path,
    required this.fileName,
    required this.extension,
    required this.fileSizeBytes,
  });

  final String path;
  final String fileName;
  final String extension;
  final int fileSizeBytes;
}

class BundledDocumentAssets {
  const BundledDocumentAssets({this.pdf = const <String>[], this.hwp = const <String>[]});

  final List<String> pdf;
  final List<String> hwp;
}

Future<BundledDocumentAssets> loadBundledDocumentAssets({AssetBundle? bundle}) async {
  final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(bundle ?? rootBundle);
  final List<String> pdf = <String>[];
  final List<String> hwp = <String>[];
  for (final String asset in manifest.listAssets()) {
    if (!isSupportedDocumentAsset(asset)) {
      continue;
    }
    if (isHwpAsset(asset)) {
      hwp.add(asset);
    } else if (isPdfAsset(asset)) {
      pdf.add(asset);
    }
  }
  return BundledDocumentAssets(
    pdf: pdf..sort(_compareDocumentAssets),
    hwp: hwp..sort(_compareDocumentAssets),
  );
}

Future<BundledDocumentFile> materializeBundledDocumentAsset(String assetKey) async {
  final ByteData data = await rootBundle.load(assetKey);
  final Uint8List bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final Directory cache = await getTemporaryDirectory();
  final Directory directory = Directory('${cache.path}/bundled_documents')
    ..createSync(recursive: true);
  final File file = File('${directory.path}/${assetName(assetKey)}');
  await file.writeAsBytes(bytes, flush: true);
  return BundledDocumentFile(
    path: file.path,
    fileName: assetName(assetKey),
    extension: assetExtension(assetKey),
    fileSizeBytes: bytes.length,
  );
}

String assetName(String key) => key.split('/').last;

String assetExtension(String key) {
  final String name = assetName(key);
  final int dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

bool isSupportedDocumentAsset(String key) {
  return _documentAssetRoots.any(key.startsWith) &&
      _documentAssetExtensions.contains(assetExtension(key));
}

bool isHwpAsset(String key) {
  final String extension = assetExtension(key);
  return extension == 'hwp' || extension == 'hwpx';
}

bool isPdfAsset(String key) => assetExtension(key) == 'pdf';

String assetDescription(String key) {
  if (isHwpAsset(key)) {
    return 'Bundled HWP document';
  }
  if (key.contains('scanned')) {
    return 'Scan-only PDF for no-searchable-text validation';
  }
  if (key.contains('annotations')) {
    return 'Existing annotations PDF';
  }
  if (key.contains('password')) {
    return 'Password-protected PDF';
  }
  return 'Searchable text PDF';
}

int _compareDocumentAssets(String left, String right) {
  final int rootCompare = _rootSortKey(left).compareTo(_rootSortKey(right));
  if (rootCompare != 0) return rootCompare;
  return assetName(left).compareTo(assetName(right));
}

int _rootSortKey(String key) {
  final int index = _documentAssetRoots.indexWhere(key.startsWith);
  return index < 0 ? _documentAssetRoots.length : index;
}
