# POC 6 Results

## Scope

POC 6 implements PDF split and merge only:

- Split the active writable PDF by one or more zero-based inclusive page ranges.
- Produce one separate output PDF per requested split range.
- Merge two or more local PDF paths in the exact supplied order.
- Return typed split and merge results containing output paths, page counts, and
  duration.
- Report split and merge progress.
- Support cooperative cancellation.
- Write temporary files first, reopen with PDFKit, and publish final output
  paths only after validation.
- Diagnostic logging with the stable `PDF Event` key.

No file manager, cloud input, scanner, password-entry workflow, PDF
optimization, bookmark reconstruction, or unrelated backlog feature is
implemented in POC 6.

## Architecture

- Flutter owns Split/Merge controls, local text inputs, running state, progress,
  cancellation actions, and output display through `PdfViewerBloc`.
- Pigeon transfers `PdfPageRange`, `PdfSplitRequest`, `PdfSplitResult`,
  `PdfMergeRequest`, `PdfMergeResult`, progress callbacks, and completion
  callbacks.
- Swift owns isolated PDFKit document loading, range validation, input
  validation, page copying, temporary/final file safety, output reopen checks,
  cleanup, and typed errors.
- `PdfSplitMergeManager` opens the active writable PDF from its path for split
  and opens every merge input path in the exact request order.
- `PdfWorkspaceView` remains the orchestrator and does not mutate the active
  viewer document for split or merge.

## Contracts

### Split

- Ranges are zero-based and inclusive.
- Valid examples: `0-1`, `2`, `0-0, 2-3`.
- Empty, reversed, overlapping, or out-of-range ranges are rejected before final
  output is published.
- One final output PDF is created for every requested range.
- Output paths are generated beside the active writable PDF.

### Merge

- Merge requires two or more local PDF paths.
- Paths are read in the exact entered order and are not sorted by filename.
- Missing, invalid, password-protected, or empty PDFs produce typed errors.
- One final merged output PDF is created beside the active writable PDF.

### Safety

- The original asset under `assets/poc/` remains unchanged.
- The active viewer document is not mutated by split or merge.
- Temporary outputs are removed after failure or cancellation where practical.
- Final outputs are moved into place only after PDFKit reopen validation.

## Manual Validation Table

Fill this table during simulator/device testing.

| Case | Input | Expected | Actual | Notes |
|---|---|---|---|---|
| Split valid range | `text_document.pdf`, `0-1` | One 2-page output | TBD | TBD |
| Split multiple ranges | `text_document.pdf`, `0-0, 2-3` | Two outputs | TBD | TBD |
| Split single page | current PDF, `0` | One 1-page output | TBD | TBD |
| Empty range | blank | `invalid_page_range` | TBD | No final output |
| Reversed range | `2-1` | `invalid_page_range` | TBD | No final output |
| Overlapping ranges | `0-2, 1-3` | `invalid_page_range` | TBD | No final output |
| Merge two sources | two local paths | Supplied order preserved | TBD | TBD |
| Merge custom order | three local paths | Text order preserved, not filename order | TBD | TBD |
| Mixed page sizes/rotation | `mixed_rotation.pdf` plus another source | Page boxes and rotation preserved where PDFKit supports it | TBD | TBD |
| Existing annotations | annotated source | Visibility/editability verified | TBD | PDFKit limitation possible |
| Cancel split/merge | larger input | Stops between pages or limitation recorded | TBD | Temp cleanup checked |

## Known Limitations

- PDFKit page copying is expected to preserve page size, rotation, crop boxes,
  and editable annotations for common PDFs, but complex forms, outlines, named
  destinations, document metadata, and uncommon page dictionaries need manual
  validation.
- Cancellation is cooperative between copied pages or output documents.
- Merge inputs must already be local paths visible to the app; POC 6 does not
  include a file picker or file manager.
- Apple Preview or another PDF viewer should be used to inspect produced output
  interoperability.

## Validation

- `dart run pigeon --input pigeons/pdf_poc_api.dart`: passed after rerun with
  approval because the Flutter/Dart SDK needed to write cache files outside the
  workspace sandbox.
- `dart format .`: passed.
- `flutter analyze`: passed.
- `flutter build ios --simulator --debug`: passed.
- `flutter test`: passed after rerun with approval because the Flutter SDK
  needed to write engine cache files outside the workspace sandbox.

Manual simulator/device verification remains required for output page order,
page size, rotation, crop-box preservation, annotation editability, cancellation
timing, cleanup, and Apple Preview interoperability.
