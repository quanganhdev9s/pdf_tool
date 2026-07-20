# Flutter iOS PDF POC — Codex Documentation Pack

Bộ tài liệu này dùng để giao Codex xây dựng technical POC cho ứng dụng PDF:

- Flutter application shell
- UIKit native PDF workspace
- PDFKit
- PencilKit
- Vision OCR
- Pigeon
- Không dùng SDK PDF thương mại
- Chỉ hỗ trợ iOS

## Cách sử dụng

1. Copy toàn bộ nội dung gói này vào root của Flutter repository.
2. Thêm các PDF test vào `assets/poc/`.
3. Khai báo các asset này trong `pubspec.yaml`.
4. Mở repository bằng Codex.
5. Chạy prompt `prompts/00_audit.md`.
6. Sau khi audit tài liệu xong, chạy `prompts/01_poc0_viewer_text.md`.
7. Chỉ chuyển sang POC tiếp theo khi POC hiện tại đạt Definition of Done.

## Thứ tự triển khai

1. POC 0 — Viewer và text interaction
2. POC 1 — PencilKit ink annotation
3. POC 2 — Electronic signature
4. POC 3 — Crop và page operations
5. POC 4 — OCR
6. POC 5 — Compression

Không yêu cầu Codex triển khai toàn bộ roadmap trong một task.
