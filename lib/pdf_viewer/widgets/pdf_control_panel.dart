import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PdfViewerBloc>();
    return Material(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: Alignment.bottomCenter,
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

class _StatusControls extends StatelessWidget {
  const _StatusControls({required this.state});

  final PdfViewerState state;

  @override
  Widget build(BuildContext context) {
    return Text(state.status, maxLines: 3, overflow: TextOverflow.ellipsis);
  }
}
