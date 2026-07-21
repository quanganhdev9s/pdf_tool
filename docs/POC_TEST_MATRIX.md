# POC Test Matrix

## Required test assets

Place representative PDFs in `assets/poc/`.

Suggested filenames:

```text
assets/poc/
├── text_document.pdf
├── scanned_vi_en.pdf
├── mixed_rotation.pdf
├── existing_crop_box.pdf
├── existing_annotations.pdf
├── forms_and_links.pdf
├── image_heavy.pdf
├── large_document.pdf
└── password_protected.pdf
```

Do not commit confidential documents.

Use synthetic or public test documents.

## Asset descriptions

### `text_document.pdf`

Purpose:

- Search
- Selection
- Copy
- Highlight
- Underline
- Free-text annotation

Recommended content:

- At least 5 pages
- English and Vietnamese
- Multiple paragraphs
- Multi-line text selection
- Multiple fonts if possible

### `scanned_vi_en.pdf`

Purpose:

- Confirm absence of an embedded PDF text layer before OCR
- Record whether PDFKit/system Live Text still allows selection and copying on
  the tested OS and device
- Vision OCR
- Vietnamese and English recognition
- Bounding-box mapping

Recommended content:

- At least 5 scanned pages
- Clear page
- Slightly skewed page
- Low-contrast page
- Mixed Vietnamese and English

### `mixed_rotation.pdf`

Purpose:

- Coordinate conversion
- Ink
- Signature
- Crop
- Page operations

Include:

- Portrait page
- Landscape page
- Rotated page metadata
- Different page sizes

### `existing_crop_box.pdf`

Purpose:

- Existing crop-box behavior
- Coordinate mapping
- New crop operation

### `existing_annotations.pdf`

Purpose:

- Preservation of annotations not created by the POC
- Save/reopen compatibility
- Page operations with existing annotations

Include when possible:

- Highlight
- Underline
- Note
- Ink
- Free text

### `forms_and_links.pdf`

Purpose:

- Detect data loss during compression
- Confirm forms and links before and after export

### `image_heavy.pdf`

Purpose:

- Compression
- Memory
- OCR rasterization performance

### `large_document.pdf`

Purpose:

- Viewer memory
- Search responsiveness
- Repeated page navigation
- OCR cancellation

Recommended size:

- 100 to 300 pages

### `password_protected.pdf`

Purpose:

- Typed password error
- No crash
- Future password-flow decision

Test password:

- `poc123`

## Test dimensions

### Viewer

| Test | Expected result |
|---|---|
| Picker Cubit and viewer Bloc shell | Picker opens event-driven Bloc viewer controls |
| Open valid PDF | PDF renders |
| Open invalid path | Typed error |
| Open invalid data | Typed error |
| Open protected PDF | Password-related typed error |
| Reopen repeatedly | No crash |
| Dispose while open | Observers and document released |
| Navigate 100 pages | Responsive |

### Search and selection

| Test | Expected result |
|---|---|
| Search existing word | Result count > 0 |
| Search missing word | Zero results, no error |
| Search scan-only PDF | No embedded PDF text layer state, unless the file unexpectedly contains embedded text |
| Select text in scan-only PDF | Record actual behavior by OS and device; Live Text may allow selection on supported Apple platforms |
| Copy text in scan-only PDF | Record actual behavior by OS and device; successful copy may come from Live Text, not an embedded PDF text layer |
| Next/previous result | Correct active result |
| Select multi-line text | Full selection available |
| Copy selection | Clipboard matches selection |
| Copy with no selection | Typed unavailable result |

Do not use “can copy text” as the only detector for an embedded PDF text layer.
Search results and PDF page string inspection indicate embedded PDF text; Live
Text selection/copy is a system-recognized interaction layer and is not saved
back into the PDF.

### Highlight and underline

| Test | Expected result |
|---|---|
| Single-line highlight | Correct position |
| Multi-line highlight | All lines marked |
| Cross-page selection | Supported or documented |
| Save and reopen | Annotation persists |
| Open in Preview | Annotation visible |
| Rotated page | Correct position |

### Free text

| Test | Expected result |
|---|---|
| Add text box | Visible |
| Select area and drag on one page | Flutter text field opens above keyboard |
| Add text after selecting area | Annotation appears inside selected rectangle |
| Cancel selected area composer | No annotation is added |
| Filter simulator console by `PDF Event` | Free-text area flow emits Flutter and native events |
| Change font size | Appearance updates |
| Save/reopen | Persists |
| Empty text | Validation behavior documented |
| Bounds outside page | Rejected or clamped |
| Rotated page | Correct position |

### Ink

| Test | Expected result |
|---|---|
| Toggle Read mode | PDFView scroll, zoom, text selection, and annotation tap selection are available |
| Toggle Ink mode | PencilKit overlay accepts drawing and PDF text selection toolbar is suppressed |
| Draw with touch | Visible draft ink appears on the overlay |
| Draw with Apple Pencil on device | Visible draft ink appears on the overlay |
| Clear current ink | Draft strokes are removed without changing committed PDF annotations |
| Commit ink | Editable PDF ink annotation is added to the correct page |
| Tap ink annotation in Read mode | Ink annotation becomes the selected native annotation for delete |
| Delete selected ink annotation | Selected ink annotation is removed and document becomes dirty |
| Draw after zoom | No visible shift after commit/save/reopen |
| Draw after scroll | No visible shift after commit/save/reopen |
| Draw near page edges | Strokes stay on the intended page or invalid off-page points are ignored |
| Draw on page 2 or later | Ink remains associated with that page |
| Draw on rotated page | Correct page coordinate |
| Draw on existing crop-box page | Bounds use the page crop box correctly |
| Save/reopen | Committed ink persists |
| Open in Preview | Ink annotation is visible and remains an annotation when Preview supports it |

Simulator validation can cover touch drawing, commit, save/reopen, and delete.
Apple Pencil input must be verified on a physical supported device.

### Signature

| Test | Expected result |
|---|---|
| Open Electronic signature panel | Controls are labeled as electronic signature, not digital signature |
| Capture signature | Native PencilKit signature capture overlay opens |
| Clear capture | Current capture strokes are removed |
| Confirm empty capture | Typed `no_signature_input` error |
| Confirm drawn capture | Reusable session-local signature representation is stored |
| Place signature | Signature preview appears on the current page |
| Move preview | Preview moves before commit |
| Resize preview by pinch | Preview resizes before commit |
| Resize preview by toolbar buttons | Preview resizes before commit on simulator-friendly controls |
| Commit placement | Editable PDF annotation is added on the intended page |
| Save/reopen | Editable signature representation persists |
| Tap signature annotation | Signature annotation becomes selected for deletion |
| Delete selected signature | Selected electronic signature annotation is removed |
| Export flattened copy | Separate flattened PDF is written |
| Inspect flattened copy | Signature is visible and no longer exposed as an editable annotation |

Do not record POC 2 as certificate-based digital signing. It is a handwritten
electronic signature annotation plus a flattened export experiment.

### Page operations

| Test | Expected result |
|---|---|
| Rotate | Correct after reopen |
| Delete | Page count decreases |
| Duplicate | Content duplicated |
| Reorder screen | Native page previews appear |
| Drag page preview and apply | Correct order after reopen |
| Crop | Correct visible region |
| Operations with annotations | Annotations preserved |

### OCR

| Test | Expected result |
|---|---|
| Clear English scan | High-quality result |
| Clear Vietnamese scan | Diacritics evaluated |
| Skewed page | Result documented |
| Low contrast | Result documented |
| Cancel | Operation stops or limitation documented |
| Bounding box | Overlay aligns visibly |
| Large document | UI remains responsive |

Keep Vision OCR testing even on devices where Live Text works. Vision OCR is the
controlled POC path for confidence, bounding boxes, progress, cancellation,
caching, and exportable OCR results.

### Compression

| Test | Expected result |
|---|---|
| Preserve mode on text PDF | Text remains selectable |
| Preserve mode on annotations | Editability checked |
| Rasterized mode | Size reduction measured |
| Rasterized mode text | Expected loss documented |
| Forms and links | Preservation measured |
| Large image PDF | No main-thread freeze |

## Result recording

For each POC, create or update:

```text
docs/results/POC_<number>_RESULTS.md
```

Record:

- Device or simulator
- iOS version
- Hardware model and whether Live Text is available
- Input file
- Steps
- Expected result
- Actual result
- For search, selection, and copy: record embedded PDF text behavior separately
  from system-recognized Live Text behavior
- Screenshots or logs when useful
- Pass, fail, or partial
- Known limitation
