import PDFKit
import QPdfBridge

/// Xoá chữ khỏi content stream, và ghép chữ mới vào — bằng qpdf.
///
/// Chạy trên **file**, không phải `PDFDocument`, và chạy một mình: qpdf viết lại
/// toàn bộ cấu trúc tài liệu, nên PDFKit phải ghi xong và buông file trước, rồi
/// mở lại sau. Hai engine cùng cầm một path là cách chắc chắn làm hỏng file.
enum PdfContentTextEraser {
  /// Một block cần xoá, toạ độ trang.
  struct Request: Equatable {
    var pageIndex: Int
    var rect: CGRect
  }

  /// Xoá được cái gì, không xoá được cái gì.
  ///
  /// Tính trước khi ghi, vì câu trả lời đổi thứ mà caller vẽ: block bị từ chối
  /// vẫn còn chữ cũ nên chữ mới phải đặt lên một miếng vá.
  struct Plan {
    /// Chỉ số trang → các ordinal xoá hẳn.
    fileprivate var ordinals: [Int: [Int]] = [:]
    /// Chỉ số trang → ordinal chỉ giấu, kèm `Tr` gốc để trả lại.
    fileprivate var hidden: [Int: [Int: Int]] = [:]
    /// Block đã xử lý được, cách này hay cách kia.
    var erased: [Request] = []
    /// Block không tìm thấy operator nào — trang sai, hoặc chữ nằm trong
    /// XObject mà bộ quét không đi vào.
    var refused: [Request] = []
    var operatorsDropped: Int = 0
    /// Số operator phải giấu thay vì xoá. Chữ của chúng **vẫn nằm trong file**.
    var operatorsHidden: Int = 0

    var isEmpty: Bool { ordinals.isEmpty && hidden.isEmpty }
  }

  enum Failure: Error, LocalizedError {
    /// qpdf và `CGPDFScanner` đếm operator lệch nhau → ordinal trỏ khác chỗ,
    /// không xoá gì được. Không nên xảy ra.
    case scannersDisagree(pageIndex: Int, coreGraphics: Int, qpdf: Int)
    case bridge(Error)

    var errorDescription: String? {
      switch self {
      case let .scannersDisagree(pageIndex, coreGraphics, qpdf):
        return "Page \(pageIndex): CoreGraphics counted \(coreGraphics) text operators, "
          + "qpdf counted \(qpdf). Refusing to delete by position."
      case let .bridge(error):
        return error.localizedDescription
      }
    }
  }

  /// Số operator mà qpdf đã xác nhận là khớp, theo chỉ số trang.
  ///
  /// `showTextOperatorCount` mở **cả file** bằng qpdf chỉ để đếm, và nó chạy mỗi
  /// lần chạm vào một block. Trên file nặng đó là một trong những khoản đắt nhất
  /// của cú chạm, để trả lời một câu mà câu trả lời không đổi.
  ///
  /// Khoá cache là chính con số của `CGPDFScanner`, không phải chỉ số trang —
  /// nên nó tự kiểm. Phép đối chiếu nguyên bản chỉ so hai con số; trang nào cho
  /// ra đúng con số đã được xác nhận thì phép đối chiếu đó cũng sẽ đậu. Trang
  /// đổi nội dung sẽ đếm ra số khác và rơi khỏi cache.
  private static var verifiedCounts: [Int: Int] = [:]

  /// Quên hết những gì đã xác nhận. Gọi khi file bị viết lại theo cách có thêm
  /// hoặc bớt operator — `write()` xoá operator, nên số đếm cũ thành vô nghĩa.
  static func forgetVerifiedCounts() {
    verifiedCounts.removeAll()
  }

  /// Đối chiếu số operator giữa hai bộ quét, dùng lại xác nhận cũ nếu có.
  ///
  /// Ordinal là địa chỉ chung giữa `CGPDFScanner` và qpdf. Lệch một con là mọi
  /// ordinal sau đó trỏ sai chỗ và sẽ xoá nhầm chữ người dùng không đụng tới.
  private static func verifyScannersAgree(
    pageIndex: Int,
    seenHere: Int,
    at url: URL,
    trustingCache: Bool
  ) throws {
    if trustingCache, verifiedCounts[pageIndex] == seenHere { return }

    var bridgeError: NSError?
    let seenByQpdf = QPdfTextEraser.showTextOperatorCount(
      at: url, page: pageIndex, error: &bridgeError
    )
    if let bridgeError { throw Failure.bridge(bridgeError) }
    guard seenByQpdf == seenHere else {
      throw Failure.scannersDisagree(
        pageIndex: pageIndex, coreGraphics: seenHere, qpdf: seenByQpdf
      )
    }
    verifiedCounts[pageIndex] = seenHere
  }

  /// Đổi hình chữ nhật thành ordinal operator. Chỉ đọc, không ghi gì.
  static func plan(for requests: [Request], at url: URL) throws -> Plan {
    var plan = Plan()
    guard !requests.isEmpty else { return plan }

    guard let document = PDFDocument(url: url) else {
      throw Failure.bridge(CocoaError(.fileReadCorruptFile))
    }

    // Gom theo trang: mỗi trang chỉ quét một lần dù có bao nhiêu block.
    for (pageIndex, pageRequests) in Dictionary(grouping: requests, by: \.pageIndex) {
      guard let page = document.page(at: pageIndex) else {
        plan.refused.append(contentsOf: pageRequests)
        continue
      }

      // Một lượt quét cho cả trang, dùng chung cho phép đối chiếu bên dưới và
      // cho mọi block trên trang này.
      let ops = PdfContentStreamReader.showTextOps(on: page)
      // Không tin cache ở đây. Cache đảm bảo đúng thứ phép đối chiếu vốn hỏi —
      // hai con số bằng nhau — nhưng đường này **xoá** operator, và nó chạy một
      // lần cho mỗi lần Lưu chứ không phải mỗi cú chạm. Hỏi lại qpdf ở đây gần
      // như không tốn gì, còn sai ở đây thì mất chữ thật.
      try verifyScannersAgree(
        pageIndex: pageIndex, seenHere: ops.count, at: url, trustingCache: false
      )

      var ordinals: Set<Int> = []
      var toHide: [Int: Int] = [:]
      for request in pageRequests {
        if let removal = PdfContentStreamReader.removalPlan(for: request.rect, among: ops) {
          ordinals.formUnion(removal.delete)
          toHide.merge(removal.hide) { first, _ in first }
          plan.erased.append(request)
        } else {
          plan.refused.append(request)
        }
      }
      // Xoá thắng giấu: một ordinal xoá được thì không cần giấu.
      toHide = toHide.filter { !ordinals.contains($0.key) }
      if !ordinals.isEmpty {
        plan.ordinals[pageIndex] = ordinals.sorted()
        plan.operatorsDropped += ordinals.count
      }
      if !toHide.isEmpty {
        plan.hidden[pageIndex] = toHide
        plan.operatorsHidden += toHide.count
      }
    }
    return plan
  }

  /// Xoá operator theo kế hoạch và ghép overlay lên, ghi đè tại chỗ.
  ///
  /// Ghi qua file tạm nên hỏng ở đâu thì bản gốc vẫn nguyên. Caller tự lo mở
  /// lại: mọi `PDFDocument` trên URL này thành cũ sau khi hàm trả về.
  ///
  /// - Parameter qdfMode: ghi content stream không nén, đọc được. Chỉ để debug.
  static func write(
    _ plan: Plan,
    at url: URL,
    overlay: URL? = nil,
    overlayPages: [Int] = [],
    qdfMode: Bool = false
  ) throws {
    guard !plan.isEmpty || !overlayPages.isEmpty else { return }

    // Số operator sắp đổi: đây là đường duy nhất xoá chúng.
    forgetVerifiedCounts()

    // Qua file tạm: qpdf không đọc-ghi cùng một path.
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("qpdf-erase-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: scratch) }

    let bridgePlan = plan.ordinals.reduce(into: [NSNumber: [NSNumber]]()) { result, entry in
      result[NSNumber(value: entry.key)] = entry.value.map { NSNumber(value: $0) }
    }

    do {
      let bridgeHide = plan.hidden.reduce(into: [NSNumber: [NSNumber: NSNumber]]()) { result, entry in
        result[NSNumber(value: entry.key)] = entry.value.reduce(into: [NSNumber: NSNumber]()) {
          $0[NSNumber(value: $1.key)] = NSNumber(value: $1.value)
        }
      }

      try QPdfTextEraser.erase(
        at: url,
        to: scratch,
        plan: bridgePlan,
        hide: bridgeHide,
        overlayURL: overlayPages.isEmpty ? nil : overlay,
        overlayPages: overlayPages.map { NSNumber(value: $0) },
        qdfMode: qdfMode
      )
      _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
    } catch {
      throw Failure.bridge(error)
    }
  }

  /// Làm chữ trong các hình chữ nhật **vô hình tại chỗ**, không xoá.
  ///
  /// Tách riêng khỏi `plan`/`write` vì nó trả lời một câu khác. Kia là "ghi
  /// chỉnh sửa vào file", chạy một lần lúc Lưu. Đây là "làm chữ này biến mất
  /// khỏi màn hình ngay bây giờ", và có thể gọi bất cứ lúc nào.
  ///
  /// Dùng `3 Tr` cho **mọi** operator trúng đích, kể cả những cái xoá được:
  /// giấu không làm dịch chuyển gì, nên không cần biết nhóm có chạy hết segment
  /// hay không, và không có gì để từ chối. Đổi lại chữ vẫn nằm trong file —
  /// việc xoá thật vẫn để dành cho lúc Lưu.
  ///
  /// Trả về số operator đã giấu. Caller tự lo mở lại tài liệu: mọi
  /// `PDFDocument` trên URL này thành cũ sau khi hàm trả về.
  @discardableResult
  static func hide(_ requests: [Request], at url: URL) throws -> Int {
    guard !requests.isEmpty else { return 0 }

    var hidden: [Int: [Int: Int]] = [:]
    guard let document = PDFDocument(url: url) else {
      throw Failure.bridge(CocoaError(.fileReadCorruptFile))
    }

    for (pageIndex, pageRequests) in Dictionary(grouping: requests, by: \.pageIndex) {
      guard let page = document.page(at: pageIndex) else { continue }

      // Một lượt quét cho cả trang. Vẫn phải đối chiếu — ordinal là địa chỉ
      // chung giữa hai bộ quét, và giấu nhầm chỗ thì làm biến mất chữ người
      // dùng không hề đụng tới.
      let ops = PdfContentStreamReader.showTextOps(on: page)
      try verifyScannersAgree(
        pageIndex: pageIndex, seenHere: ops.count, at: url, trustingCache: true
      )

      var modes: [Int: Int] = [:]
      for request in pageRequests {
        guard let removal = PdfContentStreamReader.removalPlan(for: request.rect, among: ops)
        else {
          // Bộ quét không thấy operator nào có gốc nằm trong hình chữ nhật này.
          // Hoặc chữ nằm trong Form XObject — chỗ mù đã biết — hoặc toạ độ của
          // hai bên không khớp nhau.
          // In cả toạ độ ra: lệch đều một khoảng nghĩa là hai bên khác gốc toạ
          // độ; rải rác nghĩa là chuyện khác.
          let nearby = ops
            .filter { abs($0.origin.y - request.rect.midY) < 40 }
            .prefix(4)
            .map { "(\(Int($0.origin.x)),\(Int($0.origin.y)))" }
            .joined(separator: " ")
          logPdfEvent(
            "text_removal_empty",
            "pageIndex=\(pageIndex) rect=\(request.rect.integral.debugDescription) "
              + "ops=\(ops.count) media=\(page.bounds(for: .mediaBox).integral.debugDescription) "
              + "crop=\(page.bounds(for: .cropBox).integral.debugDescription) "
              + "rotation=\(page.rotation) nearby=[\(nearby)] "
              + "allY=[\(ops.prefix(6).map { String(Int($0.origin.y)) }.joined(separator: ","))]"
          )
          continue
        }
        // Cả hai tập, không chỉ tập giấu: ở đây không xoá gì cả. Và lấy `Tr`
        // thật của từng cái — trả bừa 0 sẽ bật lớp OCR đang ẩn lên.
        modes.merge(removal.modes) { first, _ in first }
      }
      if !modes.isEmpty { hidden[pageIndex] = modes }
    }

    guard !hidden.isEmpty else { return 0 }

    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("qpdf-hide-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: scratch) }

    let bridgeHide = hidden.reduce(into: [NSNumber: [NSNumber: NSNumber]]()) { result, entry in
      result[NSNumber(value: entry.key)] = entry.value.reduce(into: [NSNumber: NSNumber]()) {
        $0[NSNumber(value: $1.key)] = NSNumber(value: $1.value)
      }
    }

    do {
      try QPdfTextEraser.erase(
        at: url, to: scratch,
        plan: [:], hide: bridgeHide,
        overlayURL: nil, overlayPages: [],
        qdfMode: false
      )
      _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
    } catch {
      throw Failure.bridge(error)
    }

    return hidden.values.reduce(0) { $0 + $1.count }
  }

  /// Đọc rồi ghi lại y nguyên, không đổi gì.
  ///
  /// Đáng chạy một lần trước khi tin tưởng giao file cho phần sửa: file không
  /// sống sót qua vòng này thì cũng không sống sót qua một lần sửa.
  static func verifyRoundTrip(at url: URL) throws -> Bool {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("qpdf-roundtrip-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: scratch) }

    do {
      try QPdfTextEraser.rewrite(at: url, to: scratch, qdfMode: false)
    } catch {
      throw Failure.bridge(error)
    }

    guard let before = PDFDocument(url: url), let after = PDFDocument(url: scratch) else {
      return false
    }
    return before.pageCount == after.pageCount
  }

  /// Phiên bản qpdf đang dùng. Cho màn hình ghi công và cho báo lỗi.
  static var qpdfVersion: String { QPdfTextEraser.qpdfVersion }
}
