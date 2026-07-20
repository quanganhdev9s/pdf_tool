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

- Confirm absence of selectable text before OCR
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

## Test dimensions

### Viewer

| Test | Expected result |
|---|---|
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
| Search scan-only PDF | No searchable text state |
| Next/previous result | Correct active result |
| Select multi-line text | Full selection available |
| Copy selection | Clipboard matches selection |
| Copy with no selection | Typed unavailable result |

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
| Change font size | Appearance updates |
| Save/reopen | Persists |
| Empty text | Validation behavior documented |
| Bounds outside page | Rejected or clamped |
| Rotated page | Correct position |

### Ink and signature

| Test | Expected result |
|---|---|
| Draw after zoom | No shift |
| Draw after scroll | No shift |
| Draw on rotated page | Correct page coordinate |
| Save/reopen | Persists |
| Flatten signature | Not editable afterward |

### Page operations

| Test | Expected result |
|---|---|
| Rotate | Correct after reopen |
| Delete | Page count decreases |
| Duplicate | Content duplicated |
| Reorder | Correct order |
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
- Input file
- Steps
- Expected result
- Actual result
- Screenshots or logs when useful
- Pass, fail, or partial
- Known limitation
