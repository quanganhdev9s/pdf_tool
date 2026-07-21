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

### Definition of Done

- Both modes produce openable PDFs
- Data-loss differences are documented
- Rasterized mode displays a clear warning
- Large files do not cause an avoidable main-thread freeze
- Results are recorded for `image_heavy.pdf` and `forms_and_links.pdf`

---

## Completion review

After POC 5, produce a decision report:

- What is production-viable
- What needs more native engineering
- What should be dropped
- What requires a commercial SDK
- Recommended production architecture
