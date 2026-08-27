import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_scan_api.g.dart';
import '../../pdf_viewer/screens/pdf_viewer_page.dart';
import '../bloc/scan_library_cubit.dart';
import '../scan_flow.dart';

/// The PDFs the scanner has produced.
///
/// Cubit tạo ngay ở đây vì nó chỉ sống cùng màn hình này — khác
/// `ScanReviewBloc`, cái phải nằm trên navigator để nhận callback từ native.
class ScanLibraryPage extends StatelessWidget {
  const ScanLibraryPage({super.key, this.highlightPath});

  /// Path of a scan that was just exported, so it can be called out on arrival.
  final String? highlightPath;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ScanLibraryCubit>(
      create: (_) => ScanLibraryCubit()..reload(),
      child: _ScanLibraryView(highlightPath: highlightPath),
    );
  }
}

class _ScanLibraryView extends StatelessWidget {
  const _ScanLibraryView({required this.highlightPath});

  final String? highlightPath;

  @override
  Widget build(BuildContext context) {
    final ScanLibraryCubit cubit = context.read<ScanLibraryCubit>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF đã quét'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Quét tài liệu',
            icon: const Icon(Icons.document_scanner_outlined),
            onPressed: () async {
              await startScanFlow(context);
              await cubit.reload();
            },
          ),
        ],
      ),
      body: BlocBuilder<ScanLibraryCubit, ScanLibraryState>(
        builder: (context, state) =>
            RefreshIndicator(onRefresh: cubit.reload, child: _body(context, state)),
      ),
    );
  }

  Widget _body(BuildContext context, ScanLibraryState state) {
    final String? error = state.error;
    if (error != null) {
      return _message(context, error, icon: Icons.error_outline);
    }
    final List<PdfScanExportedDocument>? documents = state.documents;
    if (documents == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (documents.isEmpty) {
      return _message(
        context,
        'Chưa có PDF nào.\nQuét một tài liệu để bắt đầu.',
        icon: Icons.picture_as_pdf_outlined,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: documents.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        final PdfScanExportedDocument document = documents[index];
        final bool isNew = document.path == highlightPath;
        return Card(
          margin: EdgeInsets.zero,
          color: isNew ? Theme.of(context).colorScheme.secondaryContainer : null,
          child: ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: Text(document.fileName),
            subtitle: Text(_subtitle(document)),
            onTap: () => _open(context, document),
            trailing: PopupMenuButton<String>(
              onSelected: (String action) => _handle(context, action, document),
              itemBuilder: (_) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(value: 'quicklook', child: Text('Xem nhanh')),
                PopupMenuItem<String>(value: 'share', child: Text('Chia sẻ')),
                PopupMenuItem<String>(value: 'delete', child: Text('Xoá')),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _message(BuildContext context, String text, {required IconData icon}) {
    // Must stay scrollable or pull-to-refresh stops working when the list is
    // empty — which is exactly when a stale empty state is most confusing.
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 96),
      children: <Widget>[
        Icon(icon, size: 48, color: Theme.of(context).disabledColor),
        const SizedBox(height: 16),
        Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }

  String _subtitle(PdfScanExportedDocument document) {
    final DateTime created = DateTime.fromMillisecondsSinceEpoch(document.createdAtEpochMs);
    final String stamp =
        '${created.day.toString().padLeft(2, '0')}/'
        '${created.month.toString().padLeft(2, '0')}/${created.year} '
        '${created.hour.toString().padLeft(2, '0')}:'
        '${created.minute.toString().padLeft(2, '0')}';
    final String size = document.fileSizeBytes >= 1024 * 1024
        ? '${(document.fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '${(document.fileSizeBytes / 1024).round()} KB';
    return '${document.pageCount} trang · $size · $stamp';
  }

  /// Opens the PDF in the app's own workspace — bottom tool bar, OCR, split,
  /// annotation. The native side copies the file before opening it, so editing
  /// here never touches the exported original.
  Future<void> _open(BuildContext context, PdfScanExportedDocument document) async {
    final ScanLibraryCubit cubit = context.read<ScanLibraryCubit>();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PdfViewerPage(assetKey: document.fileName, initialFilePath: document.path),
      ),
    );
    await cubit.reload();
  }

  Future<void> _handle(
    BuildContext context,
    String action,
    PdfScanExportedDocument document,
  ) async {
    final ScanLibraryCubit cubit = context.read<ScanLibraryCubit>();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    switch (action) {
      case 'quicklook':
        // Mở hỏng thường là tệp đã biến mất sau lưng màn hình, nên nạp lại.
        final String? error = await cubit.quickLook(document.path);
        if (error == null) return;
        _report(messenger, error);
        await cubit.reload();
      case 'share':
        _report(messenger, await cubit.share(document.path));
      case 'delete':
        await _confirmDelete(context, document);
    }
  }

  Future<void> _confirmDelete(BuildContext context, PdfScanExportedDocument document) async {
    final ScanLibraryCubit cubit = context.read<ScanLibraryCubit>();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Xoá ${document.fileName}?'),
        content: const Text('File sẽ bị xoá khỏi thiết bị.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;

    _report(messenger, await cubit.delete(document.path));
    await cubit.reload();
  }

  void _report(ScaffoldMessengerState messenger, String? message) {
    if (message == null) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}
