# POC 7 Results

## Scope

POC 7 implements document scanning to an image-based PDF only:

- Flutter Bloc controls for Standard and High Quality scanner presets.
- Native `VNDocumentCameraViewController.isSupported` check.
- Native UIKit presentation of Apple's document scanner.
- One-page and multi-page scan delegate handling.
- User cancellation without creating a final PDF.
- Native-only handling of `VNDocumentCameraScan` page images.
- Sequential scanned-page processing with scoped release behavior.
- `UIGraphicsPDFRenderer` generation of a separate image-based PDF.
- Native Photos picker input for manually selected images.
- PDFKit reopen validation before reporting success.
- Output path, page count, file size, duration, progress, cancellation, and
  typed errors through Pigeon.
- Diagnostic logging with the stable `PDF Event` key.

No custom camera UI, custom edge detector, file manager, cloud integration,
advanced scanner filters, arbitrary file importer, or searchable-PDF text layer
is implemented in POC 7.

The Pick images action is limited to images chosen through Apple's Photos
picker from the scan panel. It creates the same kind of image-based PDF output
as scanner capture, but it does not perform document-edge correction.

## Quality Presets

- Standard: target long edge 1600 px, JPEG quality 0.70.
- High Quality: target long edge 2400 px, JPEG quality 0.90.

Both presets produce image-based PDF pages. They do not embed selectable or
searchable text. Run POC 4 OCR separately after the generated PDF opens if text
recognition needs to be evaluated.

## Automated Validation

Record command results here when validation is run:

- `dart run pigeon --input pigeons/pdf_poc_api.dart`: passed after rerun with
  approval because the Flutter/Dart SDK needed to write cache files outside the
  workspace sandbox.
- `dart format .`: passed.
- `flutter analyze`: passed.
- `flutter test`: passed after rerun with approval because the Flutter SDK
  needed to write cache files outside the workspace sandbox.
- `flutter build ios --simulator --debug`: passed.

## Simulator Validation

`VNDocumentCameraViewController` is expected to be unsupported in the simulator.
The scanner action should return a typed `scanner_unavailable` error and should
not create a final output PDF.

Record actual simulator details:

- Simulator model:
- iOS version:
- Result:
- Output file created: no

## Physical Device Validation

Physical-device scanner validation is mandatory for POC 7 completion.

Record actual device details:

- Device:
- iOS version:
- App build:

### Cancellation

- Action:
- Result:
- Final output file created:

### One-Page Scan

- Quality preset:
- Page count:
- Output path:
- Output size:
- Duration:
- Page orientation/order:
- Opens in PDFKit:
- Opens in Apple Preview:

### Five-Page Scan

- Quality preset:
- Page count:
- Output path:
- Output size:
- Duration:
- Page orientation/order:
- Opens in PDFKit:
- Opens in Apple Preview:

### Mixed Orientation / Angled Page

- Quality preset:
- Page count:
- Orientation visually correct:
- Scanner correction visually acceptable:
- Notes:

### Standard vs High Quality

- Standard output size:
- High Quality output size:
- Legibility comparison:
- Expected size difference observed:

### Pick Images

- Device/simulator:
- iOS version:
- Selected image count:
- Quality preset:
- Output path:
- Output size:
- Duration:
- Page order:
- Cancel behavior:
- Opens in PDFKit:
- Opens in Apple Preview:

### OCR Follow-Up

- Generated scan PDF:
- POC 4 OCR current-page result:
- POC 4 OCR all-page result:
- Notes:

## Known Limitations

- The Apple document scanner requires a supported physical iPhone or iPad.
- The generated PDF is image-based and has no embedded text layer.
- Cancellation during PDF writing is cooperative between processed pages.
- Output quality depends on device camera, lighting, document condition, and
  VisionKit scanner behavior.
