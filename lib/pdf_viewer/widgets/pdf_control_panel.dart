import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';


import '../../pdf_poc_api.g.dart';
import '../bloc/pdf_viewer_bloc.dart';
import 'pdf_bottom_tool_bar.dart';

class PdfControlPanel extends StatelessWidget {
  const PdfControlPanel({
    super.key,
    required this.mode,
    required this.state,
    required this.totalPages,
    required this.searchText,
    required this.pageController,
    required this.searchController,
    required this.freeTextController,
    required this.onJumpToPage,
    required this.onSearch,
    required this.onAddFreeText,
    required this.onBeginFreeTextAreaSelection,
    required this.onOpenPageReorder,
    required this.onOpenDocumentViewer,
  });

  final PdfControlPanelMode mode;
  final PdfViewerState state;
  final int? totalPages;
  final String searchText;
  final TextEditingController pageController;
  final TextEditingController searchController;
  final TextEditingController freeTextController;
  final VoidCallback onJumpToPage;
  final VoidCallback onSearch;
  final VoidCallback onAddFreeText;
  final VoidCallback onBeginFreeTextAreaSelection;
  final VoidCallback onOpenPageReorder;
  final VoidCallback onOpenDocumentViewer;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PdfViewerBloc>();
    final media = MediaQuery.of(context);
    // The scaffold keeps `resizeToAvoidBottomInset: false` so the native PDF
    // view never resizes, so the panel lifts itself above the keyboard and
    // scrolls whenever the remaining height is not enough.
    final keyboardInset = media.viewInsets.bottom;
    final maxPanelHeight = (media.size.height - keyboardInset) * 0.5;

    return Material(
      elevation: 3,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + keyboardInset),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxPanelHeight),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusScope.of(context).unfocus(),
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (state.busy) ...<Widget>[
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                    ] else
                      _buildPanel(context, bloc),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context, PdfViewerBloc bloc) {
    switch (mode) {
      case PdfControlPanelMode.pages:
        return _PageControls(
          state: state,
          totalPages: totalPages,
          pageController: pageController,
          onJumpToPage: onJumpToPage,
        );
      case PdfControlPanelMode.search:
        return _SearchControls(
          state: state,
          searchText: searchText,
          searchController: searchController,
          onSearch: onSearch,
        );
      case PdfControlPanelMode.ink:
        return _InkControls(state: state);
      case PdfControlPanelMode.freeText:
        return _FreeTextControls(
          state: state,
          freeTextController: freeTextController,
          onAddFreeText: onAddFreeText,
          onBeginFreeTextAreaSelection: onBeginFreeTextAreaSelection,
        );
      case PdfControlPanelMode.signature:
        return _SignatureControls(state: state);
      case PdfControlPanelMode.pageOperations:
        return _PageOperationControls(
          state: state,
          onOpenPageReorder: onOpenPageReorder,
        );
      case PdfControlPanelMode.ocr:
        return _OcrControls(state: state);
      case PdfControlPanelMode.compression:
        return _CompressionControls(state: state);
      case PdfControlPanelMode.splitMerge:
        return _SplitMergeControls(state: state);
      case PdfControlPanelMode.documentViewer:
        return _DocumentViewerControls(
          state: state,
          onOpenDocumentViewer: onOpenDocumentViewer,
        );
      case PdfControlPanelMode.status:
        return _StatusControls(state: state);
    }
  }
}

class _PageControls extends StatelessWidget {
  const _PageControls({
    required this.state,
    required this.pageController,
    this.totalPages,
    required this.onJumpToPage,
  });

  final PdfViewerState state;
  final TextEditingController pageController;
  final int? totalPages;
  final VoidCallback onJumpToPage;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PdfViewerBloc>();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.outlined(
          tooltip: 'Previous page',
          onPressed: state.busy
              ? null
              : () {
                  bloc.add(const PdfViewerPreviousPageRequested());
                },
          icon: const Icon(Icons.chevron_left),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 44,
          child: TextField(
            controller: pageController,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.go,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => onJumpToPage(),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          totalPages != null && totalPages! > 0 ? '/$totalPages' : '',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(width: 8),
        IconButton.outlined(
          tooltip: 'Next page',
          onPressed: state.busy
              ? null
              : () {
                  bloc.add(const PdfViewerNextPageRequested());
                },
          icon: const Icon(Icons.chevron_right),
        ),
        const SizedBox(width: 12),
        FilledButton.tonal(
          onPressed: state.busy ? null : onJumpToPage,
          child: const Text('Jump'),
        ),
      ],
    );
  }
}

class _SearchControls extends StatelessWidget {
  const _SearchControls({
    required this.state,
    required this.searchText,
    required this.searchController,
    required this.onSearch,
  });

  final PdfViewerState state;
  final String searchText;
  final TextEditingController searchController;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PdfViewerBloc>();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        SizedBox(
          width: 220,
          child: TextField(
            controller: searchController,
            decoration: const InputDecoration(labelText: 'Search'),
            onSubmitted: (_) => onSearch(),
          ),
        ),
        FilledButton.tonal(
          onPressed: state.busy ? null : onSearch,
          child: const Text('Find'),
        ),
        IconButton.outlined(
          tooltip: 'Previous result',
          onPressed: state.busy
              ? null
              : () => bloc.add(const PdfViewerPreviousSearchResultRequested()),
          icon: const Icon(Icons.keyboard_arrow_up),
        ),
        IconButton.outlined(
          tooltip: 'Next result',
          onPressed: state.busy
              ? null
              : () => bloc.add(const PdfViewerNextSearchResultRequested()),
          icon: const Icon(Icons.keyboard_arrow_down),
        ),
        OutlinedButton(
          onPressed: state.busy
              ? null
              : () => bloc.add(const PdfViewerClearSearchRequested()),
          child: const Text('Clear'),
        ),
        Text(searchText),
      ],
    );
  }
}

class _InkControls extends StatelessWidget {
  const _InkControls({required this.state});

  final PdfViewerState state;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PdfViewerBloc>();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        SegmentedButton<bool>(
          segments: const <ButtonSegment<bool>>[
            ButtonSegment<bool>(
              value: false,
              icon: Icon(Icons.pan_tool_alt_outlined, size: 18),
              label: Text('Read'),
            ),
            ButtonSegment<bool>(
              value: true,
              icon: Icon(Icons.draw_outlined, size: 18),
              label: Text('Ink'),
            ),
          ],
          selected: <bool>{state.inkModeEnabled},
          onSelectionChanged: state.busy
              ? null
              : (selection) =>
                    bloc.add(PdfViewerInkModeChanged(selection.first)),
        ),
        OutlinedButton.icon(
          onPressed: state.busy
              ? null
              : () => bloc.add(const PdfViewerClearInkRequested()),
          icon: const Icon(Icons.layers_clear_outlined, size: 18),
          label: const Text('Clear ink'),
        ),
        FilledButton.tonalIcon(
          onPressed: state.busy
              ? null
              : () => bloc.add(const PdfViewerCommitInkRequested()),
          icon: const Icon(Icons.check, size: 18),
          label: const Text('Commit ink'),
        ),
        OutlinedButton.icon(
          onPressed: state.busy
              ? null
              : () => bloc.add(
                  const PdfViewerDeleteSelectedAnnotationRequested(),
                ),
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Delete selected'),
        ),
      ],
    );
  }
}

class _FreeTextControls extends StatelessWidget {
  const _FreeTextControls({
    required this.state,
    required this.freeTextController,
    required this.onAddFreeText,
    required this.onBeginFreeTextAreaSelection,
  });

  final PdfViewerState state;
  final TextEditingController freeTextController;
  final VoidCallback onAddFreeText;
  final VoidCallback onBeginFreeTextAreaSelection;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        SizedBox(
          width: 270,
          child: TextField(
            controller: freeTextController,
            decoration: const InputDecoration(labelText: 'Free text'),
          ),
        ),
        FilledButton(
          onPressed: state.busy ? null : onAddFreeText,
          child: const Text('Add text box'),
        ),
        FilledButton.tonalIcon(
          onPressed: state.busy ? null : onBeginFreeTextAreaSelection,
          icon: const Icon(Icons.crop_free, size: 18),
          label: const Text('Select area'),
        ),
      ],
    );
  }
}

class _SignatureControls extends StatelessWidget {
  const _SignatureControls({required this.state});

  final PdfViewerState state;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PdfViewerBloc>();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        FilledButton.tonalIcon(
          onPressed: state.busy
              ? null
              : () => bloc.add(const PdfViewerCaptureSignatureRequested()),
          icon: const Icon(Icons.gesture, size: 18),
          label: const Text('Capture'),
        ),
        OutlinedButton.icon(
          onPressed: state.busy
              ? null
              : () => bloc.add(const PdfViewerClearSignatureCaptureRequested()),
          icon: const Icon(Icons.layers_clear_outlined, size: 18),
          label: const Text('Clear'),
        ),
        FilledButton.icon(
          onPressed: state.busy
              ? null
              : () =>
                    bloc.add(const PdfViewerConfirmSignatureCaptureRequested()),
          icon: const Icon(Icons.check, size: 18),
          label: const Text('Confirm'),
        ),
        FilledButton.tonalIcon(
          onPressed: state.busy
              ? null
              : () =>
                    bloc.add(const PdfViewerBeginSignaturePlacementRequested()),
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
          label: const Text('Place'),
        ),
        IconButton.outlined(
          tooltip: 'Smaller signature',
          onPressed: state.busy
              ? null
              : () => bloc.add(
                  const PdfViewerResizeSignaturePlacementRequested(0.85),
                ),
          icon: const Icon(Icons.remove),
        ),
        IconButton.outlined(
          tooltip: 'Larger signature',
          onPressed: state.busy
              ? null
              : () => bloc.add(
                  const PdfViewerResizeSignaturePlacementRequested(1.15),
                ),
          icon: const Icon(Icons.add),
        ),
        FilledButton.tonalIcon(
          onPressed: state.busy
              ? null
              : () => bloc.add(
                  const PdfViewerCommitSignaturePlacementRequested(),
                ),
          icon: const Icon(Icons.done_all, size: 18),
          label: const Text('Commit'),
        ),
        OutlinedButton.icon(
          onPressed: state.busy
              ? null
              : () => bloc.add(
                  const PdfViewerCancelSignaturePlacementRequested(),
                ),
          icon: const Icon(Icons.close, size: 18),
          label: const Text('Cancel placement'),
        ),
        OutlinedButton.icon(
          onPressed: state.busy
              ? null
              : () =>
                    bloc.add(const PdfViewerDeleteSelectedSignatureRequested()),
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Delete selected'),
        ),
        OutlinedButton.icon(
          onPressed: state.busy
              ? null
              : () => bloc.add(const PdfViewerExportFlattenedCopyRequested()),
          icon: const Icon(Icons.file_download_outlined, size: 18),
          label: const Text('Export flattened'),
        ),
      ],
    );
  }
}

class _PageOperationControls extends StatelessWidget {
  const _PageOperationControls({
    required this.state,
    required this.onOpenPageReorder,
  });

  final PdfViewerState state;
  final VoidCallback onOpenPageReorder;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PdfViewerBloc>();
    final pageCount = state.documentInfo?.pageCount ?? 0;
    final canDelete = pageCount > 1;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        FilledButton.tonalIcon(
          onPressed: state.busy
              ? null
              : () => bloc.add(const PdfViewerRotateCurrentPageRequested(90)),
          icon: const Icon(Icons.rotate_right, size: 18),
          label: const Text('Rotate 90'),
        ),
        OutlinedButton.icon(
          onPressed: state.busy || !canDelete
              ? null
              : () => bloc.add(const PdfViewerDeleteCurrentPageRequested()),
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Delete page'),
        ),
        FilledButton.tonalIcon(
          onPressed: state.busy
              ? null
              : () => bloc.add(const PdfViewerDuplicateCurrentPageRequested()),
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('Duplicate'),
        ),
        FilledButton.tonalIcon(
          onPressed: state.busy ? null : onOpenPageReorder,
          icon: const Icon(Icons.view_module_outlined, size: 18),
          label: const Text('Reorder'),
        ),
        FilledButton.tonalIcon(
          onPressed: state.busy
              ? null
              : () => bloc.add(const PdfViewerCropCurrentPageRequested()),
          icon: const Icon(Icons.crop, size: 18),
          label: const Text('Crop inset'),
        ),
        OutlinedButton.icon(
          onPressed: state.busy
              ? null
              : () =>
                    bloc.add(const PdfViewerSavePageOperationsCopyRequested()),
          icon: const Icon(Icons.save_as_outlined, size: 18),
          label: const Text('Save output'),
        ),
      ],
    );
  }
}

class _StatusControls extends StatelessWidget {
  const _StatusControls({required this.state});

  final PdfViewerState state;

  @override
  Widget build(BuildContext context) {
    return Text(state.status, maxLines: 3, overflow: TextOverflow.ellipsis);
  }
}

class _OcrControls extends StatelessWidget {
  const _OcrControls({required this.state});

  final PdfViewerState state;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PdfViewerBloc>();
    final totalPages = state.ocrTotalPages;
    final progress = totalPages == 0
        ? null
        : state.ocrCompletedPages / totalPages.clamp(1, totalPages);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: state.busy || state.ocrRunning
                  ? null
                  : () => bloc.add(const PdfViewerRunOcrCurrentPageRequested()),
              icon: const Icon(Icons.my_location_outlined, size: 18),
              label: const Text('Current page'),
            ),
            FilledButton.tonalIcon(
              onPressed: state.busy || state.ocrRunning
                  ? null
                  : () => bloc.add(const PdfViewerRunOcrAllPagesRequested()),
              icon: const Icon(Icons.library_books_outlined, size: 18),
              label: const Text('All pages'),
            ),
            OutlinedButton.icon(
              onPressed: state.ocrRunning
                  ? () => bloc.add(const PdfViewerCancelOcrRequested())
                  : null,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('Cancel'),
            ),
            Text(
              state.ocrRunning || totalPages > 0
                  ? '${state.ocrCompletedPages}/$totalPages pages'
                  : '${state.ocrResults.length} blocks',
            ),
          ],
        ),
        if (state.ocrRunning || totalPages > 0) ...<Widget>[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress),
        ],
        if (state.ocrResults.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          SizedBox(
            height: 164,
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: state.ocrResults.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final block = state.ocrResults[index];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    block.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_ocrSubtitle(block)),
                  trailing: const Icon(Icons.center_focus_strong_outlined),
                  onTap: state.busy
                      ? null
                      : () => bloc.add(PdfViewerShowOcrResultRequested(block)),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  String _ocrSubtitle(PdfOcrBlock block) {
    final confidence = (block.confidence * 100)
        .clamp(0, 100)
        .toStringAsFixed(0);
    return 'Page ${block.pageIndex} · $confidence%';
  }
}

class _CompressionControls extends StatefulWidget {
  const _CompressionControls({required this.state});

  final PdfViewerState state;

  @override
  State<_CompressionControls> createState() => _CompressionControlsState();
}

class _CompressionControlsState extends State<_CompressionControls> {
  double _dpi = 120;
  double _jpegQuality = 0.6;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final bloc = context.read<PdfViewerBloc>();
    final totalPages = state.compressionTotalPages;
    final progress = totalPages == 0
        ? null
        : state.compressionCompletedPages / totalPages.clamp(1, totalPages);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: state.busy || state.compressionRunning
                  ? null
                  : () => bloc.add(
                      const PdfViewerRunPreservationCompressionRequested(),
                    ),
              icon: const Icon(Icons.inventory_2_outlined, size: 18),
              label: const Text('Preserve'),
            ),
            FilledButton.icon(
              onPressed: state.busy || state.compressionRunning
                  ? null
                  : () => bloc.add(
                      PdfViewerRunRasterizedCompressionRequested(
                        dpi: _dpi.round(),
                        jpegQuality: _jpegQuality,
                      ),
                    ),
              icon: const Icon(Icons.image_outlined, size: 18),
              label: const Text('Rasterize'),
            ),
            OutlinedButton.icon(
              onPressed: state.compressionRunning
                  ? () => bloc.add(const PdfViewerCancelCompressionRequested())
                  : null,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('Cancel'),
            ),
            Text(
              state.compressionRunning || totalPages > 0
                  ? '${state.compressionCompletedPages}/$totalPages pages'
                  : 'No output',
            ),
          ],
        ),
        const SizedBox(height: 8),
        _SliderRow(
          label: 'DPI',
          valueLabel: _dpi.round().toString(),
          value: _dpi,
          min: 72,
          max: 300,
          divisions: 19,
          onChanged: state.compressionRunning
              ? null
              : (value) => setState(() => _dpi = value),
        ),
        _SliderRow(
          label: 'JPEG',
          valueLabel: '${(_jpegQuality * 100).round()}%',
          value: _jpegQuality,
          min: 0.1,
          max: 0.95,
          divisions: 17,
          onChanged: state.compressionRunning
              ? null
              : (value) => setState(() => _jpegQuality = value),
        ),
        const Text(
          'Rasterized output may destroy selectable text, links, forms, vector quality, and editable annotations.',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        if (state.compressionRunning || totalPages > 0) ...<Widget>[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress),
        ],
        if (state.compressionResult != null) ...<Widget>[
          const SizedBox(height: 8),
          _CompressionResultView(result: state.compressionResult!),
        ],
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(width: 56, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 48, child: Text(valueLabel, textAlign: TextAlign.end)),
      ],
    );
  }
}

class _CompressionResultView extends StatelessWidget {
  const _CompressionResultView({required this.result});

  final PdfCompressionResult result;

  @override
  Widget build(BuildContext context) {
    final percent = (result.compressionRatio * 100).toStringAsFixed(1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${result.outputBytes} / ${result.inputBytes} bytes · $percent% · ${result.durationMilliseconds} ms',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          'Text ${_yesNo(result.textSelectable)} · Annotations ${_yesNo(result.annotationsEditable)} · Links ${_yesNo(result.linksFunctional)} · Forms ${_yesNo(result.formsFunctional)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          result.visualQualityNotes,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        if (result.warning.isNotEmpty)
          Text(result.warning, maxLines: 3, overflow: TextOverflow.ellipsis),
        Text(result.outputPath, maxLines: 2, overflow: TextOverflow.ellipsis),
      ],
    );
  }

  String _yesNo(bool value) => value ? 'yes' : 'no';
}

class _SplitMergeControls extends StatefulWidget {
  const _SplitMergeControls({required this.state});

  final PdfViewerState state;

  @override
  State<_SplitMergeControls> createState() => _SplitMergeControlsState();
}

class _SplitMergeControlsState extends State<_SplitMergeControls> {
  final TextEditingController _rangesController = TextEditingController(
    text: '0-0',
  );
  final TextEditingController _mergePathsController = TextEditingController();

  @override
  void dispose() {
    _rangesController.dispose();
    _mergePathsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final bloc = context.read<PdfViewerBloc>();
    final splitProgress = state.splitTotalPages == 0
        ? null
        : state.splitCompletedPages /
              state.splitTotalPages.clamp(1, state.splitTotalPages);
    final mergeProgress = state.mergeTotalPages == 0
        ? null
        : state.mergeCompletedPages /
              state.mergeTotalPages.clamp(1, state.mergeTotalPages);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 180,
              child: TextField(
                controller: _rangesController,
                decoration: const InputDecoration(labelText: 'Ranges'),
                textInputAction: TextInputAction.done,
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: state.busy || state.splitRunning
                  ? null
                  : () => bloc.add(
                      PdfViewerRunSplitRequested(_rangesController.text),
                    ),
              icon: const Icon(Icons.call_split, size: 18),
              label: const Text('Split'),
            ),
            OutlinedButton.icon(
              onPressed: state.splitRunning
                  ? () => bloc.add(const PdfViewerCancelSplitRequested())
                  : null,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('Cancel split'),
            ),
            Text(
              state.splitRunning || state.splitTotalPages > 0
                  ? '${state.splitCompletedPages}/${state.splitTotalPages} split pages'
                  : 'No split',
            ),
          ],
        ),
        if (state.splitRunning || state.splitTotalPages > 0) ...<Widget>[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: splitProgress),
        ],
        if (state.splitResult != null) ...<Widget>[
          const SizedBox(height: 8),
          _SplitResultView(result: state.splitResult!),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: _mergePathsController,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Merge PDF paths'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FilledButton.icon(
              onPressed: state.busy || state.mergeRunning
                  ? null
                  : () => bloc.add(
                      PdfViewerRunMergeRequested(_mergePathsController.text),
                    ),
              icon: const Icon(Icons.merge_type_outlined, size: 18),
              label: const Text('Merge'),
            ),
            OutlinedButton.icon(
              onPressed: state.mergeRunning
                  ? () => bloc.add(const PdfViewerCancelMergeRequested())
                  : null,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('Cancel merge'),
            ),
            Text(
              state.mergeRunning || state.mergeTotalPages > 0
                  ? '${state.mergeCompletedPages}/${state.mergeTotalPages} merge pages'
                  : 'No merge',
            ),
          ],
        ),
        if (state.mergeRunning || state.mergeTotalPages > 0) ...<Widget>[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: mergeProgress),
        ],
        if (state.mergeResult != null) ...<Widget>[
          const SizedBox(height: 8),
          _MergeResultView(result: state.mergeResult!),
        ],
      ],
    );
  }
}

class _SplitResultView extends StatelessWidget {
  const _SplitResultView({required this.result});

  final PdfSplitResult result;

  @override
  Widget build(BuildContext context) {
    final lines = result.outputs
        .map((output) => '${output.pageCount}p · ${output.outputPath}')
        .join('\n');
    return Text(
      '$lines\n${result.durationMilliseconds} ms',
      maxLines: 6,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _MergeResultView extends StatelessWidget {
  const _MergeResultView({required this.result});

  final PdfMergeResult result;

  @override
  Widget build(BuildContext context) {
    return Text(
      '${result.inputDocumentCount} inputs · ${result.pageCount} pages · ${result.durationMilliseconds} ms\n${result.outputPath}',
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Convert-to-PDF controls.
///
/// Public because it is no longer a case of the control panel: the viewer's
/// app bar opens it in a sheet instead. Everything it needs still comes from
/// `PdfViewerBloc`, so the sheet has to be given the same provider.
class ConvertControls extends StatefulWidget {
  const ConvertControls({super.key, required this.state});

  final PdfViewerState state;

  @override
  State<ConvertControls> createState() => _ConvertControlsState();
}

class _ConvertControlsState extends State<ConvertControls> {
  PdfConvertPageSize _pageSize = PdfConvertPageSize.a4;
  PdfScanQuality _imageQuality = PdfScanQuality.standard;
  final TextEditingController _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    context.read<PdfViewerBloc>().add(
      const PdfViewerLoadGeneratedOutputsRequested(),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final bloc = context.read<PdfViewerBloc>();
    final totalPages = state.conversionTotalPages;
    final progress = totalPages == 0
        ? null
        : state.conversionCompletedPages / totalPages.clamp(1, totalPages);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SegmentedButton<PdfConvertPageSize>(
              segments: const <ButtonSegment<PdfConvertPageSize>>[
                ButtonSegment<PdfConvertPageSize>(
                  value: PdfConvertPageSize.a4,
                  label: Text('A4'),
                ),
                ButtonSegment<PdfConvertPageSize>(
                  value: PdfConvertPageSize.letter,
                  label: Text('Letter'),
                ),
              ],
              selected: <PdfConvertPageSize>{_pageSize},
              onSelectionChanged: state.conversionRunning
                  ? null
                  : (selection) => setState(() => _pageSize = selection.first),
            ),
            SegmentedButton<PdfScanQuality>(
              segments: const <ButtonSegment<PdfScanQuality>>[
                ButtonSegment<PdfScanQuality>(
                  value: PdfScanQuality.standard,
                  icon: Icon(Icons.speed_outlined, size: 18),
                  label: Text('Standard'),
                ),
                ButtonSegment<PdfScanQuality>(
                  value: PdfScanQuality.high,
                  icon: Icon(Icons.high_quality_outlined, size: 18),
                  label: Text('High'),
                ),
              ],
              selected: <PdfScanQuality>{_imageQuality},
              onSelectionChanged: state.conversionRunning
                  ? null
                  : (selection) =>
                        setState(() => _imageQuality = selection.first),
            ),
            FilledButton.icon(
              onPressed: state.busy || state.conversionRunning
                  ? null
                  : () {
                      FocusScope.of(context).unfocus();
                      bloc.add(
                        PdfViewerPickFileForPdfConversionRequested(
                          pageSize: _pageSize,
                          imageQuality: _imageQuality,
                        ),
                      );
                    },
              icon: const Icon(Icons.upload_file_outlined, size: 18),
              label: const Text('Pick file'),
            ),
            OutlinedButton.icon(
              onPressed: state.conversionRunning
                  ? () =>
                        bloc.add(const PdfViewerCancelPdfConversionRequested())
                  : null,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('Cancel'),
            ),
            Text(
              state.conversionRunning || totalPages > 0
                  ? '${state.conversionCompletedPages}/$totalPages pages'
                  : 'No output',
            ),
          ],
        ),
        const SizedBox(height: 12),
        // The URL source sits in its own card so it reads as a second way to
        // start a conversion, not as another option for the picked file.
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'From a web page',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      enabled: !state.conversionRunning,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      textInputAction: TextInputAction.go,
                      decoration: InputDecoration(
                        labelText: 'Web page URL',
                        hintText: 'example.com',
                        isDense: true,
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              tooltip: 'Paste',
                              visualDensity: VisualDensity.compact,
                              onPressed: state.conversionRunning
                                  ? null
                                  : _pasteUrl,
                              icon: const Icon(Icons.content_paste, size: 18),
                            ),
                            if (_urlController.text.isNotEmpty)
                              IconButton(
                                tooltip: 'Clear',
                                visualDensity: VisualDensity.compact,
                                onPressed: state.conversionRunning
                                    ? null
                                    : () => setState(_urlController.clear),
                                icon: const Icon(Icons.close, size: 18),
                              ),
                          ],
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _convertUrl(bloc),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: state.busy || state.conversionRunning
                        ? null
                        : () => _convertUrl(bloc),
                    icon: const Icon(Icons.language, size: 18),
                    label: const Text('Convert web'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Files: Word, Excel, PowerPoint, Pages, Numbers, Keynote, RTF, '
          'HTML, text, CSV and images.',
        ),
        if (state.conversionRunning || totalPages > 0) ...<Widget>[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress),
        ],
        if (state.conversionResult != null) ...<Widget>[
          const SizedBox(height: 8),
          _ConvertResultView(result: state.conversionResult!),
        ],
        const SizedBox(height: 12),
        _GeneratedOutputsList(state: state),
      ],
    );
  }

  Future<void> _pasteUrl() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) {
      return;
    }
    setState(() {
      _urlController.text = text;
      _urlController.selection = TextSelection.collapsed(offset: text.length);
    });
  }

  void _convertUrl(PdfViewerBloc bloc) {
    FocusScope.of(context).unfocus();
    bloc.add(
      PdfViewerConvertUrlToPdfRequested(
        url: _urlController.text,
        pageSize: _pageSize,
      ),
    );
  }
}

/// Shows every PDF produced by an earlier operation so the generated output is
/// reachable in-app. Tapping a row opens it in the native viewer.
class _GeneratedOutputsList extends StatelessWidget {
  const _GeneratedOutputsList({required this.state});

  final PdfViewerState state;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PdfViewerBloc>();
    final outputs = state.generatedOutputs;
    final currentPath = state.documentInfo?.workingPath;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              'Generated files (${outputs.length})',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Refresh',
              onPressed: state.generatedOutputsLoading
                  ? null
                  : () => bloc.add(
                      const PdfViewerLoadGeneratedOutputsRequested(),
                    ),
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        if (state.generatedOutputsLoading)
          const LinearProgressIndicator()
        else if (outputs.isEmpty)
          const Text('No generated file yet.')
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: outputs.length,
              itemBuilder: (context, index) {
                final output = outputs[index];
                final isCurrent = output.path == currentPath;
                final theme = Theme.of(context);
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  selected: isCurrent,
                  leading: Icon(
                    isCurrent
                        ? Icons.check_circle
                        : Icons.picture_as_pdf_outlined,
                  ),
                  title: Text(
                    output.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${output.pageCount} pages · '
                    '${(output.fileSizeBytes / 1024).toStringAsFixed(0)} KB',
                  ),
                  // The current document is already on screen behind this
                  // panel, so its row reports state instead of offering a tap
                  // that would do nothing.
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (isCurrent)
                        Text(
                          'Viewing',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        )
                      else
                        const Icon(Icons.open_in_new, size: 18),
                      IconButton(
                        tooltip: 'Share',
                        visualDensity: VisualDensity.compact,
                        onPressed: state.busy
                            ? null
                            : () => bloc.add(
                                PdfViewerShareGeneratedOutputRequested(
                                  output.path,
                                ),
                              ),
                        icon: const Icon(Icons.ios_share, size: 18),
                      ),
                    ],
                  ),
                  onTap: state.busy || isCurrent
                      ? null
                      : () => bloc.add(
                          PdfViewerOpenGeneratedOutputRequested(output.path),
                        ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _ConvertResultView extends StatelessWidget {
  const _ConvertResultView({required this.result});

  final PdfConvertToPdfResult result;

  @override
  Widget build(BuildContext context) {
    return Text(
      '${result.sourceFileName} (${result.sourceFormat}) · '
      '${result.pageCount} pages · ${result.fileSizeBytes} bytes · '
      '${result.durationMilliseconds} ms\n${result.outputPath}',
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Standalone document viewing: pick any supported file and open it in a
/// Flutter route that hosts the native renderer. Nothing is converted.
class _DocumentViewerControls extends StatelessWidget {
  const _DocumentViewerControls({
    required this.state,
    required this.onOpenDocumentViewer,
  });

  final PdfViewerState state;
  final VoidCallback onOpenDocumentViewer;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PdfViewerBloc>();
    final document = state.viewableDocument;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FilledButton.icon(
              onPressed: state.busy || state.viewablePickPending
                  ? null
                  : () {
                      FocusScope.of(context).unfocus();
                      bloc.add(
                        const PdfViewerPickDocumentForViewingRequested(),
                      );
                    },
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('Choose file'),
            ),
            if (document != null)
              FilledButton.tonalIcon(
                onPressed: onOpenDocumentViewer,
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('Open viewer'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          document == null
              ? 'Word, Excel, PowerPoint, Pages, Numbers, Keynote, RTF, HTML, '
                    'text, CSV, images and PDF.'
              : '${document.fileName} · ${document.fileFormat.toUpperCase()} · '
                    '${(document.fileSizeBytes / 1024).toStringAsFixed(0)} KB',
        ),
      ],
    );
  }
}
