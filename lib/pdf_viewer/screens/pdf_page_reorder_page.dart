import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/pdf_viewer_bloc.dart';

class PdfPageReorderPage extends StatefulWidget {
  const PdfPageReorderPage({super.key});

  @override
  State<PdfPageReorderPage> createState() => _PdfPageReorderPageState();
}

class _PdfPageReorderPageState extends State<PdfPageReorderPage> {
  late PdfViewerBloc _bloc;
  bool _completed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bloc = context.read<PdfViewerBloc>();
  }

  @override
  void dispose() {
    if (!_completed) {
      _bloc.add(const PdfViewerCancelPendingPageReorderRequested());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reorder pages'),
        leading: IconButton(
          tooltip: 'Cancel',
          onPressed: _cancel,
          icon: const Icon(Icons.close),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Apply',
            onPressed: _apply,
            icon: const Icon(Icons.check),
          ),
        ],
      ),
      body: SafeArea(
        child: Platform.isIOS
            ? const UiKitView(viewType: 'pdf_poc_page_reorder_view')
            : const Center(
                child: Text('This technical POC supports iOS only.'),
              ),
      ),
    );
  }

  void _apply() {
    _completed = true;
    _bloc.add(const PdfViewerCommitPendingPageReorderRequested());
    Navigator.of(context).pop();
  }

  void _cancel() {
    _completed = true;
    _bloc.add(const PdfViewerCancelPendingPageReorderRequested());
    Navigator.of(context).pop();
  }
}
