import 'package:flutter/material.dart';

class FreeTextAreaComposer extends StatelessWidget {
  const FreeTextAreaComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.bottomInset,
    required this.onCancel,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final double bottomInset;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Keep the composer above the iOS keyboard while the selected PDF rect
    // remains stored in Bloc state.
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      left: 12,
      right: 12,
      bottom: bottomInset + 12,
      child: SafeArea(
        top: false,
        child: Material(
          elevation: 8,
          color: colors.surface,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Text for selected area',
                    ),
                    onSubmitted: (_) => onSubmit(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  tooltip: 'Cancel selected area',
                  onPressed: busy ? null : onCancel,
                  icon: const Icon(Icons.close),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : onSubmit,
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
