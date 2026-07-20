import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_viewer/data/pdf_event_log.dart';
import 'pdf_asset_picker_state.dart';

class PdfAssetPickerCubit extends Cubit<PdfAssetPickerState> {
  PdfAssetPickerCubit() : super(const PdfAssetPickerState());

  void selectAsset(String assetKey) {
    logPdfEvent('asset_tap', <String, Object?>{'asset': assetKey});
  }
}
