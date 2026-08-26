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

/// Giữ một `PdfDocumentViewerView` sống ngoài vòng đời của platform view.
///
/// Dựng `WKWebView` là bắt WebKit spawn cả một cụm process, và đo được ~1.7s ở
/// lượt đầu — nhiều hơn toàn bộ phần parse và vẽ tài liệu cộng lại. Flutter thì
/// mount rồi unmount platform view mỗi lần mở tài liệu, nên nếu view chết theo
/// thì lần mở nào cũng trả lại khoản đó từ đầu.
///
/// Bể chỉ giữ **một** bản rảnh: mở hai trình xem cùng lúc là chuyện không có
/// trong app này, và giữ nhiều web view ẩn thì tốn bộ nhớ hơn là tiết kiệm
/// thời gian.
final class PdfDocumentViewerViewPool {
  static let shared = PdfDocumentViewerViewPool()

  private var idle: PdfDocumentViewerView?

  /// Bản rảnh đỗ ngoài mép cửa sổ: 1pt, không nhận chạm, không ai thấy.
  private static let parkedFrame = CGRect(x: -2, y: -2, width: 1, height: 1)

  /// Dựng sẵn web view và hâm nóng trang vỏ HWP. Gọi lúc khởi động app.
  func prewarm() {
    let view = idle ?? PdfDocumentViewerView(frame: Self.parkedFrame)
    idle = view
    park(view)
    view.prewarmHwpShell()
  }

  /// View cho Flutter gắn vào — bản đã hâm nóng nếu có.
  func acquire(frame: CGRect) -> PdfDocumentViewerView {
    if let view = idle {
      idle = nil
      view.removeFromSuperview()
      view.isUserInteractionEnabled = true
      view.frame = frame
      logPdfEvent("document_viewer_reused", nil)
      return view
    }
    return PdfDocumentViewerView(frame: frame)
  }

  /// Nhận view về sau khi Flutter bỏ nó, và hâm nóng lại cho lượt mở sau.
  func release(_ view: PdfDocumentViewerView) {
    view.removeFromSuperview()
    // Đã có bản rảnh rồi thì để bản này chết: hai web view ẩn không nhanh hơn
    // một cái.
    guard idle == nil else { return }
    idle = view
    park(view)
    view.prewarmHwpShell()
  }

  /// Gắn bản rảnh vào cửa sổ.
  ///
  /// Bắt buộc, không phải cho đẹp: `WKWebView` không nằm trong cửa sổ nào thì
  /// WebKit coi là ẩn và hãm tiến trình web của nó lại — trang vỏ sẽ nằm im
  /// giữa chừng và phần hâm nóng thành công cốc.
  private func park(_ view: PdfDocumentViewerView) {
    guard view.superview == nil else { return }
    guard let window = Self.keyWindow() else {
      // Cửa sổ chưa có lúc app vừa khởi động. Thử lại một lần, rồi thôi: hâm
      // nóng là tối ưu, hỏng thì chỉ chậm như cũ chứ không sai.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak view] in
        guard let self, let view, view === self.idle, view.superview == nil else { return }
        guard let window = Self.keyWindow() else {
          logPdfEvent("document_viewer_prewarm_no_window", nil)
          return
        }
        view.frame = Self.parkedFrame
        view.isUserInteractionEnabled = false
        window.addSubview(view)
      }
      return
    }
    view.frame = Self.parkedFrame
    view.isUserInteractionEnabled = false
    window.addSubview(view)
  }

  private static func keyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first
  }
}

final class PdfDocumentViewerPlatformView: NSObject, FlutterPlatformView {
  private let viewerView: PdfDocumentViewerView

  init(frame: CGRect) {
    viewerView = PdfDocumentViewerViewPool.shared.acquire(frame: frame)
    super.init()
    PdfPocRuntime.shared.attach(documentViewerView: viewerView)
  }

  deinit {
    PdfPocRuntime.shared.detach(documentViewerView: viewerView)
    PdfDocumentViewerViewPool.shared.release(viewerView)
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

  /// Mốc bắt đầu nạp, để đo riêng khoảng dựng trang vỏ.
  private var shellStart: CFTimeInterval = 0

  /// Trang vỏ HWP đang ở đâu trong vòng đời của nó.
  ///
  /// Có mặt để mở tệp thứ hai **không** phải nạp lại trang: nạp lại là dựng
  /// lại JS context, tức biên dịch lại 7.7MB WASM, cho một runtime hoàn toàn
  /// không phụ thuộc tệp nào.
  private enum ShellState {
    /// Web view đang trống, hoặc đang giữ một định dạng khác (Office, PDF).
    case cold
    /// Đang nạp trang vỏ ở chế độ hâm nóng; runtime chưa sẵn sàng.
    case warming
    /// Runtime đã biên dịch xong và đang chờ tài liệu.
    case warm
    /// Đang có tài liệu mở trên trang vỏ.
    case document
  }

  private var shellState: ShellState = .cold

  /// Người dùng mở tệp trong lúc trang vỏ còn đang hâm nóng. Không thúc được
  /// gì thêm — chỉ đợi `hwp_runtime_ready` rồi nạp ngay.
  private var documentLoadPending = false

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
    let webViewStart = CACurrentMediaTime()
    webView = WKWebView(frame: frame, configuration: configuration)
    super.init(frame: frame)
    logPdfEvent(
      "document_viewer_webview_built",
      "in=\(Int(((CACurrentMediaTime() - webViewStart) * 1000).rounded()))ms"
    )
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
    shellStart = CACurrentMediaTime()
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

      switch shellState {
      case .warm, .document:
        // Trang vỏ còn nguyên và runtime đã chạy: chỉ cần bảo nó đi lấy tệp
        // mới ở `/document`. Bỏ qua toàn bộ phần dựng web view và biên dịch
        // WASM.
        shellState = .document
        logPdfEvent("hwp_shell_reused", "file=\(sourceURL.lastPathComponent)")
        runHost("loadDocument()")
      case .warming:
        documentLoadPending = true
        logPdfEvent("hwp_shell_warming", "file=\(sourceURL.lastPathComponent)")
      case .cold:
        shellState = .document
        webView.load(URLRequest(url: pageURL))
      }
      return
    }

    // Định dạng khác nạp thẳng vào web view, nên trang vỏ HWP mất chỗ.
    shellState = .cold
    webView.loadFileURL(
      sourceURL,
      allowingReadAccessTo: sourceURL.deletingLastPathComponent()
    )
  }

  /// Nạp trước trang vỏ HWP mà chưa mở tệp nào.
  ///
  /// Đây là phần tiết kiệm chính: lúc người dùng chọn tệp thì cụm process của
  /// WebKit đã chạy, `rhwp_bg.wasm` đã biên dịch, và lượt mở chỉ còn phần parse
  /// tài liệu.
  func prewarmHwpShell() {
    guard shellState == .cold, loadedURL == nil else { return }
    guard let pageURL = HwpViewerSchemeHandler.pageURL(prewarm: true) else { return }
    shellState = .warming
    logPdfEvent("hwp_prewarm_start", nil)
    webView.load(URLRequest(url: pageURL))
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

  /// Gọi xuống phần trang vỏ **không** phụ thuộc tài liệu. Tách khỏi
  /// `__rhwpEditor` vì cái đó chỉ tồn tại khi đang có tệp mở.
  private func runHost(_ call: String) {
    webView.evaluateJavaScript("window.__rhwpHost?.\(call)", completionHandler: nil)
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

    relay.onRuntimeReady = { [weak self] in
      guard let self else { return }
      guard self.shellState == .warming else { return }
      self.shellState = .warm
      guard self.documentLoadPending else { return }
      // Người dùng đã chọn tệp trong lúc hâm nóng: nạp ngay, không đợi thêm.
      self.documentLoadPending = false
      self.shellState = .document
      logPdfEvent("hwp_shell_reused", "file=\(self.loadedURL?.lastPathComponent ?? "")")
      self.runHost("loadDocument()")
    }

    relay.onRendered = { [weak self] in
      // Đường dùng lại trang vỏ không có navigation nào, nên `didFinish` không
      // chạy và vòng quay phải dừng ở đây.
      self?.activityIndicator.stopAnimating()
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
    switch shellState {
    case .document, .warm:
      // Đóng tài liệu chứ **không** nạp trang trắng: trang trắng vứt luôn cả
      // runtime, và lần mở sau lại phải biên dịch WASM từ đầu. `unload()` chỉ
      // trả lại bộ nhớ của tài liệu.
      documentLoadPending = false
      shellState = .warm
      hwpHandler.documentURL = nil
      runHost("unload()")
    case .warming:
      documentLoadPending = false
    case .cold:
      webView.loadHTMLString("", baseURL: nil)
    }
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
    // Lượt hâm nóng chưa mở tệp nào, nên nó không phải một lượt mở tài liệu —
    // đo nó chung với các lượt kia thì con số mất nghĩa.
    if shellState == .warming {
      logPdfEvent("hwp_prewarm_shell_loaded", nil)
      return
    }
    let shellMs = Int(((CACurrentMediaTime() - shellStart) * 1000).rounded())
    logPdfEvent(
      "document_viewer_loaded",
      "file=\(loadedURL?.lastPathComponent ?? "") shell=\(shellMs)ms"
    )
    // HWP còn parse và vẽ tiếp; các định dạng khác thì nạp xong là hết lượt mở.
    if let loadedURL, !HwpFileType.handles(loadedURL) { PdfEventClock.stop() }
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
    // Trang vỏ không nạp được thì không còn gì để dùng lại.
    shellState = .cold
    documentLoadPending = false
    logPdfEvent("document_viewer_failed", "error=\(error.localizedDescription)")
    showMessage("This file could not be displayed.\n\(error.localizedDescription)")
  }
}
