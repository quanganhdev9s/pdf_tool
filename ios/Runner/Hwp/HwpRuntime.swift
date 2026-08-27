import Flutter
import Foundation
import UIKit

/// Lỗi trả về Flutter từ phía HWP.
///
/// Riêng khỏi `PdfPocError` có chủ ý: hai cầu Pigeon là hai cái độc lập, và
/// dùng chung kiểu lỗi là buộc chúng lại với nhau ở đúng chỗ không cần.
struct HwpError: Error {
  let code: String
  let message: String
  let details: String?

  var pigeonError: PigeonError {
    PigeonError(code: code, message: message, details: details)
  }
}

/// Cầu giữa Flutter và trình xem HWP.
///
/// Giữ view đang trên màn hình, nhận lệnh từ `HwpHostApi` và đẩy trạng thái
/// ngược lên qua `HwpFlutterApi`.
final class HwpRuntime {
  static let shared = HwpRuntime()

  private var viewerView: HwpViewerView?
  private var flutterApi: HwpFlutterApi?

  private init() {}

  func configure(binaryMessenger: FlutterBinaryMessenger) {
    logPdfEvent("hwp_runtime_configure")
    flutterApi = HwpFlutterApi(binaryMessenger: binaryMessenger)
    HwpHostApiSetup.setUp(binaryMessenger: binaryMessenger, api: HwpHostApiImpl())
  }

  func attach(viewerView: HwpViewerView) {
    logPdfEvent("hwp_runtime_attach_viewer")
    self.viewerView = viewerView
    viewerView.delegate = self
  }

  func detach(viewerView: HwpViewerView) {
    guard self.viewerView === viewerView else { return }
    logPdfEvent("hwp_runtime_detach_viewer")
    viewerView.delegate = nil
    viewerView.close()
    self.viewerView = nil
  }

  func requireViewer() throws -> HwpViewerView {
    guard let viewerView else {
      throw HwpError(
        code: "document_not_open",
        message: "The HWP viewer is not on screen.",
        details: nil
      )
    }
    return viewerView
  }
}

extension HwpRuntime: HwpViewerViewDelegate {
  func hwpViewer(_ view: HwpViewerView, didChangeEditorState json: String) {
    guard let state = HwpEditorStateDecoder.decode(json) else { return }
    // Không log mỗi lần: nó bắn ra sau mỗi lần con trỏ nhúc nhích.
    flutterApi?.onEditorStateChanged(state: state) { _ in }
  }

  func hwpViewer(
    _ view: HwpViewerView,
    didSaveEditsWith error: String?,
    contentLoss: String,
    savedPath: String?,
    savedAsFallback: Bool
  ) {
    logPdfEvent(
      "hwp_callback_edits_saved",
      "ok=\(error == nil) fallback=\(savedAsFallback) loss=\(contentLoss.count)"
    )
    flutterApi?.onEditsSaved(
      result: HwpSaveResult(
        ok: error == nil,
        contentLoss: contentLoss.isEmpty ? nil : contentLoss,
        error: error,
        savedPath: savedPath,
        savedAsFallback: savedAsFallback
      )
    ) { _ in }
  }
}

/// Cài đặt `HwpHostApi`. Mọi lệnh đều đi tới đúng một view đang gắn.
private struct HwpHostApiImpl: HwpHostApi {
  func loadDocument(path: String, sourceIsAsset: Bool) throws {
    // Mốc 0 của lượt mở tệp: mọi dòng log native sau đây đóng dấu `t=` theo nó.
    PdfEventClock.start()
    try call { try $0.load(path: path, sourceIsAsset: sourceIsAsset) }
  }

  func setEditingEnabled(enabled: Bool) throws {
    try call { try $0.setEditing(enabled) }
  }

  func saveEdits() throws {
    try call { try $0.saveEdits() }
  }

  func applyCharFormat(format: HwpCharFormat) throws {
    try call { try $0.applyCharFormat(format) }
  }

  func applyParaFormat(format: HwpParaFormat) throws {
    try call { try $0.applyParaFormat(format) }
  }

  func setChromeInset(pixels: Double) throws {
    try call { $0.setChromeInset(pixels) }
  }

  func undo() throws {
    try call { try $0.undoEdit() }
  }

  func redo() throws {
    try call { try $0.redoEdit() }
  }

  func goToPage(pageIndex: Int64) throws {
    try call { $0.goToPage(pageIndex) }
  }

  func find(
    query: String,
    forward: Bool,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    do {
      try call { view in
        view.find(query: query, forward: forward) { found in
          completion(.success(found))
        }
      }
    } catch {
      completion(.failure(pigeonError(from: error)))
    }
  }

  func clearSearch() throws {
    try call { $0.clearSearch() }
  }

  func share() throws {
    try call { try $0.share() }
  }

  func close() throws {
    try call { $0.close() }
  }

  private func call(_ body: (HwpViewerView) throws -> Void) throws {
    do {
      try body(try HwpRuntime.shared.requireViewer())
    } catch {
      throw pigeonError(from: error)
    }
  }

  private func pigeonError(from error: Error) -> Error {
    (error as? HwpError)?.pigeonError ?? error
  }
}

/// Trang vỏ gửi JSON thô. Hình dạng của nó là hợp đồng giữa `editor.js` và
/// `HwpEditorState`; ở giữa chỉ có chỗ này biết cả hai.
private enum HwpEditorStateDecoder {
  static func decode(_ json: String) -> HwpEditorState? {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      logPdfEvent("hwp_editor_state_decode_failed", json.prefix(120).description)
      return nil
    }
    func flag(_ key: String) -> Bool { object[key] as? Bool ?? false }
    return HwpEditorState(
      hasCaret: flag("hasCaret"),
      hasSelection: flag("hasSelection"),
      bold: flag("bold"),
      italic: flag("italic"),
      underline: flag("underline"),
      strikethrough: flag("strikethrough"),
      fontSizePt: object["fontSizePt"] as? Double,
      alignment: object["alignment"] as? String,
      lineSpacing: object["lineSpacing"] as? Double,
      canUndo: flag("canUndo"),
      canRedo: flag("canRedo"),
      dirty: flag("dirty"),
      pageIndex: Int64(object["pageIndex"] as? Int ?? 0),
      // Ít nhất 1: thanh lật trang chia cho số này để hiện "trang/tổng".
      pageCount: Int64(max(1, object["pageCount"] as? Int ?? 1))
    )
  }
}

// MARK: - Platform view

final class HwpViewerPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    HwpViewerPlatformView(frame: frame)
  }
}

final class HwpViewerPlatformView: NSObject, FlutterPlatformView {
  private let viewerView: HwpViewerView

  init(frame: CGRect) {
    viewerView = HwpViewerViewPool.shared.acquire(frame: frame)
    super.init()
    HwpRuntime.shared.attach(viewerView: viewerView)
  }

  deinit {
    HwpRuntime.shared.detach(viewerView: viewerView)
    HwpViewerViewPool.shared.release(viewerView)
  }

  func view() -> UIView {
    viewerView
  }
}

/// Giữ một `HwpViewerView` sống ngoài vòng đời của platform view.
///
/// Dựng `WKWebView` là bắt WebKit spawn cả một cụm process — đo được ~1.7s ở
/// lượt đầu. Flutter mount rồi unmount platform view mỗi lần mở tài liệu, nên
/// view chết theo là lần nào cũng trả lại khoản đó.
final class HwpViewerViewPool {
  static let shared = HwpViewerViewPool()

  private var idle: HwpViewerView?

  /// Bản rảnh đỗ ngoài mép cửa sổ: 1pt, không nhận chạm, không ai thấy.
  private static let parkedFrame = CGRect(x: -2, y: -2, width: 1, height: 1)

  /// Dựng sẵn web view và hâm nóng trang vỏ. Gọi lúc khởi động app.
  func prewarm() {
    let view = idle ?? HwpViewerView(frame: Self.parkedFrame)
    idle = view
    park(view)
    view.prewarmHwpShell()
  }

  /// View cho Flutter gắn vào — bản đã hâm nóng nếu có.
  func acquire(frame: CGRect) -> HwpViewerView {
    if let view = idle {
      idle = nil
      view.removeFromSuperview()
      view.isUserInteractionEnabled = true
      view.frame = frame
      logPdfEvent("hwp_viewer_reused")
      return view
    }
    return HwpViewerView(frame: frame)
  }

  /// Nhận view về sau khi Flutter bỏ nó, và hâm nóng lại cho lượt mở sau.
  func release(_ view: HwpViewerView) {
    view.removeFromSuperview()
    // Hai web view ẩn không nhanh hơn một cái.
    guard idle == nil else { return }
    idle = view
    park(view)
    view.prewarmHwpShell()
  }

  /// Gắn bản rảnh vào cửa sổ. Bắt buộc: `WKWebView` không nằm trong cửa sổ nào
  /// thì WebKit hãm tiến trình web lại và phần hâm nóng thành công cốc.
  private func park(_ view: HwpViewerView) {
    guard view.superview == nil else { return }
    guard let window = Self.keyWindow() else {
      // Cửa sổ chưa có lúc app vừa khởi động. Thử lại một lần rồi thôi — hâm
      // nóng hỏng thì chỉ chậm như cũ chứ không sai.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak view] in
        guard let self, let view, view === self.idle, view.superview == nil else { return }
        guard let window = Self.keyWindow() else {
          logPdfEvent("hwp_prewarm_no_window")
          return
        }
        self.park(view, in: window)
      }
      return
    }
    park(view, in: window)
  }

  private func park(_ view: HwpViewerView, in window: UIWindow) {
    view.frame = Self.parkedFrame
    view.isUserInteractionEnabled = false
    window.addSubview(view)
  }

  private static func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    return windows.first { $0.isKeyWindow } ?? windows.first
  }
}
