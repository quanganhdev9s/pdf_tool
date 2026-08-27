# Bản vá rhwp

`HwpViewer/rhwp_bg.wasm` **không phải bản gốc** — nó được build từ rhwp
v0.8.4 kèm ba bản vá ở đây. Nếu nâng cấp rhwp mà bỏ qua thư mục này, cả ba lỗi
dưới đây sẽ quay lại.

- **Gốc:** [edwardkim/rhwp](https://github.com/edwardkim/rhwp) v0.8.4, commit `496333b` (2026-08-12), MIT
- **Chưa gửi upstream.** Nhánh `devel` của họ đi trước `main` vài nghìn dòng và
  đang sửa cùng khu vực (PR #6017, issue #5809), nên bản vá này nhiều khả năng
  xung đột khi nâng cấp.

## Ba lỗi được vá

Cả ba đều nằm ở `reflow_line_segs_impl` trong `src/renderer/composer/line_breaking.rs`.

Bối cảnh chung: HWP lưu sẵn `lineseg` — vị trí, chiều cao và bề rộng từng dòng
do Hancom tính. Chỉ xem thì rhwp phát lại đúng số đó nên khớp bản gốc. Vừa sửa
một ký tự là nó vứt lineseg đi và tự tính lại, và ba thông tin dưới đây bị mất.

### 1. Chiều cao dòng không tính theo metric font

`font_size_to_line_height` trả về đúng cỡ chữ, bỏ qua metric dọc của font. Công
thức đúng:

```
line_height    = fontSize × (ascender − descender + lineGap) / unitsPerEm
baseline_ratio = (ascender + lineGap) / (ascender − descender + lineGap)
```

| Font | Công thức | Hancom thực đo |
|---|---|---|
| Arial | 1.1499 / 0.8157 | 1.1500 / 0.8158 |
| Font Hàn (em 1000, asc 800, desc −200) | 1.0000 | 1.0000 |

Vì đa số tài liệu Hàn cho tỉ lệ đúng bằng 1.0 nên lỗi này không lộ ra ở đó —
chỉ tài liệu dùng font Latin mới bị. Triệu chứng: gõ một ký tự là đoạn đó co
~15%, kéo theo tụt trang.

`src/renderer/font_line_metrics.rs` (mới) giữ bảng metric `hhea`. Font không có
trong bảng dùng mặc định `1.0` / `0.85` — **giữ nguyên hành vi cũ**, không hồi quy.

Kiểm chứng trên 20 tài liệu: 1 tệp cải thiện 0% → 100% số đoạn khớp, 18 tệp
không đổi, 1 tệp xấu đi nhẹ (93.7% → 91.9%, các đoạn trộn Hàn–Latin).

### 2. Mất việc chữ né ảnh

Một dòng thị giác cạnh ảnh `wrap=square` được lưu thành **nhiều lineseg cùng
`vertical_pos`**, mỗi cái có `segment_width` riêng. Reflow cũ ngắt mọi dòng theo
một bề rộng phẳng, nên chữ chạy xuyên qua ảnh.

Bản vá gộp theo `vertical_pos`, lấy đoạn rộng nhất, và **chỉ áp dụng khi các
dòng khác bề rộng nhau** — dấu hiệu đang né vật cản. Đo trên 39 tài liệu: chỉ
4.51% số đoạn nhiều dòng đi vào đường mới.

Mép phải các dòng cạnh ảnh (ảnh bắt đầu ở `x=478`): `467 → 676` (đè lên ảnh)
thành `467 → 461` (né đúng), và ổn định qua nhiều lần sửa.

> Đã thử cấp cho khe hẹp bên kia ảnh một ô chữ riêng, và **sai**: khe 586
> HWPUNIT (≈5.9pt) gần như không chứa được chữ nào, số đoạn dao động 29 ↔ 21
> qua mỗi lần sửa.

### 3. Mất thụt lề

`make_line_seg` dựng lineseg bằng `..Default::default()` nên `column_start` về 0.
Với nhiều tài liệu, phần thụt ngang **chỉ nằm ở lineseg** — `marginLeft` và
`indent` trong paraShape vẫn bằng 0 — nên cả đoạn nhảy về lề trái.

Thực đo, chèn đúng một ký tự: `x = 153.2 → 75.6` (dịch 77.6px). Sau khi vá:
`153.2 → 153.2`. Đoạn không thụt lề không đổi.

Khôi phục `column_start` **không kèm điều kiện** (khác lỗi 2), vì đoạn thụt lề
bình thường không có "bề rộng khác nhau" nào để kích hoạt. Dòng vượt quá số dòng
đã lưu thì lấy theo dòng cuối, không về 0.

## Build lại

```bash
git clone --depth 1 --branch v0.8.4 https://github.com/edwardkim/rhwp.git
cd rhwp
git apply /duong/dan/0001-line-breaking-fixes.patch
wasm-pack build --release --target web --out-dir /tmp/rhwp-out
cp /tmp/rhwp-out/rhwp.js /tmp/rhwp-out/rhwp_bg.wasm <repo>/ios/Runner/PdfPoc/Hwp/HwpViewer/
```

Cần `rustup` và `wasm-pack`. Repo tự ghim toolchain qua `rust-toolchain.toml`.

Artifact ra phải là **7.7MB**, và `rhwp.js` **giống hệt từng byte** với bản đang
có trong repo — đó là cách xác nhận môi trường build tái tạo đúng upstream.

## `0002-diagnostic-tools.patch`

11 công cụ đo trong `examples/`, **không cần để build**. Chúng đã dùng để trả lời
những câu mà đọc code không trả lời được: bảng bề rộng Arial có sai không (không
— lệch 0.0% so với WebKit), Hancom lưu `line_height` bằng bao nhiêu, phạm vi ảnh
hưởng của lỗi 2 là 4.51%. Giữ lại cho lần điều tra sau.

## Còn tồn

- **Gõ vào đoạn có ảnh vẫn nhảy một lần** (10 → 11 dòng thị giác). Nguyên nhân
  **không phải** đo chữ sai: đã đối chiếu với Arial thật trong WebKit, rhwp lệch
  ≤0.2%. Với Arial 11pt thật thì chỗ đó chỉ chứa được 56 ký tự, rhwp nhét 60,
  còn Hancom nhét 65 — tức tài liệu mang một bố cục **không tái lập được bằng
  Arial**, nhiều khả năng Hancom đã thay font khác khi tạo tệp.
- **Chèn ảnh mới trong app sẽ không có wrap.** Bản vá chỉ *giữ lại* việc né ảnh
  đã có sẵn trong tệp, không *tạo ra* nó — rhwp chưa cài đặt ngắt dòng né vật cản.
