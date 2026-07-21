# ExecPlan: POC 3 Crop and Page Operations

## Objective

Implement POC 3 only: mutate the writable PDF copy with PDFKit page operations,
including rotate, delete, reorder, duplicate, crop-box changes, saving to a
separate output, and reopen verification.

## Scope

In scope:

- Add Pigeon Host API commands for rotate, delete, duplicate, move, crop,
  pending reorder commit/cancel, and save-to-new-output operations.
- Add Flutter Bloc events and bottom-toolbar controls for page operations.
- Add a dedicated reorder route with native PDF page previews and drag/drop
  ordering.
- Add a native Swift page-operations manager/service owned by the PDF workspace.
- Preserve existing PDF annotations when rotating, deleting, moving,
  duplicating, cropping, saving, and reopening.
- Reopen the generated output after save-to-new-output to verify page count and
  parseability.
- Document that crop changes the PDF crop box and is not secure deletion.
- Keep POC 0, POC 1, and POC 2 behavior working.

Out of scope:

- OCR, compression, split, merge, file manager, share sheet, or backlog
  features.
- Secure redaction or claims that cropped hidden content is deleted.
- Production page-thumbnail reordering UI.

## Architecture

- Flutter owns the POC page-operation controls and dispatches
  `PdfViewerEvent` objects.
- Swift owns `PDFDocument`, `PDFPage`, crop boxes, page insertion/removal, page
  rotation, save/reopen verification, reorder thumbnails, drag/drop ordering,
  and annotation preservation.
- Pigeon remains the typed Dart-Swift bridge and transfers only serializable
  request/result data.
- Page operations run on the open writable PDF session; save-to-new-output
  writes a separate PDF file derived from the current working copy.

## Implementation Steps

1. Completed: read documentation, previous result reports, and current
   Pigeon/Flutter/Swift implementation.
2. Completed: update Pigeon schema for POC 3 page-operation commands and
   regenerate Dart/Swift bridges.
3. Completed: add Flutter Bloc events, a page-operations panel, and a dedicated
   reorder route.
4. Completed: add native PDFKit page-operations manager and wire it into
   `PdfWorkspaceView` and `PdfPocHostApiImpl`.
5. Completed: add a native `PdfPageReorderView` platform view with PDFKit
   thumbnails, drag/drop reordering, pending order storage, and Apply/Cancel
   Pigeon flow.
6. Completed: update documentation and add POC 3 result notes.
7. Completed: run `dart format .`, `flutter analyze`, `flutter test`, and
   `flutter build ios --simulator --debug`.

## Validation Plan

- Automated completed:
  - `dart run pigeon --input pigeons/pdf_poc_api.dart`: passed after rerun with
    approval because SDK cache writes were outside the workspace sandbox.
  - `dart format .`: passed.
  - `flutter analyze`: passed.
  - `flutter test`: passed after rerun with approval because SDK cache writes
    were outside the workspace sandbox.
  - `flutter build ios --simulator --debug`: passed.
- Manual required on simulator/device:
  - Rotate a page, save to a new output, reopen, and verify rotation.
  - Delete a page and verify page count after reopen.
  - Duplicate a page and verify page count/order after reopen.
  - Open the Reorder screen, drag page previews, apply, and verify order after
    reopen.
  - Apply crop and verify visible region after reopen.
  - Repeat after creating annotations and confirm annotations remain on the
    intended pages.
  - Confirm the source asset under `assets/poc/` remains unchanged.

## Risks and Limitations

- PDFKit page mutation may preserve annotations differently across PDF inputs;
  manual validation with representative assets remains required.
- Crop box changes hide content visually but do not securely delete hidden PDF
  content.
- The reorder screen validates drag/drop thumbnail ordering, but it is still a
  POC screen rather than a production page organizer.
