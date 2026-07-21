# POC 2 Results

## Scope

POC 2 implements electronic signature validation only:

- Electronic signature panel in the existing bottom toolbar and
  `PdfViewerBloc` flow.
- Native PencilKit capture overlay with capture, clear, and confirm actions.
- Session-local reusable `PKDrawing` signature representation.
- Native placement preview on the current PDF page.
- Drag to move and pinch or toolbar buttons to resize before committing
  placement.
- Simulator-friendly Smaller/Larger controls resize the placement when pinch is
  awkward to test.
- Commit placement as an editable PDF annotation.
- Tap a committed electronic signature annotation in Read mode and delete it.
- Save/reopen through the existing editable working-copy save path.
- Export a separate flattened PDF copy.
- Diagnostic logging with the stable `PDF Event` key.

No certificate-based digital signing, OCR, crop, page reordering, compression
workflow, file manager, or deferred backlog feature is implemented in POC 2.

## Architecture

- Flutter owns viewer controls and state through `PdfViewerBloc`,
  `PdfViewerEvent`, and `PdfViewerState`.
- Pigeon adds electronic-signature commands for capture, clear, confirm,
  placement, commit, cancel, delete selected signature, and flattened export.
- Swift owns PencilKit capture, `PKDrawing` storage, preview placement,
  drag/resize gestures, PDFKit coordinate conversion, annotation creation,
  annotation deletion, save, and flattened export.
- The editable electronic signature is stored as a PDF ink annotation whose
  contents mark it as a POC electronic-signature annotation.
- The flattened export writes a separate PDF file and renders pages through
  PDFKit drawing.

## Coordinate Contract

- Capture strokes are stored in PencilKit drawing coordinates.
- Placement preview lives in native workspace coordinates.
- Commit converts the placement frame through `PDFView` to `PDFPage`
  coordinates.
- Captured stroke points are normalized from the capture bounds and scaled into
  the selected PDF page rectangle.
- Rotation, zoom, scroll, and crop-box handling remain native through PDFKit
  conversion APIs.

## Known Limitations

- This is a handwritten electronic signature annotation, not a cryptographic PDF
  digital signature.
- The reusable signature representation is session-local only.
- The editable committed signature uses an ink annotation representation. It is
  not a certificate, identity proof, timestamp, or audit trail.
- The flattened export is a POC path and needs manual verification with Preview
  or another PDF viewer to confirm annotation editability is removed.
- Simulator validation cannot prove Apple Pencil hardware behavior.
- Production annotation handles, color controls, reusable signature library, and
  share/export UI are outside POC 2.

## Manual Validation Checklist

- Open `text_document.pdf`.
- Open the Electronic signature panel.
- Start capture, draw a signature, clear it, draw again, and confirm.
- Place the signature on the current page.
- Drag the placement preview and resize it with pinch or the Smaller/Larger
  toolbar buttons.
- Commit placement, save, close, and reopen.
- Tap the committed electronic signature in Read mode and delete it.
- Capture once and place the same signature again in the same session.
- Export flattened copy and inspect the generated path in a PDF viewer.

## Validation

- `dart format .`: passed.
- `flutter analyze`: passed.
- `flutter test`: passed after rerun with approval because the Flutter SDK
  needed to write engine cache files outside the workspace sandbox.
- `flutter build ios --simulator --debug`: passed.

Manual simulator/device verification remains required for capture quality,
move/resize behavior, save/reopen positioning, Apple Pencil input, and flattened
export editability.
