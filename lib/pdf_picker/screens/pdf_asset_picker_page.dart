import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../common/event_log.dart';
import '../../hwp/bloc/hwp_viewer_cubit.dart';
import '../../hwp/hwp_api.g.dart';
import '../../hwp/screens/hwp_viewer_page.dart';
import '../../common/bundled_assets.dart';
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
      listenWhen: (previous, current) => current.error != null && previous.error != current.error,
      listener: (context, state) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(state.error!)));
      },
      builder: (context, state) {
        final PdfAssetPickerCubit cubit = context.read<PdfAssetPickerCubit>();
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Chọn tài liệu'),
              actions: <Widget>[
                IconButton(
                  tooltip: 'PDF đã quét',
                  icon: const Icon(Icons.folder_open_outlined),
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => const ScanLibraryPage())),
                ),
                IconButton(
                  tooltip: 'Quét tài liệu',
                  icon: const Icon(Icons.document_scanner_outlined),
                  onPressed: () => startScanFlow(context),
                ),
              ],
              bottom: const TabBar(
                tabs: <Widget>[
                  Tab(text: 'PDF'),
                  Tab(text: 'HWP'),
                ],
              ),
            ),
            body: SafeArea(
              child: Column(
                children: <Widget>[
                  if (state.importing) const LinearProgressIndicator(),
                  Expanded(
                    child: TabBarView(
                      children: <Widget>[
                        _PdfTab(state: state, cubit: cubit),
                        _HwpTab(state: state, cubit: cubit),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// PDF: bản người dùng mang vào, rồi tới mẫu đi kèm bản build.
class _PdfTab extends StatelessWidget {
  const _PdfTab({required this.state, required this.cubit});

  final PdfAssetPickerState state;
  final PdfAssetPickerCubit cubit;

  @override
  Widget build(BuildContext context) {
    final List<ImportedPdf> imported = state.imported
        .where((ImportedPdf document) => !document.isHwp)
        .toList();

    return RefreshIndicator(
      onRefresh: cubit.loadDocuments,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _OpenButton(
            label: 'Mở PDF từ tệp',
            enabled: !state.importing,
            onPressed: () => _import(context, const <String>['pdf']),
          ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Tài liệu của bạn'),
          if (imported.isEmpty)
            const _EmptyList(
              icon: Icons.picture_as_pdf_outlined,
              message:
                  'Chưa có PDF nào. Thêm từ Files, iCloud Drive hoặc ứng dụng '
                  'khác — bản sao sẽ nằm lại đây.',
            )
          else
            for (final ImportedPdf document in imported)
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
        ],
      ),
    );
  }
}

/// HWP: những tệp từng mở hoặc từng ghi lại, rồi tới mẫu đi kèm bản build.
///
/// Danh sách đọc thẳng từ thư mục `Imported`, mà trình soạn thảo cũng ghi đè
/// tại chỗ vào đúng thư mục đó — nên "từng mở" và "từng ghi" là cùng một danh
/// sách, không phải giữ thêm lịch sử nào.
class _HwpTab extends StatelessWidget {
  const _HwpTab({required this.state, required this.cubit});

  final PdfAssetPickerState state;
  final PdfAssetPickerCubit cubit;

  @override
  Widget build(BuildContext context) {
    final List<ImportedPdf> imported = state.imported
        .where((ImportedPdf document) => document.isHwp)
        .toList();

    return RefreshIndicator(
      onRefresh: cubit.loadDocuments,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _OpenButton(
            label: 'Mở tệp HWP',
            enabled: !state.importing,
            onPressed: () => _import(context, const <String>['hwp', 'hwpx']),
          ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Đã mở gần đây'),
          if (imported.isEmpty)
            const _EmptyList(
              icon: Icons.description_outlined,
              message:
                  'Chưa mở tệp HWP nào. Tệp mở ở đây được giữ lại kèm mọi thay '
                  'đổi đã lưu.',
            )
          else
            for (final ImportedPdf document in imported)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ImportedTile(document: document),
              ),
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
    );
  }
}

class _OpenButton extends StatelessWidget {
  const _OpenButton({required this.label, required this.enabled, required this.onPressed});

  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: const Icon(Icons.file_open_outlined),
        label: Text(label),
      ),
    );
  }
}

/// Nhập rồi mở luôn: đã đi tìm một tệp thì cái muốn là xem nó, còn mục trong
/// danh sách là để lần sau.
Future<void> _import(BuildContext context, List<String> extensions) async {
  final PdfAssetPickerCubit cubit = context.read<PdfAssetPickerCubit>();
  final ImportedPdf? document = await cubit.importFromFiles(allowedExtensions: extensions);
  if (document == null) return;

  if (!context.mounted) return;
  await _openImportedDocument(context, document);
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(title, style: Theme.of(context).textTheme.titleSmall);
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            Icon(icon, color: Theme.of(context).disabledColor),
            const SizedBox(width: 12),
            Expanded(child: Text(message, style: Theme.of(context).textTheme.bodySmall)),
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
        leading: Icon(document.isHwp ? Icons.description_outlined : Icons.picture_as_pdf_outlined),
        title: Text(document.fileName),
        subtitle: Text(_subtitle(document)),
        trailing: IconButton(
          tooltip: 'Xoá',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => context.read<PdfAssetPickerCubit>().deleteImported(document),
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

/// Mở trình xem HWP trên một route riêng, kèm cubit sống đúng bằng route đó.
///
/// `HwpFlutterApi` chỉ đăng ký được một đầu nhận mỗi lúc, nên cubit **phải**
/// đóng lại trước khi mở tài liệu kế tiếp.
Future<void> _openHwpViewer(NavigatorState navigator, HwpDocument document) async {
  // Mốc 0 của một lượt mở tệp. Native có đồng hồ riêng, bắt đầu khi nó nhận
  // `loadDocument`; so hai bên theo dòng `hwp_load_into_viewer`.
  startPdfEventClock();
  final HwpViewerCubit cubit = HwpViewerCubit(document: document);
  try {
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => BlocProvider<HwpViewerCubit>.value(
          value: cubit,
          child: HwpViewerPage(document: document),
        ),
      ),
    );
  } finally {
    if (!cubit.isClosed) {
      await cubit.closeViewer();
      await cubit.close();
    }
  }
}

Future<void> _openImportedDocument(BuildContext context, ImportedPdf document) async {
  final NavigatorState navigator = Navigator.of(context);
  if (document.isHwp) {
    await _openHwpViewer(
      navigator,
      HwpDocument(
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
      builder: (_) => PdfViewerPage(assetKey: document.fileName, initialFilePath: document.path),
    ),
  );
}

Future<void> _openBundledDocument(BuildContext context, String assetKey) async {
  final NavigatorState navigator = Navigator.of(context);
  if (isHwpAsset(assetKey)) {
    try {
      final BundledDocumentFile file = await materializeBundledDocumentAsset(assetKey);
      if (!context.mounted) return;
      await _openHwpViewer(
        navigator,
        HwpDocument(
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
        ..showSnackBar(SnackBar(content: Text('Không mở được tài liệu mẫu: $error')));
    }
    return;
  }

  await navigator.push(MaterialPageRoute<void>(builder: (_) => PdfViewerPage(assetKey: assetKey)));
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
          isHwpAsset(assetKey) ? Icons.description_outlined : Icons.picture_as_pdf_outlined,
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
