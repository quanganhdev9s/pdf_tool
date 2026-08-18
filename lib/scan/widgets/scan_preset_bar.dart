import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_scan_api.g.dart';
import '../bloc/scan_review_bloc.dart';

/// Preset picker plus the original/enhanced comparison toggle.
///
/// Presets are a closed set rather than sliders: each one is tuned against
/// fixture images and can be regression-tested, which a free-form brightness
/// control cannot be. Shadow correction is not here at all — the pipeline
/// detects under-lit regions and fixes only those, so there is nothing for the
/// user to aim.
class ScanPresetBar extends StatelessWidget {
  const ScanPresetBar({super.key, required this.state});

  final ScanReviewState state;

  static const Map<PdfScanPreset, String> _labels = <PdfScanPreset, String>{
    PdfScanPreset.original: 'Original',
    PdfScanPreset.enhancedColor: 'Enhanced',
    PdfScanPreset.cleanGrayscale: 'Grayscale',
    PdfScanPreset.blackAndWhite: 'B&W',
  };

  @override
  Widget build(BuildContext context) {
    final ScanReviewBloc bloc = context.read<ScanReviewBloc>();
    final PdfScanPreset? active = state.currentPage?.preset;
    final bool enabled = state.hasSession && !state.isBusy;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final MapEntry<PdfScanPreset, String> entry
                    in _labels.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(entry.value),
                      selected: active == entry.key,
                      onSelected: enabled
                          ? (_) => bloc.add(
                                ScanPresetSelected(
                                  entry.key,
                                  applyToAll: false,
                                ),
                              )
                          : null,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              TextButton.icon(
                onPressed: enabled && active != null
                    ? () => bloc.add(ScanPresetSelected(active, applyToAll: true))
                    : null,
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('Apply to all'),
              ),
              const Spacer(),
              // Held rather than toggled: comparing is a momentary check
              // against the original, not a mode to get stuck in.
              GestureDetector(
                onTapDown: enabled
                    ? (_) => bloc.add(const ScanComparisonToggled(true))
                    : null,
                onTapUp: enabled
                    ? (_) => bloc.add(const ScanComparisonToggled(false))
                    : null,
                onTapCancel: enabled
                    ? () => bloc.add(const ScanComparisonToggled(false))
                    : null,
                child: Chip(
                  avatar: const Icon(Icons.compare_outlined, size: 18),
                  label: Text(
                    state.isComparingOriginal ? 'Showing original' : 'Hold to compare',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
