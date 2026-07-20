import 'package:flutter/foundation.dart';

const String pdfEventTag = 'PDF Event';

void logPdfEvent(String event, [Map<String, Object?> details = const {}]) {
  final detailText = details.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join(' ');
  debugPrint(
    '$pdfEventTag | flutter | $event${detailText.isEmpty ? '' : ' | $detailText'}',
  );
}
