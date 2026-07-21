import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_poc_api.g.dart';
import '../bloc/pdf_viewer_bloc.dart';
import 'selection_action_toolbar.dart';

class PdfControlPanel extends StatelessWidget {
  const PdfControlPanel({
    super.key,
    required this.state,
    required this.pageText,
    required this.dirtyText,
    required this.searchText,
    required this.pageController,
    required this.searchController,
    required this.freeTextController,
    required this.onJumpToPage,
    required this.onSearch,
    required this.onAddFreeText,
    required this.onBeginFreeTextAreaSelection,
  });

  final PdfViewerState state;
  final String pageText;
  final String dirtyText;
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (state.hasSelection) ...<Widget>[
              SelectionActionToolbar(
                busy: state.busy,
                selectedText: state.selectedText!,
                onCopy: () => bloc.add(const PdfViewerCopySelectionRequested()),
                onHighlight: () => bloc.add(
                  const PdfViewerMarkupSelectionRequested(
                    PdfMarkupType.highlight,
                  ),
                ),
                onUnderline: () => bloc.add(
                  const PdfViewerMarkupSelectionRequested(
                    PdfMarkupType.underline,
                  ),
                ),
                onStrikeout: () => bloc.add(
                  const PdfViewerMarkupSelectionRequested(
                    PdfMarkupType.strikeout,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                IconButton.outlined(
                  tooltip: 'Previous page',
                  onPressed: state.busy
                      ? null
                      : () => bloc.add(const PdfViewerPreviousPageRequested()),
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton.outlined(
                  tooltip: 'Next page',
                  onPressed: state.busy
                      ? null
                      : () => bloc.add(const PdfViewerNextPageRequested()),
                  icon: const Icon(Icons.chevron_right),
                ),
                SizedBox(
                  width: 86,
                  child: TextField(
                    controller: pageController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Page'),
                    onSubmitted: (_) => onJumpToPage(),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: state.busy ? null : onJumpToPage,
                  child: const Text('Jump'),
                ),
                Text('$pageText · $dirtyText'),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
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
            ),
            const SizedBox(height: 8),
            Wrap(
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
                      : () => bloc.add(
                          const PdfViewerPreviousSearchResultRequested(),
                        ),
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton.outlined(
                  tooltip: 'Next result',
                  onPressed: state.busy
                      ? null
                      : () => bloc.add(
                          const PdfViewerNextSearchResultRequested(),
                        ),
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
            ),
            const SizedBox(height: 8),
            Wrap(
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
                if (!state.hasSelection)
                  Text(
                    'Select text to show Copy, Highlight, Underline, Strikeout',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Selection: ${state.hasSelection ? state.selectedText : 'none'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(state.status, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (state.busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
