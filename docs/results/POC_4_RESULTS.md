# POC 4 Results

## Scope

POC 4 implements Vision OCR only:

- OCR controls in the existing PDF viewer bottom toolbar.
- Current-page OCR and all-page OCR from Flutter Bloc events.
- Native PDF page rasterization and `VNRecognizeTextRequest` execution.
- Vietnamese and English recognition language hints.
- Result callbacks with page index, text, confidence, and normalized bounding
  boxes.
- Page progress callbacks and cooperative cancellation.
- Tap an OCR result to navigate the PDF viewer and show a transient location
  overlay.
- Diagnostic logging with the stable `PDF Event` key.

No scanner, file manager, cloud import, compression, searchable-PDF generation,
OCR caching, or OCR export pipeline is implemented in POC 4.

## Architecture

- Flutter owns OCR controls, running state, progress, result list, cancellation
  action, and result selection through `PdfViewerBloc`.
- Pigeon transfers `PdfOcrRequest`, `PdfOcrBlock`, OCR progress, OCR result,
  and OCR completion messages.
- Swift owns PDFKit rasterization, Vision request configuration, cooperative
  cancellation, and mapping an OCR result back into the visible PDF view.
- `PdfOcrManager` runs Vision work on a serial background queue and schedules
  PDF page rendering on the main thread.
- `PdfWorkspaceView` remains the native orchestrator for document availability,
  OCR manager callbacks, and the transient OCR result overlay.

## Coordinate Contract

- `PdfOcrBlock.normalizedBoundingBox` is Vision-normalized in the range `0..1`.
- The normalized origin is bottom-left.
- `showOcrResult` maps that box into the PDF page `cropBox`, then into
  `PDFView` coordinates for display.
- The overlay is viewer-only and is not saved into the PDF.

## Live Text Contract

- `scanned_vi_en.pdf` has no embedded PDF text layer.
- On supported Apple OS/device combinations, PDFKit/system Live Text may still
  allow text selection and copy from rendered page imagery.
- Successful Live Text copy must not be used as the only signal that a PDF has
  an embedded text layer.
- Vision OCR remains the controlled POC 4 path for text, confidence, bounding
  boxes, progress, cancellation, and future export/cache work.
- POC 4 does not embed Live Text or Vision OCR output into the PDF.

## Known Limitations

- Cancellation is cooperative. A Vision request already processing one page may
  finish before callbacks stop.
- OCR quality depends on iOS version, device support, image quality, language
  support, and page rendering scale.
- The transient overlay is intended for immediate result inspection. It is not a
  persistent annotation and should be reselected after zoom/scroll changes if
  alignment needs to be checked again.
- Searchable PDF output is not implemented or claimed.

## Manual Validation Checklist

- Open `scanned_vi_en.pdf`.
- Confirm PDFKit embedded search fails or returns no embedded-text results.
- Separately record whether system Live Text selection/copy works, including
  iOS version, simulator/device model, and language behavior.
- Run OCR on the current page and record Vietnamese and English text quality.
- Run OCR on all pages and confirm progress reaches the page count.
- Tap several OCR results and verify the overlay aligns with source text.
- Start all-page OCR, cancel it, and record whether cancellation stops between
  pages or after the in-flight page finishes.
- Confirm no searchable PDF or saved OCR text layer is produced.

## Validation

- `dart run pigeon --input pigeons/pdf_poc_api.dart`: passed before this result
  note was written.
- `dart format` on edited Flutter files: passed.
- `flutter analyze`: passed.
- `flutter build ios --simulator --debug`: passed.
- `flutter test`: passed after rerun with approval because the Flutter SDK
  needed to write engine cache files outside the workspace sandbox.

Manual simulator/device verification remains required for OCR quality, Live Text
comparison, bounding-box alignment, and cancellation timing.
