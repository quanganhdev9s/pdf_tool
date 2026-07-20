# POC 0 Results

## Scope

POC 0 implements the native viewer and text interaction validation only:

- Writable-copy open/reset/close for PDFs from `assets/poc/`.
- Flutter-side picker state is managed by `PdfAssetPickerCubit`; PDF viewer
  state is managed by event-driven `PdfViewerBloc` using `flutter_bloc`.
  Widgets render controls and own text/focus controller lifecycles only.
- UIKit `PDFView` embedded through Flutter `UiKitView`.
- Page count/current-page callbacks and previous/next/jump navigation.
- PDFKit text search with next/previous result navigation.
- Native text selection and iOS clipboard copy.
- Highlight, underline, and strikeout annotations from the current PDF
  selection.
- Flutter selection action toolbar for Copy, Highlight, Underline, and
  Strikeout after native PDF text selection changes are reported.
- Free-text annotation insertion using fixed Flutter-provided PDF page bounds or
  a user-selected rectangle dragged on the native PDF view. After the drag
  completes, Flutter opens a text field above the keyboard and creates the
  annotation only after text is submitted.
- Save and reopen of the editable writable copy.

No PencilKit, signature, OCR, crop, page reordering, compression, file manager,
or deferred backlog feature is implemented.

## Coordinate Contract

- Page indexes are zero-based across Dart and Swift.
- Free-text bounds are PDF page coordinates relative to the page `cropBox`.
- The POC 0 free-text origin convention is bottom-left PDF page space.
- Display, zoom, scroll, and rotation conversion remains native and uses PDFKit
  objects instead of Dart-side geometry.

## Bloc Integration

- `PdfAssetPickerPage` uses `PdfAssetPickerCubit` for the simple asset-list
  screen.
- `PdfViewerPage` uses `PdfViewerBloc` for document/search/selection/free-text
  state, busy/status updates, event logging, generated Pigeon host calls, and
  generated Pigeon callback events.
- Widgets should not call generated Pigeon APIs directly for viewer operations.
  Dispatch a `PdfViewerEvent` instead.
- `flutter_bloc` is included to provide Bloc/Cubit state management for the
  Flutter shell. It is not a PDF SDK and does not change the native PDFKit
  ownership boundary.
- Flutter code is split by role: `lib/pdf_picker/` for picker Cubit and picker
  screen, and `lib/pdf_viewer/` for viewer Bloc/events/state, viewer screen,
  reusable controls, asset metadata, and diagnostic logging helpers.
- `lib/pdf_viewer/screens/pdf_bloc_app.dart` is only a compatibility barrel that
  exports the active picker/viewer screens.

## Event Logging

- POC 0 logs observable viewer, bridge, selection, annotation, and error events
  with the filter key `PDF Event`.
- Flutter logs use the prefix `PDF Event | flutter | ...`.
- Native Swift/PDFKit logs use the prefix `PDF Event | native | ...`.
- Because this POC is iOS-only, simulator runs should be filtered in the
  Android Studio Run/Debug console or the Xcode console rather than Android
  device logcat.
- For the selected-area free-text flow, the expected log sequence is:
  `begin_free_text_area_selection`, `free_text_area_drag_begin`,
  `free_text_area_rect_converted`, `callback_free_text_area_selected`,
  `add_free_text_selected_area_request`, and `add_free_text_success`.
- Logs are diagnostic only and must not be treated as persisted audit history.

## Known Limitations

- Free-text annotations are added at fixed bounds supplied by Flutter. POC 0 does
  not provide custom native controls for selecting, moving, or resizing existing
  free-text annotations.
- Free-text area selection creates a new annotation from a drag rectangle on one
  PDF page. The selected rectangle is clamped to the page crop box.
- A free-text annotation is not existing PDF text editing.
- Search depends on a PDF text layer. Scan-only PDFs return `no_searchable_text`;
  OCR is intentionally deferred.
- Multi-page and multi-line selection behavior depends on PDFKit selection
  output. The implementation creates per-line markup where PDFKit exposes line
  selections.
- The system edit menu is suppressed when selected PDF text is reported so the
  Flutter action toolbar remains the POC 0 control surface.
- Annotation interoperability with Apple Preview still requires manual testing
  on a generated writable copy.
- Password-protected PDFs return `password_required`; no password-entry flow is
  implemented in POC 0.

## Validation

- `dart format .`: passed.
- `flutter analyze`: passed.
- `flutter test`: passed.
- `flutter build ios --simulator --debug`: passed.

Manual Apple Preview verification and repeated open/close testing on an iOS
simulator or device remain to be performed interactively.
