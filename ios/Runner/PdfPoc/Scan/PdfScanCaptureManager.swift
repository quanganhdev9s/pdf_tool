import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

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

  func startAppleDocumentScan(presenter: UIViewController) throws {
    try ensureIdle()
    guard VNDocumentCameraViewController.isSupported else {
      throw PdfPocError(
        code: "scanner_unavailable",
        message: "The document scanner is not available on this device.",
        details: "VNDocumentCameraViewController.isSupported=false"
      )
    }
    isCapturing = true
    let scanner = VNDocumentCameraViewController()
    scanner.delegate = self
    activeController = scanner
    logPdfEvent("scan_capture_present", "source=scanner")
    presenter.present(scanner, animated: true)
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

  // MARK: - VisionKit ingest

  /// Writes each scanned page to disk one at a time inside an autorelease pool.
  /// A 30-page scan at full resolution would not survive holding every
  /// `UIImage` at once.
  private func ingest(scan: VNDocumentCameraScan) {
    workQueue.async { [weak self] in
      guard let self else { return }
      var session: PdfScanSessionRecord?
      do {
        let created = try self.store.createSession(source: .scanner)
        session = created
        for pageIndex in 0..<scan.pageCount {
          try autoreleasepool {
            let image = scan.imageOfPage(at: pageIndex)
            try self.appendPage(image: image, to: created)
          }
        }
        guard !created.pages.isEmpty else {
          throw PdfPocError(
            code: "scan_failed",
            message: "The scanner returned no usable pages.",
            details: nil
          )
        }
        DispatchQueue.main.async { self.finish(with: created) }
      } catch let error as PdfPocError {
        DispatchQueue.main.async { self.fail(error, discarding: session) }
      } catch {
        DispatchQueue.main.async {
          self.fail(
            PdfPocError(
              code: "scan_failed",
              message: "Could not store the scanned pages.",
              details: error.localizedDescription
            ),
            discarding: session
          )
        }
      }
    }
  }

  private func appendPage(image: UIImage, to session: PdfScanSessionRecord) throws {
    let pageId = UUID().uuidString
    let destination = store.originalImageURL(for: session, pageId: pageId)
    guard let data = image.jpegData(compressionQuality: 0.95) else {
      throw PdfPocError(
        code: "scan_failed",
        message: "Could not encode a scanned page.",
        details: "pageId=\(pageId)"
      )
    }
    try data.write(to: destination, options: .atomic)
    session.pages.append(PdfScanPageRecord(id: pageId, originalURL: destination))
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

extension PdfScanCaptureManager: VNDocumentCameraViewControllerDelegate {
  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFinishWith scan: VNDocumentCameraScan
  ) {
    controller.dismiss(animated: true) { [weak self] in
      self?.ingest(scan: scan)
    }
  }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    controller.dismiss(animated: true) { [weak self] in
      self?.finishCancelled()
    }
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFailWithError error: Error
  ) {
    controller.dismiss(animated: true) { [weak self] in
      guard let self else { return }
      self.fail(
        PdfPocError(
          code: "scan_failed",
          message: "The document scanner reported a failure.",
          details: error.localizedDescription
        ),
        discarding: nil
      )
    }
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
