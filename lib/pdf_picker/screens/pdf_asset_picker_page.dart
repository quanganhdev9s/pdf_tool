import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_viewer/data/pdf_assets.dart';
import '../../pdf_viewer/screens/pdf_viewer_page.dart';
import '../../scan/scan_flow.dart';
import '../../scan/screens/scan_library_page.dart';
import '../cubit/pdf_asset_picker_bloc.dart';
import '../data/imported_pdf_store.dart';

class PdfAssetPickerPage extends StatelessWidget {
  const PdfAssetPickerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<PdfAssetPickerCubit>(
      create: (_) => PdfAssetPickerCubit()..loadImported(),
      child: const _PdfAssetPickerView(),
    );
  }
}

class _PdfAssetPickerView extends StatelessWidget {
  const _PdfAssetPickerView();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PdfAssetPickerCubit, PdfAssetPickerState>(
      listenWhen: (previous, current) =>
          current.error != null && previous.error != current.error,
      listener: (context, state) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(state.error!)));
      },
      builder: (context, state) {
        final PdfAssetPickerCubit cubit = context.read<PdfAssetPickerCubit>();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Chọn PDF'),
            actions: <Widget>[
              IconButton(
                tooltip: 'Mở PDF từ tệp',
                icon: const Icon(Icons.file_open_outlined),
                onPressed: state.importing ? null : () => _import(context),
              ),
              IconButton(
                tooltip: 'PDF đã quét',
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ScanLibraryPage(),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Quét tài liệu',
                icon: const Icon(Icons.document_scanner_outlined),
                onPressed: () => startScanFlow(context, fromPhotoLibrary: false),
              ),
              IconButton(
                tooltip: 'Chọn ảnh',
                icon: const Icon(Icons.photo_library_outlined),
                onPressed: () => startScanFlow(context, fromPhotoLibrary: true),
              ),
            ],
          ),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: cubit.loadImported,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  if (state.importing) const LinearProgressIndicator(),
                  _SectionHeader(
                    title: 'PDF của bạn',
                    trailing: TextButton.icon(
                      onPressed: state.importing ? null : () => _import(context),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Thêm từ tệp'),
                    ),
                  ),
                  if (state.imported.isEmpty)
                    const _EmptyImports()
                  else
                    for (final ImportedPdf document in state.imported)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ImportedTile(document: document),
                      ),
                  const SizedBox(height: 16),
                  const _SectionHeader(title: 'PDF mẫu'),
                  for (final String assetKey in state.assets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _AssetTile(assetKey: assetKey),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Imports, then opens what was imported. Opening straight away is the point
  /// of having asked for a file; the entry stays in the list for next time.
  Future<void> _import(BuildContext context) async {
    final PdfAssetPickerCubit cubit = context.read<PdfAssetPickerCubit>();
    final NavigatorState navigator = Navigator.of(context);
    final ImportedPdf? document = await cubit.importFromFiles();
    if (document == null) return;

    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => PdfViewerPage(
          assetKey: document.fileName,
          initialFilePath: document.path,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        ?trailing,
      ],
    );
  }
}

class _EmptyImports extends StatelessWidget {
  const _EmptyImports();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            Icon(Icons.picture_as_pdf_outlined, color: Theme.of(context).disabledColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Chưa có PDF nào. Thêm một tệp từ Files, iCloud Drive hoặc '
                'ứng dụng khác — bản sao sẽ nằm lại đây.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportedTile extends StatelessWidget {
  const _ImportedTile({required this.document});

  final ImportedPdf document;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.picture_as_pdf_outlined),
        title: Text(document.fileName),
        subtitle: Text(_subtitle(document)),
        trailing: IconButton(
          tooltip: 'Xoá',
          icon: const Icon(Icons.delete_outline),
          onPressed: () =>
              context.read<PdfAssetPickerCubit>().deleteImported(document),
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PdfViewerPage(
              assetKey: document.fileName,
              initialFilePath: document.path,
            ),
          ),
        ),
      ),
    );
  }

  /// Size and date, no page count: counting pages means opening every file in
  /// the list, and the only thing that could do it in Dart is another PDF
  /// library pulled in for one number on a subtitle.
  String _subtitle(ImportedPdf document) {
    final DateTime added = document.modifiedAt;
    final String stamp =
        '${added.day.toString().padLeft(2, '0')}/'
        '${added.month.toString().padLeft(2, '0')}/${added.year}';
    final String size = document.fileSizeBytes >= 1024 * 1024
        ? '${(document.fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '${(document.fileSizeBytes / 1024).round()} KB';
    return '$size · $stamp';
  }
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({required this.assetKey});

  final String assetKey;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.picture_as_pdf_outlined),
        title: Text(assetName(assetKey)),
        subtitle: Text(assetDescription(assetKey)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          context.read<PdfAssetPickerCubit>().selectAsset(assetKey);
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PdfViewerPage(assetKey: assetKey),
            ),
          );
        },
      ),
    );
  }
}
