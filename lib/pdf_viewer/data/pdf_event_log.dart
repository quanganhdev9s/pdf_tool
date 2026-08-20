const String pdfEventTag = 'PDF Event';

/// `print`, not `debugPrint`: `debugPrint` throttles its output and drops what
/// overflows the budget, which loses exactly the bursts worth reading — a tap
/// that logs a selection, its colour sample and its geometry in one go.
void logPdfEvent(String event, [Map<String, Object?> details = const {}]) {
  final detailText = details.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join(' ');
  // This is the POC's event trace and it has to reach the IDE console
  // unthrottled.
  // ignore: avoid_print
  print(
    '$pdfEventTag | flutter | $event${detailText.isEmpty ? '' : ' | $detailText'}',
  );
}
