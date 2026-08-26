import Foundation
import QuartzCore
import UniformTypeIdentifiers
import WebKit

/// Phục vụ trang xem HWP và chính tệp đang mở, qua một scheme riêng.
///
/// Không dùng `loadFileURL` được. Trang vỏ phải `fetch` hai thứ — mô-đun WASM
/// và bytes của tài liệu — mà `WKWebView` chặn `fetch` trên `file://` vì
/// cross-origin. Scheme riêng thì mọi thứ nằm cùng một origin, nên `fetch`
/// chạy bình thường.
///
/// Nó còn giải quyết một chuyện thứ hai: `WebAssembly.instantiateStreaming`
/// chỉ nhận phản hồi có `Content-Type: application/wasm`. Ở đây ta tự đặt
/// header nên chắc chắn đúng.
final class HwpViewerSchemeHandler: NSObject, WKURLSchemeHandler {
  /// Scheme riêng của app. Không được trùng scheme chuẩn — `WKWebView` từ chối
  /// đăng ký handler cho `http`, `https`, `file` và vài cái khác.
  static let scheme = "rhwp-app"
  static let host = "viewer"

  /// Đường dẫn ảo trỏ tới tài liệu người dùng đang mở.
  private static let documentPath = "/document"

  /// Thư mục chứa `index.html`, `rhwp.js`, `rhwp_bg.wasm` trong app bundle.
  private let assetsDirectory: URL?

  /// Tệp HWP đang xem. Đặt trước khi nạp trang.
  var documentURL: URL?

  override init() {
    // Thư mục được đưa vào bundle nguyên khối (folder reference), nên tên thư
    // mục là thứ duy nhất cần biết.
    assetsDirectory = Bundle.main.url(forResource: "HwpViewer", withExtension: nil)
    super.init()
  }

  /// URL trang vỏ. `prewarm` là nạp trang mà không mở tệp nào — chỉ biên dịch
  /// WASM rồi đứng chờ.
  static func pageURL(prewarm: Bool = false) -> URL? {
    URL(string: "\(scheme)://\(host)/index.html\(prewarm ? "?prewarm=1" : "")")
  }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url else {
      task.didFailWithError(Self.notFound(nil))
      return
    }

    // Đọc đồng bộ có chủ ý: cả ba tài nguyên đều nằm trên đĩa cục bộ, và
    // `WKURLSchemeTask` bắt buộc mọi lời gọi phải trên cùng luồng đã bắt đầu nó.
    // Nhảy sang luồng khác rồi gọi `didReceive` là cách chắc chắn để crash.
    do {
      let readStart = CACurrentMediaTime()
      let (data, mimeType) = try payload(for: url)
      logPdfEvent(
        "hwp_asset_served",
        "path=\(url.path) bytes=\(data.count)"
          + " read=\(Int(((CACurrentMediaTime() - readStart) * 1000).rounded()))ms"
      )
      // `HTTPURLResponse` chứ không phải `URLResponse`.
      //
      // `URLResponse(url:mimeType:...)` đặt được thuộc tính `mimeType`, nhưng
      // không sinh ra **header** `Content-Type` — mà
      // `WebAssembly.instantiateStreaming` đọc header. Dùng nó thì nạp WASM hỏng
      // với đúng một dòng: "Unexpected response MIME type. Expected
      // 'application/wasm'".
      guard let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": mimeType,
          "Content-Length": String(data.count),
        ]
      ) else {
        throw Self.notFound(url)
      }
      task.didReceive(response)
      task.didReceive(data)
      task.didFinish()
    } catch {
      logPdfEvent("hwp_viewer_asset_missing", "path=\(url.path) error=\(error)")
      task.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
    // Không có việc gì đang chạy nền để huỷ.
  }

  // MARK: - Tài nguyên

  private func payload(for url: URL) throws -> (Data, String) {
    if url.path == Self.documentPath {
      guard let documentURL else { throw Self.notFound(url) }
      return (try Data(contentsOf: documentURL), "application/octet-stream")
    }

    guard let assetsDirectory else { throw Self.notFound(url) }
    // Chỉ lấy tên tệp: chặn `../` leo ra khỏi thư mục tài nguyên.
    let name = (url.path as NSString).lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else { throw Self.notFound(url) }

    let fileURL = assetsDirectory.appendingPathComponent(name)
    guard fileURL.deletingLastPathComponent().standardizedFileURL
      == assetsDirectory.standardizedFileURL else {
      throw Self.notFound(url)
    }
    return (try Data(contentsOf: fileURL), Self.mimeType(for: name))
  }

  private static func mimeType(for name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "html": return "text/html"
    case "js": return "text/javascript"
    // Bắt buộc đúng chuỗi này, nếu không `instantiateStreaming` từ chối và
    // rhwp lặng lẽ rơi về đường nạp chậm hơn — hoặc hỏng hẳn.
    case "wasm": return "application/wasm"
    case "css": return "text/css"
    case "woff2": return "font/woff2"
    default: return "application/octet-stream"
    }
  }

  private static func notFound(_ url: URL?) -> NSError {
    NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorFileDoesNotExist,
      userInfo: [NSURLErrorFailingURLStringErrorKey: url?.absoluteString ?? ""]
    )
  }
}

/// Đuôi tệp mà trình xem HWP nhận.
enum HwpFileType {
  static let extensions: Set<String> = ["hwp", "hwpx"]

  static func handles(_ url: URL) -> Bool {
    extensions.contains(url.pathExtension.lowercased())
  }

  /// Kiểu cho document picker, theo hai đường và cố ý thừa.
  ///
  /// `UTType(_:)` là failable: UTI khai trong `Info.plist` mà hệ thống chưa nạp
  /// thì nó trả nil, và picker sẽ không cho chọn tệp `.hwp` nào — hỏng lặng lẽ,
  /// không có lỗi nào để lần theo.
  ///
  /// Nên hỏi thêm theo **đuôi tệp**. Đường đó luôn trả về một kiểu, kể cả khi
  /// phải bịa ra một kiểu động `dyn.xxxx`. Trùng nhau cũng không sao — nhiều
  /// nhất là picker nhận cùng một kiểu hai lần.
  static var contentTypes: [UTType] {
    let declared = ["com.hancom.hwp", "com.hancom.hwpx"].compactMap(UTType.init)
    let byExtension = extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    var seen: Set<UTType> = []
    let types = (declared + byExtension).filter { seen.insert($0).inserted }
    logPdfEvent(
      "hwp_content_types",
      "declared=\(declared.count) resolved=[\(types.map(\.identifier).joined(separator: ","))]"
    )
    return types
  }
}

/// Đưa log của trang vỏ về cùng dòng log với phần còn lại của app.
///
/// Trang vỏ chạy trong `WKWebView` nên `console.log` của nó không đi đâu cả.
/// Nó `postMessage` sang đây, và mọi thứ hiện chung một chỗ với `logPdfEvent`.
final class HwpViewerLogRelay: NSObject, WKScriptMessageHandler {
  static let name = "hwpViewer"

  /// Bytes của tài liệu sau khi sửa, kèm báo cáo phần nội dung trình xuất phải
  /// bỏ đi. Báo cáo rỗng nghĩa là không mất gì.
  var onExported: ((Data, String) -> Void)?

  /// Trình soạn thảo không dựng nổi tệp. Chưa có gì được ghi xuống đĩa.
  var onExportFailed: ((String) -> Void)?

  /// Runtime của trang vỏ đã biên dịch xong và đang chờ tài liệu.
  var onRuntimeReady: (() -> Void)?

  /// Tài liệu đã vẽ xong. Đường dùng lại trang vỏ không có navigation nên đây
  /// là tín hiệu "mở xong" duy nhất.
  var onRendered: (() -> Void)?

  /// Trạng thái con trỏ/vùng chọn, nguyên văn JSON. Swift không đọc vào trong:
  /// hình dạng của nó thuộc về trang vỏ và Flutter, không thuộc về đây.
  var onStateChanged: ((String) -> Void)?

  func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any],
          let event = body["event"] as? String else { return }
    let detail = body["detail"] as? String

    switch event {
    case "hwp_editor_export_data":
      // Không log payload: đây là cả tệp dưới dạng base64.
      guard let detail, let data = Data(base64Encoded: detail) else {
        logPdfEvent("hwp_editor_export_decode_failed", nil)
        onExportFailed?("The editor produced a payload that could not be decoded.")
        return
      }
      let loss = body["contentLoss"] as? String ?? ""
      logPdfEvent("hwp_editor_export_received", "bytes=\(data.count) loss=\(loss.count)")
      onExported?(data, loss)
    case "hwp_editor_export_failed":
      logPdfEvent(event, detail)
      onExportFailed?(detail ?? "The editor could not build the file.")
    case "hwp_editor_state":
      // Không log: nó bắn ra sau mỗi lần con trỏ nhúc nhích và sẽ nhấn chìm
      // mọi dòng log khác.
      guard let detail else { return }
      onStateChanged?(detail)
    case "hwp_runtime_ready":
      logPdfEvent(event, detail)
      onRuntimeReady?()
    default:
      logPdfEvent(event, detail)
      // Tài liệu đã vẽ xong: log về sau là cuộn và sửa, không thuộc lượt mở.
      if event == "hwp_render_done" {
        onRendered?()
        PdfEventClock.stop()
      }
    }
  }
}
