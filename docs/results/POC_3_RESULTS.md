# POC 3 Results

## Scope

POC 3 implements crop and page-operation validation only:

- Page Operations panel in the existing bottom toolbar and `PdfViewerBloc`
  flow.
- Rotate the current page by 90 degrees.
- Delete the current page while keeping at least one page in the document.
- Duplicate the current page after itself.
- Open a dedicated page reorder screen with PDF page previews.
- Drag and drop page previews to create a pending page order, then apply or
  cancel that order.
- Apply a crop-box inset to the current page.
- Save the mutated document to a separate page-operations output path and
  reopen that output through PDFKit for verification.
- Preserve existing and newly created PDF annotations through PDFKit page
  mutation APIs where PDFKit supports it.
- Diagnostic logging with the stable `PDF Event` key.

No OCR, compression, split, merge, file manager, secure redaction, or deferred
backlog feature is implemented in POC 3.

## Architecture

- Flutter owns viewer controls and state through `PdfViewerBloc`,
  `PdfViewerEvent`, and `PdfViewerState`.
- Pigeon adds page-operation commands for rotate, delete, duplicate, move,
  crop, crop-to-inset, pending reorder commit/cancel, and
  save-page-operations output.
- Swift owns `PDFDocument`, `PDFPage`, page insertion/removal, page rotation,
  crop-box mutation, save, reopen, and PDFKit validation.
- `PdfPageOperationsManager` contains page-index validation and the focused
  PDFKit page mutation logic.
- `PdfPageReorderView` is a native UIKit collection view embedded in a separate
  Flutter route. It renders PDFKit thumbnails locally and updates a pending
  serializable page-order list in `PdfPocRuntime`; page thumbnails are not sent
  through Pigeon.
- `PdfWorkspaceView` remains the orchestrator: it requires an open document,
  invokes the manager, clears stale search/selection state, marks dirty, and
  notifies Flutter about page-count/page-index changes.

## Crop Contract

- Crop uses `PDFPage.setBounds(_:for: .cropBox)`.
- Crop visually clips the page to the requested crop box.
- Crop does not securely delete hidden PDF content and must not be described as
  redaction or secure deletion.
- The POC crop button applies a fixed inset from the current crop box so Swift
  can calculate the result using PDFKit page geometry.

## Output Contract

- The original asset under `assets/poc/` remains unchanged.
- Normal Save still writes the current editable working copy.
- Save output writes a separate `*_page_ops.pdf` file.
- The page-operations output is reopened with PDFKit immediately after writing;
  failure to parse or open is reported as a typed error.

## Known Limitations

- The POC uses simple current-page buttons, not a thumbnail-based production
  page organizer.
- Page duplication uses PDFKit page copying; PDFKit behavior with uncommon page
  dictionaries, forms, or complex annotations still requires representative
  manual validation.
- Crop is visual clipping only. Hidden cropped content can remain in the PDF.
- Manual verification in Preview or another PDF viewer is still needed to
  inspect annotation preservation and visual crop behavior.

## Manual Validation Checklist

- Open `mixed_rotation.pdf` and rotate current pages; save output and reopen.
- Open a multi-page PDF, delete one page, save output, and confirm page count
  after reopen.
- Duplicate a page and confirm page count/order after reopen.
- Open the Reorder screen, drag page previews into a new order, apply, save
  output, and confirm order after reopen.
- Crop `existing_crop_box.pdf` and confirm the visible region changes after
  reopen.
- Create highlight/free-text/ink/signature annotations, then run page
  operations and confirm annotations remain on intended pages.
- Confirm `assets/poc/` source PDFs remain unchanged.

## Validation

- `dart run pigeon --input pigeons/pdf_poc_api.dart`: passed after rerun with
  approval because the Flutter/Dart SDK needed to write cache files outside the
  workspace sandbox.
- `dart format .`: passed.
- `flutter analyze`: passed.
- `flutter test`: passed after rerun with approval because the Flutter SDK
  needed to write engine cache files outside the workspace sandbox.
- `flutter build ios --simulator --debug`: passed.

Manual simulator/device verification remains required for visual page order,
crop appearance, annotation preservation, and third-party viewer
interoperability.
