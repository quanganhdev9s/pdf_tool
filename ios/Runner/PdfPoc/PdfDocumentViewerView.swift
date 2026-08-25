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

/// Những gì trình soạn thảo HWP muốn nói ngược ra ngoài. `PdfPocRuntime` nhận
/// và chuyển tiếp sang Flutter — view này không biết gì về Pigeon.
protocol PdfDocumentViewerViewDelegate: AnyObject {
  /// Con trỏ, vùng chọn hoặc nội dung vừa đổi. `json` là nguyên văn từ trang
  /// vỏ.
  func documentViewer(_ view: PdfDocumentViewerView, didChangeEditorState json: String)

  /// Một lần ghi tài liệu đã xong. `contentLoss` rỗng nghĩa là không mất gì.
  func documentViewer(
    _ view: PdfDocumentViewerView,
    didSaveEditsWith error: String?,
    contentLoss: String
  )
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

  weak var delegate: PdfDocumentViewerViewDelegate?

  /// Theo dõi bàn phím để đẩy chiều cao của nó xuống trang vỏ.
  private var keyboardObservers: [NSObjectProtocol] = []

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
    observeKeyboard()
  }

  deinit {
    for observer in keyboardObservers {
      NotificationCenter.default.removeObserver(observer)
    }
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
    // Nạp tệp khác là trang vỏ mới: chế độ sửa của tệp cũ không còn nữa.
    editingURL = nil
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
  /// Không nạp trang khác. Xem và sửa dùng chung một trang và **chung một
  /// instance WASM** — chạm, đặt con trỏ và ghi đều là code của ta, nên không
  /// phụ thuộc hành vi chạm của một ứng dụng bên ngoài.
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
    editingURL = editing ? loadedURL : nil
    logPdfEvent(
      editing ? "hwp_editor_open" : "hwp_editor_close",
      "file=\(loadedURL.lastPathComponent)"
    )
    runEditor("setEditing(\(editing))")
  }

  /// Yêu cầu trang soạn thảo xuất tài liệu. Kết quả về bất đồng bộ qua relay.
  func saveEdits() throws {
    try requireEditor()
    logPdfEvent("hwp_editor_save_request")
    runEditor("export()")
  }

  /// Áp định dạng chữ lên vùng đang chọn, hoặc giữ lại cho đoạn gõ tiếp theo.
  func applyCharFormat(_ format: HwpCharFormat) throws {
    try requireEditor()
    var props: [String: Any] = [:]
    if let bold = format.bold { props["bold"] = bold }
    if let italic = format.italic { props["italic"] = italic }
    if let underline = format.underline { props["underline"] = underline }
    if let strikethrough = format.strikethrough { props["strikethrough"] = strikethrough }
    // Cỡ chữ đi qua bằng **điểm**; trang vỏ đổi sang HWPUNIT. Đơn vị của định
    // dạng tệp không nên rò ra tới đây.
    if let fontSizePt = format.fontSizePt { props["fontSizePt"] = fontSizePt }
    guard !props.isEmpty else { return }
    logPdfEvent("hwp_char_format", props.keys.sorted().joined(separator: ","))
    runEditor("applyCharFormat(\(Self.jsString(props)))")
  }

  /// Áp định dạng lên các đoạn mà con trỏ hoặc vùng chọn chạm tới.
  func applyParaFormat(_ format: HwpParaFormat) throws {
    try requireEditor()
    var props: [String: Any] = [:]
    if let alignment = format.alignment { props["alignment"] = alignment }
    if let lineSpacing = format.lineSpacing { props["lineSpacing"] = lineSpacing }
    guard !props.isEmpty else { return }
    logPdfEvent("hwp_para_format", props.keys.sorted().joined(separator: ","))
    runEditor("applyParaFormat(\(Self.jsString(props)))")
  }

  /// Chiều cao phần giao diện Flutter đang phủ lên đáy web view.
  ///
  /// Không đi qua `requireEditor()`: Flutter báo số 0 khi rời chế độ sửa, và
  /// lúc đó `editingURL` đã là nil rồi — chặn ở đây thì phần chừa chỗ không
  /// bao giờ được trả lại.
  func setChromeInset(_ pixels: Double) {
    runEditor("setChromeInset(\(Int(pixels.rounded())))")
  }

  func undoEdit() throws {
    try requireEditor()
    runEditor("undo()")
  }

  func redoEdit() throws {
    try requireEditor()
    runEditor("redo()")
  }

  /// Lật trang trong trình xem HWP.
  ///
  /// Cố tình **không** gọi `requireEditor()`: trang vỏ chỉ dựng một trang mỗi
  /// lúc, nên lật trang là việc của cả chế độ chỉ xem. `runEditor` dùng optional
  /// chaining nên khi trang vỏ chưa gắn xong thì đây chỉ là lệnh rỗng.
  func goToPage(_ pageIndex: Int64) {
    runEditor("goToPage(\(pageIndex))")
  }

  private func requireEditor() throws {
    guard editingURL != nil else {
      throw PdfPocError(
        code: "document_not_open",
        message: "The HWP editor is not open.",
        details: nil
      )
    }
  }

  private func runEditor(_ call: String) {
    webView.evaluateJavaScript("window.__rhwpEditor?.\(call)", completionHandler: nil)
  }

  /// Một literal chuỗi JavaScript chứa JSON.
  ///
  /// Nối chuỗi vào `evaluateJavaScript` bằng tay là chỗ dễ hỏng nhất; để
  /// `JSONSerialization` lo phần thoát ký tự, rồi bọc kết quả lại thành một
  /// chuỗi JS cũng bằng `JSONSerialization`.
  private static func jsString(_ value: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value),
          let json = String(data: data, encoding: .utf8),
          let quoted = try? JSONSerialization.data(
            withJSONObject: [json], options: .fragmentsAllowed
          ),
          let wrapped = String(data: quoted, encoding: .utf8) else {
      return "\"{}\""
    }
    // `wrapped` là `["…"]`; bỏ hai ngoặc vuông là còn đúng literal chuỗi.
    return String(wrapped.dropFirst().dropLast())
  }

  private func configureRelay() {
    relay.onExported = { [weak self] data, contentLoss in
      guard let self else { return }
      guard let url = self.editingURL else {
        self.reportSave(error: "The HWP editor closed before the file could be written.")
        return
      }
      do {
        // Ghi qua tệp tạm rồi thay chỗ: hỏng giữa chừng thì bản cũ vẫn nguyên.
        let scratch = url.deletingLastPathComponent()
          .appendingPathComponent("hwp-save-\(UUID().uuidString).tmp")
        try data.write(to: scratch, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
        logPdfEvent(
          "hwp_editor_saved",
          "file=\(url.lastPathComponent) bytes=\(data.count) loss=\(contentLoss.count)"
        )
        self.reportSave(error: nil, contentLoss: contentLoss)
      } catch {
        logPdfEvent("hwp_editor_save_failed", "error=\(error)")
        self.reportSave(error: error.localizedDescription)
      }
    }

    relay.onExportFailed = { [weak self] message in
      self?.reportSave(error: message)
    }

    relay.onStateChanged = { [weak self] json in
      guard let self else { return }
      self.delegate?.documentViewer(self, didChangeEditorState: json)
    }
  }

  /// Kết quả lưu phải đi tới tận UI. Trước đây nó chỉ vào log, nên "ghi hỏng"
  /// và "ghi xong" trông y hệt nhau trên màn hình.
  private func reportSave(error: String?, contentLoss: String = "") {
    delegate?.documentViewer(self, didSaveEditsWith: error, contentLoss: contentLoss)
  }

  /// Màn hình Flutter đặt `resizeToAvoidBottomInset: false`, nên web view giữ
  /// nguyên chiều cao khi bàn phím lên và con trỏ dễ nằm khuất dưới nó. Đo bàn
  /// phím ở đây rồi đẩy con số xuống trang vỏ; đường này chắc chắn hơn là trông
  /// vào `visualViewport` bên trong WebKit.
  private func observeKeyboard() {
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      UIResponder.keyboardWillChangeFrameNotification,
      UIResponder.keyboardWillHideNotification,
    ]
    keyboardObservers = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        self?.handleKeyboard(notification)
      }
    }
  }

  private func handleKeyboard(_ notification: Notification) {
    guard editingURL != nil, window != nil else { return }
    var inset: CGFloat = 0
    if notification.name != UIResponder.keyboardWillHideNotification,
       let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
      let keyboard = convert(frame.cgRectValue, from: nil)
      inset = max(0, bounds.maxY - keyboard.minY)
    }
    runEditor("setKeyboardInset(\(Int(inset.rounded())))")
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
    editingURL = nil
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
    // Bỏ thanh phụ trợ bàn phím của iOS. Phải đợi tới đây: view nhận bàn phím
    // chỉ tồn tại sau khi trang đã nạp. Xem `WKWebView+InputAccessory.swift`.
    webView.removeInputAccessoryView()
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
