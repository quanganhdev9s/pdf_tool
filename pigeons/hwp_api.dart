import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/hwp/hwp_api.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Runner/Hwp/Bridge/HwpApi.g.swift',
    // App chỉ có một Swift module, nên file sinh thứ ba không được khai lại
    // `PigeonError` — `PdfPocApi.g.swift` đã khai rồi.
    swiftOptions: SwiftOptions(includeErrorClass: false),
    dartPackageName: 'pdf_tool',
  ),
)
/// Tệp HWP cần mở. [path] là file nguồn hoặc asset key; native tự tạo working
/// copy tạm để reader/editor thao tác.
class HwpDocument {
  HwpDocument({
    required this.path,
    required this.sourceIsAsset,
    required this.fileName,
    required this.fileFormat,
    required this.fileSizeBytes,
  });

  /// File path hoặc Flutter asset key để native copy ra working copy tạm.
  String path;

  /// `true` khi [path] là asset key. Asset không ghi đè được nên Save sẽ tạo
  /// file mới trong store.
  bool sourceIsAsset;

  String fileName;

  /// `hwp` hoặc `hwpx`.
  String fileFormat;
  int fileSizeBytes;
}

/// Trạng thái con trỏ trong trình soạn thảo, đủ để vẽ thanh công cụ.
///
/// Con trỏ và vùng chọn sống trong trang vỏ chứ không trong tài liệu — rhwp
/// không giữ chúng — nên đây là ảnh chụp đẩy ngược lên, không phải nguồn sự
/// thật để ghi xuống.
class HwpEditorState {
  HwpEditorState({
    required this.hasCaret,
    required this.hasSelection,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.strikethrough,
    required this.fontSizePt,
    required this.alignment,
    required this.lineSpacing,
    required this.canUndo,
    required this.canRedo,
    required this.dirty,
    required this.pageIndex,
    required this.pageCount,
  });

  bool hasCaret;
  bool hasSelection;
  bool bold;
  bool italic;
  bool underline;
  bool strikethrough;

  /// Cỡ chữ theo **điểm**. rhwp lưu theo HWPUNIT (pt × 100); phép chia nằm ở
  /// trang vỏ để bên Flutter không phải biết đơn vị của định dạng tệp.
  double? fontSizePt;

  /// `left`, `center`, `right`, `justify` hoặc `distribute`.
  String? alignment;
  double? lineSpacing;
  bool canUndo;
  bool canRedo;

  /// Có thay đổi chưa ghi xuống tệp. Tắt chế độ sửa khi đang bật cờ này là mất
  /// thay đổi.
  bool dirty;

  /// Trang đang hiển thị, đếm từ 0.
  int pageIndex;

  /// Tổng số trang, luôn ít nhất là 1.
  ///
  /// Đổi được **trong lúc sửa**: gõ thêm chữ có thể làm tài liệu nở ra hoặc co
  /// lại một trang, nên thanh lật trang phải đọc lại con số này chứ không nhớ
  /// giá trị lúc mở tệp.
  int pageCount;
}

/// Định dạng chữ cần áp. Khoá nào `null` thì giữ nguyên — bật đậm không được
/// phép lặng lẽ đặt lại cỡ chữ.
class HwpCharFormat {
  HwpCharFormat({
    this.bold,
    this.italic,
    this.underline,
    this.strikethrough,
    this.fontSizePt,
  });

  bool? bold;
  bool? italic;
  bool? underline;
  bool? strikethrough;
  double? fontSizePt;
}

/// Định dạng đoạn cần áp. Cùng quy ước `null` là giữ nguyên như
/// [HwpCharFormat].
class HwpParaFormat {
  HwpParaFormat({this.alignment, this.lineSpacing});

  String? alignment;
  double? lineSpacing;
}

/// Kết quả một lần ghi tài liệu xuống đĩa.
class HwpSaveResult {
  HwpSaveResult({
    required this.ok,
    this.contentLoss,
    this.error,
    this.savedPath,
    this.savedAsFallback,
  });

  bool ok;

  /// Báo cáo phần nội dung trình xuất phải bỏ đi, lấy từ
  /// `exportHwpWithReport`. Report JSON có thể không rỗng nhưng `count: 0`,
  /// nên UI phải đọc nội dung thay vì chỉ kiểm tra chuỗi rỗng.
  String? contentLoss;

  String? error;

  /// Đường dẫn tệp thật sự đã được ghi. Có thể khác tệp đang mở nếu native
  /// không replace được file gốc và phải lưu thành bản sao.
  String? savedPath;

  /// `true` khi lần lưu này ghi ra bản sao thay vì ghi đè file đang mở.
  bool? savedAsFallback;
}

/// Kết quả một lượt tìm. [index] đếm từ 1 để hiện thẳng lên giao diện; `0`
/// nghĩa là không có kết quả nào.
class HwpSearchResult {
  HwpSearchResult({required this.index, required this.total});

  int index;
  int total;
}

@HostApi()
abstract class HwpHostApi {
  /// Nạp tệp vào trình xem đang gắn trên màn hình.
  void loadDocument(String path, bool sourceIsAsset);

  /// Chuyển sang chế độ sửa, hoặc quay lại chỉ xem.
  ///
  /// Tắt sẽ **bỏ mọi thay đổi chưa lưu** — chúng chỉ nằm trong trình soạn
  /// thảo, không nằm trong tệp.
  void setEditingEnabled(bool enabled);

  /// Ghi tài liệu đang sửa đè lên tệp đang mở.
  ///
  /// Trả về ngay; việc xuất chạy bất đồng bộ trong trang vỏ và kết quả về qua
  /// `onEditsSaved`.
  void saveEdits();

  /// Áp định dạng chữ lên vùng đang chọn.
  ///
  /// Không có vùng chọn thì định dạng được giữ lại và áp cho đoạn chữ gõ tiếp
  /// theo, giống mọi trình soạn thảo khác.
  void applyCharFormat(HwpCharFormat format);

  /// Áp định dạng lên đoạn văn đang chứa con trỏ, hoặc mọi đoạn mà vùng chọn
  /// chạm tới.
  void applyParaFormat(HwpParaFormat format);

  /// Cho trang vỏ biết Flutter đang che mất bao nhiêu điểm ở đáy web view —
  /// tức chiều cao thanh công cụ nổi.
  ///
  /// Bàn phím thì native tự đo được; chỗ này chỉ nói về phần giao diện của
  /// Flutter, thứ native không nhìn thấy. Con trỏ phải tránh cả hai.
  void setChromeInset(double pixels);

  /// Hoàn tác bước sửa gần nhất. Ngăn xếp nằm trong trang vỏ và mất khi tắt
  /// chế độ sửa.
  void undo();

  void redo();

  /// Lật tới trang `pageIndex`, đếm từ 0. Chỉ số ngoài phạm vi bị kẹp về đầu
  /// hoặc cuối chứ không báo lỗi.
  void goToPage(int pageIndex);

  /// Tìm kết quả kế tiếp hoặc trước đó. Cả tài liệu được tô, kết quả hiện tại
  /// tô đậm hơn.
  @async
  HwpSearchResult find(String query, bool forward);

  void clearSearch();

  /// Chia sẻ tệp đang mở qua bảng chia sẻ của hệ thống.
  void share();

  /// Nhả trình xem và xoá bản sao cục bộ.
  void close();
}

@FlutterApi()
abstract class HwpFlutterApi {
  /// Con trỏ, vùng chọn hoặc nội dung vừa đổi.
  void onEditorStateChanged(HwpEditorState state);

  /// Một lần ghi tài liệu đã xong — thành công hay không.
  void onEditsSaved(HwpSaveResult result);
}
