# ExecPlan: POC 2 Electronic Signature

## Objective

Implement POC 2 only: capture a handwritten electronic signature using
PencilKit, keep a reusable local signature representation during the current
viewer session, place it on a selected PDF page, move/resize it before
committing, save an editable output, and export a flattened output.

## Scope

In scope:

- Add Pigeon Host API commands for signature capture, placement, commit,
  placement cancellation, selected signature deletion, and flattened export.
- Add Flutter Bloc events and bottom-toolbar UI controls labeled as electronic
  signature.
- Present a UIKit/PencilKit signature capture controller with Clear, Cancel, and
  Confirm actions.
- Store the confirmed `PKDrawing` in the native document session as reusable
  session-local data.
- Place the captured signature on the current page using a native placement
  overlay with drag and pinch resize.
- Commit the placement as an editable PDF ink annotation.
- Export a flattened PDF copy to a separate writable path.
- Keep POC 0 viewer/text/free-text and POC 1 ink behavior working.

Out of scope:

- Certificate-based PDF digital signatures.
- Signature identity, certificates, timestamps, cryptographic validation, or
  audit trails.
- OCR, compression, crop, page operations, file manager, share sheet, or backlog
  features.
- Production-grade annotation handles or style customization.

## Architecture

- Flutter owns toolbar/panel controls and dispatches `PdfViewerEvent` objects.
- Swift owns `PKCanvasView` signature capture, `PKDrawing` storage, PDFKit
  coordinate conversion, annotation creation, placement overlay geometry,
  deletion, saving, and flattened export.
- Pigeon remains the typed Dart-Swift bridge.
- Editable signature output is represented as a PDF ink annotation generated
  from the captured drawing paths. Flattened export draws all page annotations
  into page content and writes a separate PDF file.

## Implementation Steps

1. Completed: update Pigeon schema for POC 2 signature commands and regenerate
   Dart/Swift bridges.
2. Completed: add Flutter Bloc events/state and a bottom-toolbar signature
   panel.
3. Completed: add native UIKit/PencilKit capture overlay and session-local
   signature drawing storage.
4. Completed: add native placement overlay with drag/pinch resize, commit to
   editable ink annotation, delete selected signature annotation, and flattened
   export.
5. Completed: update documentation and POC 2 result report.
6. Completed: run `dart format .`, `flutter analyze`, `flutter test`, and
   `flutter build ios --simulator --debug`.

## Validation Plan

- Automated completed:
  - `dart format .`: passed.
  - `flutter analyze`: passed.
  - `flutter test`: passed.
  - `flutter build ios --simulator --debug`: passed.
- Manual required on simulator/device:
  - Capture electronic signature.
  - Clear and recapture before confirm.
  - Place signature on current page.
  - Move and resize before commit.
  - Commit, save, close, and reopen.
  - Select/delete committed signature annotation.
  - Export flattened copy and confirm signature is no longer an editable
    annotation in a PDF viewer that supports annotation inspection.

## Risks and Limitations

- Editable signature output uses a PDF ink annotation, not a cryptographic
  digital signature.
- Flattened export is a POC implementation and must be manually checked with
  representative PDFs and annotations.
- Simulator cannot validate Apple Pencil hardware behavior.
