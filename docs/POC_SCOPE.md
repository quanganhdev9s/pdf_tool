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

## Required exports

The POC must support:

- Editable working PDF
- Flattened PDF copy
- OCR text result
- Compression output

Keep each output separate from the original input asset.

## Deferred features

Do not implement during this POC:

- File manager
- Folder management
- Recent files
- Favorites
- File sorting and search
- Split PDF
- Merge PDF
- Image-to-PDF
- Text-to-PDF
- PDF-to-image export
- Watermark
- Page numbering
- Scanner UI
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
9. Editable and flattened output variants.
10. No use of a commercial PDF SDK.
