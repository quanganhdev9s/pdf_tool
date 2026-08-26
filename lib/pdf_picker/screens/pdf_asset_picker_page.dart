import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_poc_api.g.dart';
import '../../pdf_viewer/bloc/pdf_viewer_bloc.dart';
import '../../pdf_viewer/data/pdf_assets.dart';
import '../../pdf_viewer/screens/document_viewer_page.dart';
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
      create: (_) => PdfAssetPickerCubit()..loadDocuments(),
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
            title: const Text('Chọn tài liệu'),
            actions: <Widget>[
              IconButton(
                tooltip: 'Mở PDF/HWP từ tệp',
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
                onPressed: () => startScanFlow(context),
              ),
            ],
          ),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: cubit.loadDocuments,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  if (state.importing) const LinearProgressIndicator(),
                  const _SectionHeader(title: 'Tài liệu của bạn'),
                  if (state.imported.isEmpty)
                    const _EmptyImports()
                  else
                    for (final ImportedPdf document in state.imported)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ImportedTile(document: document),
                      ),
                  if (state.pdfAssets.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 16),
                    const _SectionHeader(title: 'PDF mẫu'),
                    for (final String assetKey in state.pdfAssets)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _AssetTile(assetKey: assetKey),
                      ),
                  ],
                  if (state.hwpAssets.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 16),
                    const _SectionHeader(title: 'HWP mẫu'),
                    for (final String assetKey in state.hwpAssets)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _AssetTile(assetKey: assetKey),
                      ),
                  ],
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
    final ImportedPdf? document = await cubit.importFromFiles();
    if (document == null) return;

    if (!context.mounted) return;
    await _openImportedDocument(context, document);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(title, style: Theme.of(context).textTheme.titleSmall);
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
            Icon(
              Icons.picture_as_pdf_outlined,
              color: Theme.of(context).disabledColor,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Chưa có tài liệu nào. Thêm PDF hoặc HWP từ Files, iCloud Drive hoặc '
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
        leading: Icon(
          document.isHwp
              ? Icons.description_outlined
              : Icons.picture_as_pdf_outlined,
        ),
        title: Text(document.fileName),
        subtitle: Text(_subtitle(document)),
        trailing: IconButton(
          tooltip: 'Xoá',
          icon: const Icon(Icons.delete_outline),
          onPressed: () =>
              context.read<PdfAssetPickerCubit>().deleteImported(document),
        ),
        onTap: () => _openImportedDocument(context, document),
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

Future<void> _openDocumentViewer(
  NavigatorState navigator,
  PdfViewableDocument document,
) async {
  final PdfViewerBloc bloc = PdfViewerBloc(assetKey: document.fileName);
  try {
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => BlocProvider<PdfViewerBloc>.value(
          value: bloc,
          child: DocumentViewerPage(document: document),
        ),
      ),
    );
  } finally {
    if (!bloc.isClosed) {
      bloc.add(const PdfViewerCloseDocumentViewerRequested());
      await Future<void>.delayed(Duration.zero);
      await bloc.close();
    }
  }
}

Future<void> _openImportedDocument(
  BuildContext context,
  ImportedPdf document,
) async {
  final NavigatorState navigator = Navigator.of(context);
  if (document.isHwp) {
    await _openDocumentViewer(
      navigator,
      PdfViewableDocument(
        path: document.path,
        fileName: document.fileName,
        fileFormat: document.extension,
        fileSizeBytes: document.fileSizeBytes,
      ),
    );
    return;
  }

  await navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => PdfViewerPage(
        assetKey: document.fileName,
        initialFilePath: document.path,
      ),
    ),
  );
}

Future<void> _openBundledDocument(BuildContext context, String assetKey) async {
  final NavigatorState navigator = Navigator.of(context);
  if (isHwpAsset(assetKey)) {
    try {
      final BundledDocumentFile file = await materializeBundledDocumentAsset(
        assetKey,
      );
      if (!context.mounted) return;
      await _openDocumentViewer(
        navigator,
        PdfViewableDocument(
          path: file.path,
          fileName: file.fileName,
          fileFormat: file.extension,
          fileSizeBytes: file.fileSizeBytes,
        ),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Không mở được tài liệu mẫu: $error')),
        );
    }
    return;
  }

  await navigator.push(
    MaterialPageRoute<void>(builder: (_) => PdfViewerPage(assetKey: assetKey)),
  );
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({required this.assetKey});

  final String assetKey;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(
          isHwpAsset(assetKey)
              ? Icons.description_outlined
              : Icons.picture_as_pdf_outlined,
        ),
        title: Text(assetName(assetKey)),
        subtitle: Text(assetDescription(assetKey)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          context.read<PdfAssetPickerCubit>().selectAsset(assetKey);
          _openBundledDocument(context, assetKey);
        },
      ),
    );
  }
}
