// Trình soạn thảo HWP: con trỏ, bôi đen, gõ chữ, định dạng, hoàn tác.
// rhwp không giữ con trỏ — vị trí và vùng chọn là việc của tệp này. Mọi nút bấm
// nằm ở Flutter; trang vỏ chỉ vẽ, nhận chạm, báo trạng thái qua `hwp_editor_state`.

/// Đơn vị cỡ chữ của HWP là 1/100 điểm. Bên Flutter chỉ nói chuyện bằng điểm,
/// nên phép đổi nằm ở đây — Swift không phải biết đơn vị của định dạng tệp.
const HWPUNIT_PER_PT = 100;

/// rhwp vẽ ở 96 DPI, nên một điểm là 96/72 px trang.
const PX_PER_PT = 96 / 72;

/// `hitTest` dùng giá trị này cho "không nằm trong ô bảng nào".
const NO_CELL = 0xffffffff;

/// Gộp các phím gõ liền nhau vào một bước hoàn tác trong khoảng này.
const COALESCE_MS = 1500;

const UNDO_LIMIT = 100;

/// Giữ lâu bao nhiêu thì thành bôi đen thay vì đặt con trỏ.
const LONG_PRESS_MS = 450;

let doc = null;
let pagesEl = null;
let report = () => {};

let editing = false;
let dirty = false;

/// Hai đầu vùng chọn, mỗi cái `{sectionIndex, paragraphIndex, charOffset}`.
/// Bằng nhau nghĩa là chỉ có con trỏ.
let anchor = null;
let focus = null;

/// Cột muốn giữ khi bấm lên/xuống — phải nhét lại vào `moveVerticalEx` lần sau,
/// nếu không con trỏ trượt dần mỗi khi qua một dòng ngắn.
let preferredX = -1;

/// Định dạng đã bấm khi chưa bôi đen chữ nào — áp cho đoạn gõ tiếp theo.
/// Giữ theo khoá của Flutter (`fontSizePt`), đổi sang khoá rhwp lúc áp.
let pendingCharFormat = null;

let composing = false;
let preedit = '';

/// Đáy web view bị che mất bao nhiêu px. Hai nguồn, hai bên biết một nửa:
/// native đo bàn phím, Flutter báo chiều cao thanh công cụ nổi của nó.
let keyboardInset = 0;
let chromeInset = 0;

/// Bảng danh sách của Hancom, chỉ dùng để tra `listId` cho `getCaretStops`.
/// Bỏ đi mỗi khi mở/đóng chế độ sửa vì nó nói về cấu trúc tài liệu.
let cursorModel = null;

const undoStack = [];
const redoStack = [];

/// Vị trí con trỏ cần đặt **sau khi** `commit` vẽ lại xong. Đặt con trỏ là đo
/// hình học trên trang, nên phải đợi trang mới vẽ ra.
let caretAfterCommit = null;

/// Ô nhập ẩn, bám theo con trỏ. Bàn phím và IME của iOS chỉ làm việc với một
/// phần tử soạn thảo thật.
let input = null;

/// Ký tự đệm rộng bằng không, luôn có trong ô nhập: bàn phím mềm chỉ bắn
/// `deleteContentBackward` khi thật sự có cái để xoá.
const INPUT_FILLER = '\u200b';

// ---------------------------------------------------------------- tiện ích

function post(event, detail) {
  report(event, detail);
}

function parse(json, fallback) {
  try {
    return JSON.parse(json);
  } catch (_) {
    return fallback;
  }
}

/// Gọi hàm đọc của rhwp rồi parse JSON. Mọi hàm rhwp đều ném được, nên mọi
/// đường đọc phải đi qua đây.
function ask(fn, fallback = null) {
  let json;
  try {
    json = fn();
  } catch (error) {
    post('hwp_query_failed', (error && error.message) || String(error));
    return fallback;
  }
  return parse(json, fallback);
}

/// Như [ask] nhưng cho những hàm trả thẳng ra số.
function count(fn, fallback = 0) {
  try {
    const value = fn();
    return typeof value === 'number' ? value : fallback;
  } catch (error) {
    post('hwp_query_failed', (error && error.message) || String(error));
    return fallback;
  }
}

// ------------------------------------------------- vị trí: thân bài & ô bảng
//
// Vị trí có trường `cell` tuỳ chọn: `null` là thân bài, có giá trị là ô bảng
// (khi đó `paragraphIndex` là chỉ số đoạn bên trong ô). rhwp có hai họ hàm song
// song; `q*` (đọc) và `w*` (ghi) chọn hộ để chỗ khác không phải biết.

/// Ba thành phần định danh ô, hoặc `null` nếu vị trí nằm ở thân bài.
function cellOf(position) {
  return (position && position.cell) || null;
}

/// Vùng chọn không được bắc qua ranh giới ô: `deleteRangeInCell` và
/// `getSelectionRectsInCell` chỉ nhận **một** ô.
function sameRegion(a, b) {
  const ca = cellOf(a);
  const cb = cellOf(b);
  if (!ca && !cb) return a.sectionIndex === b.sectionIndex;
  if (!ca || !cb) return false;
  return a.sectionIndex === b.sectionIndex
    && ca.parentParaIndex === cb.parentParaIndex
    && ca.controlIndex === cb.controlIndex
    && ca.cellIndex === cb.cellIndex;
}

/// Tiền tố tham số của họ hàm `*InCell`.
function cellArgs(position) {
  const c = cellOf(position);
  return [position.sectionIndex, c.parentParaIndex, c.controlIndex, c.cellIndex];
}

function qParagraphLength(position) {
  const c = cellOf(position);
  return c
    ? count(() => doc.getCellParagraphLength(...cellArgs(position), position.paragraphIndex))
    : count(() => doc.getParagraphLength(position.sectionIndex, position.paragraphIndex));
}

function qParagraphCount(position) {
  const c = cellOf(position);
  return c
    ? count(() => doc.getCellParagraphCount(...cellArgs(position)))
    : count(() => doc.getParagraphCount(position.sectionIndex));
}

function qTextRange(position, offset, length) {
  if (length <= 0) return '';
  const c = cellOf(position);
  try {
    return c
      ? doc.getTextInCell(...cellArgs(position), position.paragraphIndex, offset, length)
      : doc.getTextRange(position.sectionIndex, position.paragraphIndex, offset, length);
  } catch (error) {
    post('hwp_query_failed', (error && error.message) || String(error));
    return '';
  }
}

function qParagraphText(position) {
  return qTextRange(position, 0, qParagraphLength(position));
}

function qCursorRect(position) {
  const c = cellOf(position);
  return ask(
    () => (c
      ? doc.getCursorRectInCell(...cellArgs(position), position.paragraphIndex, position.charOffset)
      : doc.getCursorRect(position.sectionIndex, position.paragraphIndex, position.charOffset)),
    null,
  );
}

function qSelectionRects(range) {
  const c = cellOf(range.start);
  return ask(
    () => (c
      ? doc.getSelectionRectsInCell(
          ...cellArgs(range.start),
          range.start.paragraphIndex, range.start.charOffset,
          range.end.paragraphIndex, range.end.charOffset,
        )
      : doc.getSelectionRects(
          range.sectionIndex,
          range.start.paragraphIndex, range.start.charOffset,
          range.end.paragraphIndex, range.end.charOffset,
        )),
    [],
  );
}

function qCharPropertiesAt(position, offset) {
  const c = cellOf(position);
  return ask(
    () => (c
      ? doc.getCellCharPropertiesAt(...cellArgs(position), position.paragraphIndex, offset)
      : doc.getCharPropertiesAt(position.sectionIndex, position.paragraphIndex, offset)),
    {},
  );
}

function qParaPropertiesAt(position) {
  const c = cellOf(position);
  return ask(
    () => (c
      ? doc.getCellParaPropertiesAt(...cellArgs(position), position.paragraphIndex)
      : doc.getParaPropertiesAt(position.sectionIndex, position.paragraphIndex)),
    {},
  );
}

function qLineInfo(position, offset) {
  const c = cellOf(position);
  return ask(
    () => (c
      ? doc.getLineInfoInCell(...cellArgs(position), position.paragraphIndex, offset)
      : doc.getLineInfo(position.sectionIndex, position.paragraphIndex, offset)),
    null,
  );
}

/// Nhóm lệnh **ghi**. Trả về JSON đã parse, hoặc `null` nếu lời gọi ném.
function wInsertText(position, text) {
  const c = cellOf(position);
  return ask(() => (c
    ? doc.insertTextInCell(...cellArgs(position), position.paragraphIndex, position.charOffset, text)
    : doc.insertText(position.sectionIndex, position.paragraphIndex, position.charOffset, text)), null);
}

function wDeleteText(position, offset, n) {
  const c = cellOf(position);
  if (c) doc.deleteTextInCell(...cellArgs(position), position.paragraphIndex, offset, n);
  else doc.deleteText(position.sectionIndex, position.paragraphIndex, offset, n);
}

function wDeleteRange(range) {
  const c = cellOf(range.start);
  return ask(() => (c
    ? doc.deleteRangeInCell(
        ...cellArgs(range.start),
        range.start.paragraphIndex, range.start.charOffset,
        range.end.paragraphIndex, range.end.charOffset)
    : doc.deleteRange(
        range.sectionIndex,
        range.start.paragraphIndex, range.start.charOffset,
        range.end.paragraphIndex, range.end.charOffset)), null);
}

function wSplitParagraph(position, meta) {
  const c = cellOf(position);
  return ask(() => (c
    ? doc.splitParagraphInCell(...cellArgs(position), position.paragraphIndex, position.charOffset, meta || null)
    : doc.splitParagraph(position.sectionIndex, position.paragraphIndex, position.charOffset, meta || null)), null);
}

function wMergeParagraph(position) {
  const c = cellOf(position);
  return ask(() => (c
    ? doc.mergeParagraphInCell(...cellArgs(position), position.paragraphIndex)
    : doc.mergeParagraph(position.sectionIndex, position.paragraphIndex)), null);
}

function wApplyCharFormat(position, start, end, props) {
  const c = cellOf(position);
  const json = JSON.stringify(props);
  if (c) doc.applyCharFormatInCell(...cellArgs(position), position.paragraphIndex, start, end, json);
  else doc.applyCharFormat(position.sectionIndex, position.paragraphIndex, start, end, json);
}

function samePos(a, b) {
  return !!a && !!b
    && a.sectionIndex === b.sectionIndex
    && a.paragraphIndex === b.paragraphIndex
    && a.charOffset === b.charOffset
    && sameRegion(a, b);
}

/// Thứ tự tài liệu: đoạn trước, rồi tới ký tự.
function comparePos(a, b) {
  if (a.paragraphIndex !== b.paragraphIndex) return a.paragraphIndex - b.paragraphIndex;
  return a.charOffset - b.charOffset;
}

function hasSelection() {
  return !!anchor && !!focus && !samePos(anchor, focus);
}

/// Vùng chọn đã sắp xếp, hoặc `null` nếu chỉ có con trỏ.
function selectionRange() {
  if (!hasSelection()) return null;
  const [start, end] = comparePos(anchor, focus) <= 0 ? [anchor, focus] : [focus, anchor];
  return { sectionIndex: start.sectionIndex, start, end };
}

// -------------------------------------------------------------- vẽ trang

/// Dựng trước/sau khung nhìn chừng này để cuộn nhanh không thấy trang trống.
const MOUNT_MARGIN = '120%';

/// Những trang đang có nội dung thật. Trang không nằm trong đây chỉ là khung
/// rỗng giữ đúng chỗ, chưa tốn gì.
const mounted = new Set();

let pageObserver = null;

function pageTotal() {
  return Math.max(1, count(() => doc.pageCount(), 1));
}

/// Tạo/bỏ khung cho khớp số trang, và đặt đúng tỉ lệ để thanh cuộn dài đúng
/// ngay từ đầu — `getPageInfo` cho kích thước mà không phải dựng hình.
function syncPageFrames(total) {
  const started = performance.now();
  let infoMs = 0;
  let added = 0;
  while (pagesEl.children.length > total) {
    const gone = pagesEl.lastElementChild;
    mounted.delete(Number(gone.dataset.page));
    if (pageObserver) pageObserver.unobserve(gone);
    gone.remove();
  }
  for (let i = pagesEl.children.length; i < total; i += 1) {
    const frame = document.createElement('div');
    frame.className = 'page';
    frame.dataset.page = String(i);
    const infoStart = performance.now();
    const info = ask(() => doc.getPageInfo(i), null);
    infoMs += performance.now() - infoStart;
    if (info && info.width > 0 && info.height > 0) {
      frame.style.aspectRatio = `${info.width} / ${info.height}`;
    }
    pagesEl.appendChild(frame);
    if (pageObserver) pageObserver.observe(frame);
    added += 1;
  }
  if (added > 0) {
    post(
      'hwp_frames_synced',
      `total=${total} added=${added} getPageInfo=${Math.round(infoMs)}ms`
        + ` in=${Math.round(performance.now() - started)}ms`,
    );
  }
}

/// Dựng nội dung thật vào khung. Gọi lại được — dùng cả cho việc vẽ lại sau khi
/// sửa.
function mountPage(index) {
  const frame = pagesEl.children[index];
  if (!frame) return;
  const started = performance.now();
  const holder = document.createElement('div');
  const markup = doc.renderPageSvg(index);
  const rendered = performance.now();
  holder.innerHTML = markup;
  const svg = holder.firstElementChild;
  const parsed = performance.now();

  // svg + lớp phủ riêng: con trỏ và vệt bôi đen di chuyển được mà không phải
  // vẽ lại svg.
  const overlay = document.createElement('div');
  overlay.className = 'ov';
  frame.replaceChildren(svg, overlay);
  mounted.add(index);
  post(
    'hwp_page_mounted',
    `page=${index} bytes=${markup.length} svg=${Math.round(rendered - started)}ms`
      + ` dom=${Math.round(parsed - rendered)}ms in=${Math.round(performance.now() - started)}ms`,
  );
}

/// Trả khung về rỗng. Phải **xoá hẳn** nội dung chứ không ẩn đi: giữ lại nút cũ
/// là đúng cách sinh ra lỗi hiển thị nội dung lỗi thời.
function unmountPage(index) {
  const frame = pagesEl.children[index];
  if (!frame) return;
  frame.replaceChildren();
  mounted.delete(index);
}

/// Vẽ lại từ trang `from` trở đi, và đồng bộ số khung.
///
/// Chỉ dựng lại những trang **đang hiển thị**. Trang chưa dựng thì không cần
/// làm gì — lúc cuộn tới nó sẽ dựng từ trạng thái mới nhất.
///
/// **Không** bỏ qua trang đang hiển thị vì "trông không đổi". Đã thử so chuỗi
/// SVG rồi dừng sớm và cách đó làm **mất chữ**: chữ lặp lại khiến hai trang
/// khác nhau cho ra SVG y hệt.
function renderPages(from = 0) {
  const total = pageTotal();
  syncPageFrames(total);
  for (const index of [...mounted]) {
    if (index >= from && index < total) mountPage(index);
  }
  // Trang chứa con trỏ phải có mặt để còn vẽ con trỏ lên.
  if (focus) {
    const page = pageOf(focus);
    if (page < total && !mounted.has(page)) mountPage(page);
  }
  publishState();
  return total;
}

/// Nút DOM của trang `index`, chỉ khi nó đã dựng — trang mới là khung rỗng thì
/// chưa có hình học để vẽ đè lên.
function pageWrap(index) {
  const frame = pagesEl.children[index];
  return frame && frame.firstElementChild ? frame : null;
}

/// Cuộn trang `index` vào tầm nhìn.
function showPage(index) {
  const total = pageTotal();
  const i = Math.min(Math.max(0, Math.trunc(Number(index) || 0)), total - 1);
  const frame = pagesEl.children[i];
  if (frame) frame.scrollIntoView({ block: 'start' });
}

/// Dựng trang khi nó sắp vào khung nhìn, bỏ khi đã cuộn qua xa.
function observePages() {
  pageObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      const index = Number(entry.target.dataset.page);
      if (!Number.isFinite(index)) continue;
      if (entry.isIntersecting) {
        if (!mounted.has(index)) mountPage(index);
      } else if (mounted.has(index)) {
        // Giữ lại trang có con trỏ, nếu không vệt bôi đen và caret biến mất.
        if (!focus || pageOf(focus) !== index) unmountPage(index);
      }
    }
    drawOverlays();
    post('hwp_pages_mounted', `${mounted.size}/${pagesEl.children.length}`);
  }, { root: null, rootMargin: `${MOUNT_MARGIN} 0px` });
  for (const frame of pagesEl.children) pageObserver.observe(frame);
}

/// Tỉ lệ px trang / px màn hình. Tính lại mỗi lần — xoay máy và bàn phím đều
/// làm đổi, nhớ giá trị cũ là con trỏ đứng yên một chỗ.
function pageGeometry(wrap) {
  const svg = wrap.firstElementChild;
  const box = svg.viewBox && svg.viewBox.baseVal;
  const width = (box && box.width) || (svg.width && svg.width.baseVal.value) || wrap.clientWidth;
  const rect = svg.getBoundingClientRect();
  return { rect, width, scale: rect.width / width };
}

function pagePoint(wrap, event) {
  const geom = pageGeometry(wrap);
  return {
    x: (event.clientX - geom.rect.left) / geom.scale,
    y: (event.clientY - geom.rect.top) / geom.scale,
  };
}

// ------------------------------------------------------------- lớp phủ

function clearOverlays() {
  for (const wrap of pagesEl.children) {
    const overlay = wrap.lastElementChild;
    if (overlay === wrap.firstElementChild) continue;
    if (overlay && overlay.classList && overlay.classList.contains('ov')) {
      overlay.replaceChildren();
    }
  }
}

function drawOverlays() {
  if (!pagesEl) return;
  clearOverlays();
  if (!editing || !focus) return;

  const range = selectionRange();
  if (range) {
    drawSelection(range);
    return;
  }
  drawCaret();
  if (composing && preedit) drawPreedit();
}

function caretRect() {
  if (!focus) return null;
  const rect = qCursorRect(focus);
  return rect && typeof rect.pageIndex === 'number' ? rect : null;
}

function drawCaret() {
  const rect = caretRect();
  if (!rect) return;
  const wrap = pageWrap(rect.pageIndex);
  if (!wrap) return;
  const { scale } = pageGeometry(wrap);

  const bar = document.createElement('div');
  bar.className = 'caret';
  bar.style.left = `${rect.x * scale}px`;
  bar.style.top = `${rect.y * scale}px`;
  bar.style.height = `${Math.max(rect.height * scale, 8)}px`;
  wrap.lastElementChild.appendChild(bar);
}

function drawSelection(range) {
  const rects = qSelectionRects(range);
  for (const rect of rects) {
    const wrap = pageWrap(rect.pageIndex);
    if (!wrap) continue;
    const { scale } = pageGeometry(wrap);
    const box = document.createElement('div');
    box.className = 'sel';
    box.style.left = `${rect.x * scale}px`;
    box.style.top = `${rect.y * scale}px`;
    box.style.width = `${rect.width * scale}px`;
    box.style.height = `${rect.height * scale}px`;
    wrap.lastElementChild.appendChild(box);
  }
}

/// Vẽ chữ đang tổ hợp (IME tiếng Hàn) — nó chưa nằm trong tài liệu. Nền đục để
/// che chữ phía sau thay vì chồng lên.
function drawPreedit() {
  const rect = caretRect();
  if (!rect) return;
  const wrap = pageWrap(rect.pageIndex);
  if (!wrap) return;
  const { scale } = pageGeometry(wrap);
  const props = qCharPropertiesAt(focus, focus.charOffset);
  const height = Math.max(rect.height * scale, 8);

  const chip = document.createElement('div');
  chip.className = 'preedit';
  chip.textContent = preedit;
  chip.style.left = `${rect.x * scale}px`;
  chip.style.top = `${rect.y * scale}px`;
  chip.style.height = `${height}px`;
  chip.style.lineHeight = `${height}px`;
  if (props.fontFamily) chip.style.fontFamily = props.fontFamily;
  if (typeof props.fontSize === 'number') {
    chip.style.fontSize = `${(props.fontSize / HWPUNIT_PER_PT) * PX_PER_PT * scale}px`;
  }
  wrap.lastElementChild.appendChild(chip);
}

// ------------------------------------------------- ghi thay đổi & vẽ lại

/// Bọc mọi thay đổi nội dung.
/// Đừng dùng `beginBatch`/`endBatch`: nó tắt luôn `paginate()`, nên vẽ ngay sau
/// đó là vẽ trên bản phân trang đã cũ.
function commit(at, fn) {
  const started = performance.now();
  const pagesBefore = doc.pageCount();
  const pageBefore = pageOf(at);
  const linesBefore = lineCountOf(at);
  const objectsBefore = objectsLogged ? null : objectsOn(pageBefore);
  let failure = null;

  try {
    fn();
  } catch (error) {
    failure = error;
  }

  const pageAfter = pageOf(caretAfterCommit || at);
  const linesAfter = lineCountOf(caretAfterCommit || at);
  if (objectsBefore !== null) {
    objectsLogged = true;
    post('hwp_objects_before', objectsBefore);
    post('hwp_objects_after', objectsOn(pageAfter));
  }
  // Lùi lại một trang cho an toàn ở ranh giới: sửa ở đầu trang N có thể kéo
  // dòng cuối của trang N-1 xuống.
  const from = Math.max(0, Math.min(pageBefore, pageAfter) - 1);
  const total = renderPages(from);

  dirty = true;
  post(
    'hwp_edit_commit',
    `page=${pageBefore}->${pageAfter} pages=${pagesBefore}->${total}`
      + ` lines=${linesBefore}->${linesAfter}`
      + ` in=${Math.round(performance.now() - started)}ms`,
  );
  if (failure) {
    post('hwp_edit_failed', (failure && (failure.stack || failure.message)) || String(failure));
  }
}

/// Đã chụp ảnh bố cục đối tượng cho lần sửa đầu tiên chưa.
let objectsLogged = false;

/// Chụp ảnh/đối tượng trên một trang để chẩn đoán, in thô vì hình dạng JSON của
/// `getPageControlLayout` không được ghi ở đâu.
function objectsOn(page) {
  let json = '';
  try {
    json = doc.getPageControlLayout(page) || '';
  } catch (error) {
    return `error=${(error && error.message) || error}`;
  }
  return json.length > 600 ? `${json.slice(0, 600)}…(${json.length})` : json;
}

/// Số dòng thị giác của đoạn. Dùng để phân biệt đo chữ lệch chút ít (số dòng
/// gần như không đổi) với mất hẳn quy tắc né ảnh (số dòng tụt hẳn).
function lineCountOf(position) {
  if (!position) return -1;
  const line = qLineInfo(position, 0);
  return line && typeof line.lineCount === 'number' ? line.lineCount : -1;
}

/// Trang chứa một vị trí, hoặc 0 nếu không tra được.
function pageOf(position) {
  if (!position) return 0;
  // Ô bảng không có số trang riêng — nó nằm trên trang của đoạn neo bảng.
  const c = cellOf(position);
  const paraIndex = c ? c.parentParaIndex : position.paragraphIndex;
  const where = ask(
    () => doc.getPageOfPosition(position.sectionIndex, paraIndex),
    null,
  );
  return where && where.ok && typeof where.page === 'number' ? where.page : 0;
}

/// Đặt con trỏ sau khi trang đã vẽ lại xong.
function flushCaret() {
  const position = caretAfterCommit;
  caretAfterCommit = null;
  if (position) setCaret(position);
  else {
    drawOverlays();
    publishState();
  }
}

// ------------------------------------------------------------- hoàn tác

/// Mỗi bước hoàn tác giữ thao tác nghịch của nó — `saveSnapshot` chụp cả tài
/// liệu vào WASM nên không dùng được. `cmd.cell` cho biết lệnh sửa ở vùng nào.
function exec(cmd) {
  const c = cmd.cell || null;
  const pre = c ? [cmd.s, c.parentParaIndex, c.controlIndex, c.cellIndex] : [cmd.s];
  switch (cmd.op) {
    case 'insertText':
      if (c) doc.insertTextInCell(...pre, cmd.p, cmd.o, cmd.text);
      else doc.insertText(cmd.s, cmd.p, cmd.o, cmd.text);
      return;
    case 'deleteText':
      if (c) doc.deleteTextInCell(...pre, cmd.p, cmd.o, cmd.n);
      else doc.deleteText(cmd.s, cmd.p, cmd.o, cmd.n);
      return;
    case 'deleteRange':
      if (c) {
        doc.deleteRangeInCell(...pre, cmd.startPara, cmd.startOffset, cmd.endPara, cmd.endOffset);
      } else {
        doc.deleteRange(cmd.s, cmd.startPara, cmd.startOffset, cmd.endPara, cmd.endOffset);
      }
      return;
    case 'split':
      if (c) doc.splitParagraphInCell(...pre, cmd.p, cmd.o, cmd.meta || null);
      else doc.splitParagraph(cmd.s, cmd.p, cmd.o, cmd.meta || null);
      return;
    case 'merge':
      if (c) doc.mergeParagraphInCell(...pre, cmd.p);
      else doc.mergeParagraph(cmd.s, cmd.p);
      return;
    case 'setCharShapeId':
      if (c) doc.setCharShapeIdInCell(...pre, cmd.p, cmd.start, cmd.end, cmd.id);
      else doc.setCharShapeId(cmd.s, cmd.p, cmd.start, cmd.end, cmd.id);
      return;
    case 'setParaShapeId':
      if (c) doc.setCellParaShapeId(...pre, cmd.p, cmd.id);
      else doc.setParaShapeId(cmd.s, cmd.p, cmd.id);
      return;
    case 'applyCharFormat':
      if (c) doc.applyCharFormatInCell(...pre, cmd.p, cmd.start, cmd.end, JSON.stringify(cmd.props));
      else doc.applyCharFormat(cmd.s, cmd.p, cmd.start, cmd.end, JSON.stringify(cmd.props));
      return;
    case 'applyParaFormat':
      if (c) doc.applyParaFormatInCell(...pre, cmd.p, JSON.stringify(cmd.props));
      else doc.applyParaFormat(cmd.s, cmd.p, JSON.stringify(cmd.props));
      return;
    default:
      post('hwp_undo_unknown_op', cmd.op);
  }
}

function pushStep(step) {
  step.time = Date.now();
  undoStack.push(step);
  if (undoStack.length > UNDO_LIMIT) undoStack.shift();
  redoStack.length = 0;
  return step;
}

/// Gõ liên tiếp trong cùng một đoạn thì gộp vào một bước, nếu không mỗi ký tự
/// là một lần hoàn tác và người dùng phải bấm hai mươi lần để xoá một từ.
function pushTyping(s, p, offset, text, caretBefore, caretAfter, cell) {
  const last = undoStack[undoStack.length - 1];
  if (
    last
    && last.kind === 'type'
    && last.s === s
    && last.p === p
    && last.tail === offset
    && Date.now() - last.time < COALESCE_MS
  ) {
    last.text += text;
    last.tail = offset + text.length;
    last.caretAfter = caretAfter;
    last.time = Date.now();
    last.undo = [{ op: 'deleteText', s, p, o: last.o, n: last.text.length, cell }];
    last.redo = [{ op: 'insertText', s, p, o: last.o, text: last.text, cell }];
    redoStack.length = 0;
    return;
  }
  pushStep({
    kind: 'type',
    s,
    p,
    o: offset,
    tail: offset + text.length,
    text,
    caretBefore,
    caretAfter,
    undo: [{ op: 'deleteText', s, p, o: offset, n: text.length, cell }],
    redo: [{ op: 'insertText', s, p, o: offset, text, cell }],
  });
}

/// Xoá lùi liên tiếp cũng gộp, nhưng theo chiều ngược: mỗi ký tự bị xoá được
/// ghép vào **đầu** chuỗi cần trả lại.
function pushBackspace(s, p, offset, removed, caretBefore, caretAfter, cell) {
  const last = undoStack[undoStack.length - 1];
  if (
    last
    && last.kind === 'backspace'
    && last.s === s
    && last.p === p
    && last.o === offset + removed.length
    && Date.now() - last.time < COALESCE_MS
  ) {
    last.text = removed + last.text;
    last.o = offset;
    last.caretAfter = caretAfter;
    last.time = Date.now();
    last.undo = [{ op: 'insertText', s, p, o: offset, text: last.text, cell }];
    last.redo = [{ op: 'deleteText', s, p, o: offset, n: last.text.length, cell }];
    redoStack.length = 0;
    return;
  }
  pushStep({
    kind: 'backspace',
    s,
    p,
    o: offset,
    text: removed,
    caretBefore,
    caretAfter,
    undo: [{ op: 'insertText', s, p, o: offset, text: removed, cell }],
    redo: [{ op: 'deleteText', s, p, o: offset, n: removed.length, cell }],
  });
}

function undo() {
  const step = undoStack.pop();
  if (!step) {
    publishState();
    return;
  }
  commit(step.caretAfter || step.caretBefore, () => {
    for (let i = step.undo.length - 1; i >= 0; i -= 1) exec(step.undo[i]);
  });
  redoStack.push(step);
  setCaret(step.caretBefore);
  post('hwp_undo', step.kind);
}

function redo() {
  const step = redoStack.pop();
  if (!step) {
    publishState();
    return;
  }
  commit(step.caretBefore || step.caretAfter, () => {
    for (const cmd of step.redo) exec(cmd);
  });
  undoStack.push(step);
  setCaret(step.caretAfter);
  post('hwp_redo', step.kind);
}

// --------------------------------------------------------- di chuyển con trỏ

/// Đã kiểm tra font của tài liệu chưa. Chỉ làm một lần cho mỗi lần mở.
let fontChecked = false;

/// Canvas dùng riêng cho việc đo chữ chẩn đoán.
let probeCanvas = null;

function measureWith(font, sample) {
  if (!probeCanvas) probeCanvas = document.createElement('canvas').getContext('2d');
  probeCanvas.font = font;
  return probeCanvas.measureText(sample).width;
}

/// Máy có cài font này không. Phải đo bề rộng chứ không dùng
/// `document.fonts.check()` — hàm đó trả true cả với font không tồn tại.
function fontInstalled(family) {
  const sample = '한글Hangul漢字0123';
  const missing = '__rhwp_no_such_font__';
  for (const fallback of ['monospace', 'serif']) {
    const wanted = measureWith(`48px "${family}", ${fallback}`, sample);
    const absent = measureWith(`48px "${missing}", ${fallback}`, sample);
    if (Math.abs(wanted - absent) > 0.5) return true;
  }
  return false;
}

/// Log xem máy có đủ font tài liệu yêu cầu không. Thiếu font thì chỗ ngắt dòng
/// sẽ khác Hancom.
function checkFont(position) {
  if (fontChecked) return;
  fontChecked = true;
  const props = qCharPropertiesAt(position, 0);
  const families = new Set();
  if (props && props.fontFamily) families.add(props.fontFamily);
  if (props && Array.isArray(props.fontFamilies)) {
    for (const family of props.fontFamilies) if (family) families.add(family);
  }
  if (!families.size) return;
  const report = [...families]
    .map((family) => `${family}=${fontInstalled(family) ? 'yes' : 'NO'}`)
    .join(' ');
  const fallback = (() => {
    try {
      return doc.getFallbackFont();
    } catch (_) {
      return '?';
    }
  })();
  post('hwp_font_check', `${report} fallback=${fallback}`);
}

function setCaret(position, keepColumn = false) {
  if (position) checkFont(position);
  anchor = position ? { ...position } : null;
  focus = position ? { ...position } : null;
  if (!keepColumn) preferredX = -1;
  pendingCharFormat = null;
  drawOverlays();
  moveInputToCaret();
  scrollCaretIntoView();
  publishState();
}

function extendTo(position, keepColumn = false) {
  if (!anchor) anchor = { ...position };
  // Vùng chọn không bắc qua hai vùng được: `deleteRange*` chỉ nhận một vùng.
  if (!sameRegion(position, anchor)) return;
  focus = { ...position };
  if (!keepColumn) preferredX = -1;
  drawOverlays();
  publishState();
}

function bodyListId(sectionIndex) {
  if (!cursorModel) cursorModel = ask(() => doc.getCursorModel(), null);
  const lists = cursorModel && cursorModel.lists;
  if (!Array.isArray(lists)) return null;
  const body = lists.find((list) => !list.isCell && list.sectionIndex === sectionIndex);
  return body && typeof body.listId === 'number' ? body.listId : null;
}

/// Các chỗ con trỏ được phép đứng. `getCaretStops` biết né điều khiển nội tuyến
/// nhưng ăn hệ toạ độ khác, tra không ra thì lùi về đếm code point.
function caretStops(position) {
  const { sectionIndex, paragraphIndex } = position;
  // `bodyListId` chỉ tra được danh sách của thân bài; trong ô thì lùi về đếm
  // theo code point bên dưới.
  const listId = cellOf(position) ? null : bodyListId(sectionIndex);
  if (listId !== null) {
    const parsed = ask(() => doc.getCaretStops(listId, paragraphIndex), null);
    const values = Array.isArray(parsed) ? parsed : (parsed && parsed.stops);
    // Phải là mảng toàn số — hình dạng JSON của `getCaretStops` không được ghi
    // ở đâu, đoán sai thì con trỏ lặng lẽ không nhúc nhích.
    if (Array.isArray(values) && values.length
        && values.every((value) => Number.isFinite(value))) {
      return values;
    }
  }
  const text = qParagraphText(position);
  const fallback = [0];
  for (const ch of text) fallback.push(fallback[fallback.length - 1] + ch.length);
  return fallback;
}

/// Vị trí ngay trước `offset`, đếm theo code point. Lưới an toàn cho phím xoá:
/// dù các hàm dời con trỏ trả về gì, xoá lùi vẫn phải xoá được một ký tự.
function offsetBefore(position, offset) {
  const text = qTextRange(position, 0, offset);
  if (!text) return Math.max(0, offset - 1);
  const chars = Array.from(text);
  const last = chars[chars.length - 1];
  return offset - (last ? last.length : 1);
}

/// Vị trí ngay sau `offset`, cùng quy ước với [offsetBefore].
function offsetAfter(position, offset, length) {
  const rest = qTextRange(position, offset, length - offset);
  if (!rest) return Math.min(length, offset + 1);
  const first = Array.from(rest)[0];
  return offset + (first ? first.length : 1);
}

function nearestStopIndex(stops, offset) {
  let best = 0;
  for (let i = 0; i < stops.length; i += 1) {
    if (stops[i] <= offset) best = i;
    else break;
  }
  return best;
}

function stepHorizontal(position, delta) {
  const stops = caretStops(position);
  const index = stops.indexOf(position.charOffset);
  const next = (index >= 0 ? index : nearestStopIndex(stops, position.charOffset)) + delta;

  if (next >= 0 && next < stops.length) return { ...position, charOffset: stops[next] };

  // Ra khỏi đoạn: sang đoạn kề, đứng ở đầu bên kia.
  if (delta < 0 && position.paragraphIndex > 0) {
    const p = position.paragraphIndex - 1;
    return {
      ...position,
      paragraphIndex: p,
      charOffset: qParagraphLength({ ...position, paragraphIndex: p }),
    };
  }
  if (delta > 0 && position.paragraphIndex + 1 < qParagraphCount(position)) {
    return {
      ...position,
      paragraphIndex: position.paragraphIndex + 1,
      charOffset: 0,
    };
  }
  return position;
}

/// `moveVerticalEx` không có bản cho ô bảng, nên trong ô phải dò dòng bằng
/// `getLineInfoInCell` — thô hơn, và không nhảy sang ô kề.
function moveVertical(delta, extend) {
  if (!focus) return;

  if (cellOf(focus)) {
    const line = qLineInfo(focus, focus.charOffset);
    if (!line || typeof line.lineIndex !== 'number') return;
    const wanted = line.lineIndex + delta;
    if (wanted < 0 || wanted >= (line.lineCount || 0)) {
      // Ra khỏi ô thì dừng lại — chưa nối sang ô kề.
      return;
    }
    const column = focus.charOffset - (line.charStart || 0);
    const probe = { ...focus, charOffset: line.charStart || 0 };
    // Nhích dần: `getLineInfoInCell` chỉ trả về dòng chứa offset.
    const length = qParagraphLength(focus);
    let target = null;
    for (let o = 0; o <= length; o += 1) {
      const info = qLineInfo(probe, o);
      if (info && info.lineIndex === wanted) {
        target = { ...focus, charOffset: Math.min(o + column, info.charEnd ?? o) };
        break;
      }
    }
    if (!target) return;
    if (extend) extendTo(target, true);
    else setCaret(target, true);
    return;
  }

  const moved = ask(
    () => doc.moveVerticalEx(JSON.stringify({
      sectionIdx: focus.sectionIndex,
      paraIdx: focus.paragraphIndex,
      charOffset: focus.charOffset,
      delta,
      preferredX,
    })),
    null,
  );
  if (!moved || typeof moved.paragraphIndex !== 'number') return;
  if (typeof moved.preferredX === 'number') preferredX = moved.preferredX;
  const position = {
    sectionIndex: moved.sectionIndex,
    paragraphIndex: moved.paragraphIndex,
    charOffset: moved.charOffset,
  };
  if (extend) extendTo(position, true);
  else setCaret(position, true);
}

function moveToLineEdge(atEnd, extend) {
  if (!focus) return;
  const line = qLineInfo(focus, focus.charOffset);
  if (!line) return;
  const position = { ...focus, charOffset: atEnd ? line.charEnd : line.charStart };
  if (extend) extendTo(position);
  else setCaret(position);
}

// -------------------------------------------------------------- soạn thảo

/// Văn bản của vùng chọn, tách theo đoạn.
function collectRangeText(range) {
  const parts = [];
  for (let p = range.start.paragraphIndex; p <= range.end.paragraphIndex; p += 1) {
    const at = { ...range.start, paragraphIndex: p };
    const length = qParagraphLength(at);
    const from = p === range.start.paragraphIndex ? range.start.charOffset : 0;
    const to = p === range.end.paragraphIndex ? range.end.charOffset : length;
    parts.push(to > from ? qTextRange(at, from, to - from) : '');
  }
  return parts;
}

/// Xoá vùng chọn, đẩy một bước hoàn tác, trả về vị trí con trỏ sau khi xoá.
/// Phải gọi **trong** `commit`.
function removeRange(range) {
  const parts = collectRangeText(range);
  const result = wDeleteRange(range);
  // Phải trải `range.start` để giữ `cell` — dựng bằng literal là con trỏ rơi
  // khỏi ô và lần gõ kế tiếp ghi nhầm vào thân bài.
  const after = {
    ...range.start,
    paragraphIndex: result && typeof result.paraIdx === 'number'
      ? result.paraIdx
      : range.start.paragraphIndex,
    charOffset: result && typeof result.charOffset === 'number'
      ? result.charOffset
      : range.start.charOffset,
  };

  // Dựng lại: chèn chữ của từng đoạn rồi tách ra đúng chỗ nó đã bị nhập vào.
  const undoOps = [];
  let cursor = { ...after };
  for (let i = 0; i < parts.length; i += 1) {
    if (parts[i]) {
      undoOps.push({
        op: 'insertText',
        s: cursor.sectionIndex,
        p: cursor.paragraphIndex,
        o: cursor.charOffset,
        text: parts[i],
        cell: cellOf(range.start),
      });
      cursor = { ...cursor, charOffset: cursor.charOffset + parts[i].length };
    }
    if (i < parts.length - 1) {
      undoOps.push({
        op: 'split',
        s: cursor.sectionIndex,
        p: cursor.paragraphIndex,
        o: cursor.charOffset,
        cell: cellOf(range.start),
      });
      cursor = {
        sectionIndex: cursor.sectionIndex,
        paragraphIndex: cursor.paragraphIndex + 1,
        charOffset: 0,
      };
    }
  }

  // Làm lại chỉ là xoá lại đúng vùng đó: hoàn tác đã trả nội dung về nguyên
  // trạng nên toạ độ cũ vẫn đúng.
  return {
    after,
    step: pushStep({
      kind: 'deleteRange',
      caretBefore: { ...range.start },
      caretAfter: after,
      undo: undoOps,
      redo: [{
        op: 'deleteRange',
        s: range.sectionIndex,
        startPara: range.start.paragraphIndex,
        startOffset: range.start.charOffset,
        endPara: range.end.paragraphIndex,
        endOffset: range.end.charOffset,
        cell: cellOf(range.start),
      }],
    }),
  };
}

/// Khoá của Flutter → khoá mà `applyCharFormat` hiểu. Không có màu chữ vì rhwp
/// 0.8.4 đọc được `textColor` nhưng không ghi vào được.
function toCharProps(ui) {
  const props = {};
  for (const key of ['bold', 'italic', 'underline', 'strikethrough']) {
    if (typeof ui[key] === 'boolean') props[key] = ui[key];
  }
  if (typeof ui.fontSizePt === 'number') {
    props.fontSize = Math.round(ui.fontSizePt * HWPUNIT_PER_PT);
  }
  return props;
}

function typeText(text) {
  if (!focus || !text) return;
  const range = selectionRange();
  const caretBefore = { ...(range ? range.start : focus) };
  const format = pendingCharFormat ? toCharProps(pendingCharFormat) : null;

  commit(caretBefore, () => {
    let target = caretBefore;
    let deletion = null;
    if (range) {
      deletion = removeRange(range);
      target = deletion.after;
    }

    const result = wInsertText(target, text);
    const after = {
      ...target,
      charOffset: result && typeof result.charOffset === 'number'
        ? result.charOffset
        : target.charOffset + text.length,
    };

    if (format && Object.keys(format).length) {
      wApplyCharFormat(target, target.charOffset, after.charOffset, format);
    }

    if (deletion) {
      // Xoá-rồi-chèn là một bước: gộp phần chèn vào bước xoá vừa đẩy.
      const step = deletion.step;
      step.kind = 'replace';
      step.undo.unshift({
        op: 'deleteText',
        s: target.sectionIndex,
        p: target.paragraphIndex,
        o: target.charOffset,
        n: text.length,
        cell: cellOf(target),
      });
      step.redo.push({
        op: 'insertText',
        s: target.sectionIndex,
        p: target.paragraphIndex,
        o: target.charOffset,
        text,
        cell: cellOf(target),
      });
      step.caretAfter = after;
    } else {
      pushTyping(
        target.sectionIndex,
        target.paragraphIndex,
        target.charOffset,
        text,
        caretBefore,
        after,
        cellOf(target),
      );
    }
    caretAfterCommit = after;
  });

  pendingCharFormat = null;
  flushCaret();
}

function deleteSelection() {
  const range = selectionRange();
  if (!range) return false;
  commit(range.start, () => {
    caretAfterCommit = removeRange(range).after;
  });
  flushCaret();
  return true;
}

function deleteBackward() {
  if (deleteSelection()) return;
  if (!focus) return;
  const { sectionIndex, paragraphIndex, charOffset } = focus;

  if (charOffset > 0) {
    const stepped = stepHorizontal(focus, -1);
    // Nếu phép dời không ở lại trong đoạn này — hoặc không đi đâu cả — thì lùi
    // về đếm chữ. Trước đây chỗ này `return`, nên phím xoá không làm gì hết.
    const previous = stepped.paragraphIndex === paragraphIndex
        && stepped.charOffset < charOffset
      ? stepped
      : { ...focus, charOffset: offsetBefore(focus, charOffset) };
    const removedCount = charOffset - previous.charOffset;
    if (removedCount <= 0) return;
    const removed = qTextRange(focus, previous.charOffset, removedCount);
    const before = { ...focus };
    commit(before, () => {
      wDeleteText(focus, previous.charOffset, removedCount);
      pushBackspace(sectionIndex, paragraphIndex, previous.charOffset, removed, before, previous, cellOf(focus));
      caretAfterCommit = previous;
    });
    flushCaret();
    return;
  }

  if (paragraphIndex === 0) return;
  mergeIntoPrevious({ ...focus }, { ...focus });
}

function deleteForward() {
  if (deleteSelection()) return;
  if (!focus) return;
  const { sectionIndex, paragraphIndex, charOffset } = focus;
  const length = qParagraphLength(focus);

  if (charOffset < length) {
    const stepped = stepHorizontal(focus, 1);
    const next = stepped.paragraphIndex === paragraphIndex
        && stepped.charOffset > charOffset
      ? stepped
      : {
          ...focus,
          charOffset: offsetAfter(focus, charOffset, length),
        };
    const removedCount = next.charOffset - charOffset;
    if (removedCount <= 0) return;
    const removed = qTextRange(focus, charOffset, removedCount);
    const at = { ...focus };
    commit(at, () => {
      wDeleteText(focus, charOffset, removedCount);
      pushStep({
        kind: 'delete',
        caretBefore: at,
        caretAfter: at,
        undo: [{ op: 'insertText', s: sectionIndex, p: paragraphIndex, o: charOffset, text: removed, cell: cellOf(focus) }],
        redo: [{
          op: 'deleteText',
          s: sectionIndex,
          p: paragraphIndex,
          o: charOffset,
          n: removedCount,
          cell: cellOf(focus),
        }],
      });
      caretAfterCommit = at;
    });
    flushCaret();
    return;
  }

  if (paragraphIndex + 1 >= qParagraphCount(focus)) return;
  mergeIntoPrevious({ ...focus, paragraphIndex: paragraphIndex + 1 }, { ...focus });
}

/// Nhập đoạn vào đoạn trước nó. Hoàn tác phải tự nhớ `paraShapeId`, vì rhwp
/// không trả lại metadata của đoạn bị bỏ.
function mergeIntoPrevious(at, caretBefore) {
  const { sectionIndex, paragraphIndex } = at;
  const shape = qParaPropertiesAt(at);

  commit({ ...at, paragraphIndex: paragraphIndex - 1 }, () => {
    const result = wMergeParagraph(at);
    const after = {
      ...at,
      paragraphIndex: result && typeof result.paraIdx === 'number'
        ? result.paraIdx
        : paragraphIndex - 1,
      charOffset: result && typeof result.charOffset === 'number' ? result.charOffset : 0,
    };
    const undoOps = [{
      op: 'split',
      s: sectionIndex,
      p: after.paragraphIndex,
      o: after.charOffset,
      meta: result && result.removedParaMeta ? JSON.stringify(result.removedParaMeta) : null,
      cell: cellOf(at),
    }];
    if (typeof shape.paraShapeId === 'number') {
      undoOps.push({
        op: 'setParaShapeId',
        s: sectionIndex,
        p: after.paragraphIndex + 1,
        id: shape.paraShapeId,
        cell: cellOf(at),
      });
    }
    pushStep({
      kind: 'merge',
      caretBefore,
      caretAfter: after,
      undo: undoOps,
      redo: [{ op: 'merge', s: sectionIndex, p: paragraphIndex, cell: cellOf(at) }],
    });
    caretAfterCommit = after;
  });
  flushCaret();
}

function splitParagraph() {
  if (!focus) return;
  const range = selectionRange();
  const caretBefore = { ...(range ? range.start : focus) };

  commit(caretBefore, () => {
    let target = caretBefore;
    let deletion = null;
    if (range) {
      deletion = removeRange(range);
      target = deletion.after;
    }
    const result = wSplitParagraph(target, null);
    const after = {
      ...target,
      paragraphIndex: result && typeof result.paraIdx === 'number'
        ? result.paraIdx
        : target.paragraphIndex + 1,
      charOffset: 0,
    };
    const split = {
      op: 'split',
      s: target.sectionIndex,
      p: target.paragraphIndex,
      o: target.charOffset,
      cell: cellOf(target),
    };
    const unsplit = {
      op: 'merge', s: after.sectionIndex, p: after.paragraphIndex, cell: cellOf(target),
    };

    if (deletion) {
      deletion.step.kind = 'replace';
      deletion.step.undo.unshift(unsplit);
      deletion.step.redo.push(split);
      deletion.step.caretAfter = after;
    } else {
      pushStep({
        kind: 'split',
        caretBefore,
        caretAfter: after,
        undo: [unsplit],
        redo: [split],
      });
    }
    caretAfterCommit = after;
  });
  flushCaret();
}

// -------------------------------------------------------------- định dạng

/// Các đoạn mà vùng chọn (hoặc con trỏ) chạm tới, kèm khoảng ký tự trong từng
/// đoạn.
function formatTargets() {
  if (!focus) return [];
  const range = selectionRange();
  if (!range) {
    return [{
      sectionIndex: focus.sectionIndex,
      paragraphIndex: focus.paragraphIndex,
      start: focus.charOffset,
      end: focus.charOffset,
      cell: cellOf(focus),
    }];
  }
  const targets = [];
  for (let p = range.start.paragraphIndex; p <= range.end.paragraphIndex; p += 1) {
    const length = qParagraphLength({ ...range.start, paragraphIndex: p });
    targets.push({
      sectionIndex: range.sectionIndex,
      paragraphIndex: p,
      start: p === range.start.paragraphIndex ? range.start.charOffset : 0,
      end: p === range.end.paragraphIndex ? range.end.charOffset : length,
      cell: cellOf(range.start),
    });
  }
  return targets;
}

/// Chụp `charShapeId` theo từng khúc để hoàn tác trả lại đúng như cũ —
/// `applyCharFormat` không nói nó đã đổi những gì.
function captureCharShapes(target) {
  const runs = [];
  for (let offset = target.start; offset < target.end; offset += 1) {
    const props = qCharPropertiesAt(target, offset);
    const id = props && props.charShapeId;
    if (typeof id !== 'number') continue;
    const last = runs[runs.length - 1];
    if (last && last.id === id && last.end === offset) last.end = offset + 1;
    else runs.push({ id, start: offset, end: offset + 1 });
  }
  return runs;
}

function applyCharFormat(ui) {
  if (!focus || !ui || Object.keys(ui).length === 0) return;

  if (!selectionRange()) {
    // Chưa bôi đen chữ nào: giữ lại, áp cho đoạn gõ tiếp theo — đúng như mọi
    // trình soạn thảo khác.
    pendingCharFormat = { ...(pendingCharFormat || {}), ...ui };
    post('hwp_char_format_pending', Object.keys(ui).join(','));
    publishState();
    return;
  }

  const props = toCharProps(ui);
  if (Object.keys(props).length === 0) return;

  const undoOps = [];
  const redoOps = [];
  for (const target of formatTargets()) {
    if (target.end <= target.start) continue;
    for (const run of captureCharShapes(target)) {
      undoOps.push({
        op: 'setCharShapeId',
        s: target.sectionIndex,
        p: target.paragraphIndex,
        start: run.start,
        end: run.end,
        id: run.id,
        cell: cellOf(target),
      });
    }
    redoOps.push({
      op: 'applyCharFormat',
      s: target.sectionIndex,
      p: target.paragraphIndex,
      start: target.start,
      end: target.end,
      props,
      cell: cellOf(target),
    });
  }
  if (redoOps.length === 0) return;

  const at = { ...focus };
  commit(at, () => {
    for (const cmd of redoOps) exec(cmd);
    pushStep({ kind: 'charFormat', caretBefore: at, caretAfter: at, undo: undoOps, redo: redoOps });
  });
  drawOverlays();
  publishState();
}

function applyParaFormat(ui) {
  if (!focus || !ui) return;
  const props = {};
  if (typeof ui.alignment === 'string') props.alignment = ui.alignment;
  if (typeof ui.lineSpacing === 'number') props.lineSpacing = ui.lineSpacing;
  if (Object.keys(props).length === 0) return;

  const undoOps = [];
  const redoOps = [];
  for (const target of formatTargets()) {
    const shape = qParaPropertiesAt(target);
    if (typeof shape.paraShapeId === 'number') {
      undoOps.push({
        op: 'setParaShapeId',
        s: target.sectionIndex,
        p: target.paragraphIndex,
        id: shape.paraShapeId,
        cell: cellOf(target),
      });
    }
    redoOps.push({
      op: 'applyParaFormat',
      s: target.sectionIndex,
      p: target.paragraphIndex,
      props,
      cell: cellOf(target),
    });
  }
  if (redoOps.length === 0) return;

  const at = { ...focus };
  commit(at, () => {
    for (const cmd of redoOps) exec(cmd);
    pushStep({ kind: 'paraFormat', caretBefore: at, caretAfter: at, undo: undoOps, redo: redoOps });
  });
  drawOverlays();
  publishState();
}

// ----------------------------------------------------------- báo trạng thái

let statePending = null;

function publishState() {
  if (statePending) return;
  statePending = setTimeout(() => {
    statePending = null;
    sendState();
  }, 100);
}

function sendState() {
  const state = {
    hasCaret: !!focus && editing,
    hasSelection: hasSelection(),
    bold: false,
    italic: false,
    underline: false,
    strikethrough: false,
    fontSizePt: null,
    alignment: null,
    lineSpacing: null,
    canUndo: undoStack.length > 0,
    canRedo: redoStack.length > 0,
    dirty,
    pageIndex: focus ? pageOf(focus) : 0,
    pageCount: pageTotal(),
  };

  if (focus && editing) {
    const range = selectionRange();
    const at = range ? range.start : focus;
    // Ở giữa hai ký tự thì lấy thuộc tính của ký tự bên trái, giống mọi trình
    // soạn thảo: gõ tiếp là nối vào chữ vừa gõ chứ không phải chữ phía sau.
    const probe = range ? at.charOffset : Math.max(0, at.charOffset - 1);
    const char = qCharPropertiesAt(at, probe);
    const para = qParaPropertiesAt(at);
    state.bold = !!char.bold;
    state.italic = !!char.italic;
    state.underline = !!char.underline;
    state.strikethrough = !!char.strikethrough;
    if (typeof char.fontSize === 'number') state.fontSizePt = char.fontSize / HWPUNIT_PER_PT;
    if (typeof para.alignment === 'string') state.alignment = para.alignment;
    if (typeof para.lineSpacing === 'number') state.lineSpacing = para.lineSpacing;

    // Định dạng đang chờ thắng: đó là thứ người dùng vừa bấm, dù tài liệu chưa
    // đổi. Nó cùng khoá với `state` nên gộp thẳng được.
    if (pendingCharFormat) Object.assign(state, pendingCharFormat);
  }

  post('hwp_editor_state', JSON.stringify(state));
}

// ------------------------------------------------------------- ô nhập ẩn

function createInput() {
  const element = document.createElement('textarea');
  element.id = 'hwp-input';
  element.setAttribute('autocapitalize', 'off');
  element.setAttribute('autocorrect', 'off');
  element.setAttribute('autocomplete', 'off');
  element.setAttribute('spellcheck', 'false');

  element.addEventListener('beforeinput', (event) => {
    // Trong lúc tổ hợp thì để yên cho IME: chặn ở đây là chặn cả bộ gõ.
    if (composing) return;
    // Bàn phím mềm mỗi hãng bắn một kiểu khác nhau; đây là chỗ duy nhất nhìn
    // thấy chúng, nên log lại để còn lần được khi một phím nào đó không ăn.
    post('hwp_input', event.inputType);
    event.preventDefault();
    switch (event.inputType) {
      case 'insertText':
      case 'insertReplacementText':
        if (event.data) typeText(event.data);
        break;
      case 'insertFromPaste': {
        // Dán không mang chữ trong `data`; nó nằm trong dataTransfer.
        const pasted = event.data
          || (event.dataTransfer && event.dataTransfer.getData('text/plain'));
        if (pasted) typeText(pasted);
        break;
      }
      case 'insertParagraph':
      case 'insertLineBreak':
        splitParagraph();
        break;
      case 'deleteContentBackward':
      case 'deleteWordBackward':
      case 'deleteSoftLineBackward':
        deleteBackward();
        break;
      case 'deleteContentForward':
      case 'deleteWordForward':
        deleteForward();
        break;
      default:
        break;
    }
    resetInput();
  });

  // Chạy khi `preventDefault` không được tôn trọng. Nạp lại ký tự đệm, nếu
  // không lần bấm xoá kế tiếp rơi vào ô rỗng.
  element.addEventListener('input', () => {
    if (!composing) resetInput();
  });

  element.addEventListener('compositionstart', () => {
    composing = true;
    preedit = '';
  });

  element.addEventListener('compositionupdate', (event) => {
    preedit = event.data || '';
    drawOverlays();
  });

  element.addEventListener('compositionend', (event) => {
    composing = false;
    const text = event.data || '';
    preedit = '';
    resetInput();
    if (text) typeText(text);
    else drawOverlays();
  });

  element.addEventListener('keydown', (event) => {
    if (composing || !focus) return;
    const extend = event.shiftKey;
    const range = selectionRange();

    switch (event.key) {
      // Phím xoá đi qua `beforeinput`, đừng xử lý ở đây — từng thêm đường dự
      // phòng hẹn giờ và nó xoá mất hai ký tự mỗi lần bấm.
      case 'ArrowLeft':
        event.preventDefault();
        if (!extend && range) setCaret(range.start);
        else if (extend) extendTo(stepHorizontal(focus, -1));
        else setCaret(stepHorizontal(focus, -1));
        break;
      case 'ArrowRight':
        event.preventDefault();
        if (!extend && range) setCaret(range.end);
        else if (extend) extendTo(stepHorizontal(focus, 1));
        else setCaret(stepHorizontal(focus, 1));
        break;
      case 'ArrowUp':
        event.preventDefault();
        moveVertical(-1, extend);
        break;
      case 'ArrowDown':
        event.preventDefault();
        moveVertical(1, extend);
        break;
      case 'Home':
        event.preventDefault();
        moveToLineEdge(false, extend);
        break;
      case 'End':
        event.preventDefault();
        moveToLineEdge(true, extend);
        break;
      default:
        break;
    }
  });

  document.body.appendChild(element);
  input = element;
  resetInput();
  return element;
}

/// Trả ô nhập về trạng thái chuẩn: đúng một ký tự đệm, con trỏ ở sau nó.
function resetInput() {
  if (!input || composing) return;
  if (input.value !== INPUT_FILLER) input.value = INPUT_FILLER;
  try {
    input.setSelectionRange(INPUT_FILLER.length, INPUT_FILLER.length);
  } catch (_) {
    // Một số bàn phím từ chối đặt vùng chọn khi ô chưa được chọn; bỏ qua.
  }
}

/// Bàn phím iOS chỉ lên khi `focus()` chạy **trong** một cử chỉ của người dùng.
function focusInput() {
  if (!input) input = createInput();
  if (document.activeElement !== input) input.focus({ preventScroll: true });
  resetInput();
}

function moveInputToCaret() {
  if (!input) return;
  const rect = caretRect();
  if (!rect) return;
  const wrap = pageWrap(rect.pageIndex);
  if (!wrap) return;
  const geom = pageGeometry(wrap);
  input.style.left = `${geom.rect.left + rect.x * geom.scale}px`;
  input.style.top = `${geom.rect.top + rect.y * geom.scale}px`;
}

/// Chừa chỗ ở đáy đúng bằng phần bị che. Web view không tự co khi bàn phím lên
/// (`resizeToAvoidBottomInset: false`), nên phải tự bù.
function applyBottomInset() {
  const inset = keyboardInset + chromeInset;
  pagesEl.style.paddingBottom = inset > 0 ? `${12 + inset}px` : '';
  scrollCaretIntoView();
}

function scrollCaretIntoView() {
  const rect = caretRect();
  if (!rect) return;
  const wrap = pageWrap(rect.pageIndex);
  if (!wrap) return;
  const geom = pageGeometry(wrap);
  const top = geom.rect.top + rect.y * geom.scale;
  const bottom = top + rect.height * geom.scale;
  const visibleBottom = window.innerHeight - keyboardInset - chromeInset - 16;

  if (bottom > visibleBottom) window.scrollBy(0, bottom - visibleBottom);
  else if (top < 16) window.scrollBy(0, top - 16);
}

// ------------------------------------------------------------------- chạm

let pressTimer = null;
let pressStart = null;
let selecting = false;

function hitAt(wrap, event) {
  const page = Number(wrap.dataset.page);
  const point = pagePoint(wrap, event);
  let hit;
  try {
    hit = ask(() => doc.hitTest(page, point.x, point.y), null);
  } catch (error) {
    post('hwp_hit_test_failed', (error && error.message) || String(error));
    return null;
  }
  if (!hit || typeof hit.paragraphIndex !== 'number') {
    post('hwp_hit_test_empty', `page=${page} x=${Math.round(point.x)} y=${Math.round(point.y)}`);
    return null;
  }
  // Hộp chữ, đầu/chân trang, chú thích: mỗi thứ một hệ toạ độ riêng — chưa làm.
  if (hit.isTextBox) {
    post('hwp_edit_region_unsupported', 'textbox');
    return null;
  }

  // Bảng lồng nhau (`cellPath` dài hơn 1) chưa đỡ được: `*InCell` chỉ nhận một
  // tầng, phải dùng bản `*ByPath`.
  const path = Array.isArray(hit.cellPath) ? hit.cellPath : [];
  const inCell = path.length > 0
    || (typeof hit.parentParaIndex === 'number' && hit.parentParaIndex !== NO_CELL);
  if (inCell) {
    if (path.length > 1) {
      post('hwp_edit_region_unsupported', `nested_cell_depth=${path.length}`);
      return null;
    }
    if (typeof hit.parentParaIndex !== 'number'
        || typeof hit.controlIndex !== 'number'
        || typeof hit.cellIndex !== 'number'
        || typeof hit.cellParaIndex !== 'number') {
      post('hwp_edit_region_unsupported', 'cell_fields_missing');
      return null;
    }
    return {
      sectionIndex: hit.sectionIndex,
      paragraphIndex: hit.cellParaIndex,
      charOffset: hit.charOffset,
      cell: {
        parentParaIndex: hit.parentParaIndex,
        controlIndex: hit.controlIndex,
        cellIndex: hit.cellIndex,
      },
    };
  }

  return {
    sectionIndex: hit.sectionIndex,
    paragraphIndex: hit.paragraphIndex,
    charOffset: hit.charOffset,
  };
}

/// Ranh giới từ, đếm thẳng trên chuỗi — khớp vì `charOffset` cũng là code unit
/// UTF-16, đỡ phải bắc cầu qua hệ toạ độ của `getWordStarts`.
function wordAt(position) {
  const text = qParagraphText(position);
  if (!text) return null;
  const isWord = (ch) => !!ch && !/[\s.,;:!?()[\]{}"'`~/\\|<>]/.test(ch);

  let start = Math.min(position.charOffset, text.length);
  if (!isWord(text[start]) && start > 0 && isWord(text[start - 1])) start -= 1;
  if (!isWord(text[start])) return null;

  let end = start;
  while (start > 0 && isWord(text[start - 1])) start -= 1;
  while (end < text.length && isWord(text[end])) end += 1;
  return {
    start: { ...position, charOffset: start },
    end: { ...position, charOffset: end },
  };
}

function onPointerDown(event) {
  if (!editing || !doc) return;
  const wrap = event.target.closest && event.target.closest('.page');
  if (!wrap) return;

  pressStart = { x: event.clientX, y: event.clientY, wrap, pointerId: event.pointerId };
  selecting = false;
  clearTimeout(pressTimer);

  // Chạm là đặt con trỏ, kéo là cuộn trang — nên bôi đen phải đi qua giữ lâu,
  // nếu không thì trong chế độ sửa không cuộn được nữa.
  pressTimer = setTimeout(() => {
    pressTimer = null;
    const position = hitAt(wrap, event);
    if (!position) return;
    const word = wordAt(position);
    anchor = word ? word.start : { ...position };
    focus = word ? word.end : { ...position };
    selecting = true;
    try { wrap.setPointerCapture(event.pointerId); } catch (_) {}
    focusInput();
    drawOverlays();
    publishState();
    post('hwp_selection_started', `para=${position.paragraphIndex} off=${position.charOffset}`);
  }, LONG_PRESS_MS);
}

/// Kéo qua khỏi mép trang: tìm trang đang nằm dưới ngón tay.
function hitAtAnyPage(event) {
  const element = document.elementFromPoint(event.clientX, event.clientY);
  const wrap = element && element.closest ? element.closest('.page') : null;
  return wrap ? hitAt(wrap, event) : null;
}

function onPointerMove(event) {
  if (!pressStart) return;
  if (pressTimer) {
    // Di chuyển trước khi hết giờ giữ nghĩa là đang cuộn, không phải bôi đen.
    if (Math.hypot(event.clientX - pressStart.x, event.clientY - pressStart.y) > 10) {
      clearTimeout(pressTimer);
      pressTimer = null;
      pressStart = null;
    }
    return;
  }
  if (!selecting) return;
  // Tìm trang dưới ngón tay trước — `hitTest` với toạ độ ngoài trang trả về vị
  // trí sai chứ không phải null.
  const position = hitAtAnyPage(event) || hitAt(pressStart.wrap, event);
  if (position) extendTo(position);
}

function onPointerUp(event) {
  if (!pressStart) return;
  const { wrap } = pressStart;

  if (pressTimer) {
    clearTimeout(pressTimer);
    pressTimer = null;
    const position = hitAt(wrap, event);
    if (position) {
      focusInput();
      setCaret(position);
      post('hwp_caret_placed', `para=${position.paragraphIndex} off=${position.charOffset}`);
    }
  }
  if (selecting) {
    try { wrap.releasePointerCapture(event.pointerId); } catch (_) {}
    selecting = false;
    moveInputToCaret();
  }
  pressStart = null;
}

// ---------------------------------------------------------------- xuất tệp

function exportDocument() {
  try {
    // Hancom mở tệp lên là đặt con trỏ ở chỗ đã ghi trong tài liệu; ghi lại
    // chỗ người dùng đang đứng thì mở lại thấy đúng đó.
    if (focus) {
      doc.setCaretPosition(focus.sectionIndex, focus.paragraphIndex, focus.charOffset);
    }
    // Dùng bản `WithReport` để có báo cáo nội dung bị mất khi ghi — thứ duy
    // nhất cho biết ta có đang âm thầm làm hỏng tài liệu không.
    const result = doc.exportHwpWithReport();
    const loss = result.contentLoss();
    const bytes = result.takeBytes();
    // Chia nhỏ khi mã hoá: `fromCharCode.apply` với cả tệp một lần tràn stack.
    let binary = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    post('hwp_editor_export_ready', `bytes=${bytes.length}`);
    window.webkit?.messageHandlers?.hwpViewer?.postMessage({
      event: 'hwp_editor_export_data',
      detail: btoa(binary),
      contentLoss: loss || '',
    });
  } catch (error) {
    const message = (error && (error.stack || error.message)) || String(error);
    post('hwp_editor_export_failed', message);
    window.webkit?.messageHandlers?.hwpViewer?.postMessage({
      event: 'hwp_editor_export_failed',
      detail: String((error && error.message) || error),
    });
  }
}

// ----------------------------------------------------------------- công khai

/// Vẽ lại sau khi xoay xong. Giữ tham chiếu để `detach` gỡ được — một hàm ẩn
/// danh thì `removeEventListener` không có gì để gỡ, và mỗi lần mở tệp lại
/// chồng thêm một listener nữa lên `window`.
function onOrientationChange() {
  setTimeout(drawOverlays, 250);
}

/// Gỡ trình soạn thảo khỏi tài liệu đang mở và trả mọi trạng thái về mặc định.
///
/// Có mặt vì trang vỏ **được dùng lại**: mở tệp thứ hai không nạp lại trang,
/// nên nếu không dọn ở đây thì listener, khung trang, ngăn xếp hoàn tác và con
/// trỏ của tệp cũ sẽ đi theo sang tệp mới.
export function detach() {
  if (!pagesEl) return;

  pagesEl.removeEventListener('pointerdown', onPointerDown);
  pagesEl.removeEventListener('pointermove', onPointerMove);
  pagesEl.removeEventListener('pointerup', onPointerUp);
  pagesEl.removeEventListener('pointercancel', onPointerUp);
  window.removeEventListener('resize', drawOverlays);
  window.removeEventListener('orientationchange', onOrientationChange);

  if (pageObserver) {
    pageObserver.disconnect();
    pageObserver = null;
  }
  mounted.clear();
  pagesEl.replaceChildren();
  pagesEl.style.paddingBottom = '';
  // Tệp mới phải mở ở trang đầu, chứ không phải ở chỗ đang cuộn dở của tệp cũ.
  window.scrollTo(0, 0);

  if (statePending) {
    clearTimeout(statePending);
    statePending = null;
  }
  if (pressTimer) {
    clearTimeout(pressTimer);
    pressTimer = null;
  }
  pressStart = null;
  selecting = false;

  editing = false;
  document.body.classList.remove('editing');
  dirty = false;
  anchor = null;
  focus = null;
  preferredX = -1;
  pendingCharFormat = null;
  composing = false;
  preedit = '';
  keyboardInset = 0;
  chromeInset = 0;
  cursorModel = null;
  caretAfterCommit = null;
  fontChecked = false;
  objectsLogged = false;
  undoStack.length = 0;
  redoStack.length = 0;

  // Ô nhập sống lâu hơn tài liệu — dựng lại nó là mất bàn phím đang lên — nên
  // chỉ đưa về trạng thái sạch.
  if (input) {
    input.blur();
    resetInput();
  }

  // `HwpDocument` giữ bộ nhớ bên trong WASM; bỏ tham chiếu JS thôi thì phần đó
  // không được thu hồi. Tệp 8MB mở vài lần là đủ để bị hệ thống kết liễu.
  const stale = doc;
  doc = null;
  try {
    stale?.free?.();
  } catch (error) {
    report('hwp_document_free_failed', String((error && error.message) || error));
  }

  delete window.__rhwpEditor;
}

/// Gắn trình soạn thảo vào tài liệu đã parse. Gọi lại được: mỗi lần mở tệp mới
/// trên cùng trang vỏ, nó tự dọn tài liệu trước đó.
export function attach(hwpDocument, container, reporter) {
  detach();

  doc = hwpDocument;
  pagesEl = container;
  report = reporter || (() => {});

  pagesEl.addEventListener('pointerdown', onPointerDown);
  pagesEl.addEventListener('pointermove', onPointerMove);
  pagesEl.addEventListener('pointerup', onPointerUp);
  pagesEl.addEventListener('pointercancel', onPointerUp);
  window.addEventListener('resize', drawOverlays);
  window.addEventListener('orientationchange', onOrientationChange);

  // Swift gọi xuống qua `evaluateJavaScript`.
  window.__rhwpEditor = {
    setEditing(enabled) {
      editing = !!enabled;
      document.body.classList.toggle('editing', editing);
      if (!editing) {
        // Tắt chế độ sửa là **bỏ mọi thay đổi chưa lưu** — chúng chỉ nằm trong
        // trình soạn thảo, không nằm trong tệp. Ngăn xếp hoàn tác đi theo.
        anchor = null;
        focus = null;
        preedit = '';
        composing = false;
        pendingCharFormat = null;
        undoStack.length = 0;
        redoStack.length = 0;
        dirty = false;
        if (input) input.blur();
        clearOverlays();
        // Native ngừng báo chiều cao bàn phím khi không còn sửa, nên phần chừa
        // chỗ cho nó phải tự trả về ở đây.
        keyboardInset = 0;
        chromeInset = 0;
        applyBottomInset();
      }
      cursorModel = null;
      fontChecked = false;
      objectsLogged = false;
      publishState();
      post('hwp_edit_mode', `enabled=${editing}`);
    },
    applyCharFormat(json) {
      applyCharFormat(parse(json, null) || {});
    },
    applyParaFormat(json) {
      applyParaFormat(parse(json, null) || {});
    },
    undo,
    redo,
    goToPage(index) {
      showPage(index);
    },
    setKeyboardInset(pixels) {
      keyboardInset = Number(pixels) || 0;
      applyBottomInset();
    },
    setChromeInset(pixels) {
      chromeInset = Number(pixels) || 0;
      applyBottomInset();
    },
    export: exportDocument,
  };

  observePages();
  return { renderPages };
}
