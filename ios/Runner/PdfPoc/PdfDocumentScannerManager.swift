import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Owns POC 7 scanner orchestration: support checks, UIKit presentation,
/// VisionKit delegate callbacks, cancellation, and handoff to the scanned-PDF
/// writer without sending scan images over Pigeon.
final class PdfDocumentScannerManager: NSObject {
  var onProgress: ((String, Int64, Int64) -> Void)?
  var onCompleted: ((String, PdfDocumentScanResult?, Bool) -> Void)?
  var onError: ((String, PdfPocError) -> Void)?
  var onGeneratedDocumentReady: ((URL) -> Void)?

  private let workQueue = DispatchQueue(label: "pdf.poc.document_scanner", qos: .userInitiated)
  private let writer = PdfScannedDocumentWriter()
  private let stateLock = NSLock()
  private var activeOperationId: String?
  private var activeRequest: PdfDocumentScanRequest?
  private var activeOutputURL: URL?
  private weak var activeController: UIViewController?
  private var cancelledOperationIds = Set<String>()

  func start(request: PdfDocumentScanRequest, outputURL: URL, presenter: UIViewController) throws {
    try ensurePresenterThread()
    guard VNDocumentCameraViewController.isSupported else {
      throw PdfPocError(
        code: "scanner_unavailable",
        message: "Apple document scanner is not available on this environment.",
        details: "VNDocumentCameraViewController.isSupported=false"
      )
    }
    guard activeOperationId == nil else {
      throw PdfPocError(
        code: "operation_in_progress",
        message: "A document scan is already running.",
        details: nil
      )
    }

    let operationId = UUID().uuidString
    setActive(operationId: operationId, request: request, outputURL: outputURL)
    let scanner = VNDocumentCameraViewController()
    scanner.delegate = self
    activeController = scanner
    logPdfEvent(
      "document_scan_present",
      "operationId=\(operationId) output=\(outputURL.path) quality=\(request.quality)"
    )
    presenter.present(scanner, animated: true)
  }

  func pickImages(request: PdfDocumentScanRequest, outputURL: URL, presenter: UIViewController) throws {
    try ensurePresenterThread()
    guard activeOperationId == nil else {
      throw PdfPocError(
        code: "operation_in_progress",
        message: "A document scan or image pick operation is already running.",
        details: nil
      )
    }

    let operationId = UUID().uuidString
    setActive(operationId: operationId, request: request, outputURL: outputURL)
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = 0
    if #available(iOS 15.0, *) {
      configuration.selection = .ordered
    }
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    activeController = picker
    logPdfEvent(
      "image_pick_present",
      "operationId=\(operationId) output=\(outputURL.path) quality=\(request.quality)"
    )
    presenter.present(picker, animated: true)
  }

  func cancel() {
    stateLock.lock()
    let operationId = activeOperationId
    if let operationId {
      cancelledOperationIds.insert(operationId)
      logPdfEvent("document_scan_cancel_requested", "operationId=\(operationId)")
    }
    stateLock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.activeController?.dismiss(animated: true)
    }
  }

  private func handleCompletedScan(_ scan: VNDocumentCameraScan, controller: VNDocumentCameraViewController) {
    guard let operationId = activeOperationId,
          let request = activeRequest,
          let outputURL = activeOutputURL else {
      controller.dismiss(animated: true)
      return
    }
    logPdfEvent("document_scan_finished", "operationId=\(operationId) pages=\(scan.pageCount)")
    controller.dismiss(animated: true) { [weak self] in
      self?.writeScan(scan, operationId: operationId, request: request, outputURL: outputURL)
    }
  }

  private func writeScan(
    _ scan: VNDocumentCameraScan,
    operationId: String,
    request: PdfDocumentScanRequest,
    outputURL: URL
  ) {
    workQueue.async { [weak self] in
      guard let self else { return }
      do {
        let result = try self.writer.write(
          scan: scan,
          request: request,
          outputURL: outputURL,
          operationId: operationId,
          isCancelled: { self.isCancelled(operationId) },
          onProgress: { completedPages, totalPages in
            DispatchQueue.main.async {
              self.onProgress?(operationId, completedPages, totalPages)
            }
          }
        )
        DispatchQueue.main.async {
          self.onGeneratedDocumentReady?(outputURL)
          self.finish(operationId: operationId, result: result, cancelled: false)
        }
      } catch let error as PdfPocError {
        try? FileManager.default.removeItem(at: outputURL)
        if error.code == "scan_cancelled" {
          DispatchQueue.main.async {
            self.finish(operationId: operationId, result: nil, cancelled: true)
          }
        } else {
          self.fail(operationId: operationId, error: error)
        }
      } catch {
        try? FileManager.default.removeItem(at: outputURL)
        self.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "scan_failed",
            message: "Document scan PDF generation failed.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  private func handlePickedImages(_ results: [PHPickerResult], picker: PHPickerViewController) {
    guard let operationId = activeOperationId,
          let request = activeRequest,
          let outputURL = activeOutputURL else {
      picker.dismiss(animated: true)
      return
    }
    guard !results.isEmpty else {
      logPdfEvent("image_pick_user_cancelled", "operationId=\(operationId)")
      picker.dismiss(animated: true) { [weak self] in
        self?.finish(operationId: operationId, result: nil, cancelled: true)
      }
      return
    }
    logPdfEvent("image_pick_finished", "operationId=\(operationId) count=\(results.count)")
    picker.dismiss(animated: true) { [weak self] in
      self?.loadPickedImages(
        results,
        operationId: operationId,
        request: request,
        outputURL: outputURL
      )
    }
  }

  private func loadPickedImages(
    _ results: [PHPickerResult],
    operationId: String,
    request: PdfDocumentScanRequest,
    outputURL: URL
  ) {
    workQueue.async { [weak self] in
      guard let self else { return }
      do {
        let tempDirectory = outputURL.deletingLastPathComponent()
          .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent)_picked_images", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        self.loadPickedImage(
          at: 0,
          results: results,
          tempDirectory: tempDirectory,
          copiedURLs: [],
          operationId: operationId,
          request: request,
          outputURL: outputURL
        )
      } catch {
        self.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "image_pick_failed",
            message: "Could not prepare picked images for PDF generation.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  /// Copies PHPicker temporary image files before their provider callbacks end,
  /// then writes the image-based PDF from those local files sequentially.
  private func loadPickedImage(
    at index: Int,
    results: [PHPickerResult],
    tempDirectory: URL,
    copiedURLs: [URL],
    operationId: String,
    request: PdfDocumentScanRequest,
    outputURL: URL
  ) {
    if isCancelled(operationId) {
      try? FileManager.default.removeItem(at: tempDirectory)
      DispatchQueue.main.async {
        self.finish(operationId: operationId, result: nil, cancelled: true)
      }
      return
    }
    guard index < results.count else {
      writePickedImagePdf(
        imageFileURLs: copiedURLs,
        tempDirectory: tempDirectory,
        operationId: operationId,
        request: request,
        outputURL: outputURL
      )
      return
    }

    let provider = results[index].itemProvider
    guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
      try? FileManager.default.removeItem(at: tempDirectory)
      fail(
        operationId: operationId,
        error: PdfPocError(
          code: "image_pick_failed",
          message: "The selected item is not an image.",
          details: "index=\(index)"
        )
      )
      return
    }

    provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] sourceURL, error in
      guard let self else { return }
      if let error {
        try? FileManager.default.removeItem(at: tempDirectory)
        self.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "image_pick_failed",
            message: "Could not load a picked image.",
            details: error.localizedDescription
          )
        )
        return
      }
      guard let sourceURL else {
        try? FileManager.default.removeItem(at: tempDirectory)
        self.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "image_pick_failed",
            message: "The image picker did not provide a file URL.",
            details: "index=\(index)"
          )
        )
        return
      }
      do {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "image" : sourceURL.pathExtension
        let copiedURL = tempDirectory.appendingPathComponent("picked_\(index).\(fileExtension)")
        try? FileManager.default.removeItem(at: copiedURL)
        try FileManager.default.copyItem(at: sourceURL, to: copiedURL)
        self.loadPickedImage(
          at: index + 1,
          results: results,
          tempDirectory: tempDirectory,
          copiedURLs: copiedURLs + [copiedURL],
          operationId: operationId,
          request: request,
          outputURL: outputURL
        )
      } catch {
        try? FileManager.default.removeItem(at: tempDirectory)
        self.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "image_pick_failed",
            message: "Could not copy a picked image into temporary storage.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  private func writePickedImagePdf(
    imageFileURLs: [URL],
    tempDirectory: URL,
    operationId: String,
    request: PdfDocumentScanRequest,
    outputURL: URL
  ) {
    workQueue.async { [weak self] in
      guard let self else { return }
      do {
        let result = try self.writer.write(
          imageFileURLs: imageFileURLs,
          request: request,
          outputURL: outputURL,
          operationId: operationId,
          isCancelled: { self.isCancelled(operationId) },
          onProgress: { completedPages, totalPages in
            DispatchQueue.main.async {
              self.onProgress?(operationId, completedPages, totalPages)
            }
          }
        )
        try? FileManager.default.removeItem(at: tempDirectory)
        DispatchQueue.main.async {
          self.onGeneratedDocumentReady?(outputURL)
          self.finish(operationId: operationId, result: result, cancelled: false)
        }
      } catch let error as PdfPocError {
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: tempDirectory)
        if error.code == "scan_cancelled" {
          DispatchQueue.main.async {
            self.finish(operationId: operationId, result: nil, cancelled: true)
          }
        } else {
          self.fail(operationId: operationId, error: error)
        }
      } catch {
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: tempDirectory)
        self.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "image_pick_failed",
            message: "Picked-image PDF generation failed.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  private func userCancelled(controller: VNDocumentCameraViewController) {
    guard let operationId = activeOperationId else {
      controller.dismiss(animated: true)
      return
    }
    logPdfEvent("document_scan_user_cancelled", "operationId=\(operationId)")
    if let outputURL = activeOutputURL {
      try? FileManager.default.removeItem(at: outputURL)
    }
    controller.dismiss(animated: true) { [weak self] in
      self?.finish(operationId: operationId, result: nil, cancelled: true)
    }
  }

  private func setActive(
    operationId: String,
    request: PdfDocumentScanRequest,
    outputURL: URL
  ) {
    stateLock.lock()
    activeOperationId = operationId
    activeRequest = request
    activeOutputURL = outputURL
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
  }

  private func isCancelled(_ operationId: String) -> Bool {
    stateLock.lock()
    let cancelled = cancelledOperationIds.contains(operationId) || activeOperationId != operationId
    stateLock.unlock()
    return cancelled
  }

  private func finish(operationId: String, result: PdfDocumentScanResult?, cancelled: Bool) {
    stateLock.lock()
    guard activeOperationId == operationId || cancelled else {
      stateLock.unlock()
      return
    }
    if activeOperationId == operationId {
      activeOperationId = nil
      activeRequest = nil
      activeOutputURL = nil
      activeController = nil
    }
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
    logPdfEvent(
      "document_scan_completed",
      "operationId=\(operationId) cancelled=\(cancelled) output=\(result?.outputPath ?? "")"
    )
    onCompleted?(operationId, result, cancelled)
  }

  private func fail(operationId: String, error: PdfPocError) {
    stateLock.lock()
    if activeOperationId == operationId {
      activeOperationId = nil
      activeRequest = nil
      activeOutputURL = nil
      activeController = nil
    }
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
    logPdfEvent(
      "document_scan_failed",
      "operationId=\(operationId) code=\(error.code) message=\(error.message)"
    )
    DispatchQueue.main.async {
      self.onError?(operationId, error)
    }
  }

  private func ensurePresenterThread() throws {
    guard Thread.isMainThread else {
      throw PdfPocError(
        code: "internal_error",
        message: "Document scanner presentation must run on the main thread.",
        details: nil
      )
    }
  }
}

extension PdfDocumentScannerManager: VNDocumentCameraViewControllerDelegate {
  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFinishWith scan: VNDocumentCameraScan
  ) {
    handleCompletedScan(scan, controller: controller)
  }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    userCancelled(controller: controller)
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFailWithError error: Error
  ) {
    guard let operationId = activeOperationId else {
      controller.dismiss(animated: true)
      return
    }
    controller.dismiss(animated: true) { [weak self] in
      self?.fail(
        operationId: operationId,
        error: PdfPocError(
          code: "scan_failed",
          message: "Apple document scanner failed.",
          details: error.localizedDescription
        )
      )
    }
  }
}

extension PdfDocumentScannerManager: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    handlePickedImages(results, picker: picker)
  }
}
