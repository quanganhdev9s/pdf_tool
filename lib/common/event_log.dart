const String pdfEventTag = 'PDF Event';

/// Trục thời gian của một lượt mở tệp, song song với `PdfEventClock` bên native.
/// Mốc 0 khác native vài mili-giây — nó bắt đầu khi native gọi ngược lên đây —
/// nên đọc hai bên thì so theo dòng `callback_document_for_viewing_picked`.
final Stopwatch _pdfEventClock = Stopwatch();

void startPdfEventClock() {
  _pdfEventClock
    ..reset()
    ..start();
}

void stopPdfEventClock() {
  _pdfEventClock.stop();
}

/// `print`, not `debugPrint`: `debugPrint` throttles its output and drops what
/// overflows the budget, which loses exactly the bursts worth reading — a tap
/// that logs a selection, its colour sample and its geometry in one go.
void logPdfEvent(String event, [Map<String, Object?> details = const {}]) {
  final detailText = details.entries.map((entry) => '${entry.key}=${entry.value}').join(' ');
  final stamp = _pdfEventClock.isRunning ? ' | t=${_pdfEventClock.elapsedMilliseconds}ms' : '';
  // This is the POC's event trace and it has to reach the IDE console
  // unthrottled.
  // ignore: avoid_print
  print(
    '$pdfEventTag | flutter | $event'
    '${detailText.isEmpty ? '' : ' | $detailText'}$stamp',
  );
}
