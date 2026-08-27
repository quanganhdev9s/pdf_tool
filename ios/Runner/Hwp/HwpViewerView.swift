import Foundation
import Flutter
import UIKit
import WebKit

/// Những gì trình soạn thảo muốn nói ngược ra ngoài. `HwpRuntime` nhận và
/// chuyển tiếp sang Flutter — view này không biết gì về Pigeon.
protocol HwpViewerViewDelegate: AnyObject {
  /// Con trỏ, vùng chọn hoặc nội dung vừa đổi. `json` là nguyên văn từ trang
  /// vỏ.
  func hwpViewer(_ view: HwpViewerView, didChangeEditorState json: String)

  /// Một lần ghi tài liệu đã xong. `contentLoss` rỗng nghĩa là không mất gì.
  func hwpViewer(
    _ view: HwpViewerView,
    didSaveEditsWith error: String?,
    contentLoss: String,
    savedPath: String?,
    savedAsFallback: Bool
  )
}

/// Vẽ tệp HWP trong bố cục Flutter bằng `WKWebView`.
///
/// WebKit không hiểu định dạng này và iOS cũng không có bộ chuyển đổi nào, nên
/// web view ở đây không nạp tệp — nó nạp một trang vỏ, và rhwp (Rust/WASM) dàn
/// trang rồi vẽ ra SVG. Xem `HwpViewerSchemeHandler`.
///
/// Không có gì của hệ thống chen vào như `QLPreviewController`, nên Flutter sở
/// hữu cả màn hình: app bar, thanh công cụ và mọi thứ quanh tài liệu.
final class HwpViewerView: UIView {
  private let webView: WKWebView
  private let activityIndicator = UIActivityIndicatorView(style: .large)
  private let messageLabel = UILabel()
  private var sourceURL: URL?
  private var loadedURL: URL?

  /// Phục vụ trang xem HWP. Phải gắn vào `WKWebViewConfiguration` **trước** khi
  /// dựng web view — đăng ký scheme sau đó là không được.
  private let hwpHandler = HwpViewerSchemeHandler()
  private let relay = HwpViewerLogRelay()

  /// Tài liệu đang mở trong trình soạn thảo, nếu có. `nil` là đang chỉ xem.
  private var editingURL: URL?

  /// File đích thật khi bấm Save. Viewer vẫn đọc/ghi trong phiên hiện tại từ
  /// working copy tạm; chỉ lệnh Save mới chạm vào URL này.
  private var saveTargetURL: URL?

  /// Mốc bắt đầu nạp, để đo riêng khoảng dựng trang vỏ.
  private var shellStart: CFTimeInterval = 0

  /// Trang vỏ HWP đang ở đâu trong vòng đời của nó. Có mặt để mở tệp sau không
  /// phải nạp lại trang — nạp lại là biên dịch lại 7.7MB WASM.
  private enum ShellState {
    /// Web view đang trống — chưa nạp trang vỏ, hoặc lần nạp đã hỏng.
    case cold
    /// Đang nạp trang vỏ ở chế độ hâm nóng; runtime chưa sẵn sàng.
    case warming
    /// Runtime đã biên dịch xong và đang chờ tài liệu.
    case warm
    /// Đang có tài liệu mở trên trang vỏ.
    case document
  }

  private var shellState: ShellState = .cold

  /// Mở tệp trong lúc trang vỏ còn đang hâm nóng: đợi `hwp_runtime_ready`.
  private var documentLoadPending = false

  weak var delegate: HwpViewerViewDelegate?

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
      "hwp_viewer_webview_built",
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

  func load(path: String, sourceIsAsset: Bool) throws {
    let sourceURL = try resolveSourceURL(path: path, sourceIsAsset: sourceIsAsset)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw HwpError(
        code: "asset_not_found",
        message: "The document to view no longer exists.",
        details: path
      )
    }
    guard HwpFileType.handles(sourceURL) else {
      throw HwpError(
        code: "unsupported_source_format",
        message: "This viewer only opens HWP documents.",
        details: sourceURL.lastPathComponent
      )
    }
    let previousSourceURL = self.sourceURL
    try clearWorkingDirectory()
    let workingURL = try makeWorkingCopy(from: sourceURL)
    if previousSourceURL?.standardizedFileURL.path != sourceURL.standardizedFileURL.path {
      cleanupTemporaryURL(previousSourceURL)
    }
    loadedURL = workingURL
    self.sourceURL = sourceURL
    saveTargetURL = sourceIsAsset ? nil : sourceURL
    shellStart = CACurrentMediaTime()
    // Nạp tệp khác là trang vỏ mới: chế độ sửa của tệp cũ không còn nữa.
    editingURL = nil
    showMessage(nil)
    activityIndicator.startAnimating()
    hwpHandler.documentURL = workingURL
    guard let pageURL = HwpViewerSchemeHandler.pageURL() else {
      throw HwpError(
        code: "internal_error",
        message: "Could not build the HWP viewer URL.",
        details: nil
      )
    }
    logPdfEvent(
      "hwp_viewer_load",
      "source=\(sourceURL.lastPathComponent) asset=\(sourceIsAsset) working=\(workingURL.lastPathComponent)"
    )

    switch shellState {
    case .warm, .document:
      // Runtime đã chạy: chỉ cần bảo nó đi lấy tệp mới ở `/document`.
      shellState = .document
      logPdfEvent("hwp_shell_reused", "file=\(workingURL.lastPathComponent)")
      runHost("loadDocument()")
    case .warming:
      documentLoadPending = true
      logPdfEvent("hwp_shell_warming", "file=\(sourceURL.lastPathComponent)")
    case .cold:
      shellState = .document
      webView.load(URLRequest(url: pageURL))
    }
  }

  private func resolveSourceURL(path: String, sourceIsAsset: Bool) throws -> URL {
    guard sourceIsAsset else { return URL(fileURLWithPath: path) }
    let assetPath = FlutterDartProject.lookupKey(forAsset: path)
    let assetName = (assetPath as NSString).deletingPathExtension
    let assetExtension = (assetPath as NSString).pathExtension
    guard let url = Bundle.main.url(forResource: assetName, withExtension: assetExtension) else {
      throw HwpError(
        code: "asset_not_found",
        message: "The Flutter asset was not found in the app bundle.",
        details: assetPath
      )
    }
    return url
  }

  private func makeWorkingCopy(from sourceURL: URL) throws -> URL {
    let directory = try workingDirectory()
    let fileName = sourceURL.lastPathComponent.isEmpty ? "document.hwp" : sourceURL.lastPathComponent
    let workingURL = directory.appendingPathComponent(fileName)
    try FileManager.default.copyItem(at: sourceURL, to: workingURL)
    logPdfEvent(
      "hwp_working_copy_created",
      "source=\(sourceURL.lastPathComponent) working=\(workingURL.lastPathComponent)"
    )
    return workingURL
  }

  private func workingDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hwp_viewer_working", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func clearWorkingDirectory() throws {
    let directory = try workingDirectory()
    let contents = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    for url in contents {
      try FileManager.default.removeItem(at: url)
    }
    logPdfEvent("hwp_working_directory_cleared", "count=\(contents.count)")
  }

  private func clearWorkingDirectoryIgnoringErrors() {
    do {
      try clearWorkingDirectory()
    } catch {
      logPdfEvent("hwp_working_directory_clear_failed", "error=\(error)")
    }
  }

  /// Nạp trước trang vỏ HWP mà chưa mở tệp nào. Tới lúc người dùng chọn tệp thì
  /// process WebKit đã chạy và WASM đã biên dịch, chỉ còn phần parse.
  func prewarmHwpShell() {
    guard shellState == .cold, loadedURL == nil else { return }
    guard let pageURL = HwpViewerSchemeHandler.pageURL(prewarm: true) else { return }
    shellState = .warming
    logPdfEvent("hwp_prewarm_start", nil)
    webView.load(URLRequest(url: pageURL))
  }

  /// `window.find` chọn được kết quả nhưng WebKit tô nó rất nhạt, và nhạt thêm
  /// khi web view không còn là first responder. Đổi kiểu `::selection` làm kết
  /// quả hiện lên như một vệt đánh dấu mà không đụng vào DOM của tài liệu, nên
  /// tìm nhiều lần cũng không làm hỏng nội dung.
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

  /// Tìm chữ qua `searchText` của rhwp, **không** phải `window.find`: trang vỏ
  /// chỉ dựng những trang quanh khung nhìn, tìm trên DOM là bỏ sót phần còn lại.
  func find(query: String, forward: Bool, completion: @escaping (Bool) -> Void) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      clearSearch()
      completion(false)
      return
    }
    let script = "window.__rhwpEditor?.find(\(Self.jsString(trimmed)), \(forward))"
    webView.evaluateJavaScript(script) { result, error in
      let found = (result as? Bool) ?? false
      if let error {
        logPdfEvent("hwp_viewer_find_failed", "error=\(error.localizedDescription)")
      } else {
        logPdfEvent("hwp_viewer_find", "query=\(trimmed) forward=\(forward) found=\(found)")
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
      throw HwpError(
        code: "document_not_open",
        message: "No document is open in the viewer.",
        details: nil
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
      throw HwpError(
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
  private static func jsString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(
            withJSONObject: [value], options: .fragmentsAllowed
          ),
          let wrapped = String(data: data, encoding: .utf8) else {
      return "\"\""
    }
    return String(wrapped.dropFirst().dropLast())
  }

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
      self.saveExportedData(data, replacing: url, contentLoss: contentLoss)
    }

    relay.onExportFailed = { [weak self] message in
      self?.reportSave(error: message)
    }

    relay.onRuntimeReady = { [weak self] in
      guard let self else { return }
      guard self.shellState == .warming else { return }
      self.shellState = .warm
      guard self.documentLoadPending else { return }
      self.documentLoadPending = false
      self.shellState = .document
      logPdfEvent("hwp_shell_reused", "file=\(self.loadedURL?.lastPathComponent ?? "")")
      self.runHost("loadDocument()")
    }

    relay.onRendered = { [weak self] in
      // Đường dùng lại trang vỏ không có navigation, `didFinish` không chạy.
      self?.activityIndicator.stopAnimating()
    }

    relay.onStateChanged = { [weak self] json in
      guard let self else { return }
      self.delegate?.hwpViewer(self, didChangeEditorState: json)
    }
  }

  /// Cố ghi đè file đích trước; nếu đường đó hỏng thì lưu bản sao vào
  /// Documents/Imported để người dùng không mất lần sửa vừa export.
  private func saveExportedData(_ data: Data, replacing url: URL, contentLoss: String) {
    guard let targetURL = saveTargetURL else {
      logPdfEvent("hwp_editor_save_without_target", "file=\(url.lastPathComponent)")
      saveImportedCopy(
        data,
        originalURL: sourceURL ?? url,
        replaceError: nil,
        contentLoss: contentLoss
      )
      return
    }

    let scratch = targetURL.deletingLastPathComponent()
      .appendingPathComponent("hwp-save-\(UUID().uuidString).tmp")
    do {
      // Ghi qua tệp tạm rồi thay chỗ: hỏng giữa chừng thì bản cũ vẫn nguyên.
      try data.write(to: scratch, options: .atomic)
      _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: scratch)
      refreshWorkingCopy(data, at: url)
      logPdfEvent(
        "hwp_editor_saved",
        "file=\(targetURL.lastPathComponent) bytes=\(data.count) loss=\(contentLoss.count)"
      )
      reportSave(error: nil, contentLoss: contentLoss, savedPath: targetURL.path)
    } catch {
      try? FileManager.default.removeItem(at: scratch)
      logPdfEvent("hwp_editor_replace_failed", "error=\(error)")
      saveImportedCopy(data, originalURL: targetURL, replaceError: error, contentLoss: contentLoss)
    }
  }

  private func saveImportedCopy(
    _ data: Data,
    originalURL: URL,
    replaceError: Error?,
    contentLoss: String
  ) {
    do {
      let fallbackURL = try fallbackURL(for: originalURL)
      try data.write(to: fallbackURL, options: .atomic)
      if let loadedURL {
        refreshWorkingCopy(data, at: loadedURL)
      }
      saveTargetURL = fallbackURL
      logPdfEvent(
        "hwp_editor_saved_fallback",
        "file=\(fallbackURL.lastPathComponent) bytes=\(data.count) loss=\(contentLoss.count)"
      )
      reportSave(
        error: nil,
        contentLoss: contentLoss,
        savedPath: fallbackURL.path,
        savedAsFallback: true
      )
    } catch {
      logPdfEvent("hwp_editor_save_fallback_failed", "error=\(error)")
      if let replaceError {
        reportSave(
          error: "Không ghi đè được file gốc: \(replaceError.localizedDescription). Không lưu được bản sao: \(error.localizedDescription)"
        )
      } else {
        reportSave(error: "Không lưu được bản sao: \(error.localizedDescription)")
      }
    }
  }

  private func fallbackURL(for originalURL: URL) throws -> URL {
    let directory = try importedDirectory()
    let baseName = originalURL.deletingPathExtension().lastPathComponent
    let base = baseName.isEmpty ? "HWP Edited" : "\(baseName) Edited"
    let pathExtension = originalURL.pathExtension.isEmpty ? "hwp" : originalURL.pathExtension
    var candidate = directory.appendingPathComponent(base).appendingPathExtension(pathExtension)
    var suffix = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = directory
        .appendingPathComponent("\(base) (\(suffix))")
        .appendingPathExtension(pathExtension)
      suffix += 1
    }
    return candidate
  }

  private func importedDirectory() throws -> URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let directory = documents.appendingPathComponent("Imported", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func refreshWorkingCopy(_ data: Data, at url: URL) {
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      logPdfEvent("hwp_working_copy_refresh_failed", "error=\(error)")
    }
  }

  private func reportSave(
    error: String?,
    contentLoss: String = "",
    savedPath: String? = nil,
    savedAsFallback: Bool = false
  ) {
    delegate?.hwpViewer(
      self,
      didSaveEditsWith: error,
      contentLoss: contentLoss,
      savedPath: savedPath,
      savedAsFallback: savedAsFallback
    )
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
    logPdfEvent("hwp_keyboard_inset", "inset=\(Int(inset.rounded())) event=\(notification.name.rawValue)")
    runEditor("setKeyboardInset(\(Int(inset.rounded())))")
  }

  func clearSearch() {
    runEditor("clearFind()")
  }

  /// Hands the viewed file to the system share sheet. The file stays where it
  /// is; only a copy is exported by whatever destination the user picks.
  func share() throws {
    guard let loadedURL else {
      throw HwpError(
        code: "document_not_open",
        message: "No document is open in the viewer.",
        details: nil
      )
    }
    guard let presenter = nearestViewController() else {
      throw HwpError(
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
    logPdfEvent("hwp_viewer_share", "file=\(loadedURL.lastPathComponent)")
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

  /// Removes only temporary viewer copies. Files in Documents/Imported are the
  /// user's library and must survive closing this screen.
  func close() {
    logPdfEvent("hwp_viewer_close", "file=\(loadedURL?.lastPathComponent ?? "")")
    webView.stopLoading()
    switch shellState {
    case .document, .warm:
      // Không nạp trang trắng: nó vứt luôn runtime. `unload()` chỉ trả lại bộ
      // nhớ của tài liệu.
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
    clearWorkingDirectoryIgnoringErrors()
    cleanupTemporaryURL(sourceURL)
    sourceURL = nil
    loadedURL = nil
    editingURL = nil
    saveTargetURL = nil
  }

  private func cleanupTemporaryURL(_ url: URL?) {
    guard let url, isTemporaryURL(url) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private func isTemporaryURL(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    let tempPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
    return path.hasPrefix(tempPath)
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

extension HwpViewerView: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    activityIndicator.stopAnimating()
    // Bỏ thanh phụ trợ bàn phím của iOS. Phải đợi tới đây: view nhận bàn phím
    // chỉ tồn tại sau khi trang đã nạp. Xem `WKWebView+InputAccessory.swift`.
    webView.removeInputAccessoryView()
    // Lượt hâm nóng chưa mở tệp nào, đo chung với các lượt kia thì mất nghĩa.
    if shellState == .warming {
      logPdfEvent("hwp_prewarm_shell_loaded", nil)
      return
    }
    let shellMs = Int(((CACurrentMediaTime() - shellStart) * 1000).rounded())
    logPdfEvent(
      "hwp_viewer_shell_loaded",
      "file=\(loadedURL?.lastPathComponent ?? "") shell=\(shellMs)ms"
    )
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
    logPdfEvent("hwp_viewer_failed", "error=\(error.localizedDescription)")
    showMessage("This file could not be displayed.\n\(error.localizedDescription)")
  }
}
