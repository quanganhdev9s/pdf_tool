String assetName(String key) => key.split('/').last;

String assetDescription(String key) {
  if (key.contains('scanned')) {
    return 'Scan-only PDF for no-searchable-text validation';
  }
  if (key.contains('annotations')) {
    return 'Existing annotations PDF';
  }
  if (key.contains('password')) {
    return 'Password-protected PDF';
  }
  return 'Searchable text PDF';
}
