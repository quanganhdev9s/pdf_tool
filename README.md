# Flutter iOS PDF POC — Codex Documentation Pack

Bộ tài liệu này dùng để giao Codex xây dựng technical POC cho ứng dụng PDF:

- Flutter application shell
- UIKit native PDF workspace
- PDFKit
- PencilKit
- Vision OCR
- Pigeon
- Bloc/Cubit for Flutter-side POC state and controls
- Không dùng SDK PDF thương mại
- Chỉ hỗ trợ iOS

## Flutter state management

POC 0 uses `flutter_bloc` with separate state layers for the simple picker and
the more complex PDF viewer.

- The PDF asset picker uses `PdfAssetPickerCubit` because it only owns a static
  asset list and selection logging.
- The PDF viewer uses `PdfViewerBloc` because it handles commands, async Pigeon
  calls, native callbacks, busy/status state, and selected free-text-area flow.
- Viewer widgets render controls and own UI-only objects such as text
  controllers and focus nodes.
- Native Swift/PDFKit still owns all PDF objects, coordinates, annotations,
  saving, and clipboard access.
- Do not call generated Pigeon APIs directly from widgets for new POC 0 viewer
  controls; dispatch a `PdfViewerEvent` instead.
- The PDF viewer uses a bottom icon toolbar. Each icon toggles one feature panel
  such as page controls, search, ink, free text, electronic signature,
  selection actions, or status.

## Debug logging

- Flutter UI/control events: `PDF Event | flutter | ...`
- Native Swift/PDFKit events: `PDF Event | native | ...`

When testing on the iOS simulator from Android Studio, filter the Run/Debug
console by `PDF Event`. When testing from Xcode, filter the Xcode console by the
same key.

POC 1 ink controls are part of the PDF viewer Bloc. Use Read mode for
navigation, text selection, and tapping an existing ink annotation; use Ink mode
to draw on the PencilKit overlay, then commit the draft ink into editable PDF
ink annotations before saving.

POC 2 electronic-signature controls capture a handwritten signature with
PencilKit, place it as an editable annotation, and export a separate flattened
copy. This is not certificate-based PDF digital signing.
