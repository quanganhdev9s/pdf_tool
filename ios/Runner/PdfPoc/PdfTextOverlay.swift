import PDFKit
import UIKit

/// Vẽ chữ thay thế thành một trang PDF riêng, để qpdf ghép vào trang gốc.
///
/// Dùng CoreGraphics chứ không phải PDFKit hay qpdf vì `CGPDFContext` **tự nhúng
/// font** nó đã dùng, kèm encoding — kể cả font dự phòng CoreText với sang.
/// PDFKit chỉ đưa ra được freeText, mà freeText với font standard-14 bị khoá vào
/// WinAnsi nên rụng hết dấu tiếng Việt. qpdf thì ghi object, không ghi glyph.
extension NSAttributedString.Key {
  /// Font của run trong **đơn vị trang**, đặt cạnh `.font`.
  ///
  /// `.font` là bản đã nhân zoom để hiện lên màn hình; cái này là bản sẽ ghi
  /// vào file. Hai bản tách nhau vì sự thật gốc không được phép đi qua phép
  /// nhân đó: nhân rồi chia nhiều lần thì cỡ chữ trôi, và ô nhập bị dựng lại
  /// mỗi lần người dùng zoom.
  ///
  /// `UITextView` giữ nguyên attribute nó không hiểu khi người dùng sửa chữ, và
  /// kế thừa nó vào `typingAttributes` — nên gõ vào giữa một đoạn đậm thì chữ
  /// mới mang theo đúng font trang của đoạn đó, không cần ai ánh xạ range.
  static let pdfPageFont = NSAttributedString.Key("pdfPageFont")
}

enum PdfTextOverlay {
  /// One block of replacement text, in page space.
  struct Request {
    var pageIndex: Int
    /// Hộp bố cục. Ascender dòng đầu rơi đúng `bounds.maxY` — chỗ chữ cũ nằm.
    var bounds: CGRect
    /// Chữ thay thế, **đơn vị trang**, mang run font của chính nó.
    var attributed: NSAttributedString

    /// Chiều cao tối đa chữ được chiếm, tính từ `bounds` xuống. Nil là thả tự do.
    ///
    /// Lưới an toàn thôi: `PdfTextEditManager` chặn không cho gõ quá sức chứa,
    /// nên đến đây chữ đã vừa. Cắt ở render là để một khung bị kéo nhỏ lại sau
    /// khi gõ không lấn được sang block dưới.
    var maxHeight: CGFloat?

  }

  enum Failure: Error, LocalizedError {
    /// Trang xoay. Từ chối chứ không xấp xỉ: content stream viết trong không
    /// gian chưa xoay, đặt chữ theo toạ độ đã xoay sẽ ra thẳng trên máy và nằm
    /// ngang trong file.
    case pageRotated(pageIndex: Int, degrees: Int)
    case pageMissing(pageIndex: Int)
    case contextFailed(URL)

    var errorDescription: String? {
      switch self {
      case let .pageRotated(pageIndex, degrees):
        return "Page \(pageIndex) is rotated \(degrees)°, which text placement does not handle yet."
      case let .pageMissing(pageIndex):
        return "Page \(pageIndex) is not in this document."
      case let .contextFailed(url):
        return "Could not open a PDF context at \(url.path)."
      }
    }
  }

  /// Thay cho "cao bao nhiêu cũng được". Không dùng `greatestFiniteMagnitude`
  /// vì nó cho ra NaN.
  static let unboundedHeight: CGFloat = 100_000

  /// Ghi overlay, trả về trang đích của từng trang overlay.
  ///
  /// Mỗi trang *được sửa* một trang overlay, không phải mỗi trang tài liệu.
  /// Trả mảng rỗng và không ghi gì khi không có gì để vẽ.
  @discardableResult
  static func write(
    _ requests: [Request],
    for document: PDFDocument,
    to url: URL
  ) throws -> [Int] {
    let drawable = requests.filter {
      !$0.attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && $0.bounds.width > 1 && $0.bounds.height > 0
        && $0.bounds.origin.x.isFinite && $0.bounds.origin.y.isFinite
    }
    guard !drawable.isEmpty else { return [] }

    let byPage = Dictionary(grouping: drawable, by: \.pageIndex)
    let order = byPage.keys.sorted()

    // Kiểm trước khi ghi byte nào: từ chối thì không được để lại file dở.
    for pageIndex in order {
      guard let page = document.page(at: pageIndex) else {
        throw Failure.pageMissing(pageIndex: pageIndex)
      }
      guard page.rotation % 360 == 0 else {
        throw Failure.pageRotated(pageIndex: pageIndex, degrees: page.rotation)
      }
    }

    guard let consumer = CGDataConsumer(url: url as CFURL) else {
      throw Failure.contextFailed(url)
    }
    // Box mặc định sẽ bị thay theo từng trang; ở đây chỉ cần hợp lệ.
    var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
      throw Failure.contextFailed(url)
    }

    for pageIndex in order {
      guard let page = document.page(at: pageIndex) else { continue }
      // Media box chứ không phải crop box: content stream đích viết trong
      // không gian media box.
      var box = page.bounds(for: .mediaBox)
      let info: [String: Any] = [
        kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)
      ]
      context.beginPDFPage(info as CFDictionary)
      context.saveGState()
      // PDF hướng lên, UIKit hướng xuống — lật một lần cho cả trang. Dưới dòng
      // này là toạ độ kiểu view, nên `draw` dùng chung được với lớp xem trước.
      let fold = box.minY + box.maxY
      context.translateBy(x: 0, y: fold)
      context.scaleBy(x: 1, y: -1)

      for request in byPage[pageIndex] ?? [] {
        var flipped = request
        flipped.bounds = CGRect(
          x: request.bounds.minX,
          y: fold - request.bounds.maxY,
          width: request.bounds.width,
          height: request.bounds.height
        )
        draw(flipped, into: context)
      }

      context.restoreGState()
      context.endPDFPage()
    }

    context.closePDF()
    return order
  }

  /// Bộ thuộc tính dùng chung cho cả ba nơi vẽ: ô nhập, lớp xem trước, và
  /// trang giấy. Trước đây mỗi nơi tự dựng và chúng lệch nhau — khác leading,
  /// khác chỗ ngắt dòng, nên chữ nhảy khi commit.
  static func attributes(
    font: UIFont,
    colour: UIColor,
    kern: CGFloat
  ) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.alignment = .left
    return [
      .font: font,
      .pdfPageFont: font,
      .foregroundColor: colour,
      .kern: kern,
      .paragraphStyle: paragraph,
    ]
  }

  /// Cùng chuỗi, mỗi run đặt lại `.font` theo font trang của nó nhân `zoom`.
  ///
  /// Một hàm cho cả ba nơi, vì cả ba hỏi cùng một câu ở ba tỉ lệ khác nhau: ô
  /// nhập và lớp xem trước hỏi ở tỉ lệ màn hình, trang giấy hỏi ở `zoom = 1`.
  /// Tách ra là ba cách bố cục hơi khác nhau, và chữ nhảy đúng lúc commit.
  ///
  /// Màu và tracking đặt cho cả chuỗi: chúng vẫn là thuộc tính của block, chỉ
  /// font mới đi theo run.
  static func restyled(
    _ attributed: NSAttributedString,
    zoom: CGFloat,
    colour: UIColor,
    kern: CGFloat
  ) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: attributed)
    let whole = NSRange(location: 0, length: result.length)
    guard whole.length > 0 else { return result }

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.alignment = .left

    // Gom trước, sửa sau — **bắt buộc**.
    //
    // `addAttributes` bên trong `enumerateAttribute` là sửa đúng cái đang duyệt:
    // đặt lại thuộc tính làm các run gộp hoặc tách, và bộ duyệt đi tiếp trên một
    // bố cục khác với bố cục nó khởi hành. Kết quả là run bị bỏ sót — và mọi
    // run bị bỏ sót thì giữ nguyên `.font` cũ, tức là cả chuỗi trông như một
    // font.
    var runs: [(range: NSRange, font: UIFont)] = []
    result.enumerateAttribute(.pdfPageFont, in: whole) { value, range, _ in
      // Run không mang font trang thì lấy `.font` hiện có làm gốc và đóng dấu
      // lại — chuỗi từ `UITextView` có thể chứa run do UIKit tự sinh.
      let pageFont = (value as? UIFont)
        ?? (result.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
      guard let pageFont else { return }
      runs.append((range, pageFont))
    }

    result.beginEditing()
    result.addAttributes(
      [.foregroundColor: colour, .kern: kern, .paragraphStyle: paragraph],
      range: whole
    )
    // `.font` là chỗ duy nhất zoom được phép chạm vào.
    for run in runs {
      result.addAttributes(
        [
          .pdfPageFont: run.font,
          .font: run.font.withSize(max(run.font.pointSize * zoom, 1)),
        ],
        range: run.range
      )
    }
    result.endEditing()
    return result
  }

  /// Font trang của run đầu tiên — thứ đại diện cho cả block khi phải trả lời
  /// bằng **một** con số: báo về Flutter, và đo lại lúc chọn lại block đã sửa.
  static func leadingFont(of attributed: NSAttributedString) -> UIFont? {
    guard attributed.length > 0 else { return nil }
    return attributed.attribute(.pdfPageFont, at: 0, effectiveRange: nil) as? UIFont
      ?? attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
  }

  /// Vẽ một block, trong hệ toạ độ context đang có sẵn.
  ///
  /// `bounds` đọc theo kiểu **y-down**: `minY` là cạnh trên. Lớp xem trước đưa
  /// thẳng toạ độ view sang; `write` lật trang một lần rồi làm y hệt.
  ///
  /// Dùng `NSAttributedString.draw` chứ không phải `CTFramesetter`, để trùng
  /// đúng layout mà `UITextView` đang chạy. Chiều cao thả tự do: chữ dài hơn
  /// chữ cũ phải được tràn ra ngoài block chứ không bị cắt.
  static func draw(_ request: Request, into context: CGContext) {
    let attributed = request.attributed
    guard attributed.length > 0, request.bounds.width > 1 else { return }

    context.saveGState()
    if let maxHeight = request.maxHeight, maxHeight > 0 {
      context.clip(
        to: CGRect(
          x: request.bounds.minX,
          y: request.bounds.minY,
          width: request.bounds.width,
          height: maxHeight
        )
      )
    }
    UIGraphicsPushContext(context)
    attributed.draw(
      with: CGRect(
        x: request.bounds.minX,
        y: request.bounds.minY,
        width: request.bounds.width,
        height: unboundedHeight
      ),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    UIGraphicsPopContext()
    context.restoreGState()
  }
}
