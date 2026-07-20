Implement POC 0 — Native Viewer and Text Interaction.

Read:

- `AGENTS.md`
- `docs/POC_SCOPE.md`
- `docs/POC_ARCHITECTURE.md`
- POC 0 in `docs/POC_ROADMAP.md`
- `docs/POC_TEST_MATRIX.md`
- `docs/PIGEON_API.md`

## Scope

### Document setup

- Use a PDF from `assets/poc/`.
- Copy it to a writable application directory.
- Never modify the bundle asset.
- Support resetting the writable copy.

### Native viewer

- Embed a native UIKit `PDFView` using `UiKitView`.
- Use `FlutterPlatformView`.
- Use programmatic UIKit layout.
- Do not use SwiftUI or Storyboards.
- Support zoom.
- Support scrolling.
- Support previous page.
- Support next page.
- Support jump to a zero-based page index.
- Report page count and current page index to Flutter.
- Dispose the native view and document safely.

### Text search

- Search the entire PDF using PDFKit.
- Return total result count.
- Navigate to next and previous results.
- Scroll to and visually indicate the active result.
- Clear search state.
- Return a meaningful state when the document has no embedded PDF text layer.
- Do not use successful selection or copy as the only way to detect an embedded
  PDF text layer.
- Keep the UI responsive on larger documents.

### Text selection and copy

- Allow native PDF text selection.
- Expose selected text to Flutter.
- Copy selected text using the iOS clipboard.
- Return a typed unavailable result when there is no selection.
- Treat embedded PDF text and system-recognized Live Text as different sources
  of selectable text.
- `scanned_vi_en.pdf` contains no embedded PDF text layer, but selection and
  copying may still work through PDFKit Live Text interaction on supported Apple
  platforms.
- Do not claim Live Text has been embedded or saved into the PDF.
- Do not implement OCR in POC 0.

### Highlight and underline

- Create highlight annotations from the current `PDFSelection`.
- Create underline annotations from the current `PDFSelection`.
- Support multi-line selection.
- Support multi-page selection if PDFKit provides it reliably.
- Persist annotations in PDF page coordinates.
- Save and reopen.
- Verify persistence.

### Free-text annotation

- Add a free-text PDF annotation.
- Accept:
  - Page index
  - Text
  - PDF page bounds
  - Font size
  - Text color
- Validate or clamp invalid bounds.
- Save and reopen.
- Document PDFKit limitations around selecting, moving, and resizing free-text annotations.

A free-text annotation is not existing PDF text editing.

### Save and reopen

- Save the editable working copy.
- Close and reopen the document.
- Verify highlight, underline, and free-text persistence.
- Keep the original asset unchanged.

### Typed errors

Support at least:

- `asset_not_found`
- `asset_copy_failed`
- `invalid_pdf`
- `password_required`
- `open_failed`
- `document_not_open`
- `page_out_of_range`
- `no_searchable_text`
- `no_text_selection`
- `invalid_annotation_bounds`
- `annotation_creation_failed`
- `save_failed`
- `internal_error`

## Constraints

- iOS only
- UIKit only
- PDFKit
- Pigeon
- No direct MethodChannel implementation
- No commercial PDF SDK
- No PencilKit yet
- No signature yet
- No OCR yet
- No crop yet
- No page reordering yet
- No file manager
- No unrelated features
- Do not pass PDF page bitmap streams to Dart
- Keep PDFKit objects in Swift

## Before editing

1. Inspect the repository.
2. Present a concise implementation plan.
3. List files to create or modify.
4. Propose exact Pigeon models and methods needed for POC 0.
5. Document coordinate conventions.
6. Identify iOS API availability constraints.

## Definition of Done

- A PDF asset opens from a writable copy.
- Zoom and scroll work.
- Page count and current page are visible in Flutter.
- Previous, next, and jump-to-page work.
- Search works on `text_document.pdf`.
- Search on `scanned_vi_en.pdf` records whether PDFKit finds embedded text or
  returns a meaningful no-text-layer state.
- Selection and copy behavior on `scanned_vi_en.pdf` is recorded by OS and
  device because supported Apple platforms may expose Live Text even when the PDF
  has no embedded text layer.
- Selected text can be copied.
- Highlight persists after close and reopen.
- Underline persists after close and reopen.
- Free-text annotation persists after close and reopen.
- Output annotations are visible in Apple Preview when manually tested.
- Repeated open and close does not crash.
- Typed errors work.
- `dart format .` passes.
- `flutter analyze` passes.
- Relevant tests pass.
- iOS build validation is executed when the environment supports it.
- Final report includes changed files, decisions, known limitations, and validation results.
