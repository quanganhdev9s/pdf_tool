import 'package:flutter/material.dart';

class SelectionActionToolbar extends StatelessWidget {
  const SelectionActionToolbar({
    super.key,
    required this.busy,
    required this.selectedText,
    required this.onCopy,
    required this.onHighlight,
    required this.onUnderline,
    required this.onStrikeout,
  });

  final bool busy;
  final String selectedText;
  final VoidCallback onCopy;
  final VoidCallback onHighlight;
  final VoidCallback onUnderline;
  final VoidCallback onStrikeout;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            selectedText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: busy ? null : onCopy,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy ? null : onHighlight,
                icon: const Icon(Icons.format_color_fill, size: 18),
                label: const Text('Highlight'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy ? null : onUnderline,
                icon: const Icon(Icons.format_underlined, size: 18),
                label: const Text('Underline'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy ? null : onStrikeout,
                icon: const Icon(Icons.strikethrough_s, size: 18),
                label: const Text('Strikeout'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
