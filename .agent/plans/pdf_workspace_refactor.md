# ExecPlan: PdfWorkspaceView Refactor

## Objective

Reduce `PdfWorkspaceView.swift` responsibility and file size without changing
POC behavior or adding features.

## Scope

In scope:

- Extract reusable UIKit/PDFKit helper views and data holders.
- Extract native search state and navigation into a manager.
- Extract free-text area selection state, overlay, and coordinate conversion
  into a manager.
- Extract PencilKit ink mode state, stroke conversion, and ink annotation
  selection into a manager.
- Extract electronic-signature capture, placement, path conversion, and
  annotation selection into a manager.
- Extract electronic-signature capture and placement view classes.
- Extract flattened PDF export logic.
- Keep the existing Pigeon API, Flutter Bloc flow, and native behavior intact.
- Update documentation to describe the split.

Out of scope:

- New PDF features.
- OCR, crop, page operations, compression workflow, file manager, or backlog
  features.
- Behavior changes to existing POC 0, POC 1, or POC 2 controls.

## Steps

1. Completed: add focused Swift files for support views, search management,
   free-text area selection, ink management, signature management, signature
   views, and flattened export.
2. Completed: replace inline helper/view/export code in `PdfWorkspaceView.swift`.
3. Completed: register new Swift files in the Xcode project.
4. Completed: run format/analyze/test/iOS build validation.

## Validation

- `dart format .`: passed.
- `flutter analyze`: passed.
- `flutter test`: passed after rerun with approval because the Flutter SDK
  needed to write engine cache files outside the workspace sandbox.
- `flutter build ios --simulator --debug`: passed.
