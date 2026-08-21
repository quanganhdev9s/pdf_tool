import Foundation
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

  static func pageURL() -> URL? {
    URL(string: "\(scheme)://\(host)/index.html")
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
      let (data, mimeType) = try payload(for: url)
      let response = URLResponse(
        url: url,
        mimeType: mimeType,
        expectedContentLength: data.count,
        textEncodingName: nil
      )
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

  func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any],
          let event = body["event"] as? String else { return }
    logPdfEvent(event, body["detail"] as? String)
  }
}
