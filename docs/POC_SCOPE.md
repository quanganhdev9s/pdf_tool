# PDF Technical POC Scope

## Goal

Build an iOS-only Flutter technical proof of concept that validates the difficult parts of a free PDF implementation using Apple frameworks.

This POC answers whether the chosen architecture is technically viable.

It does not attempt to provide a polished end-user application.

## Platform

- Flutter
- iOS only
- UIKit native implementation
- No Android implementation
- No paid PDF SDK
- Minimum iOS deployment target must be selected and documented during the audit

The repository may contain Android files from the default Flutter template.
They are unused scaffolding for this technical POC and must not be implemented
or used to expand scope.

Recommended minimum iOS deployment target:

- iOS 15.0

Reasons:

- Provides a practical modern baseline for Flutter platform-view embedding.
- Supports the Apple frameworks required across the POC sequence.
- Gives a stronger floor for PencilKit behavior and Vision text recognition in
  later POCs.
- Keeps simulator and device validation realistic without increasing POC scope.

## Input documents

Do not implement a file manager.

Use PDF files stored under:

```text
assets/poc/
```

Before editing:

1. Load the asset bytes.
2. Write a working copy to a writable application directory.
3. Open the working copy with PDFKit.
4. Never modify the application-bundle asset.

## Required POC features

### POC 0 — Native viewer and text interaction

Validate:

- Open a writable PDF copy
- Native PDF rendering with `PDFView`
- Zoom and scrolling
- Previous and next page
- Jump to page
- Current page callback
- Page count callback
- Text search
- Next and previous search result
- Native text selection
- Copy selected text
- Highlight selected text
- Underline selected text
- Add free-text annotation
- Save editable annotations
- Close and reopen document
- Verify annotation persistence

A free-text annotation must never be described as editing existing PDF text.

Text interaction must distinguish these cases:

- Embedded PDF text layer: text stored in the PDF structure and searchable by
  PDFKit document search.
- System-recognized Live Text: text Apple platforms may recognize from rendered
  page images at interaction time.

The image-only file `scanned_vi_en.pdf` has no embedded PDF text layer. However,
on supported OS and device combinations, PDFKit may still expose Live Text
selection and copying. Do not treat successful selection or copy as proof that a
PDF has an embedded text layer. Do not claim Live Text has been embedded or saved
into the PDF.

### POC 1 — Ink annotation

Validate:

- Drawing through PencilKit
- Apple Pencil and touch input
- Conversion to editable PDF ink annotations when practical
- Correct coordinates under:
  - Zoom
  - Scroll
  - Page rotation
  - Existing crop box
- Save and reopen
- Select and delete an ink annotation

### POC 2 — Electronic signature

Validate:

- Capture a signature with PencilKit
- Store a reusable signature representation
- Place the signature on a page
- Move and resize
- Save as an editable PDF annotation
- Export a flattened copy

This is an electronic signature, not a cryptographic digital signature.

### POC 3 — Crop and page operations

Validate:

- Crop using PDF crop box
- Rotate pages
- Delete pages
- Reorder pages
- Duplicate pages
- Preserve annotations after operations
- Save and reopen without corruption

Cropping is not secure deletion.

### POC 4 — OCR

Required:

- Render selected PDF pages to images
- Run Vision text recognition
- Support Vietnamese and English tests
- Return recognized text
- Return normalized bounding boxes
- Return confidence
- Return page index
- Report progress
- Support cancellation
- Highlight an OCR result position in the viewer

Current POC 4 implementation keeps OCR as an in-memory diagnostic flow: Flutter
starts current-page or all-page OCR through `PdfViewerBloc`, Swift runs Vision
through `PdfOcrManager`, and tapping a result shows a transient viewer overlay.
The overlay is not a saved PDF annotation.

Keep Vision OCR in POC 4 even when Live Text works on a device. Vision OCR is
required because it provides controlled recognition requests, returned text,
confidence, bounding boxes, progress, cancellation, caching, and exportable
results. Live Text is a system interaction feature and must not be treated as an
OCR export pipeline or searchable-PDF generation step.

Experimental:

- Attempt searchable-PDF output
- Document whether the result is reliable
- Do not fabricate searchable-PDF support

### POC 5 — Compression

Compare:

1. Preservation-oriented compression
2. Rasterized maximum compression

Record:

- Input file size
- Output file size
- Compression ratio
- Whether text remains selectable
- Whether annotations remain editable
- Whether links still work
- Whether forms still work
- Visual quality
- Processing time
- Peak-memory observations when practical

Current POC 5 implementation keeps compression outputs separate from the input
asset and the editable working copy. Preservation mode writes a PDFKit copy;
rasterized mode rebuilds the PDF from JPEG-backed page images at configurable
DPI and JPEG quality. Rasterized output must be treated as destructive for text
selection, links, forms, vector quality, and editable annotations.


### POC 6 — Split and merge

Validate:

- Split the active writable PDF into separate output files by inclusive page ranges
- Validate empty, overlapping, reversed, and out-of-range page ranges
- Merge two or more local PDFs in an explicitly supplied order
- Preserve page order, page rotation, crop boxes, and editable annotations when PDFKit supports them
- Write outputs separately from every source asset and working copy
- Report progress for large operations
- Support cooperative cancellation
- Reopen every output with PDFKit before reporting success
- Avoid leaving a corrupted final file when an operation fails or is cancelled

Split and merge are document-structure operations. They do not require a file
manager in this POC. Test inputs come from writable copies of assets or outputs
created by earlier POCs.

Current POC 6 implementation exposes a Split/Merge toolbar panel. Split accepts
zero-based inclusive ranges such as `0-1, 2-3` for the active writable PDF.
Merge accepts two or more local PDF paths in the exact entered line order.
Swift creates separate outputs beside the active working copy and never mutates
the active viewer document during split or merge.

### POC 7 — Document Scanner to PDF

Validate:

- Check `VNDocumentCameraViewController.isSupported`
- Present the Apple document scanner on a physical iPhone or iPad
- Scan one page and multiple pages
- Handle user cancellation without creating an output file
- Receive corrected scan-page images from `VNDocumentCameraScan`
- Generate a separate image-based PDF with `UIGraphicsPDFRenderer`
- Support at least Standard and High Quality output presets
- Preserve page order and orientation
- Open the generated PDF with PDFKit and verify its page count
- Keep image processing and PDF generation responsive and memory-aware
- Return the output path to Flutter

POC 7 uses Apple's document-scanner UI. It must not implement a custom camera,
custom edge detector, or claim that the generated image-based PDF already has an
embedded searchable text layer. The existing POC 4 OCR flow may be run on the
created PDF as a separate follow-up operation.

Current POC 7 implementation exposes a Document Scanner toolbar panel in the
PDF viewer. Flutter sends only the selected Standard or High Quality preset.
Swift presents `VNDocumentCameraViewController`, keeps `VNDocumentCameraScan`
page images native, writes a separate image-based PDF, validates it with
PDFKit, opens the generated output in the viewer, and reports output path, page
count, file size, duration, progress, cancellation, or typed errors through
Pigeon.

The same panel also exposes an explicit Pick images action backed by Apple's
Photos picker. Picked image files stay native, are converted into a separate
image-based PDF with the same Standard/High Quality presets, and reopen in the
viewer after PDFKit validation. This is not a custom scanner, file manager,
cloud import, or searchable-PDF generation path.

## Required exports

The POC must support:

- Editable working PDF
- Flattened PDF copy
- OCR text result
- Compression output
- Split PDF outputs
- Merged PDF output
- Scanned image-based PDF output

Keep each output separate from the original input asset.

## Deferred features

Do not implement during this POC:

- File manager
- Folder management
- Recent files
- Favorites
- File sorting and search
- Image-to-PDF
- Text-to-PDF
- PDF-to-image export
- Watermark
- Page numbering
- iCloud
- Cloud storage
- Paywall
- Analytics
- Production design system
- Localization
- Android

These features belong in `docs/BACKLOG.md`.

## Explicit non-goals

Do not implement or simulate:

- Editing existing PDF content-stream text
- Secure object-level redaction
- Certificate-based PDF digital signatures
- Exact PDF-to-DOCX conversion
- Exact DOCX-to-PDF conversion
- Android support

## POC success criteria

The POC succeeds when it demonstrates:

1. Reliable UIKit PDF workspace embedding in Flutter.
2. Search and selection for text-based PDFs.
3. Editable highlight, underline, and free-text annotations.
4. Correct handwritten annotation coordinates.
5. Persistent electronic signatures.
6. Safe crop and page operations.
7. OCR text and bounding boxes from scanned pages.
8. Measured compression tradeoffs.
9. Correct split and merge outputs with preserved page order.
10. A multi-page document scan that opens as a valid PDF.
11. Editable and flattened output variants.
12. No use of a commercial PDF SDK.
