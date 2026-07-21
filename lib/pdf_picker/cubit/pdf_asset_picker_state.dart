import '../../pdf_viewer/data/pdf_assets.dart';

class PdfAssetPickerState {
  const PdfAssetPickerState({this.assets = pocPdfAssets});

  final List<String> assets;
}
