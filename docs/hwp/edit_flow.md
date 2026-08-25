Dưới đây là luồng edit hiện tại, chia theo tầng.

**1. Vào Edit Mode**
Flutter: `HwpReaderPage._beginEdit()`

Công dụng:
- Đóng keyboard nếu đang mở.
- Báo `HwpReaderCubit.beginEdit()`.
- Giữ `currentPageIndex` đang xem ở reader.
- Chuyển sang edit mode dạng multi-page, dùng cùng `ListView.builder` như reader.
- Không copy file, không render toàn bộ document.
- Dùng lại SVG cache hiện có; page nào chưa có SVG vẫn lazy render.

**2. Chạm vào content để đặt con trỏ**
Flutter: `_HwpPageSurface` → `GestureDetector.onTapUp`

Công dụng:
- Nhận tọa độ tap local trên page widget.
- Gọi `onTapPage`, tức `_placeCaret()`.

Flutter: `_placeCaret()`

Công dụng:
- Convert tọa độ Flutter widget sang tọa độ SVG/viewBox.
- Gọi native hit-test để biết tap vào section/paragraph/offset nào.
- Sau đó gọi `_cursorFor()` để lấy vị trí vẽ caret.
- Set `_caret`.
- Mở bàn phím bằng `_openTextInput()`.

Flutter service: `HwpDocumentService.hitTestPage()`

Công dụng:
- Gọi Pigeon API `hitTestHwpPage()` sang iOS native.

Native Swift: `HwpHostApiImpl.hitTestHwpPage()`

Công dụng:
- Bridge method từ Flutter sang `HwpRuntime`.

Native Swift: `HwpRuntime.hitTest()`

Công dụng:
- Validate page index.
- Lấy `rhwpHandle`.
- Gọi Rust FFI qua `RhwpEngineBridge.hitTest()`.

Native Swift FFI: `RhwpEngineBridge.hitTest()`

Công dụng:
- Convert kiểu dữ liệu Swift sang C ABI.
- Gọi symbol Rust `rhwp_bridge_hit_test`.

Rust bridge: `rhwp_bridge_hit_test()`

Công dụng:
- Lấy document theo handle.
- Gọi `document.hit_test_native(page, x, y)`.
- Trả JSON chứa `sectionIndex`, `paragraphIndex`, `charOffset`.

**3. Lấy vị trí caret**
Flutter: `_cursorFor()`

Công dụng:
- Gọi native lấy rect của caret theo `sectionIndex`, `paragraphIndex`, `charOffset`.
- Parse JSON thành `_DirectCaret`.

Flutter service: `HwpDocumentService.getCursorRect()`

Native Swift: `HwpHostApiImpl.getHwpCursorRect()` → `HwpRuntime.getCursorRect()` → `RhwpEngineBridge.getCursorRect()`

Rust bridge: `rhwp_bridge_get_cursor_rect()`

Công dụng:
- Gọi `document.get_cursor_rect_native(...)`.
- Trả JSON gồm page index, x, y, height để Flutter vẽ caret.

Flutter: `_CaretPainter`

Công dụng:
- Convert tọa độ caret trong SVG/viewBox sang tọa độ widget.
- Vẽ cursor trên page.

**4. Nhập text từ bàn phím**
Flutter: `TextInputClient.updateEditingValue()`

Công dụng:
- Nhận input từ iOS keyboard.
- Nếu text rỗng: coi là backspace → `_deleteBackward()`.
- Nếu có `\n`: đi qua `_insertTextWithParagraphBreaks()`.
- Nếu là text thường: gọi `_insertAtCaret()`.

Flutter: `_insertAtCaret()`

Công dụng:
- Log `insert_text_start`.
- Gọi service insert text.
- Nhận offset mới.
- Gọi `_refreshAfterDirectEdit()` để update caret/page.

Flutter service: `HwpDocumentService.insertText()`

Native Swift: `HwpHostApiImpl.insertHwpText()` → `HwpRuntime.insertText()` → `RhwpEngineBridge.insertText()`

Native Swift `HwpRuntime.insertText()` công dụng:
- Gọi Rust insert.
- Mark session `isDirty = true`.
- Cập nhật `pageCount` từ Rust sau khi edit.

Rust bridge: `rhwp_bridge_insert_text()`

Công dụng:
- Decode text UTF-8.
- Lưu snapshot trước khi edit để dùng cho Undo.
- Gọi `document.insert_text_native(section, paragraph, offset, text)`.
- Nếu edit thành công: đưa snapshot vào undo stack và xoá redo stack.
- Nếu edit lỗi: discard snapshot vừa tạo.

Rust core: `insert_text_native()`

Công dụng chính:
- Validate section/paragraph.
- Clear `raw_stream` để lần save sẽ serialize lại.
- Tính style chữ cần inherit tại vị trí caret.
- Insert text vào paragraph.
- Apply char shape cho text mới.
- Reflow paragraph: tính lại line segment/wrap.
- Recalculate vertical position.
- Recompose paragraph.
- Paginate lại document nếu cần.
- Stamp caret position.
- Trả JSON offset mới.

**5. Xoá text**
Flutter: `_deleteBackward()`

Công dụng:
- Nếu caret offset > 0: gọi native delete 1 ký tự trước caret.
- Nếu caret offset <= 0: gọi `_mergeParagraphAtCaret()` để gộp với paragraph trước.

Service/native/Rust bridge:
- `HwpDocumentService.deleteText()`
- `HwpHostApiImpl.deleteHwpText()`
- `HwpRuntime.deleteText()`
- `RhwpEngineBridge.deleteText()`
- `rhwp_bridge_delete_text()`
- Rust core `delete_text_native()`

Công dụng Rust:
- Lưu snapshot trước khi edit.
- Xóa text ở paragraph.
- Reflow/recompose/paginate lại.
- Cập nhật caret.
- Trả offset mới.

**6. Xuống dòng**
Flutter: `performAction(TextInputAction.newline)` hoặc input chứa `\n`

Đi qua:
- `_splitParagraphAtCaret()`
- `HwpDocumentService.splitParagraph()`
- `HwpHostApiImpl.splitHwpParagraph()`
- `HwpRuntime.splitParagraph()`
- `RhwpEngineBridge.splitParagraph()`
- `rhwp_bridge_split_paragraph()`
- Rust core `split_paragraph_native()`

Công dụng:
- Lưu snapshot trước khi edit.
- Tách paragraph tại caret.
- Paragraph sau nhận phần text phía sau caret.
- Reflow/recompose/paginate.
- Trả paragraph mới và offset mới.

**7. Backspace ở đầu paragraph**
Flutter: `_mergeParagraphAtCaret()`

Đi qua:
- `HwpDocumentService.mergeParagraph()`
- `HwpHostApiImpl.mergeHwpParagraph()`
- `HwpRuntime.mergeParagraph()`
- `RhwpEngineBridge.mergeParagraph()`
- `rhwp_bridge_merge_paragraph()`
- Rust core `merge_paragraph_native()`

Công dụng:
- Lưu snapshot trước khi edit.
- Gộp paragraph hiện tại vào paragraph trước.
- Reflow/recompose/paginate.
- Trả paragraph/offset mới.

**8. Refresh sau mỗi edit**
Flutter/Cubit: `HwpReaderCubit._refreshAfterDirectEdit()`

Công dụng:
- Gọi `_cursorFor()` để lấy caret rect mới.
- Gọi `currentInfo()` để lấy page count mới.
- Query `hwpEditHistoryState()` để cập nhật trạng thái nút Undo/Redo.
- Tăng `renderRevision` vì layout/render tree đã đổi sau edit.
- Tính dirty range từ page chứa đầu paragraph bị sửa, lùi thêm 1 page để an toàn.
- Mark dirty từ `dirtyStartPage` tới cuối document.
- Giữ SVG cũ của dirty pages để UI không nhấp nháy trắng.
- Render lại ngay các dirty pages đang visible, cộng thêm page current/caret và 1 page trước/sau visible.
- Các dirty pages còn lại lazy render khi người dùng scroll tới.

Quan trọng: đoạn này hiện **không còn `extractText()` toàn file sau mỗi ký tự**.
Kết quả render native cũ sẽ bị bỏ nếu `renderRevision` không còn khớp, tránh việc SVG render xong muộn ghi đè trạng thái mới hơn.

**9. Undo/Redo**
Flutter:
- `_undo()`
- `_redo()`

Đi qua:
- `HwpDocumentService.undoEdit()` / `redoEdit()`
- `HwpHostApiImpl.undoHwpEdit()` / `redoHwpEdit()`
- `HwpRuntime.undoEdit()` / `redoEdit()`
- `RhwpEngineBridge.undo()` / `redo()`
- Rust bridge `rhwp_bridge_undo()` / `rhwp_bridge_redo()`

Công dụng:
- Rust bridge giữ `undo_stack` và `redo_stack` bằng snapshot ID của `DocumentCore`.
- Undo: lưu snapshot trạng thái hiện tại vào redo stack, restore snapshot gần nhất từ undo stack.
- Redo: lưu snapshot hiện tại vào undo stack, restore snapshot gần nhất từ redo stack.
- Sau restore, Flutter mark dirty toàn bộ document, render lại visible pages/current page, clear caret và cập nhật `canUndo/canRedo`.
- History hiện giới hạn 40 bước trong bridge để không vượt quá snapshot store native.

**10. Render page**
Flutter/Cubit: `HwpReaderCubit.renderPage()`

Đi qua:
- `HwpDocumentService.renderPageSvg()`
- `HwpHostApiImpl.renderHwpPageSvg()`
- `HwpRuntime.renderPageSvg()`
- `RhwpEngineBridge.renderPageSvg()`
- `rhwp_bridge_render_page_svg()`
- Rust `document.render_page_svg_native(pageIndex)`

Công dụng:
- Native/Rust render page thành SVG.
- Flutter sanitize SVG để bỏ image SVG unsupported.
- `SvgPicture.string()` hiển thị page.
- Nếu page không dirty và đã có SVG cache thì bỏ qua render.
- Nếu page dirty thì render lại dù vẫn đang có SVG cũ.
- Nếu render trả về với `renderRevision` cũ thì discard kết quả.

**11. Save**
Flutter: `_saveEdit()`

Công dụng:
- Đóng keyboard.
- Gọi `HwpDocumentService.saveEditedDocument(info)`.
- Save xong extract text lại một lần.
- Thoát edit mode.
- Reset cache page.
- Render lại trang 1, các trang khác lazy render khi cuộn.

Service: `saveEditedDocument()`

Công dụng:
- Nếu đang là working copy và có quyền ghi: gọi `save()`.
- Nếu mở từ asset/original không overwrite: export ra file working copy mới.
- Sau export copy thì reopen file mới để từ lần sau chỉnh trên file trong thiết bị.

Native:
- `HwpRuntime.save()` hoặc `HwpRuntime.exportCopy()`
- `RhwpEngineBridge.export()`
- Rust bridge `rhwp_bridge_export()`

Công dụng:
- Serialize document hiện tại ra `.hwp/.hwpx`.
- Trả path, size, trạng thái validate.

Tóm lại: **Flutter giữ UI/input/cache**, **Swift giữ session + Pigeon/FFI**, còn **Rust/rhwp thực sự sửa document, reflow, paginate và render page**.
