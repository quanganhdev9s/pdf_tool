import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

protocol PdfScanCaptureManagerDelegate: AnyObject {
  func captureManager(_ manager: PdfScanCaptureManager, didCreate session: PdfScanSessionRecord)
  func captureManagerDidCancel(_ manager: PdfScanCaptureManager)
  func captureManager(_ manager: PdfScanCaptureManager, didFailWith error: PdfPocError)
}

/// Presents the two capture surfaces and lands their output as page files in a
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

  func pickScanImages(presenter: UIViewController) throws {
    try ensureIdle()
    isCapturing = true
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = 0
    configuration.selection = .ordered
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    activeController = picker
    logPdfEvent("scan_capture_present", "source=photoPicker")
    presenter.present(picker, animated: true)
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
        DispatchQueue.main.async { self.failCameraSession(error) }
      } catch {
        DispatchQueue.main.async {
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
  }

  private func failCameraSession(_ error: PdfPocError) {
    let session = cameraSession
    cameraSession = nil
    activeController?.dismiss(animated: true)
    fail(error, discarding: session)
  }

  private func appendPage(image: UIImage, to session: PdfScanSessionRecord) throws {
    let pageId = UUID().uuidString
    let destination = store.originalImageURL(for: session, pageId: pageId)
    try write(image: image, to: destination, pageId: pageId)
    session.pages.append(PdfScanPageRecord(id: pageId, originalURL: destination))
  }

  private func write(image: UIImage, to destination: URL, pageId: String) throws {
    guard let data = image.jpegData(compressionQuality: 0.95) else {
      throw PdfPocError(
        code: "scan_failed",
        message: "Could not encode a scanned page.",
        details: "pageId=\(pageId)"
      )
    }
    try data.write(to: destination, options: .atomic)
  }

  // MARK: - Photo picker ingest

  /// `PHPickerResult` file representations are only valid inside their
  /// callback, so each is copied into the session before the next is requested.
  private func ingest(pickerResults results: [PHPickerResult]) {
    workQueue.async { [weak self] in
      guard let self else { return }
      do {
        let session = try self.store.createSession(source: .photoPicker)
        self.copyPickedImage(at: 0, results: results, into: session)
      } catch let error as PdfPocError {
        DispatchQueue.main.async { self.fail(error, discarding: nil) }
      } catch {
        DispatchQueue.main.async {
          self.fail(
            PdfPocError(
              code: "scan_storage_failed",
              message: "Could not prepare storage for the selected images.",
              details: error.localizedDescription
            ),
            discarding: nil
          )
        }
      }
    }
  }

  private func copyPickedImage(
    at index: Int,
    results: [PHPickerResult],
    into session: PdfScanSessionRecord
  ) {
    guard index < results.count else {
      guard !session.pages.isEmpty else {
        DispatchQueue.main.async {
          self.fail(
            PdfPocError(
              code: "image_pick_failed",
              message: "None of the selected items could be read as an image.",
              details: nil
            ),
            discarding: session
          )
        }
        return
      }
      DispatchQueue.main.async { self.finish(with: session) }
      return
    }

    let provider = results[index].itemProvider
    guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
      copyPickedImage(at: index + 1, results: results, into: session)
      return
    }

    provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] sourceURL, error in
      guard let self else { return }
      if let error {
        DispatchQueue.main.async {
          self.fail(
            PdfPocError(
              code: "image_pick_failed",
              message: "Could not read one of the selected images.",
              details: error.localizedDescription
            ),
            discarding: session
          )
        }
        return
      }
      guard let sourceURL else {
        self.copyPickedImage(at: index + 1, results: results, into: session)
        return
      }

      let pageId = UUID().uuidString
      let fileExtension = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
      let destination = self.store.originalImageURL(
        for: session,
        pageId: pageId,
        fileExtension: fileExtension
      )
      do {
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        session.pages.append(PdfScanPageRecord(id: pageId, originalURL: destination))
        self.copyPickedImage(at: index + 1, results: results, into: session)
      } catch {
        DispatchQueue.main.async {
          self.fail(
            PdfPocError(
              code: "image_pick_failed",
              message: "Could not copy a selected image into the scan session.",
              details: error.localizedDescription
            ),
            discarding: session
          )
        }
      }
    }
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
        DispatchQueue.main.async { self.failCameraSession(error) }
      } catch {
        DispatchQueue.main.async {
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

extension PdfScanCaptureManager: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true) { [weak self] in
      guard let self else { return }
      if results.isEmpty {
        self.finishCancelled()
      } else {
        self.ingest(pickerResults: results)
      }
    }
  }
}
