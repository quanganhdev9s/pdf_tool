# POC 1 Results

## Scope

POC 1 implements PencilKit ink annotation validation only:

- Read/Ink mode controls in the existing `PdfViewerBloc` flow.
- A Swift-owned `PKCanvasView` overlay above the native `PDFView`.
- Touch and Apple Pencil capable drawing through PencilKit.
- Clear current draft ink without modifying committed PDF annotations.
- Commit current PencilKit strokes into editable PDF ink annotations when valid
  page-coordinate paths can be collected.
- Save and reopen the editable writable PDF copy through the existing save
  path.
- Tap an ink annotation in Read mode and delete the selected annotation.
- Diagnostic logging with the stable `PDF Event` key.

No signature capture, OCR, crop, page reordering, compression, file manager, or
deferred backlog feature is implemented in POC 1.

## Architecture

- Flutter owns viewer controls and state through `PdfViewerBloc`,
  `PdfViewerEvent`, and `PdfViewerState`.
- Pigeon adds four POC 1 Host API commands:
  `setInkModeEnabled`, `clearCurrentInkInput`, `commitCurrentInkToPdf`, and
  `deleteSelectedAnnotation`.
- Swift owns `PKCanvasView`, temporary `PKDrawing`, PDFKit coordinate
  conversion, PDF ink annotation creation, annotation selection, deletion, and
  saving.
- Ink commits convert PencilKit canvas points through `PDFView` into `PDFPage`
  coordinates, grouping valid paths by page before creating PDF ink
  annotations.

## Coordinate Contract

- PencilKit points are captured in the native canvas overlay coordinate space.
- Page lookup and point conversion use PDFKit conversion APIs instead of
  Flutter-side geometry or manual zoom/scroll offsets.
- Persisted ink paths are stored in PDF page coordinates.
- Ink annotation bounds use the page `cropBox`.
- Paths that leave a page are split or ignored when no containing page exists.

## Known Limitations

- PDF ink annotations preserve editability when PDFKit accepts the generated
  paths, but PencilKit pressure, velocity, and full stroke rendering fidelity
  are not preserved.
- Current UI commits the draft drawing explicitly. Users should commit before
  saving or before heavy navigation changes.
- Ink selection is tap-based in Read mode and limited to PDF ink annotations.
  Move, resize, color selection, stroke width, and custom selection handles are
  outside POC 1.
- Simulator validation cannot prove Apple Pencil hardware behavior; that must be
  tested on a physical supported iPad.
- Apple Preview interoperability requires manual verification on a saved
  writable copy.

## Manual Validation Checklist

- Open `text_document.pdf`, switch to Ink mode, draw with touch, commit, save,
  close, and reopen.
- Repeat after zooming and scrolling before drawing.
- Draw on page 2 or later and confirm the annotation stays on that page.
- Test `mixed_rotation.pdf` for rotated page behavior.
- Test `existing_crop_box.pdf` for crop-box coordinate behavior.
- Switch back to Read mode, tap a committed ink annotation, delete it, save, and
  reopen.
- Open the saved working copy in Apple Preview and confirm committed ink is
  visible.

## Validation

- `dart format .`: passed.
- `flutter analyze`: passed.
- `flutter test`: passed after rerun with approval because the Flutter SDK
  needed to write engine cache files outside the workspace sandbox.
- `flutter build ios --simulator --debug`: passed.

Manual simulator/device verification remains required for visual coordinate
behavior, Apple Pencil input, and Apple Preview interoperability.
