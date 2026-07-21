const List<String> pocPdfAssets = <String>[
  'assets/poc/text_document.pdf',
  'assets/poc/scanned_vi_en.pdf',
  'assets/poc/existing_annotations.pdf',
  'assets/poc/password_protected.pdf',
  'assets/poc/existing_crop_box.pdf',
  'assets/poc/forms_and_links.pdf',
  'assets/poc/large_document.pdf',
  'assets/poc/image_heavy.pdf',
  'assets/poc/mixed_rotation.pdf',
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
