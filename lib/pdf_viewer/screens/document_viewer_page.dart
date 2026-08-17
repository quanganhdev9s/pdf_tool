import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_poc_api.g.dart';
import '../bloc/pdf_viewer_bloc.dart';

/// Hosts the native document viewer inside a normal Flutter route, so the whole
/// screen around the document is ours to style: app bar, actions, bottom bar.
///
/// The native side only renders; every control here is Flutter.
class DocumentViewerPage extends StatefulWidget {
  const DocumentViewerPage({super.key, required this.document});

  final PdfViewableDocument document;

  @override
  State<DocumentViewerPage> createState() => _DocumentViewerPageState();
}

class _DocumentViewerPageState extends State<DocumentViewerPage> {
  bool _showDetails = false;
  // Captured while the element tree is still stable: `dispose` runs after this
  // widget is deactivated, when ancestor lookups are no longer allowed.
  PdfViewerBloc? _bloc;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bloc = context.read<PdfViewerBloc>();
  }

  @override
  void dispose() {
    _bloc?.add(const PdfViewerCloseDocumentViewerRequested());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.document;
    return Scaffold(
      appBar: AppBar(
        title: Text(document.fileName, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            tooltip: 'File details',
            onPressed: () => setState(() => _showDetails = !_showDetails),
            icon: Icon(_showDetails ? Icons.info : Icons.info_outline),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_showDetails) _DetailsBar(document: document),
          Expanded(child: _NativeDocumentViewer(path: document.path)),
        ],
      ),
    );
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
