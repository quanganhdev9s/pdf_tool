import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../pdf_scan_api.g.dart';
import '../../pdf_viewer/screens/pdf_viewer_page.dart';
import '../scan_flow.dart';

/// The PDFs the scanner has produced.
///
/// Reads the exports directory directly rather than mirroring it in
/// `ScanReviewBloc`: the list is a snapshot of the filesystem, and files can
/// appear or vanish through the Files app without this screen being involved.
class ScanLibraryPage extends StatefulWidget {
  const ScanLibraryPage({super.key, this.highlightPath});

  /// Path of a scan that was just exported, so it can be called out on arrival.
  final String? highlightPath;

  @override
  State<ScanLibraryPage> createState() => _ScanLibraryPageState();
}

class _ScanLibraryPageState extends State<ScanLibraryPage> {
  final PdfScanHostApi _api = PdfScanHostApi();
  List<PdfScanExportedDocument>? _documents;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final List<PdfScanExportedDocument> documents = await _api.listExportedScans();
      if (!mounted) return;
      setState(() {
        _documents = documents;
        _error = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message ?? 'Không đọc được danh sách PDF.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF đã quét'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Quét tài liệu',
            icon: const Icon(Icons.document_scanner_outlined),
            onPressed: () async {
              await startScanFlow(context);
              await _reload();
            },
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _reload, child: _body()),
    );
  }

  Widget _body() {
    if (_error != null) {
      return _message(_error!, icon: Icons.error_outline);
    }
    final List<PdfScanExportedDocument>? documents = _documents;
    if (documents == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (documents.isEmpty) {
      return _message(
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
        final bool isNew = document.path == widget.highlightPath;
        return Card(
          margin: EdgeInsets.zero,
          color: isNew ? Theme.of(context).colorScheme.secondaryContainer : null,
          child: ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: Text(document.fileName),
            subtitle: Text(_subtitle(document)),
            onTap: () => _open(document),
            trailing: PopupMenuButton<String>(
              onSelected: (String action) => _handle(action, document),
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

  Widget _message(String text, {required IconData icon}) {
    // Must stay scrollable or pull-to-refresh stops working when the list is
    // empty — which is exactly when a stale empty state is most confusing.
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 96),
      children: <Widget>[
        Icon(icon, size: 48, color: Theme.of(context).disabledColor),
        const SizedBox(height: 16),
        Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  String _subtitle(PdfScanExportedDocument document) {
    final DateTime created =
        DateTime.fromMillisecondsSinceEpoch(document.createdAtEpochMs);
    final String stamp = '${created.day.toString().padLeft(2, '0')}/'
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
  Future<void> _open(PdfScanExportedDocument document) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PdfViewerPage(
          assetKey: document.fileName,
          initialFilePath: document.path,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _quickLook(PdfScanExportedDocument document) async {
    try {
      await _api.openExportedScan(document.path);
    } on PlatformException catch (error) {
      _report(error);
      await _reload();
    }
  }

  Future<void> _handle(String action, PdfScanExportedDocument document) async {
    switch (action) {
      case 'quicklook':
        await _quickLook(document);
      case 'share':
        try {
          await _api.shareExportedScan(document.path);
        } on PlatformException catch (error) {
          _report(error);
        }
      case 'delete':
        await _confirmDelete(document);
    }
  }

  Future<void> _confirmDelete(PdfScanExportedDocument document) async {
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

    try {
      await _api.deleteExportedScan(document.path);
    } on PlatformException catch (error) {
      _report(error);
    }
    await _reload();
  }

  void _report(PlatformException error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.message ?? 'Thao tác thất bại.')),
    );
  }
}
