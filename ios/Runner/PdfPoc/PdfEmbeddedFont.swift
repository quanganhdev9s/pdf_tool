import CoreGraphics
import CoreText
import PDFKit
import UIKit

/// Con chữ thật của trang, lấy thẳng từ file.
///
/// PDFKit trả về một `UIFont` cho mỗi run, nhưng đó là **phỏng đoán**: nó đọc
/// `/FontDescriptor`, thấy metrics giống Helvetica thì đưa ra Helvetica. Với
/// font nhúng — thứ chiếm phần lớn tài liệu thật — phỏng đoán đó vứt đi đúng con
/// chữ mà tác giả đã chọn, và người dùng thấy cả block đổi mặt chữ ngay lúc
/// chạm vào, trước khi gõ ký tự nào.
///
/// Đây là đường lấy con chữ thật: rút stream font ra khỏi file, đăng ký với
/// CoreText, rồi vẽ bằng chính nó.
///
/// Cái giá là **subset**. Font nhúng trong PDF hầu hết chỉ mang glyph mà trang
/// đó dùng tới, nên gõ thêm một ký tự chưa từng xuất hiện là ra ô vuông. Caller
/// phải kiểm phủ trước khi dùng — `PdfTextEditManager.covers(_:_:)` làm việc đó,
/// và lui về face của PDFKit khi không đủ.
enum PdfEmbeddedFont {
  /// Font đã đăng ký, theo `/BaseFont`. Giá trị là tên PostScript **thật** của
  /// font sau khi CoreText nạp — không nhất thiết trùng `/BaseFont`.
  private static var registered: [String: String] = [:]

  /// `/BaseFont` đã thử và hỏng. Không thử lại: mỗi lần hỏng tốn một lần chép
  /// cả stream font ra khỏi file.
  private static var refused: Set<String> = []

  /// Quên hết. Gọi khi mở tài liệu khác — `/BaseFont` do máy sinh
  /// (`font0000000030346311`) là duy nhất trong phạm vi một file, không phải
  /// giữa các file.
  static func forgetAll() {
    registered.removeAll()
    refused.removeAll()
  }

  /// Font nhúng của một resource trên trang, ở cỡ đã cho. Nil khi trang không
  /// nhúng font đó, hoặc khi CoreText không nạp được nó.
  static func font(forResource resource: String, on page: PDFPage, size: CGFloat) -> UIFont? {
    guard let pageRef = page.pageRef,
          let baseFont = baseFontName(of: resource, on: pageRef) else { return nil }

    if let name = registered[baseFont] { return UIFont(name: name, size: size) }
    guard !refused.contains(baseFont) else { return nil }

    guard let embedded = embeddedData(of: resource, on: pageRef) else {
      refused.insert(baseFont)
      return nil
    }
    let data = embedded.data
    guard let provider = CGDataProvider(data: data as CFData),
          let cgFont = CGFont(provider),
          let postScript = cgFont.postScriptName as String? else {
      refused.insert(baseFont)
      logPdfEvent("embedded_font_unreadable", "baseFont=\(baseFont) bytes=\(data.count)")
      return nil
    }

    // Đăng ký là toàn tiến trình, và font đã đăng ký thì không gỡ ra — gỡ trong
    // lúc còn chữ đang vẽ bằng nó là đường ngắn nhất tới một trang trống.
    var error: Unmanaged<CFError>?
    if !CTFontManagerRegisterGraphicsFont(cgFont, &error) {
      // Đã có sẵn thì coi như thành công: một tài liệu có thể nhúng cùng một
      // font dưới nhiều resource, và lần đăng ký đầu đã đủ.
      var code: CFIndex?
      if let failure = error?.takeRetainedValue() { code = CFErrorGetCode(failure) }
      guard code == CTFontManagerError.alreadyRegistered.rawValue else {
        refused.insert(baseFont)
        logPdfEvent(
          "embedded_font_register_failed",
          "baseFont=\(baseFont) postScript=\(postScript) code=\(code.map(String.init) ?? "nil")"
        )
        return nil
      }
    }

    registered[baseFont] = postScript
    logPdfEvent(
      "embedded_font_registered",
      "baseFont=\(baseFont) postScript=\(postScript) kind=\(embedded.kind) bytes=\(data.count)"
    )
    return UIFont(name: postScript, size: size)
  }

  // MARK: - Đọc file

  /// `/BaseFont` của resource, đã bỏ tiền tố subset.
  private static func baseFontName(of resource: String, on page: CGPDFPage) -> String? {
    guard let font = fontObject(named: resource, on: page) else { return nil }
    var name: UnsafePointer<Int8>?
    guard CGPDFDictionaryGetName(font, "BaseFont", &name), let name else { return nil }
    let full = String(cString: name)
    // `ABCDEF+Helvetica`: sáu chữ cái rồi dấu cộng, chỉ ra subset chứ không chỉ
    // ra con chữ.
    return full.count > 7 && full[full.index(full.startIndex, offsetBy: 6)] == "+"
      ? String(full.dropFirst(7))
      : full
  }

  /// Byte của font, từ `/FontFile2` hoặc `/FontFile3`.
  ///
  /// `/FontFile` (Type 1 gốc) bị bỏ qua: `CGFont` không nạp được định dạng đó,
  /// và tài liệu dùng nó ngày nay là hiếm.
  private static func embeddedData(
    of resource: String,
    on page: CGPDFPage
  ) -> (data: Data, kind: String)? {
    guard let font = fontObject(named: resource, on: page),
          let descriptor = fontDescriptor(of: font) else { return nil }

    for key in ["FontFile2", "FontFile3"] {
      var stream: CGPDFStreamRef?
      guard CGPDFDictionaryGetStream(descriptor, key, &stream), let stream else { continue }
      var format = CGPDFDataFormat.raw
      guard let data = CGPDFStreamCopyData(stream, &format) else { continue }
      // Chỉ nhận dữ liệu đã giải nén. `raw` ở đây nghĩa là CoreGraphics đã bỏ
      // filter ra; hai định dạng kia là JPEG/JPEG2000 và không phải font.
      guard format == .raw else { continue }
      return (data as Data, key)
    }
    return nil
  }

  /// Từ điển font của resource. Đi qua `Type0` xuống font con: font ghép mang
  /// descriptor ở `/DescendantFonts`, không mang ở chính nó.
  private static func fontObject(
    named resource: String,
    on page: CGPDFPage
  ) -> CGPDFDictionaryRef? {
    guard let pageDictionary = page.dictionary,
          let fonts = resources(in: pageDictionary, key: "Font") else { return nil }
    var font: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(fonts, resource, &font) else { return nil }
    return font
  }

  private static func fontDescriptor(of font: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
    var descriptor: CGPDFDictionaryRef?
    if CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor), let descriptor {
      return descriptor
    }
    // Type0: descriptor nằm ở font con đầu tiên.
    var descendants: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants),
          let descendants,
          CGPDFArrayGetCount(descendants) > 0 else { return nil }
    var child: CGPDFDictionaryRef?
    guard CGPDFArrayGetDictionary(descendants, 0, &child), let child else { return nil }
    var childDescriptor: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(child, "FontDescriptor", &childDescriptor) else {
      return nil
    }
    return childDescriptor
  }
}
