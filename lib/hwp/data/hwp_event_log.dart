const String hwpEventTag = 'HWP Event';

void logHwpEvent(String event, [Map<String, Object?> details = const {}]) {
  final String detailText = details.entries
      .map((MapEntry<String, Object?> entry) => '${entry.key}=${entry.value}')
      .join(' ');
  // ignore: avoid_print
  print(
    '$hwpEventTag | flutter | $event${detailText.isEmpty ? '' : ' | $detailText'}',
  );
}
