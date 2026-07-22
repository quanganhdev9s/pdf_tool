# POC Roadmap

Implement one POC at a time.

Each POC must be reviewed and validated before proceeding.

---

## POC 0 — Native Viewer and Text Interaction

### Goal

Validate the Flutter–UIKit boundary, native PDF lifecycle, selectable-text behavior, and basic editable annotations.

### Deliverables

#### Document setup

- Add at least one text PDF under `assets/poc/`
- Copy the asset to a writable path
- Open the writable copy
- Preserve the source asset

#### Viewer

- Manage the simple PDF picker with Cubit
- Manage the PDF viewer with Bloc events and state
- Embed `PDFView` using `UiKitView`
- Zoom
- Scroll
- Previous page
- Next page
- Jump to page
- Current page callback
- Page count callback
- Safe close and reopen

#### Search

- Search the full document
- Return result count
- Navigate next result
- Navigate previous result
- Scroll to active result
- Visually indicate active result
- Handle documents without an embedded PDF text layer
- Do not use successful selection or copy as the only signal that an embedded
  PDF text layer exists

#### Selection and copy

- Enable native text selection
- Return selected text to Flutter
- Copy selected text to iOS clipboard
- Return a typed unavailable state when no text is selected
- Record whether selection and copy come from embedded PDF text or
  system-recognized Live Text when testing scan-only documents

#### Markup annotations

- Highlight current selection
- Underline current selection
- Support multi-line selection
- Support multi-page selection when PDFKit provides it
- Save and reopen annotations

#### Free-text annotation

- Add a text box on the current page
- Set:
  - Text
  - Bounds
  - Font size
  - Text color
- Save and reopen
- Document limitations of selection, move, and resize behavior in PDFKit

For POC 0, free-text placement uses either fixed bounds supplied by Flutter or a
native drag rectangle converted to PDF page coordinates. The user-selected
rectangle then opens a Flutter text field above the keyboard before the
free-text annotation is created. Moving, resizing, and selecting existing
free-text annotations are deferred unless PDFKit provides acceptable behavior
without custom editing controls.

### Out of scope

- PencilKit
- Signature
- Crop
- Page reordering
- OCR
- Compression
- File manager

### Definition of Done

- Viewer opens a writable asset copy
- Zoom and scroll work
- Page callbacks are correct
- Search works on a text PDF
- Search on a scan-only PDF records whether PDFKit finds an embedded text layer
  or returns a meaningful no-text-layer limitation
- Selection and copy behavior on scan-only PDFs is recorded by OS and device,
  because supported Apple platforms may expose Live Text even when PDF search
  has no embedded text layer
- Text can be selected and copied
- Highlight persists after reopen
- Underline persists after reopen
- Free-text annotation persists after reopen
- Annotations are visible in Apple Preview when tested manually
- Repeated open/close does not crash
- Typed errors are returned
- `dart format .` passes
- `flutter analyze` passes
- Relevant tests pass
- Known limitations are documented

---

## POC 1 — PencilKit Ink Annotation

### Goal

Validate handwriting input and coordinate conversion.

### Deliverables

- Overlay `PKCanvasView`
- Switch between reading and drawing modes
- Support touch and Apple Pencil
- Convert strokes to PDF page coordinates
- Create editable ink annotation when practical
- Save and reopen
- Select and delete an ink annotation
- Test rotated and cropped pages

### Required test cases

- Zoom before drawing
- Scroll before drawing
- Draw near page edges
- Draw on page 2 or later
- Draw on a rotated page
- Draw on a page with an existing crop box
- Close and reopen
- Open output in Apple Preview

### Definition of Done

- Drawings do not visibly shift after save/reopen
- Drawings remain associated with the correct page
- Drawing mode does not permanently break PDFView navigation
- At least one strategy preserves editable ink
- Limitations are documented

---

## POC 2 — Electronic Signature

### Goal

Validate capture, placement, persistence, and flattening of a handwritten electronic signature.

### Deliverables

- Signature capture controller using PencilKit
- Clear and confirm actions
- Store signature in a reusable local representation
- Place on selected page
- Move and resize
- Save editable version
- Export flattened version

### Definition of Done

- Signature remains correctly positioned after reopen
- Editable output allows selecting the signature representation
- Flattened output no longer exposes it as an editable annotation
- The UI and documentation call it an electronic signature
- No certificate-signing claims are made

---

## POC 3 — Crop and Page Operations

### Goal

Validate PDFKit page mutation without corrupting the file or losing annotations.

### Deliverables

- Rotate page
- Delete page
- Reorder page
- Duplicate page
- Apply crop box
- Save to a new output
- Reopen and verify

### Required test cases

- Mixed portrait and landscape pages
- Existing annotations
- Existing crop box
- Different page sizes
- Page operations after annotation creation

### Definition of Done

- Page count and order are correct after reopen
- Annotations remain on intended pages
- Crop is visually correct
- Documentation states that crop does not securely delete hidden content
- Source asset remains unchanged

---

## POC 4 — OCR

### Goal

Validate Vision OCR quality, coordinates, performance, cancellation, and integration with the viewer.

### Required deliverables

- Render selected pages for OCR
- Run Vision recognition
- Specify Vietnamese and English where supported
- Return:
  - Page index
  - Text
  - Confidence
  - Normalized bounding box
- Progress callback
- Cancellation
- Select an OCR result and show its location on the PDF page

Implementation note:

- POC 4 exposes current-page and all-page OCR controls in the existing bottom
  toolbar, reports progress/results through Pigeon callbacks, and uses a native
  transient overlay for result location previews.
- OCR result text, confidence, and boxes remain in memory for this POC unless a
  later export/cache feature is explicitly implemented.

### Experimental deliverable

Attempt searchable-PDF output only after extraction works.

The result must be reported honestly as:

- Reliable
- Partially reliable
- Not viable with the current free approach

### Definition of Done

- OCR results are returned for scan-only PDF
- Vietnamese test is documented
- Bounding-box mapping is visibly verified
- UI remains responsive
- Cancellation works or its technical limitation is documented
- Searchable-PDF claim is not made without verification

---

## POC 5 — Compression

### Goal

Measure realistic compression quality and data-loss tradeoffs.

### Mode A — Preservation-oriented

Test available PDFKit/Core Graphics write and image optimization options without intentionally rasterizing every page.

### Mode B — Rasterized maximum compression

- Render each page at selected DPI
- Compress to JPEG where appropriate
- Rebuild a PDF

Suggested presets:

- 150 DPI
- 120 DPI
- 96 DPI

### Required metrics

- Input size
- Output size
- Compression percentage
- Processing duration
- Text selectable
- Annotation editable
- Links functional
- Forms functional
- Visual quality notes

Implementation note:

- POC 5 exposes preservation and rasterized compression controls in the existing
  bottom toolbar.
- Rasterized mode supports configurable DPI and JPEG quality and returns a
  warning because it may destroy selectable text, links, forms, vector quality,
  and editable annotations.
- Compression results are diagnostic measurements, not production quality
  guarantees.

### Definition of Done

- Both modes produce openable PDFs
- Data-loss differences are documented
- Rasterized mode displays a clear warning
- Large files do not cause an avoidable main-thread freeze
- Results are recorded for `image_heavy.pdf` and `forms_and_links.pdf`

---


## POC 6 — Split and Merge

### Goal

Validate reliable document splitting and merging with PDFKit while preserving
page-level structure and never overwriting source assets.

### Split deliverables

- Split the active writable PDF by one or more inclusive page ranges
- Produce one separate PDF for each requested range
- Validate ranges before creating final outputs
- Preserve the requested page order inside each output
- Preserve page rotation, crop boxes, and editable annotations where PDFKit
  supports round-trip preservation
- Return output paths and page counts

### Merge deliverables

- Merge two or more local PDF paths
- Preserve the supplied document order
- Preserve the page order inside each input document
- Produce one separate merged output
- Return the merged path, input-document count, page count, and duration
- Return typed errors for missing, invalid, or password-protected input files

### Operation safety

- Copy test assets to writable paths before processing
- Write to a temporary output and move it into place only after successful close
  and reopen verification
- Do not modify the active working PDF unless the user explicitly opens an output
- Report progress for large operations
- Support cooperative cancellation between documents or pages
- Remove incomplete temporary files after failure or cancellation

### Implementation note

- POC 6 uses a Split/Merge panel in the existing viewer toolbar.
- Split ranges are zero-based and inclusive.
- Merge input paths are read in the exact supplied text order and are not sorted
  by filename.
- Output paths are generated natively beside the active writable PDF after
  temporary output validation succeeds.

### Required test cases

- Split a text PDF into two valid ranges
- Split one selected page into a one-page PDF
- Reject an empty range list
- Reject reversed and out-of-range ranges
- Merge two PDFs with different page sizes and rotations
- Merge a PDF containing editable annotations
- Merge three inputs in a non-alphabetical order and verify that supplied order
- Cancel a large split or merge operation
- Reopen every output in PDFKit and Apple Preview

### Out of scope

- File-manager UI
- Cloud inputs
- Password-entry workflow
- PDF optimization during split or merge
- Automatic bookmark reconstruction across merged documents

### Definition of Done

- Split outputs contain exactly the requested pages in the requested order
- Merged output contains all input pages in the supplied document order
- Page counts, rotation, crop boxes, and annotation preservation are documented
- Every successful output reopens with PDFKit
- Source assets and source working copies remain unchanged
- Cancellation does not leave a corrupted final output
- Large operations do not cause an avoidable main-thread freeze
- Known PDFKit preservation limitations are recorded

---

## POC 7 — Document Scanner to PDF

### Goal

Validate a real multi-page document-scanning flow using Apple's VisionKit
scanner and generation of a valid image-based PDF without a paid SDK.

### Required deliverables

- Check `VNDocumentCameraViewController.isSupported`
- Present `VNDocumentCameraViewController` from native iOS UI
- Support one-page and multi-page scans
- Handle scanner cancellation
- Read pages from `VNDocumentCameraScan` in their returned order
- Generate a separate PDF using `UIGraphicsPDFRenderer`
- Support two presets:
  - Standard
  - High Quality
- Return output path, page count, file size, and duration
- Open the generated PDF with PDFKit
- Allow Flutter to navigate to the generated document

### Image and memory rules

- Treat scanner results as images; do not claim embedded PDF text
- Process pages sequentially where practical
- Use `autoreleasepool` or equivalent scoped release behavior for large scans
- Scale and JPEG-compress according to the selected quality preset
- Preserve the scanner-returned page orientation
- Do not transfer full-resolution page images through Pigeon
- Do not hold duplicate decoded copies of every page longer than necessary

### OCR integration boundary

POC 7 does not automatically create a searchable PDF. After the scan PDF is
created and opened, Flutter may invoke the existing POC 4 Vision OCR flow as a
separate operation. OCR text and bounding boxes remain subject to the POC 4
contract.

### Required device tests

- Unsupported environment or simulator returns a typed scanner-unavailable error
- User cancels before taking a page
- Scan one clear A4 page
- Scan five pages
- Scan mixed portrait and landscape pages
- Scan a page at an angle and verify scanner correction visually
- Generate Standard and High Quality PDFs and compare size and legibility
- Open the output in PDFKit and Apple Preview
- Run POC 4 OCR on the generated scan PDF
- Repeat scan/open/close without leaking or crashing

### Out of scope

- Custom camera UI
- Custom document-edge detection
- Generic Photos-to-PDF conversion
- Advanced filters comparable to commercial scanner applications
- Automatic searchable-PDF text-layer generation
- File-manager or cloud-storage integration

### Definition of Done

- The Apple scanner opens on a supported physical device
- One-page and multi-page scan completion both produce valid PDFs
- Cancellation creates no final PDF
- Output page count and order match the scanner result
- Output orientation is visually correct
- Standard and High Quality presets produce measurable quality/size differences
- Generated output reopens with PDFKit and Apple Preview
- Flutter receives a typed success result or typed cancellation/error
- No custom scanner or paid SDK is used
- The documentation clearly states that the output is image-based until OCR is
  performed separately

---

## Completion review

After POC 7, produce a decision report:

- What is production-viable
- What needs more native engineering
- What should be dropped
- What requires a commercial SDK
- Recommended production architecture
