const List<String> pocPdfAssets = <String>[
  'assets/poc/text_document.pdf',
  'assets/poc/scanned_vi_en.pdf',
  'assets/poc/existing_annotations.pdf',
  'assets/poc/password_protected.pdf',
];

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
