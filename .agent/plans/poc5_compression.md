# ExecPlan: POC 5 PDF Compression

## Objective

Implement POC 5 only: compare preservation-oriented PDF output with rasterized
maximum compression, record compression metrics and destructive tradeoffs, and
keep the UI responsive during large compression work.

## Scope

In scope:

- Add typed Pigeon models and commands for compression mode, request, result,
  progress, completion, and cancellation.
- Add Flutter Bloc events/state and a compression panel for preservation mode,
  rasterized mode, DPI/JPEG quality controls, progress, cancellation, warnings,
  and metrics display.
- Add a Swift `PdfCompressionManager` that produces separate output files:
  preservation mode through PDFKit write and rasterized mode through page image
  rendering plus `UIGraphicsPDFRenderer`.
- Record input bytes, output bytes, compression ratio, duration, text
  selectability, annotation editability, link behavior, form behavior, and
  visual-quality notes.
- Keep POC 0 through POC 4 behavior working.

Out of scope:

- File manager, cloud import/export, split/merge, image-to-PDF, text-to-PDF,
  production compression presets, or background task integration.
- Claims that rasterized output preserves selectable text, links, forms, vector
  quality, or editable annotations.

## Architecture

- Flutter owns controls, progress display, warnings, and metric display.
- Swift owns PDFKit documents/pages, output path generation, save/export,
  rasterization, JPEG compression, and file-size measurement.
- Pigeon transfers serializable request/result data only.
- Compression work is asynchronous. UIKit/PDFView access remains on the main
  thread; file writing and rasterized page processing are scheduled through a
  native manager to avoid an avoidable main-thread freeze.

## Implementation Steps

1. Completed: read prompt, project instructions, POC 5 scope/roadmap/test
   matrix, Pigeon notes, and previous result style.
2. Completed: update Pigeon schema and regenerate Dart/Swift bridges.
3. Completed: add Swift compression manager, runtime callbacks, cancellation, and
   workspace output entry points.
4. Completed: add Flutter Bloc compression events/state and panel UI.
5. Completed: update docs and add POC 5 result notes.
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
  - Run preservation mode on `image_heavy.pdf` and `forms_and_links.pdf`.
  - Run rasterized mode at 150, 120, and 96 DPI where practical.
  - Confirm output PDFs open.
  - Record text selectability, annotation editability, links, forms, visual
    quality, duration, and size ratio.
  - Confirm rasterized warning is visible before/while running.

## Risks and Limitations

- Preservation-oriented compression may produce little or no size reduction
  because PDFKit exposes limited lossless compression controls.
- Rasterized compression intentionally destroys selectable text, links, forms,
  vector quality, and editable annotations.
- Cancellation is cooperative between pages; an in-flight page render/write may
  finish before the manager stops.

## Validation Results

- `dart run pigeon --input pigeons/pdf_poc_api.dart`: passed after rerun with
  approval because the Flutter/Dart SDK needed to write cache files outside the
  workspace sandbox.
- `dart format .`: passed.
- `flutter analyze`: passed.
- `flutter build ios --simulator --debug`: passed after rerun because the first
  attempt overlapped another Flutter command and could not update the iOS
  ephemeral package metadata.
- `flutter test`: passed after rerun with approval because the Flutter SDK
  needed to write engine cache files outside the workspace sandbox.
