import Foundation
import PDFKit
import UIKit
import Vision

/// Owns POC 4 OCR work: page rasterization, Vision recognition, cooperative
/// cancellation, and normalized bounding boxes returned to Flutter.
final class PdfOcrManager {
  var onProgress: ((String, Int64, Int64) -> Void)?
  var onResult: ((String, PdfOcrBlock) -> Void)?
  var onCompleted: ((String, Bool) -> Void)?
  var onError: ((String, PdfPocError) -> Void)?

  private let recognitionQueue = DispatchQueue(label: "pdf.poc.ocr", qos: .userInitiated)
  private let stateLock = NSLock()
  private var activeOperationId: String?
  private var cancelledOperationIds = Set<String>()

  /// Starts a new OCR operation and returns immediately. Rendering is scheduled
  /// on the main thread; Vision recognition runs on the serial OCR queue.
  func run(request: PdfOcrRequest, in document: PDFDocument) throws {
    let pageIndexes = try validatedPageIndexes(request.pageIndexes, in: document)
    let operationId = UUID().uuidString
    cancel()
    setActiveOperationId(operationId)
    logPdfEvent(
      "ocr_start",
      "operationId=\(operationId) pages=\(pageIndexes) languages=\(request.recognitionLanguages)"
    )
    processNextPage(
      operationId: operationId,
      request: request,
      document: document,
      pageIndexes: pageIndexes,
      position: 0
    )
  }

  /// Marks the active operation as cancelled. Cancellation is cooperative:
  /// Vision may finish the current page before the manager stops.
  func cancel() {
    let operationId: String?
    stateLock.lock()
    operationId = activeOperationId
    if let operationId {
      cancelledOperationIds.insert(operationId)
      logPdfEvent("ocr_cancel_requested", "operationId=\(operationId)")
    }
    activeOperationId = nil
    stateLock.unlock()
    if let operationId {
      DispatchQueue.main.async {
        self.onCompleted?(operationId, true)
      }
    }
  }

  private func processNextPage(
    operationId: String,
    request: PdfOcrRequest,
    document: PDFDocument,
    pageIndexes: [Int],
    position: Int
  ) {
    if isCancelled(operationId) {
      finish(operationId: operationId, cancelled: true)
      return
    }
    guard position < pageIndexes.count else {
      finish(operationId: operationId, cancelled: false)
      return
    }

    let pageIndex = pageIndexes[position]
    DispatchQueue.main.async { [weak self, weak document] in
      guard let self, let document else { return }
      if self.isCancelled(operationId) {
        self.finish(operationId: operationId, cancelled: true)
        return
      }
      guard let page = document.page(at: pageIndex) else {
        self.fail(
          operationId: operationId,
          error: PdfPocError.pageOutOfRange(Int64(pageIndex))
        )
        return
      }
      let image = self.renderPageImage(page)
      self.recognitionQueue.async { [weak self] in
        guard let self else { return }
        let recognized = self.recognize(
          image: image,
          pageIndex: pageIndex,
          request: request,
          operationId: operationId
        )
        DispatchQueue.main.async {
          guard recognized else { return }
          self.onProgress?(
            operationId,
            Int64(position + 1),
            Int64(pageIndexes.count)
          )
          self.processNextPage(
            operationId: operationId,
            request: request,
            document: document,
            pageIndexes: pageIndexes,
            position: position + 1
          )
        }
      }
    }
  }

  /// Runs one Vision text-recognition request and emits one block per Vision
  /// observation. The bounding box remains Vision-normalized, bottom-left based.
  private func recognize(
    image: UIImage,
    pageIndex: Int,
    request: PdfOcrRequest,
    operationId: String
  ) -> Bool {
    guard !isCancelled(operationId), let cgImage = image.cgImage else {
      return false
    }
    var didFail = false
    let textRequest = VNRecognizeTextRequest { [weak self] visionRequest, error in
      guard let self else { return }
      if let error {
        didFail = true
        self.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "ocr_failed",
            message: "Vision text recognition failed.",
            details: error.localizedDescription
          )
        )
        return
      }
      let observations = (visionRequest.results as? [VNRecognizedTextObservation]) ?? []
      for observation in observations {
        guard !self.isCancelled(operationId),
              let candidate = observation.topCandidates(1).first,
              !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          continue
        }
        let box = observation.boundingBox
        let block = PdfOcrBlock(
          pageIndex: Int64(pageIndex),
          text: candidate.string,
          confidence: Double(candidate.confidence),
          normalizedBoundingBox: PdfRect(
            x: Double(box.origin.x),
            y: Double(box.origin.y),
            width: Double(box.width),
            height: Double(box.height)
          )
        )
        DispatchQueue.main.async {
          self.onResult?(operationId, block)
        }
      }
    }
    textRequest.recognitionLevel = request.accurateRecognition ? .accurate : .fast
    textRequest.usesLanguageCorrection = true
    textRequest.recognitionLanguages = normalizedLanguages(request.recognitionLanguages)

    do {
      try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([textRequest])
    } catch {
      didFail = true
      fail(
        operationId: operationId,
        error: PdfPocError(
          code: "ocr_failed",
          message: "Vision text recognition could not process the rendered page image.",
          details: error.localizedDescription
        )
      )
    }
    return !didFail && !isCancelled(operationId)
  }

  /// Renders the PDF crop box into an upright white-backed bitmap for Vision.
  private func renderPageImage(_ page: PDFPage) -> UIImage {
    let pageBounds = page.bounds(for: .cropBox)
    let maxDimension: CGFloat = 1800
    let scale = min(maxDimension / max(pageBounds.width, pageBounds.height), 2.0)
    let safeScale = max(scale, 1.0)
    let outputSize = CGSize(
      width: max(pageBounds.width * safeScale, 1),
      height: max(pageBounds.height * safeScale, 1)
    )
    let renderer = UIGraphicsImageRenderer(size: outputSize)
    return renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: outputSize))
      let cgContext = context.cgContext
      cgContext.saveGState()
      cgContext.translateBy(x: 0, y: outputSize.height)
      cgContext.scaleBy(x: safeScale, y: -safeScale)
      cgContext.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
      page.draw(with: .cropBox, to: cgContext)
      cgContext.restoreGState()
    }
  }

  private func validatedPageIndexes(_ rawIndexes: [Int64], in document: PDFDocument) throws -> [Int] {
    guard !rawIndexes.isEmpty else {
      throw PdfPocError(
        code: "invalid_ocr_request",
        message: "Select at least one page before running OCR.",
        details: nil
      )
    }
    var indexes: [Int] = []
    for rawIndex in rawIndexes {
      guard rawIndex >= 0, rawIndex < Int64(document.pageCount) else {
        throw PdfPocError.pageOutOfRange(rawIndex)
      }
      indexes.append(Int(rawIndex))
    }
    return indexes
  }

  private func normalizedLanguages(_ languages: [String]) -> [String] {
    let cleaned = languages
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return cleaned.isEmpty ? ["vi-VN", "en-US"] : cleaned
  }

  private func setActiveOperationId(_ operationId: String) {
    stateLock.lock()
    activeOperationId = operationId
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
  }

  private func isCancelled(_ operationId: String) -> Bool {
    stateLock.lock()
    let cancelled = cancelledOperationIds.contains(operationId) || activeOperationId != operationId
    stateLock.unlock()
    return cancelled
  }

  private func finish(operationId: String, cancelled: Bool) {
    stateLock.lock()
    if activeOperationId == operationId {
      activeOperationId = nil
    }
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
    logPdfEvent("ocr_completed", "operationId=\(operationId) cancelled=\(cancelled)")
    DispatchQueue.main.async {
      self.onCompleted?(operationId, cancelled)
    }
  }

  private func fail(operationId: String, error: PdfPocError) {
    stateLock.lock()
    if activeOperationId == operationId {
      activeOperationId = nil
    }
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
    logPdfEvent(
      "ocr_failed",
      "operationId=\(operationId) code=\(error.code) message=\(error.message)"
    )
    DispatchQueue.main.async {
      self.onError?(operationId, error)
    }
  }
}
