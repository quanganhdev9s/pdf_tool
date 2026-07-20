Implement POC 5 — PDF Compression.

First create and maintain an ExecPlan according to `.agent/PLANS.md`.

Read all relevant documentation and previous POC result reports.

Implement and compare:

1. Preservation-oriented compression.
2. Rasterized maximum compression.

For rasterized mode, support configurable DPI and JPEG quality.

Record:

- Input bytes
- Output bytes
- Compression ratio
- Duration
- Text selectability
- Annotation editability
- Link behavior
- Form behavior
- Visual-quality notes

Do not hide destructive tradeoffs.

Rasterized output must display or return a clear warning that it may destroy:

- Selectable text
- Links
- Forms
- Vector quality
- Editable annotations

Do not implement unrelated backlog features.

Definition of Done is the POC 5 section in `docs/POC_ROADMAP.md`.
