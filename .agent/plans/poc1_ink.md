# ExecPlan: POC 1 PencilKit Ink Annotation

## Objective

Implement POC 1 only: PencilKit drawing mode over the native PDF workspace,
conversion of captured strokes into editable PDF ink annotations where
practical, save/reopen persistence, and selected ink annotation deletion.

## Scope

In scope:

- Add explicit read and ink modes.
- Add a UIKit `PKCanvasView` overlay owned by Swift.
- Support touch and Apple Pencil drawing.
- Convert strokes from the overlay into PDF page coordinates.
- Create PDF ink annotations using PDFKit when bounds and paths are valid.
- Select and delete ink annotations created or exposed as PDF annotations.
- Keep existing POC 0 text/search/free-text behavior working.

Out of scope:

- Signature capture or reusable signatures.
- OCR, compression, crop, page reorder/delete/duplicate/rotate.
- Rasterizing ink by default.
- Production-grade annotation editing UI.

## Architecture

- Flutter owns controls and state through `PdfViewerBloc`.
- Swift owns `PKCanvasView`, `PKDrawing`, PDFKit coordinate conversion, annotation
  creation/deletion, and save/reopen.
- Pigeon remains the typed Dart-Swift bridge.
- POC 1 adds Host API commands for ink mode, clearing current ink input,
  committing current ink to PDF, and deleting selected annotations.

## Implementation Steps

1. Completed: update Pigeon schema for ink commands and regenerate Dart/Swift
   bridges.
2. Completed: add Flutter Bloc events and UI controls for read/ink mode, clear
   ink, commit ink, and delete selected annotation.
3. Completed: add Swift `PKCanvasView` overlay, ink mode state, drawing capture,
   PDF ink annotation creation, and annotation deletion.
4. Completed: update documentation and result notes for POC 1 behavior and
   limitations.
5. Completed: run `dart format .`, `flutter analyze`, `flutter test`, and
   `flutter build ios --simulator --debug`.

## Validation Plan

- Automated completed:
  - `dart format .`: passed.
  - `flutter analyze`: passed.
  - `flutter test`: passed.
  - `flutter build ios --simulator --debug`: passed.
- Manual required on simulator/device:
  - Open a writable asset.
  - Switch to Ink mode.
  - Draw with touch or Apple Pencil.
  - Commit ink to PDF.
  - Save and reopen.
  - Verify the annotation remains on the same page and can be deleted.
  - Repeat after zoom/scroll and on later pages.

## Risks and Limitations

- PDFKit `PDFAnnotation` ink path fidelity may differ from PencilKit pressure
  and stroke rendering.
- Multi-page drawing from one overlay commit is split by the page that contains
  each captured point; points outside PDF pages are ignored.
- Simulator cannot validate Apple Pencil hardware behavior.
