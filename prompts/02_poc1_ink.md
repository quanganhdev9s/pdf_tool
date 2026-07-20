Implement POC 1 — PencilKit Ink Annotation.

First create and maintain an ExecPlan according to `.agent/PLANS.md`.

Read:

- `AGENTS.md`
- `docs/POC_SCOPE.md`
- `docs/POC_ARCHITECTURE.md`
- POC 1 in `docs/POC_ROADMAP.md`
- `docs/POC_TEST_MATRIX.md`
- `docs/PIGEON_API.md`
- The completed POC 0 result report

Scope:

- Add a `PKCanvasView` overlay.
- Add explicit read and ink modes.
- Support touch and Apple Pencil.
- Convert captured strokes into PDF page coordinates.
- Prefer editable PDF ink annotations.
- Save and reopen.
- Select and delete an ink annotation.
- Test zoom, scroll, rotation, crop box, and multiple pages.

Do not implement signature, OCR, compression, or page operations.

Do not rasterize ink by default.

Definition of Done is the POC 1 section in `docs/POC_ROADMAP.md`.
