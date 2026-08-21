import Flutter
import Foundation
import UIKit
import WebKit

final class PdfDocumentViewerPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    PdfDocumentViewerPlatformView(frame: frame)
  }
}

final class PdfDocumentViewerPlatformView: NSObject, FlutterPlatformView {
  private let viewerView: PdfDocumentViewerView

  init(frame: CGRect) {
    viewerView = PdfDocumentViewerView(frame: frame)
    super.init()
    PdfPocRuntime.shared.attach(documentViewerView: viewerView)
  }

  deinit {
    PdfPocRuntime.shared.detach(documentViewerView: viewerView)
  }

  func view() -> UIView {
    viewerView
  }
}

/// Renders a picked Office, iWork, or PDF file inside the Flutter layout with
/// `WKWebView`, the only native iOS renderer that understands those formats.
///
/// Unlike `QLPreviewController` this brings no system chrome, so Flutter owns
/// the whole screen: app bar, toolbars, and any controls around the document.
final class PdfDocumentViewerView: UIView {
  private let webView: WKWebView
  private let activityIndicator = UIActivityIndicatorView(style: .large)
  private let messageLabel = UILabel()
  private var loadedURL: URL?

  /// Phục vụ trang xem HWP. Phải gắn vào `WKWebViewConfiguration` **trước** khi
  /// dựng web view — đăng ký scheme sau đó là không được.
  private let hwpHandler = HwpViewerSchemeHandler()
  private let relay = HwpViewerLogRelay()

  /// Tài liệu đang mở trong trình soạn thảo, nếu có. `nil` là đang chỉ xem.
  private var editingURL: URL?

  override init(frame: CGRect) {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.addUserScript(Self.searchHighlightScript())
    configuration.setURLSchemeHandler(hwpHandler, forURLScheme: HwpViewerSchemeHandler.scheme)
    // Mọi thứ phải xong **trước** dòng dưới: `WKWebView` copy configuration lúc
    // dựng, nên sửa bản gốc sau đó không tới được web view — log của trang vỏ
    // sẽ im lặng biến mất, mà đó lại là thứ duy nhất cho biết rhwp đang làm gì.
    configuration.userContentController.add(relay, name: HwpViewerLogRelay.name)
    webView = WKWebView(frame: frame, configuration: configuration)
    super.init(frame: frame)
    configureRelay()
    configureSubviews()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    webView.frame = bounds
    activityIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
    messageLabel.frame = bounds.insetBy(dx: 24, dy: 24)
  }

  func load(path: String) throws {
    let sourceURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw PdfPocError(
        code: "asset_not_found",
        message: "The document to view no longer exists.",
        details: path
      )
    }
    loadedURL = sourceURL
    showMessage(nil)
    activityIndicator.startAnimating()
    logPdfEvent("document_viewer_load", "file=\(sourceURL.lastPathComponent)")

    // HWP đi đường riêng. WebKit không hiểu định dạng này — không như Office và
    // iWork, nơi iOS có sẵn bộ chuyển đổi — nên thay vì nạp thẳng tệp, ta nạp
    // một trang vỏ và để rhwp (Rust/WASM) dàn trang rồi vẽ ra SVG.
    if HwpFileType.handles(sourceURL) {
      hwpHandler.documentURL = sourceURL
      guard let pageURL = HwpViewerSchemeHandler.pageURL() else {
        throw PdfPocError(
          code: "internal_error",
          message: "Could not build the HWP viewer URL.",
          details: nil
        )
      }
      logPdfEvent("hwp_viewer_load", "file=\(sourceURL.lastPathComponent)")
      webView.load(URLRequest(url: pageURL))
      return
    }

    webView.loadFileURL(
      sourceURL,
      allowingReadAccessTo: sourceURL.deletingLastPathComponent()
    )
  }

  /// `window.find` selects the match but WebKit paints that selection faintly,
  /// and dims it further once the web view is not first responder. Restyling
  /// `::selection` makes the current match read as a highlight without touching
  /// the document DOM, so repeated searches never corrupt the content.
  ///
  /// Injected into every frame because WebKit renders Office previews inside
  /// nested frames.
  private static func searchHighlightScript() -> WKUserScript {
    let source = """
    (function() {
      var style = document.createElement('style');
      style.textContent =
        '::selection { background-color: #FFC64D !important; color: #000 !important; }';
      (document.head || document.documentElement).appendChild(style);
    })();
    """
    return WKUserScript(
      source: source,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: false
    )
  }

  /// Finds text in the rendered document. WebKit renders Office and iWork
  /// previews as a DOM, so `window.find` searches and selects matches the same
  /// way it does on a web page. It wraps around at the end of the document.
  func find(query: String, forward: Bool, completion: @escaping (Bool) -> Void) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      clearSearch()
      completion(false)
      return
    }
    // window.find(text, caseSensitive, backwards, wrap, wholeWord, searchInFrames, showDialog)
    let escaped = trimmed
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
    let script = "window.find('\(escaped)', false, \(forward ? "false" : "true"), true, false, true, false)"
    webView.evaluateJavaScript(script) { result, error in
      let found = (result as? Bool) ?? false
      if let error {
        logPdfEvent("document_viewer_find_failed", "error=\(error.localizedDescription)")
      } else {
        logPdfEvent("document_viewer_find", "query=\(trimmed) forward=\(forward) found=\(found)")
      }
      completion(found)
    }
  }

  // MARK: - Soạn thảo HWP

  /// Bật hoặc tắt chế độ sửa cho tệp HWP đang mở.
  ///
  /// Bật là nạp hẳn một trang khác — trình xem vẽ SVG tĩnh, còn trình soạn thảo
  /// là ứng dụng riêng chạy trong iframe. Tắt là quay về trang xem, và **bỏ mọi
  /// thay đổi chưa lưu**: chúng chỉ tồn tại bên trong iframe.
  func setEditing(_ editing: Bool) throws {
    guard let loadedURL else {
      throw PdfPocError(
        code: "document_not_open",
        message: "No document is open in the viewer.",
        details: nil
      )
    }
    guard HwpFileType.handles(loadedURL) else {
      throw PdfPocError(
        code: "unsupported_source_format",
        message: "Only HWP documents can be edited here.",
        details: loadedURL.lastPathComponent
      )
    }

    if editing {
      guard let origin = HwpEditorPage.origin else {
        throw PdfPocError(
          code: "internal_error",
          message: "Could not build the HWP editor origin.",
          details: nil
        )
      }
      editingURL = loadedURL
      activityIndicator.startAnimating()
      logPdfEvent("hwp_editor_open", "file=\(loadedURL.lastPathComponent)")
      webView.loadHTMLString(try HwpEditorPage.html(), baseURL: origin)
    } else {
      editingURL = nil
      logPdfEvent("hwp_editor_close", "file=\(loadedURL.lastPathComponent)")
      try load(path: loadedURL.path)
    }
  }

  /// Yêu cầu trang soạn thảo xuất tài liệu. Kết quả về bất đồng bộ qua relay.
  func saveEdits() throws {
    guard editingURL != nil else {
      throw PdfPocError(
        code: "document_not_open",
        message: "The HWP editor is not open.",
        details: nil
      )
    }
    logPdfEvent("hwp_editor_save_request")
    webView.evaluateJavaScript("window.__rhwpExport()", completionHandler: nil)
  }

  private func configureRelay() {
    relay.onEditorReady = { [weak self] in
      guard let self, let url = self.editingURL else { return }
      do {
        let base64 = try Data(contentsOf: url).base64EncodedString()
        let name = url.lastPathComponent
          .replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "'", with: "\\'")
        // Bơm qua `evaluateJavaScript` thay vì để trang tự `fetch`: origin của
        // trang là https giả, nó không hỏi được scheme handler của app.
        self.webView.evaluateJavaScript(
          "window.__rhwpLoad('\(base64)', '\(name)')", completionHandler: nil
        )
      } catch {
        logPdfEvent("hwp_editor_read_failed", "error=\(error)")
      }
      self.activityIndicator.stopAnimating()
    }

    relay.onExported = { [weak self] data in
      guard let self, let url = self.editingURL else { return }
      do {
        // Ghi qua tệp tạm rồi thay chỗ: hỏng giữa chừng thì bản cũ vẫn nguyên.
        let scratch = url.deletingLastPathComponent()
          .appendingPathComponent("hwp-save-\(UUID().uuidString).tmp")
        try data.write(to: scratch, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
        logPdfEvent("hwp_editor_saved", "file=\(url.lastPathComponent) bytes=\(data.count)")
      } catch {
        logPdfEvent("hwp_editor_save_failed", "error=\(error)")
      }
    }
  }

  func clearSearch() {
    webView.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
  }

  /// Hands the viewed file to the system share sheet. The file stays where it
  /// is; only a copy is exported by whatever destination the user picks.
  func share() throws {
    guard let loadedURL else {
      throw PdfPocError(
        code: "document_not_open",
        message: "No document is open in the viewer.",
        details: nil
      )
    }
    guard let presenter = nearestViewController() else {
      throw PdfPocError(
        code: "internal_error",
        message: "Could not find a UIKit presenter for the share sheet.",
        details: nil
      )
    }
    let controller = UIActivityViewController(
      activityItems: [loadedURL],
      applicationActivities: nil
    )
    // Required on iPad, where the share sheet is a popover.
    controller.popoverPresentationController?.sourceView = self
    controller.popoverPresentationController?.sourceRect = CGRect(
      x: bounds.midX,
      y: bounds.minY,
      width: 0,
      height: 0
    )
    logPdfEvent("document_viewer_share", "file=\(loadedURL.lastPathComponent)")
    presenter.present(controller, animated: true)
  }

  private func nearestViewController() -> UIViewController? {
    var responder: UIResponder? = next
    while let current = responder {
      if let viewController = current as? UIViewController {
        return viewController
      }
      responder = current.next
    }
    return nil
  }

  /// Removes the local copy taken by the picker. The viewer owns that copy, so
  /// nothing of the user's original file is touched.
  func close() {
    logPdfEvent("document_viewer_close", "file=\(loadedURL?.lastPathComponent ?? "")")
    webView.stopLoading()
    webView.loadHTMLString("", baseURL: nil)
    activityIndicator.stopAnimating()
    if let loadedURL {
      try? FileManager.default.removeItem(at: loadedURL)
    }
    loadedURL = nil
  }

  private func configureSubviews() {
    backgroundColor = .systemBackground
    webView.navigationDelegate = self
    webView.backgroundColor = .systemBackground
    addSubview(webView)

    activityIndicator.hidesWhenStopped = true
    addSubview(activityIndicator)

    messageLabel.numberOfLines = 0
    messageLabel.textAlignment = .center
    messageLabel.textColor = .secondaryLabel
    messageLabel.isHidden = true
    addSubview(messageLabel)
  }

  private func showMessage(_ text: String?) {
    messageLabel.text = text
    messageLabel.isHidden = text == nil
    webView.isHidden = text != nil
  }
}

extension PdfDocumentViewerView: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    activityIndicator.stopAnimating()
    logPdfEvent("document_viewer_loaded", "file=\(loadedURL?.lastPathComponent ?? "")")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    handleFailure(error)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    handleFailure(error)
  }

  private func handleFailure(_ error: Error) {
    activityIndicator.stopAnimating()
    logPdfEvent("document_viewer_failed", "error=\(error.localizedDescription)")
    showMessage("This file could not be displayed.\n\(error.localizedDescription)")
  }
}
