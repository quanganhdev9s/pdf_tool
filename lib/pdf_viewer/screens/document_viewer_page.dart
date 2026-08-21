import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_poc_api.g.dart';
import '../bloc/pdf_viewer_bloc.dart';

enum _ViewerMenuAction { search, details, share }

/// Đuôi tệp mà trình soạn thảo HWP nhận. Khớp với `HwpFileType` bên native.
const Set<String> _editableExtensions = <String>{'hwp', 'hwpx'};

/// Hosts the native document viewer inside a normal Flutter route, so the whole
/// screen around the document is ours to style: app bar, menu, search bar.
///
/// The native side only renders; every control here is Flutter.
class DocumentViewerPage extends StatefulWidget {
  const DocumentViewerPage({super.key, required this.document});

  final PdfViewableDocument document;

  @override
  State<DocumentViewerPage> createState() => _DocumentViewerPageState();
}

class _DocumentViewerPageState extends State<DocumentViewerPage> {
  // Captured while the element tree is still stable: `dispose` runs after this
  // widget is deactivated, when ancestor lookups are no longer allowed.
  PdfViewerBloc? _bloc;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _showDetails = false;
  bool _searching = false;
  bool? _lastSearchFound;
  bool _editing = false;
  bool _busy = false;

  /// Tệp này có sửa được không. Chỉ HWP — mọi định dạng khác chỉ xem.
  bool get _editable => _editableExtensions.contains(
    widget.document.fileName.split('.').last.toLowerCase(),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bloc = context.read<PdfViewerBloc>();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _bloc?.add(const PdfViewerCloseDocumentViewerRequested());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _searching ? _buildSearchAppBar() : _buildDefaultAppBar(),
      body: Column(
        children: <Widget>[
          if (_showDetails) _DetailsBar(document: widget.document),
          Expanded(child: _NativeDocumentViewer(path: widget.document.path)),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildDefaultAppBar() {
    return AppBar(
      title: Text(widget.document.fileName, overflow: TextOverflow.ellipsis),
      actions: <Widget>[
        if (_editable && _editing) ...<Widget>[
          IconButton(
            tooltip: 'Lưu',
            onPressed: _busy ? null : _saveEdits,
            icon: const Icon(Icons.save_outlined),
          ),
          TextButton(
            onPressed: _busy ? null : () => _setEditing(false),
            child: const Text('Xong'),
          ),
        ] else if (_editable)
          IconButton(
            tooltip: 'Sửa',
            onPressed: _busy ? null : () => _setEditing(true),
            icon: const Icon(Icons.edit_outlined),
          ),
        PopupMenuButton<_ViewerMenuAction>(
          tooltip: 'Options',
          icon: const Icon(Icons.more_vert),
          onSelected: _handleMenuAction,
          itemBuilder: (context) => <PopupMenuEntry<_ViewerMenuAction>>[
            const PopupMenuItem<_ViewerMenuAction>(
              value: _ViewerMenuAction.search,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.search),
                title: Text('Search'),
              ),
            ),
            PopupMenuItem<_ViewerMenuAction>(
              value: _ViewerMenuAction.details,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(_showDetails ? Icons.info : Icons.info_outline),
                title: Text(_showDetails ? 'Hide details' : 'File details'),
              ),
            ),
            const PopupMenuItem<_ViewerMenuAction>(
              value: _ViewerMenuAction.share,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.ios_share),
                title: Text('Share'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _buildSearchAppBar() {
    return AppBar(
      leading: IconButton(
        tooltip: 'Close search',
        icon: const Icon(Icons.arrow_back),
        onPressed: _stopSearching,
      ),
      titleSpacing: 0,
      title: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search in document',
          border: InputBorder.none,
          errorText: _lastSearchFound == false ? 'No match' : null,
        ),
        onSubmitted: (_) => _find(forward: true),
      ),
      actions: <Widget>[
        IconButton(
          tooltip: 'Previous match',
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: () => _find(forward: false),
        ),
        IconButton(
          tooltip: 'Next match',
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => _find(forward: true),
        ),
      ],
    );
  }

  void _handleMenuAction(_ViewerMenuAction action) {
    switch (action) {
      case _ViewerMenuAction.search:
        setState(() => _searching = true);
      case _ViewerMenuAction.details:
        setState(() => _showDetails = !_showDetails);
      case _ViewerMenuAction.share:
        _bloc?.shareViewerDocument();
    }
  }

  Future<void> _setEditing(bool editing) async {
    setState(() => _busy = true);
    try {
      await _bloc?.setViewerEditing(editing);
      if (mounted) setState(() => _editing = editing);
    } on Object catch (_) {
      // Lỗi đã vào log ở bloc; giữ nguyên trạng thái trước đó.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveEdits() async {
    setState(() => _busy = true);
    try {
      await _bloc?.saveViewerEdits();
      if (mounted) {
        // Việc xuất chạy bất đồng bộ bên trình soạn thảo, nên đây chỉ là "đã
        // gửi yêu cầu" — không phải "đã lưu xong".
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đang lưu…')),
        );
      }
    } on Object catch (_) {
      // Đã vào log.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _find({required bool forward}) async {
    final found = await _bloc?.findInViewer(
      _searchController.text,
      forward: forward,
    );
    if (mounted) {
      setState(() => _lastSearchFound = found);
    }
  }

  void _stopSearching() {
    _bloc?.clearViewerSearch();
    _searchFocusNode.unfocus();
    setState(() {
      _searching = false;
      _lastSearchFound = null;
      _searchController.clear();
    });
  }
}

class _DetailsBar extends StatelessWidget {
  const _DetailsBar({required this.document});

  final PdfViewableDocument document;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            const Icon(Icons.description_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${document.fileFormat.toUpperCase()} · '
                '${(document.fileSizeBytes / 1024).toStringAsFixed(0)} KB',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NativeDocumentViewer extends StatefulWidget {
  const _NativeDocumentViewer({required this.path});

  final String path;

  @override
  State<_NativeDocumentViewer> createState() => _NativeDocumentViewerState();
}

class _NativeDocumentViewerState extends State<_NativeDocumentViewer> {
  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) {
      return const Center(child: Text('This technical POC supports iOS only.'));
    }
    return UiKitView(
      viewType: 'pdf_poc_document_viewer_view',
      // The native view only exists once the platform view is created, so the
      // document is loaded from this callback rather than from initState.
      onPlatformViewCreated: (_) {
        context.read<PdfViewerBloc>().loadPickedDocumentIntoViewer(widget.path);
      },
    );
  }
}
