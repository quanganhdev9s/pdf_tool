import Foundation
import UIKit
import UniformTypeIdentifiers

protocol PdfScanCaptureManagerDelegate: AnyObject {
  func captureManager(_ manager: PdfScanCaptureManager, didCreate session: PdfScanSessionRecord)
  func captureManagerDidCancel(_ manager: PdfScanCaptureManager)
  func captureManager(_ manager: PdfScanCaptureManager, didFailWith error: PdfPocError)
}

/// Presents the capture surface and lands its output as page files in a
/// new session. Deliberately produces no PDF: export is a separate, explicit
/// step the user confirms from the review screen.
final class PdfScanCaptureManager: NSObject {
  weak var delegate: PdfScanCaptureManagerDelegate?

  private let store: PdfScanSessionStore
  private let workQueue = DispatchQueue(label: "pdf.scan.capture", qos: .userInitiated)
  private weak var activeController: UIViewController?
  private var isCapturing = false

  init(store: PdfScanSessionStore) {
    self.store = store
    super.init()
  }

  // MARK: - Entry points

  func startDocumentCapture(presenter: UIViewController) throws {
    try ensureIdle()
    isCapturing = true
    let camera = PdfScanCameraViewController()
    camera.delegate = self
    camera.modalPresentationStyle = .fullScreen
    activeController = camera
    logPdfEvent("scan_capture_present", "source=scanner")
    presenter.present(camera, animated: true)
  }

  func cancel() {
    DispatchQueue.main.async { [weak self] in
      self?.activeController?.dismiss(animated: true)
    }
  }

  private func ensureIdle() throws {
    guard Thread.isMainThread else {
      throw PdfPocError(
        code: "internal_error",
        message: "Scan capture must be presented from the main thread.",
        details: nil
      )
    }
    guard !isCapturing else {
      throw PdfPocError(
        code: "operation_in_progress",
        message: "A scan capture is already running.",
        details: nil
      )
    }
  }

  private func finishCancelled() {
    isCapturing = false
    activeController = nil
    logPdfEvent("scan_capture_cancelled")
    delegate?.captureManagerDidCancel(self)
  }

  private func finish(with session: PdfScanSessionRecord) {
    isCapturing = false
    activeController = nil
    logPdfEvent("scan_capture_finished", "sessionId=\(session.id) pages=\(session.pages.count)")
    delegate?.captureManager(self, didCreate: session)
  }

  private func fail(_ error: PdfPocError, discarding session: PdfScanSessionRecord?) {
    isCapturing = false
    activeController = nil
    if let session {
      store.discardSession(withId: session.id)
    }
    logPdfEvent("scan_capture_failed", "code=\(error.code) message=\(error.message)")
    delegate?.captureManager(self, didFailWith: error)
  }

  // MARK: - Camera ingest

  /// The session is created by the first page rather than at presentation, so
  /// cancelling before shooting anything leaves nothing on disk to sweep.
  ///
  /// Chỉ đụng tới trên `workQueue`. Trang được ghi ở đó còn lỗi lại đến từ main,
  /// nên mọi đường vào phải quy về cùng một hàng đợi.
  private var cameraSession: PdfScanSessionRecord?

  /// Writes one captured page immediately. Pages are never accumulated in
  /// memory: at full capture resolution a long scan would not survive it.
  private func appendCameraPage(_ image: UIImage) {
    workQueue.async { [weak self] in
      guard let self else { return }
      do {
        let session = try self.cameraSession ?? self.store.createSession(source: .scanner)
        self.cameraSession = session
        try autoreleasepool {
          try self.appendPage(image: image, to: session)
        }
      } catch let error as PdfPocError {
        self.failCameraSession(error)
      } catch {
        self.failCameraSession(
          PdfPocError(
            code: "scan_failed",
            message: "Could not store the captured page.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  private func failCameraSession(_ error: PdfPocError) {
    workQueue.async { [weak self] in
      guard let self else { return }
      let session = self.cameraSession
      self.cameraSession = nil
      DispatchQueue.main.async {
        self.activeController?.dismiss(animated: true)
        self.fail(error, discarding: session)
      }
    }
  }

  private func appendPage(image: UIImage, to session: PdfScanSessionRecord) throws {
    let pageId = UUID().uuidString
    let destination = store.originalImageURL(for: session, pageId: pageId)
    try write(image: image, to: destination, pageId: pageId)
    session.pages.append(PdfScanPageRecord(id: pageId, originalURL: destination))
  }

  private func write(image: UIImage, to destination: URL, pageId: String) throws {
    var timer = StepTimer()
    guard let data = image.jpegData(compressionQuality: 0.95) else {
      throw PdfPocError(
        code: "scan_failed",
        message: "Could not encode a scanned page.",
        details: "pageId=\(pageId)"
      )
    }
    let encodeMs = timer.lap()
    try data.write(to: destination, options: .atomic)
    logPdfEvent(
      "scan_page_written",
      "pageId=\(pageId) size=\(Int(image.size.width))x\(Int(image.size.height))"
        + " bytes=\(data.count) encode=\(encodeMs)ms disk=\(timer.lap())ms"
    )
  }

}

extension PdfScanCaptureManager: PdfScanCameraViewControllerDelegate {
  func cameraController(_ controller: PdfScanCameraViewController, didCapture page: UIImage) {
    appendCameraPage(page)
  }

  /// Re-crop of the page already written: same record, same file, new pixels.
  ///
  /// Overwriting rather than appending is what keeps the page count and the
  /// order the user is looking at intact — from their side they adjusted a
  /// page, they did not add one.
  func cameraController(
    _ controller: PdfScanCameraViewController,
    didAdjustLastPage page: UIImage
  ) {
    workQueue.async { [weak self] in
      guard let self,
            let session = self.cameraSession,
            let last = session.pages.last else {
        return
      }
      do {
        try autoreleasepool {
          try self.write(image: page, to: last.originalURL, pageId: last.id)
        }
        logPdfEvent("scan_capture_page_adjusted", "pageId=\(last.id)")
      } catch let error as PdfPocError {
        self.failCameraSession(error)
      } catch {
        self.failCameraSession(
          PdfPocError(
            code: "scan_failed",
            message: "Could not store the adjusted page.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  func cameraControllerDidFinish(_ controller: PdfScanCameraViewController) {
    controller.dismiss(animated: true)
    // Writes are queued; hop through the same queue so the session reported
    // here has every page the user shot.
    workQueue.async { [weak self] in
      guard let self else { return }
      let session = self.cameraSession
      self.cameraSession = nil
      DispatchQueue.main.async {
        guard let session, !session.pages.isEmpty else {
          if let session { self.store.discardSession(withId: session.id) }
          self.finishCancelled()
          return
        }
        self.finish(with: session)
      }
    }
  }

  func cameraControllerDidCancel(_ controller: PdfScanCameraViewController) {
    controller.dismiss(animated: true)
    workQueue.async { [weak self] in
      guard let self else { return }
      if let session = self.cameraSession {
        self.store.discardSession(withId: session.id)
      }
      self.cameraSession = nil
      DispatchQueue.main.async { self.finishCancelled() }
    }
  }

  func cameraController(
    _ controller: PdfScanCameraViewController,
    didFailWith error: PdfPocError
  ) {
    controller.dismiss(animated: true)
    failCameraSession(error)
  }
}

