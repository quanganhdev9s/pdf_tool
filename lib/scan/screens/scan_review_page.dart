import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_scan_api.g.dart';
import '../bloc/scan_review_bloc.dart';
import '../widgets/scan_preset_bar.dart';
import 'scan_library_page.dart';

/// Hosts the native review canvas and owns everything around it.
///
/// The canvas itself is a `UiKitView`: preset switching has to redraw an
/// already-decoded image, which is only instant if the pixels stay on the
/// native side.
class ScanReviewPage extends StatelessWidget {
  const ScanReviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ScanReviewBloc, ScanReviewState>(
      listenWhen: (ScanReviewState previous, ScanReviewState current) =>
          previous.errorMessage != current.errorMessage ||
          previous.exportResult != current.exportResult ||
          (previous.status != current.status &&
              current.status == ScanReviewStatus.idle),
      listener: _handleSideEffects,
      builder: (BuildContext context, ScanReviewState state) {
        return Scaffold(
          appBar: AppBar(
            title: Text(_title(state)),
            leading: IconButton(
              tooltip: 'Discard scan',
              icon: const Icon(Icons.close),
              onPressed: state.isBusy ? null : () => _confirmDiscard(context),
            ),
            actions: <Widget>[
              IconButton(
                tooltip: 'Rotate page',
                icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
                onPressed: state.isBusy || state.currentPage == null
                    ? null
                    : () => context
                        .read<ScanReviewBloc>()
                        .add(ScanPageRotateRequested(state.currentPage!.pageId)),
              ),
              IconButton(
                tooltip: 'Delete page',
                icon: const Icon(Icons.delete_outline),
                onPressed: state.isBusy || state.currentPage == null
                    ? null
                    : () => _confirmDeletePage(context, state.currentPage!),
              ),
            ],
            bottom: state.progress != null
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(3),
                    child: LinearProgressIndicator(value: state.progress),
                  )
                : null,
          ),
          body: SafeArea(
            child: Column(
              children: <Widget>[
                Expanded(child: _canvas(state)),
                ScanPresetBar(state: state),
              ],
            ),
          ),
          bottomNavigationBar: _exportBar(context, state),
        );
      },
    );
  }

  Widget _canvas(ScanReviewState state) {
    if (!Platform.isIOS) {
      return const Center(child: Text('Scanning is available on iOS only.'));
    }
    if (!state.hasSession) {
      return const Center(child: Text('No pages captured yet.'));
    }
    return const UiKitView(viewType: 'pdf_scan_review_view');
  }

  Widget _exportBar(BuildContext context, ScanReviewState state) {
    final bool canExport = state.hasSession && !state.isBusy;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '${state.pages.length} page${state.pages.length == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          if (state.isBusy)
            TextButton(
              onPressed: () => context
                  .read<ScanReviewBloc>()
                  .add(const ScanOperationCancelRequested()),
              child: const Text('Cancel'),
            ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: canExport
                ? () => context
                    .read<ScanReviewBloc>()
                    .add(const ScanExportRequested())
                : null,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Export PDF'),
          ),
        ],
      ),
    );
  }

  String _title(ScanReviewState state) {
    switch (state.status) {
      case ScanReviewStatus.capturing:
        return 'Capturing…';
      case ScanReviewStatus.processing:
        return 'Enhancing…';
      case ScanReviewStatus.exporting:
        return 'Exporting…';
      case ScanReviewStatus.idle:
      case ScanReviewStatus.reviewing:
        return 'Review scan';
    }
  }

  void _handleSideEffects(BuildContext context, ScanReviewState state) {
    // Navigation happens before capture returns, so backing out of the capture
    // sheet leaves this page mounted with nothing to review.
    if (state.status == ScanReviewStatus.idle && !state.hasSession) {
      Navigator.of(context).maybePop();
      return;
    }

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (state.errorMessage != null) {
      messenger.showSnackBar(SnackBar(content: Text(state.errorMessage!)));
      return;
    }
    // Only a fresh result navigates: `listenWhen` fires on an exportResult
    // change, so reaching here with one set means it just arrived.
    final PdfScanExportResult? result = state.exportResult;
    if (result != null) {
      // Replace rather than push: the review screen's session is finished, and
      // going "back" into it after export would offer a second export of the
      // same pages.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ScanLibraryPage(highlightPath: result.outputPath),
        ),
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Đã xuất ${result.pageCount} trang · '
            '${(result.fileSizeBytes / 1024).round()} KB · ${result.presetSummary}',
          ),
        ),
      );
    }
  }

  Future<void> _confirmDiscard(BuildContext context) async {
    final ScanReviewBloc bloc = context.read<ScanReviewBloc>();
    final NavigatorState navigator = Navigator.of(context);
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Discard this scan?'),
        content: const Text('The captured pages will be deleted.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard ?? false) {
      bloc.add(const ScanSessionDiscardRequested());
      navigator.pop();
    }
  }

  Future<void> _confirmDeletePage(
    BuildContext context,
    PdfScanPageInfo page,
  ) async {
    final ScanReviewBloc bloc = context.read<ScanReviewBloc>();
    final bool? delete = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Delete page ${page.index + 1}?'),
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
      ),
    );
    if (delete ?? false) {
      bloc.add(ScanPageDeleteRequested(page.pageId));
    }
  }
}
