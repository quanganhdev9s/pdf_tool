import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';

import '../../hwp/data/hwp_working_document_store.dart';
import '../../hwp/screens/hwp_diagnostic_page.dart';
import '../../pdf_viewer/data/pdf_assets.dart';
import '../../pdf_viewer/screens/pdf_viewer_page.dart';
import '../../scan/scan_flow.dart';
import '../../scan/screens/scan_library_page.dart';
import '../cubit/pdf_asset_picker_bloc.dart';
import '../data/imported_pdf_store.dart';

class PdfAssetPickerPage extends StatelessWidget {
  const PdfAssetPickerPage({super.key, this.cubit});

  final PdfAssetPickerCubit? cubit;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<PdfAssetPickerCubit>(
      create: (_) => (cubit ?? PdfAssetPickerCubit())..loadDocuments(),
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
                tooltip: 'Mở PDF từ tệp',
                icon: const Icon(Icons.file_open_outlined),
                onPressed: state.importing ? null : () => _import(context),
              ),
              IconButton(
                tooltip: 'Mở HWP từ tệp',
                icon: const Icon(Icons.description_outlined),
                onPressed: state.importing ? null : () => _openHwp(context),
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
                  if (state.importing || state.loading)
                    const LinearProgressIndicator(),
                  const _SectionHeader(title: 'PDF của bạn'),
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
                  if (state.assets.isEmpty)
                    const _EmptyAssetKind(label: 'PDF')
                  else
                    for (final String assetKey in state.assets)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _AssetTile(assetKey: assetKey),
                      ),
                  const SizedBox(height: 16),
                  const _SectionHeader(title: 'HWP đang chỉnh sửa'),
                  if (state.hwpDocuments.isEmpty)
                    const _EmptyHwpWorkingCopies()
                  else
                    for (final HwpWorkingDocument document
                        in state.hwpDocuments)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _HwpWorkingTile(document: document),
                      ),
                  const SizedBox(height: 16),
                  const _SectionHeader(title: 'HWP mẫu'),
                  if (state.hwpAssets.isEmpty)
                    const _EmptyAssetKind(label: 'HWP')
                  else
                    for (final String assetKey in state.hwpAssets)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _HwpAssetTile(assetKey: assetKey),
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
    await cubit.loadDocuments();
  }

  Future<void> _openHwp(BuildContext context) async {
    final PdfAssetPickerCubit cubit = context.read<PdfAssetPickerCubit>();
    final NavigatorState navigator = Navigator.of(context);
    final PlatformFile? picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: <String>['hwp', 'hwpx'],
    );
    final String? path = picked?.path;
    if (path == null) return;

    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => HwpReaderPage.file(filePath: path),
      ),
    );
    await cubit.loadDocuments();
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

class _EmptyHwpWorkingCopies extends StatelessWidget {
  const _EmptyHwpWorkingCopies();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.description_outlined,
              color: Theme.of(context).disabledColor,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Chưa có bản HWP đang chỉnh sửa. Mở một HWP rồi bấm Save để '
                'tạo bản làm việc riêng.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyAssetKind extends StatelessWidget {
  const _EmptyAssetKind({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(
        'Không tìm thấy asset $label trong bundle.',
        style: Theme.of(context).textTheme.bodySmall,
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

class _HwpWorkingTile extends StatelessWidget {
  const _HwpWorkingTile({required this.document});

  final HwpWorkingDocument document;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey<String>(document.path),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: Theme.of(context).colorScheme.errorContainer,
        child: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) {
        context.read<PdfAssetPickerCubit>().deleteHwpDocument(document);
      },
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.description_outlined),
          title: Text(document.fileName),
          subtitle: Text(_subtitle(document)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final PdfAssetPickerCubit cubit = context
                .read<PdfAssetPickerCubit>();
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => HwpReaderPage.file(filePath: document.path),
              ),
            );
            await cubit.loadDocuments();
          },
        ),
      ),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Xoá bản HWP?'),
          content: Text(document.fileName),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  String _subtitle(HwpWorkingDocument document) {
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

class _HwpAssetTile extends StatelessWidget {
  const _HwpAssetTile({required this.assetKey});

  final String assetKey;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.description_outlined),
        title: Text(assetName(assetKey)),
        subtitle: const Text('Reader; bấm Save để tạo bản chỉnh sửa'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final PdfAssetPickerCubit cubit = context.read<PdfAssetPickerCubit>();
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => HwpReaderPage.asset(assetKey: assetKey),
            ),
          );
          await cubit.loadDocuments();
        },
      ),
    );
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
