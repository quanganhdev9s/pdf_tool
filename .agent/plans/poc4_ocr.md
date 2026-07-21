# ExecPlan: POC 4 Vision OCR

## Objective

Implement POC 4 only: render selected PDF pages to images, run Apple Vision text
recognition off the main thread where safe, return OCR text/confidence/bounding
boxes by page, report progress, support cancellation, and map a selected OCR
result back to a visible PDF region.

## Scope

In scope:

- Add Pigeon models for OCR request, OCR result block, and OCR progress.
- Add Pigeon Host API commands to run OCR, cancel OCR, and show an OCR result
  location.
- Add Pigeon Flutter callbacks for OCR progress, OCR results, and OCR
  completion.
- Add Flutter Bloc events/state and an OCR panel for current/all-page OCR,
  cancellation, result display, and result location selection.
- Add a Swift `PdfOcrManager` that renders selected pages, runs Vision
  recognition, returns page index, text, confidence, and normalized bounding box.
- Add a native overlay that maps an OCR result's normalized bounding box back to
  the visible PDF page region.
- Keep POC 0 through POC 3 behavior working.

Out of scope:

- Scanner UI, file manager, cloud features, compression, and searchable-PDF
  generation.
- Claims that Vision OCR output makes the PDF searchable.
- Persisted OCR cache or export pipeline beyond diagnostic result display.

## Architecture

- Flutter owns the OCR controls, progress display, cancellation button, and
  result list.
- Swift owns PDF page rasterization, Vision requests, cancellation flags,
  bounding-box conversion, and PDFView overlay positioning.
- Pigeon transfers only serializable request/result data.
- OCR work runs asynchronously. UIKit/PDFView access is kept on the main thread;
  Vision recognition and image processing run on a background queue using
  rendered page images.

## Implementation Steps

1. Completed: read prompt, core docs, POC 4 roadmap/test matrix, and previous
   POC result reports.
2. Completed: update Pigeon schema and regenerate Dart/Swift bridges.
3. Completed: add Flutter Bloc OCR events/state and OCR panel UI.
4. Completed: add Swift `PdfOcrManager`, result callbacks, cancellation, and
   location overlay.
5. Completed: update docs and add POC 4 result notes.
6. Completed: run `dart format .`, `flutter analyze`, `flutter test`, and
   `flutter build ios --simulator --debug`.

## Validation Plan

- Automated:
  - `dart run pigeon --input pigeons/pdf_poc_api.dart`
  - `dart format .` or targeted format for edited Flutter files
  - `flutter analyze`
  - `flutter test`
  - `flutter build ios --simulator --debug`
- Manual required on simulator/device:
  - Open `scanned_vi_en.pdf`.
  - Run OCR on the current page and all pages.
  - Confirm Vietnamese and English text quality is documented.
  - Tap an OCR result and verify the visible overlay aligns with the source
    text region.
  - Cancel an in-flight OCR run and confirm progress stops or limitation is
    recorded.
  - Confirm OCR output is not described as an embedded PDF text layer or a
    searchable PDF.

## Risks and Limitations

- Vision language support and quality vary by OS/device. Vietnamese recognition
  must be manually evaluated.
- Cancellation is cooperative between pages; Vision may not stop instantly while
  a single page request is executing.
- Normalized bounding boxes are returned in Vision's bottom-left normalized
  image space and converted natively for PDFView highlighting.

## Validation Results

- `dart run pigeon --input pigeons/pdf_poc_api.dart`: passed before native and
  Flutter implementation.
- Targeted `dart format` on edited Flutter files: passed.
- `flutter analyze`: passed.
- `flutter build ios --simulator --debug`: passed.
- `flutter test`: passed after rerun with approval because the Flutter SDK
  needed to write engine cache files outside the workspace sandbox.
