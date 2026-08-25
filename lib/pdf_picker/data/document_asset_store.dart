import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class DocumentAssetStore {
  Future<List<String>> listPdfAssets() =>
      _listAssetsWithExtensions(const <String>{'.pdf'});

  Future<List<String>> listHwpAssets() =>
      _listAssetsWithExtensions(const <String>{'.hwp', '.hwpx'});

  Future<List<String>> _listAssetsWithExtensions(Set<String> extensions) async {
    final List<String> assetKeys = await _assetKeys();
    final List<String> assets = assetKeys.where((String key) {
      final String lower = key.toLowerCase();
      return extensions.any(lower.endsWith);
    }).toList();
    assets.sort();
    return assets;
  }

  Future<List<String>> _assetKeys() async {
    final List<String> localAssets = await _assetKeysFromPubspec();
    if (localAssets.isNotEmpty) {
      return localAssets;
    }

    try {
      final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(
        rootBundle,
      );
      final List<String> assets = manifest.listAssets();
      if (assets.isNotEmpty) {
        return assets;
      }
    } on Object {
      // The JSON manifest is kept as a compatibility fallback for tests and
      // older Flutter asset bundles.
    }

    try {
      final String manifestJson = await rootBundle.loadString(
        'AssetManifest.json',
      );
      final Map<String, dynamic> manifest =
          jsonDecode(manifestJson) as Map<String, dynamic>;
      final List<String> assets = manifest.keys.toList();
      if (assets.isNotEmpty) {
        return assets;
      }
    } on Object {
      // Fall back to pubspec scanning below in local tests.
    }
    return const <String>[];
  }

  Future<List<String>> _assetKeysFromPubspec() async {
    final File? pubspec = _findPubspec();
    if (pubspec == null) {
      return const <String>[];
    }
    final String rootPath = pubspec.parent.path;

    final Set<String> assets = <String>{};
    for (final String line in await pubspec.readAsLines()) {
      final String trimmed = line.trim();
      if (trimmed.startsWith('#') || !trimmed.startsWith('- ')) {
        continue;
      }
      final String assetPath = trimmed.substring(2).trim();
      if (!assetPath.startsWith('assets/')) {
        continue;
      }
      final String resolvedPath = '$rootPath/$assetPath';
      final FileSystemEntityType type = FileSystemEntity.typeSync(resolvedPath);
      if (type == FileSystemEntityType.directory) {
        for (final FileSystemEntity entity in Directory(
          resolvedPath,
        ).listSync(recursive: true)) {
          if (entity is File) {
            assets.add(_relativeAssetKey(rootPath, entity.path));
          }
        }
      } else if (type == FileSystemEntityType.file) {
        assets.add(assetPath);
      }
    }
    final List<String> sorted = assets.toList()..sort();
    return sorted;
  }

  File? _findPubspec() {
    final List<Directory> starts = <Directory>[Directory.current];
    try {
      final String scriptPath = Platform.script.toFilePath();
      if (scriptPath.isNotEmpty) {
        starts.add(File(scriptPath).parent);
      }
    } on Object {
      // Some embedder script URIs are not file paths.
    }

    for (final Directory start in starts) {
      Directory directory = start;
      for (int depth = 0; depth < 10; depth += 1) {
        final File pubspec = File('${directory.path}/pubspec.yaml');
        if (pubspec.existsSync()) {
          return pubspec;
        }
        final Directory parent = directory.parent;
        if (parent.path == directory.path) {
          break;
        }
        directory = parent;
      }
    }
    return null;
  }

  String _relativeAssetKey(String rootPath, String filePath) {
    final String normalizedRoot = rootPath.replaceAll(RegExp(r'/+$'), '');
    if (filePath.startsWith('$normalizedRoot/')) {
      return filePath.substring(normalizedRoot.length + 1);
    }
    return filePath;
  }
}
