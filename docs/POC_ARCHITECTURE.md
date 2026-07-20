# POC Architecture

## High-level design

```text
Flutter
├── POC document selector
├── Toolbar and controls
├── Search input
├── Text-box input
├── Page indicator
├── OCR and compression progress
└── UiKitView
    └── FlutterPlatformView
        └── PdfWorkspaceView: UIView
            ├── PDFView
            ├── PKCanvasView
            ├── Native overlays
            └── Native coordinators and services
```

## Flutter responsibilities

Flutter owns:

- Selecting a test asset
- Copy request initiation
- Tool selection
- Search query input
- Free-text input and style selection
- Page-navigation controls
- Displaying current page and page count
- Displaying typed errors
- Displaying operation progress
- Displaying OCR results
- Displaying compression metrics

Flutter must not own:

- `PDFDocument`
- `PDFPage`
- `PDFSelection`
- `PDFAnnotation`
- `PKDrawing` lifecycle associated with the open document
- PDF rendering cache
- PDF coordinate conversion

## Native iOS responsibilities

Swift owns:

- Native view lifecycle
- `PDFView`
- Open `PDFDocument`
- Current document session
- Search selections
- Current text selection
- Annotation creation
- PencilKit overlay
- Signature placement overlay
- Page operations
- OCR
- Compression
- Save, reopen, and export
- Clipboard copy

## Native view structure

Use a custom UIKit `UIView`.

Suggested structure:

```text
PdfWorkspaceView
├── PDFView
├── PKCanvasView
├── Selection/placement overlay
└── Loading/progress overlay when native UI is necessary
```

Use programmatic Auto Layout.

Do not add SwiftUI.

## Required Flutter and Xcode configuration

Flutter configuration:

- Declare POC PDF assets under `assets/poc/`.
- Use `UiKitView` for the native PDF workspace.
- Use generated Pigeon APIs for Dart-Swift communication.
- Do not use a direct `MethodChannel` for POC commands.
- Keep Android template files unused for this iOS-only POC.

Xcode configuration:

- Set the iOS deployment target to 15.0 for the app and test targets.
- Register the `FlutterPlatformViewFactory` from the iOS app delegate or
  equivalent Flutter plugin registration path.
- Keep the native PDF workspace UIKit-only and programmatic.
- Add PDFKit for POC 0; add PencilKit, Vision, Core Graphics, and
  UIGraphicsPDFRenderer only when the corresponding POC requires them.

## Suggested native files

```text
ios/Runner/PdfPoc/
├── PlatformView/
│   ├── PdfPlatformViewFactory.swift
│   └── PdfPlatformView.swift
├── Workspace/
│   ├── PdfWorkspaceView.swift
│   ├── PdfWorkspaceCoordinator.swift
│   └── PdfDocumentSession.swift
├── Search/
│   └── PdfSearchService.swift
├── Annotation/
│   ├── PdfMarkupService.swift
│   ├── PdfFreeTextService.swift
│   ├── PdfInkService.swift
│   └── PdfAnnotationSelectionController.swift
├── Signature/
│   ├── SignatureCaptureViewController.swift
│   └── PdfSignaturePlacementController.swift
├── PageOperations/
│   ├── PdfPageOperationService.swift
│   └── PdfCropController.swift
├── OCR/
│   └── PdfOcrService.swift
├── Compression/
│   └── PdfCompressionService.swift
└── Bridge/
    ├── PdfPocHostApiImpl.swift
    └── PdfPocEventApi.swift
```

Names may be adjusted to match the repository conventions.

## Document lifecycle

Use one explicit document session per platform view.

Suggested lifecycle:

```text
create platform view
→ copy asset to writable path
→ open PDFDocument
→ assign document to PDFView
→ observe page changes
→ perform interactions
→ save
→ optionally reopen for verification
→ detach observers
→ clear PDFView.document
→ release session
→ dispose platform view
```

POC 0 should use this lifecycle without PencilKit, signature, crop, OCR, or
compression services. The first native workspace can support one active document
session; if that shortcut is used, document the single-session limitation before
adding multi-view support.

The session must own:

- Input path
- Working path
- `PDFDocument`
- Search state
- Dirty state
- Current tool
- Native observers

## Asset-copy rules

Flutter assets are read-only.

The POC should create a deterministic or unique writable copy.

Recommended locations:

- Application Support for persistent POC working files
- Temporary directory for disposable export tests

Do not overwrite the original asset.

A reset action may delete and recreate the working copy.

## Coordinate systems

The implementation must document and test these coordinate spaces:

1. Flutter logical coordinates
2. Platform-view coordinates
3. `PDFView` coordinates
4. `PDFPage` coordinates
5. PencilKit canvas coordinates
6. Vision normalized image coordinates

Persist annotations in PDF page coordinates.

Coordinate contract for POC 0:

- Dart and Swift use zero-based page indexes.
- Free-text bounds are expressed in PDF page coordinates.
- Bounds are relative to the page `cropBox`.
- The PDF page origin is bottom-left unless a method explicitly documents a
  different origin.
- Rotation must be handled by PDFKit conversion APIs, not by manually applying
  display scale or scroll offsets.

Use PDFKit conversion APIs rather than manually guessing scale or offsets.

Coordinate tests must include:

- Zoomed page
- Scrolled page
- Rotated page
- Mixed page sizes
- Existing crop box
- Multi-page continuous mode

## Search architecture

Search should remain native.

Native search state should hold:

- Query
- All result selections
- Active result index
- Search generation identifier
- Cancellation state if asynchronous search is used

Flutter receives:

- Total results
- Active result index
- Optional result snippet
- Search status
- Typed errors

Do not pass `PDFSelection` objects to Flutter.

## Annotation architecture

Highlight and underline:

```text
current PDFSelection
→ split by page and line bounds
→ create PDFAnnotation objects
→ add to corresponding PDFPage
→ mark document dirty
```

Free text:

```text
Flutter request
→ validate page and bounds
→ create free-text PDFAnnotation
→ set contents and appearance properties
→ add to PDFPage
→ mark document dirty
```

For POC 0, free-text annotations are placed from explicit Flutter-provided
bounds. Native selection, moving, and resizing of free-text annotations are
limitations to document unless a later POC explicitly adds custom annotation
editing controls.

Ink:

```text
PencilKit input
→ convert drawing paths into PDF page coordinates
→ create PDF ink annotation when possible
→ save editable annotation
```

Do not rasterize ink by default.

## Event architecture

Use Pigeon Flutter APIs or event callbacks for:

- Document opened
- Page changed
- Dirty state changed
- Search state changed
- Selection changed
- Progress changed
- Operation completed
- Typed error

Avoid polling where event callbacks are available.

## Threading

Main thread:

- Create and dispose views
- Mutate `PDFView`
- Present view controllers
- Update annotation-selection overlays
- Update PencilKit UI

Background work where safe:

- Vision OCR
- Page rasterization for OCR
- Rasterized compression
- File-size calculation
- Non-UI result processing

Marshal results back to the main thread before updating UIKit.

Do not assume every PDFKit operation is thread-safe. Keep a single controlled document session and serialize document mutations.

## Saving strategy

Provide separate operations:

- Save current editable working copy
- Save editable copy as a new path
- Save flattened copy
- Reopen saved document for verification

Never overwrite the asset source.

Digital signing is outside scope.

## Error strategy

Every host operation must return a typed success or typed error.

Suggested stable codes:

- `asset_not_found`
- `asset_copy_failed`
- `invalid_pdf`
- `password_required`
- `open_failed`
- `page_out_of_range`
- `no_searchable_text`
- `no_text_selection`
- `annotation_creation_failed`
- `save_failed`
- `ocr_failed`
- `operation_cancelled`
- `compression_failed`
- `unsupported_operation`
- `internal_error`

## Disposal requirements

On disposal:

- Remove NotificationCenter observers
- Cancel pending search/OCR/compression work
- Detach delegates
- Remove PencilKit tool picker observers
- Clear temporary overlays
- Set `pdfView.document = nil`
- Release document session references
- Do not send callbacks to a disposed Flutter view
