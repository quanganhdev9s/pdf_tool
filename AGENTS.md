# Project Instructions

## Project identity

This repository contains an iOS-only Flutter technical proof of concept for PDF processing.

The purpose is to validate difficult and uncertain PDF capabilities using free Apple frameworks before building a production application.

This is not a production-ready application.

## Required technology stack

Use:

- Flutter for the application shell, controls, state, and diagnostic UI.
- Swift for native iOS PDF functionality.
- UIKit for the entire native PDF workspace.
- PDFKit for rendering, text selection, text search, annotations, saving, and page operations.
- PencilKit for handwriting and electronic-signature capture.
- Vision for OCR.
- UIGraphicsPDFRenderer and Core Graphics for PDF generation and rasterized compression.
- Flutter `UiKitView` and `FlutterPlatformView` for native view embedding.
- Pigeon for type-safe Dart–Swift communication.

## Native UI framework

Use UIKit for all native iOS PDF workspace implementation.

Required UIKit-based components include:

- `PDFView`
- `PDFThumbnailView` when needed
- `PKCanvasView`
- `PKToolPicker`
- Native annotation overlays
- Crop and signature controllers

Embed the native workspace using `FlutterPlatformView` and return a `UIView`.

Do not introduce:

- SwiftUI
- `UIHostingController`
- `UIViewRepresentable`
- Storyboards for the PDF POC

unless a task explicitly requires one and documents a concrete technical reason.

Prefer programmatic Auto Layout.

## Architecture boundaries

Flutter owns:

- Application shell
- POC controls
- Toolbar state
- Text input dialogs
- Diagnostic output
- Progress and error UI
- Choosing a test asset

Swift owns:

- `PDFView`
- `PDFDocument`
- `PDFPage`
- `PDFSelection`
- `PDFAnnotation`
- `PKCanvasView`
- PDF coordinate conversion
- Document save and reopen
- OCR processing
- Compression
- Native clipboard interaction

Keep PDFKit object ownership in Swift.

Do not expose PDFKit objects to Dart.

Pigeon messages may contain only serializable data such as:

- Strings
- Integers
- Doubles
- Booleans
- Lists
- Enums
- Serializable request and result models

Do not continuously transfer rendered PDF page bitmaps through Pigeon.

## Product semantics

Always preserve these distinctions:

- A free-text annotation is not editing existing PDF text.
- Highlight and underline are annotations.
- A drawn signature is an electronic signature, not a certificate-based digital signature.
- Changing a crop box is not secure content removal.
- A black rectangle is not secure redaction.
- OCR text extraction is not automatically a searchable PDF.
- Rasterized compression can destroy text selection, links, forms, vector quality, and editable annotations.
- Flattened annotations are no longer editable as annotations.

Do not claim unsupported capabilities.

## Prohibited dependencies

Do not add any commercial PDF SDK.

Do not add:

- Nutrient
- Apryse
- ComPDFKit
- Foxit PDF SDK
- Syncfusion PDF SDK
- Any trial SDK requiring a production license

Do not add a third-party dependency when the required capability is already available through Flutter or Apple frameworks without first documenting the reason.

## Test documents

Test PDFs must be loaded from `assets/poc/`.

Assets are read-only.

Before editing a PDF:

1. Read the asset through Flutter.
2. Copy it to a writable application directory.
3. Open the writable copy in PDFKit.
4. Preserve the original asset unchanged.

## Documentation to read

Before implementing any feature, read:

- `docs/POC_SCOPE.md`
- `docs/POC_ARCHITECTURE.md`
- `docs/POC_ROADMAP.md`
- `docs/POC_TEST_MATRIX.md`
- `docs/PIGEON_API.md`
- The relevant prompt under `prompts/`

Read `docs/BACKLOG.md` only to confirm that a feature is deferred.

## Scope control

Implement only the POC requested by the current task.

Do not implement later POCs early.

Do not implement deferred backlog features unless explicitly requested.

Prefer a small, observable, testable implementation over a broad incomplete implementation.

## Execution plans

For POC 1 through POC 5, or for any significant architecture change, create an ExecPlan under `.agent/plans/` according to `.agent/PLANS.md`.

Keep the plan updated while implementing.

## Error handling

Use typed errors across Pigeon.

Do not silently ignore errors.

Error results must contain:

- Stable error code
- Human-readable message
- Optional technical details suitable for debug builds

Do not expose sensitive file content in logs.

## Threading

UIKit, PDFView updates, and view lifecycle operations must run on the main thread.

Long-running operations should run off the main thread where safe, including:

- OCR
- Page rendering for OCR
- Rasterized compression
- Large save/export operations

Do not access UIKit objects from background threads.

Document any PDFKit thread-safety assumptions.

## Validation

Before completing a task, run all applicable checks:

```bash
dart format .
flutter analyze
flutter test
```

When Swift code changes, also run the relevant iOS build or tests when the environment allows it.

At completion, report:

- Files created
- Files modified
- Architecture decisions
- Known limitations
- Commands executed
- Validation results
- Validation that could not be executed

Do not claim a command passed unless it was actually executed.
