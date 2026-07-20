Implement POC 4 — Vision OCR.

First create and maintain an ExecPlan according to `.agent/PLANS.md`.

Read:

- All core project documentation
- POC 4 in `docs/POC_ROADMAP.md`
- OCR cases in `docs/POC_TEST_MATRIX.md`
- Previous POC result reports

Required scope:

- Render selected PDF pages to images.
- Run Vision text recognition off the main thread where safe.
- Test Vietnamese and English.
- Return page index, text, confidence, and normalized bounding box.
- Report progress.
- Support cancellation.
- Map a selected OCR result back to a visible region on the PDF page.
- Keep UI responsive.

Experimental scope:

- Investigate searchable-PDF output only after extraction is reliable.
- Report the result honestly.
- Do not claim searchable PDF unless search and copy are verified after reopening the generated file.

Do not implement scanner UI, file manager, or cloud features.

Definition of Done is the POC 4 section in `docs/POC_ROADMAP.md`.
