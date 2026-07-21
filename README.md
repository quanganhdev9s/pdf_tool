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

## Cách sử dụng

1. Copy toàn bộ nội dung gói này vào root của Flutter repository.
2. Thêm các PDF test vào `assets/poc/`.
3. Khai báo các asset này trong `pubspec.yaml`.
4. Mở repository bằng Codex.
5. Chạy prompt `prompts/00_audit.md`.
6. Sau khi audit tài liệu xong, chạy `prompts/01_poc0_viewer_text.md`.
7. Chỉ chuyển sang POC tiếp theo khi POC hiện tại đạt Definition of Done.

## Thứ tự triển khai

1. POC 0 — Viewer và text interaction
2. POC 1 — PencilKit ink annotation
3. POC 2 — Electronic signature
4. POC 3 — Crop và page operations
5. POC 4 — OCR
6. POC 5 — Compression

Không yêu cầu Codex triển khai toàn bộ roadmap trong một task.

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

Current Flutter structure:

- `lib/main.dart`: app entrypoint only.
- `lib/pdf_picker/cubit/`: simple Cubit and state for choosing a test asset.
- `lib/pdf_picker/screens/`: asset picker screen.
- `lib/pdf_viewer/bloc/`: `PdfViewerBloc`, `PdfViewerEvent`,
  `PdfViewerState`, and Bloc barrel.
- `lib/pdf_viewer/screens/`: PDF viewer screen and compatibility barrels.
- `lib/pdf_viewer/widgets/`: reusable viewer controls and composer widgets.
- `lib/pdf_viewer/data/`: test asset metadata and diagnostic logging helpers.
- `lib/pdf_viewer/screens/pdf_bloc_app.dart`: compatibility barrel that exports
  the active picker/viewer screens.

## Debug logging

POC 0 and POC 1 emit diagnostic events with the stable filter key `PDF Event`.

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
