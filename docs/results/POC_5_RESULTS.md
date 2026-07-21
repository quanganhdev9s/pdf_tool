# POC 5 Results

## Scope

POC 5 implements PDF compression comparison only:

- Preservation-oriented compression through a separate PDFKit output copy.
- Rasterized maximum compression through page rendering, JPEG compression, and
  PDF reconstruction.
- Configurable rasterized DPI and JPEG quality from the viewer UI.
- Progress callbacks, cancellation, output path, input/output bytes,
  compression ratio, duration, behavior flags, warning text, and visual-quality
  notes.
- Diagnostic logging with the stable `PDF Event` key.

No file manager, cloud export, split/merge, scanner, image-to-PDF, text-to-PDF,
production preset system, or background task integration is implemented in POC
5.

## Architecture

- Flutter owns compression controls, warning display, progress, cancellation,
  and metric display through `PdfViewerBloc`.
- Pigeon transfers `PdfCompressionRequest`, `PdfCompressionResult`, compression
  progress, and compression completion messages.
- Swift owns `PDFDocument`, output path generation, PDFKit write, page
  rasterization, JPEG compression, PDF reconstruction, metrics, and
  cancellation.
- `PdfCompressionManager` schedules preservation writes and rasterized output
  through a native manager. Rasterized page rendering is processed page by page
  so progress/cancel can be observed between pages.

## Mode Contracts

### Preservation-Oriented

- Writes a separate PDFKit output copy.
- Does not intentionally rasterize every page.
- Is expected to preserve PDF structure, selectable text, links, forms, and
  editable annotations where PDFKit supports them.
- May produce little or no size reduction.
- Requires manual validation in the POC matrix before any production claim.

### Rasterized Maximum Compression

- Renders each page at the selected DPI.
- JPEG-compresses each rendered page at the selected quality.
- Rebuilds a PDF containing page images.
- May reduce file size for image-heavy PDFs.
- May destroy selectable text, links, forms, vector quality, and editable
  annotations.

## Metrics Recorded

Each completed result reports:

- Input bytes.
- Output bytes.
- Compression ratio.
- Duration in milliseconds.
- Text selectability expectation.
- Annotation editability expectation.
- Link behavior expectation.
- Form behavior expectation.
- Visual-quality notes.
- Clear warning text for destructive rasterized output.

## Manual Result Table

Fill this table during simulator/device testing.

| File | Mode | Settings | Input bytes | Output bytes | Ratio | Duration | Text selectable | Annotations editable | Links functional | Forms functional | Visual notes |
|---|---|---|---:|---:|---:|---:|---|---|---|---|---|
| `image_heavy.pdf` | Preserve | n/a | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| `image_heavy.pdf` | Rasterized | 150 DPI / q TBD | TBD | TBD | TBD | TBD | No expected | No expected | No expected | No expected | TBD |
| `image_heavy.pdf` | Rasterized | 120 DPI / q TBD | TBD | TBD | TBD | TBD | No expected | No expected | No expected | No expected | TBD |
| `image_heavy.pdf` | Rasterized | 96 DPI / q TBD | TBD | TBD | TBD | TBD | No expected | No expected | No expected | No expected | TBD |
| `forms_and_links.pdf` | Preserve | n/a | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| `forms_and_links.pdf` | Rasterized | selected | TBD | TBD | TBD | TBD | No expected | No expected | No expected | No expected | TBD |

## Known Limitations

- Preservation mode uses PDFKit write APIs; Apple frameworks expose limited
  knobs for lossless PDF compression.
- Rasterized mode uses temporary JPEG files and rebuilds a page-image PDF. It is
  intentionally destructive.
- Cancellation is cooperative. The current PDFKit write or page render may
  finish before cancellation is observed.
- Peak memory is not measured automatically in the UI; record observed memory
  behavior manually when practical.
- Behavior flags are implementation expectations and must be verified manually
  on the produced output PDFs.

## Manual Validation Checklist

- Open `image_heavy.pdf`.
- Run preservation mode and confirm the output PDF opens.
- Run rasterized mode at 150, 120, and 96 DPI where practical.
- Compare output size and visual quality across DPI/JPEG settings.
- Open `forms_and_links.pdf`.
- Run preservation mode and manually check text selection, links, forms, and
  annotation editability.
- Run rasterized mode and confirm the destructive warning matches observed loss.
- Start a rasterized run and cancel it; record whether it stops between pages or
  after the in-flight page finishes.
- Confirm source PDFs under `assets/poc/` remain unchanged.

## Validation

- `dart run pigeon --input pigeons/pdf_poc_api.dart`: passed after rerun with
  approval because the Flutter/Dart SDK needed to write cache files outside the
  workspace sandbox.
- `dart format` on edited Flutter/Pigeon files: passed.
- `flutter analyze`: passed.
- `flutter build ios --simulator --debug`: passed after rerun because the first
  attempt overlapped another Flutter command and could not update the iOS
  ephemeral package metadata.
- `flutter test`: passed after rerun with approval because the Flutter SDK
  needed to write engine cache files outside the workspace sandbox.

Manual simulator/device verification remains required for size/quality metrics,
forms, links, annotation editability, cancellation timing, and produced-output
interoperability.
