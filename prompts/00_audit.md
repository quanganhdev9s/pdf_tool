Read:

- `AGENTS.md`
- `docs/POC_SCOPE.md`
- `docs/POC_ARCHITECTURE.md`
- `docs/POC_ROADMAP.md`
- `docs/POC_TEST_MATRIX.md`
- `docs/PIGEON_API.md`
- `docs/BACKLOG.md`

This is an iOS-only Flutter technical POC.

Do not modify source code yet.

Audit the documentation and current repository.

Report:

1. Whether the POC is technically achievable using Flutter, UIKit, PDFKit, PencilKit, Vision, Core Graphics, UIGraphicsPDFRenderer, UiKitView, and Pigeon.
2. Contradictions or missing decisions.
3. Recommended minimum iOS deployment target, with reasons.
4. Required Flutter and Xcode configuration.
5. Proposed native platform-view lifecycle.
6. Proposed ownership boundaries between Dart and Swift.
7. Minimum Pigeon API required for POC 0.
8. Main-thread and background-thread rules.
9. File lifecycle and writable-copy strategy.
10. PDF coordinate-system risks.
11. Search, selection, and annotation limitations in PDFKit.
12. Testing gaps.
13. A step-by-step implementation order for POC 0 only.

Do not:

- Add packages
- Add a commercial PDF SDK
- Implement deferred backlog features
- Introduce SwiftUI
- Claim free-text annotation edits existing PDF text
- Claim crop performs secure deletion
- Claim OCR extraction creates a searchable PDF automatically
- Claim a drawn signature is a digital certificate signature

Return:

- Documentation corrections
- Architecture recommendations
- POC 0 implementation plan

Do not write implementation code until the audit is complete.
