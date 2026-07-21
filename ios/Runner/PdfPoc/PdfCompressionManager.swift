import Foundation
import PDFKit
import UIKit

struct PdfCompressionProfile {
  let hasSearchableText: Bool
  let hasAnnotations: Bool
  let hasLinks: Bool
  let hasForms: Bool
}

private struct RasterizedPageImage {
  let fileURL: URL
  let pageBounds: CGRect
}

/// Owns POC 5 compression work: preservation-oriented PDFKit output,
/// rasterized JPEG-backed output, metrics, warnings, and cooperative cancel.
final class PdfCompressionManager {
  var onProgress: ((String, Int64, Int64) -> Void)?
  var onCompleted: ((String, PdfCompressionResult?, Bool) -> Void)?
  var onError: ((String, PdfPocError) -> Void)?

  private let workQueue = DispatchQueue(label: "pdf.poc.compression", qos: .userInitiated)
  private let stateLock = NSLock()
  private var activeOperationId: String?
  private var cancelledOperationIds = Set<String>()

  func run(
    request: PdfCompressionRequest,
    document: PDFDocument,
    workingURL: URL,
    outputURL: URL,
    profile: PdfCompressionProfile
  ) throws {
    let pageCount = document.pageCount
    guard pageCount > 0 else {
      throw PdfPocError(
        code: "invalid_pdf",
        message: "The open PDF has no pages to compress.",
        details: nil
      )
    }

    let operationId = UUID().uuidString
    cancel()
    setActiveOperationId(operationId)
    logPdfEvent(
      "compression_start",
      "operationId=\(operationId) mode=\(request.mode) output=\(outputURL.path)"
    )

    switch request.mode {
    case .preserve:
      runPreservationMode(
        operationId: operationId,
        document: document,
        workingURL: workingURL,
        outputURL: outputURL,
        profile: profile
      )
    case .rasterized:
      runRasterizedMode(
        operationId: operationId,
        request: request,
        document: document,
        workingURL: workingURL,
        outputURL: outputURL
      )
    }
  }

  /// Marks the active operation cancelled. The manager stops between pages or
  /// after the current PDFKit write/render step returns.
  func cancel() {
    let operationId: String?
    stateLock.lock()
    operationId = activeOperationId
    if let operationId {
      cancelledOperationIds.insert(operationId)
      logPdfEvent("compression_cancel_requested", "operationId=\(operationId)")
    }
    activeOperationId = nil
    stateLock.unlock()
    if let operationId {
      DispatchQueue.main.async {
        self.onCompleted?(operationId, nil, true)
      }
    }
  }

  /// Preservation mode keeps the PDF structure by asking PDFKit to write a
  /// separate copy. Size reduction is intentionally not guaranteed.
  private func runPreservationMode(
    operationId: String,
    document: PDFDocument,
    workingURL: URL,
    outputURL: URL,
    profile: PdfCompressionProfile
  ) {
    let startedAt = Date()
    workQueue.async { [weak self, weak document] in
      guard let self, let document else { return }
      if self.isCancelled(operationId) { return }
      do {
        try FileManager.default.createDirectory(
          at: outputURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        guard document.write(to: outputURL) else {
          throw PdfPocError(
            code: "compression_failed",
            message: "PDFKit could not write the preservation-oriented output.",
            details: outputURL.path
          )
        }
        if self.isCancelled(operationId) { return }
        let result = try self.result(
          outputURL: outputURL,
          workingURL: workingURL,
          startedAt: startedAt,
          textSelectable: profile.hasSearchableText,
          annotationsEditable: true,
          linksFunctional: true,
          formsFunctional: true,
          visualQualityNotes:
            "Preservation mode uses PDFKit write without intentionally rasterizing pages. Source features detected: text=\(profile.hasSearchableText), annotations=\(profile.hasAnnotations), links=\(profile.hasLinks), forms=\(profile.hasForms).",
          warning:
            "Preservation mode is expected to keep PDF structure, but size reduction may be minimal and output behavior still requires manual verification."
        )
        DispatchQueue.main.async {
          self.onProgress?(operationId, 1, 1)
          self.finish(operationId: operationId, result: result, cancelled: false)
        }
      } catch let error as PdfPocError {
        self.fail(operationId: operationId, error: error)
      } catch {
        self.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "compression_failed",
            message: "Preservation-oriented compression failed.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  /// Rasterized mode intentionally rebuilds each page as a JPEG image in a new
  /// PDF, trading structure/editability for smaller files.
  private func runRasterizedMode(
    operationId: String,
    request: PdfCompressionRequest,
    document: PDFDocument,
    workingURL: URL,
    outputURL: URL
  ) {
    let startedAt = Date()
    let dpi = clampedDpi(request.rasterDpi)
    let jpegQuality = clampedJpegQuality(request.jpegQuality)
    let tempDirectory = outputURL.deletingLastPathComponent()
      .appendingPathComponent("\(outputURL.deletingPathExtension().lastPathComponent)_pages", isDirectory: true)

    workQueue.async { [weak self] in
      do {
        try FileManager.default.createDirectory(
          at: tempDirectory,
          withIntermediateDirectories: true
        )
      } catch {
        self?.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "compression_failed",
            message: "Could not create a temporary rasterization directory.",
            details: error.localizedDescription
          )
        )
        return
      }
      DispatchQueue.main.async {
        self?.renderRasterizedPage(
          operationId: operationId,
          document: document,
          workingURL: workingURL,
          outputURL: outputURL,
          tempDirectory: tempDirectory,
          dpi: dpi,
          jpegQuality: jpegQuality,
          startedAt: startedAt,
          pageIndex: 0,
          images: []
        )
      }
    }
  }

  /// Renders one page at a time on the main thread so the app can observe
  /// progress/cancel between pages instead of blocking on the whole document.
  private func renderRasterizedPage(
    operationId: String,
    document: PDFDocument,
    workingURL: URL,
    outputURL: URL,
    tempDirectory: URL,
    dpi: Int,
    jpegQuality: CGFloat,
    startedAt: Date,
    pageIndex: Int,
    images: [RasterizedPageImage]
  ) {
    if isCancelled(operationId) {
      cleanup(tempDirectory)
      return
    }
    guard pageIndex < document.pageCount else {
      writeRasterizedPdf(
        operationId: operationId,
        images: images,
        workingURL: workingURL,
        outputURL: outputURL,
        tempDirectory: tempDirectory,
        dpi: dpi,
        jpegQuality: jpegQuality,
        startedAt: startedAt
      )
      return
    }
    guard let page = document.page(at: pageIndex) else {
      fail(operationId: operationId, error: PdfPocError.pageOutOfRange(Int64(pageIndex)))
      cleanup(tempDirectory)
      return
    }

    let pageBounds = page.bounds(for: .cropBox)
    let jpegData = renderJpegData(page: page, pageBounds: pageBounds, dpi: dpi, quality: jpegQuality)
    let pageURL = tempDirectory.appendingPathComponent("page_\(pageIndex).jpg")
    workQueue.async { [weak self] in
      guard let self else { return }
      if self.isCancelled(operationId) {
        self.cleanup(tempDirectory)
        return
      }
      do {
        try jpegData.write(to: pageURL, options: [.atomic])
        let nextImages = images + [RasterizedPageImage(fileURL: pageURL, pageBounds: pageBounds)]
        DispatchQueue.main.async {
          self.onProgress?(
            operationId,
            Int64(pageIndex + 1),
            Int64(document.pageCount)
          )
          self.renderRasterizedPage(
            operationId: operationId,
            document: document,
            workingURL: workingURL,
            outputURL: outputURL,
            tempDirectory: tempDirectory,
            dpi: dpi,
            jpegQuality: jpegQuality,
            startedAt: startedAt,
            pageIndex: pageIndex + 1,
            images: nextImages
          )
        }
      } catch {
        self.cleanup(tempDirectory)
        self.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "compression_failed",
            message: "Could not write a rasterized page image.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  private func writeRasterizedPdf(
    operationId: String,
    images: [RasterizedPageImage],
    workingURL: URL,
    outputURL: URL,
    tempDirectory: URL,
    dpi: Int,
    jpegQuality: CGFloat,
    startedAt: Date
  ) {
    workQueue.async { [weak self] in
      guard let self else { return }
      if self.isCancelled(operationId) {
        self.cleanup(tempDirectory)
        return
      }
      do {
        try FileManager.default.createDirectory(
          at: outputURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let renderer = UIGraphicsPDFRenderer(bounds: .zero)
        try renderer.writePDF(to: outputURL) { context in
          for imageInfo in images {
            if self.isCancelled(operationId) { return }
            let pageBounds = imageInfo.pageBounds
            context.beginPage(withBounds: CGRect(origin: .zero, size: pageBounds.size), pageInfo: [:])
            guard let image = UIImage(contentsOfFile: imageInfo.fileURL.path) else { continue }
            image.draw(in: CGRect(origin: .zero, size: pageBounds.size))
          }
        }
        if self.isCancelled(operationId) {
          try? FileManager.default.removeItem(at: outputURL)
          self.cleanup(tempDirectory)
          return
        }
        let result = try self.result(
          outputURL: outputURL,
          workingURL: workingURL,
          startedAt: startedAt,
          textSelectable: false,
          annotationsEditable: false,
          linksFunctional: false,
          formsFunctional: false,
          visualQualityNotes:
            "Rasterized at \(dpi) DPI with JPEG quality \(String(format: "%.2f", jpegQuality)). Visual quality must be inspected on device and in another PDF viewer.",
          warning: Self.rasterizedWarning
        )
        self.cleanup(tempDirectory)
        DispatchQueue.main.async {
          self.finish(operationId: operationId, result: result, cancelled: false)
        }
      } catch {
        self.cleanup(tempDirectory)
        self.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "compression_failed",
            message: "Could not write the rasterized compressed PDF.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  private func renderJpegData(
    page: PDFPage,
    pageBounds: CGRect,
    dpi: Int,
    quality: CGFloat
  ) -> Data {
    let scale = CGFloat(dpi) / 72
    let outputSize = CGSize(
      width: max(pageBounds.width * scale, 1),
      height: max(pageBounds.height * scale, 1)
    )
    let renderer = UIGraphicsImageRenderer(size: outputSize)
    let image = renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: outputSize))
      let cgContext = context.cgContext
      cgContext.saveGState()
      cgContext.translateBy(x: 0, y: outputSize.height)
      cgContext.scaleBy(x: scale, y: -scale)
      cgContext.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
      page.draw(with: .cropBox, to: cgContext)
      cgContext.restoreGState()
    }
    return image.jpegData(compressionQuality: quality) ?? Data()
  }

  private func result(
    outputURL: URL,
    workingURL: URL,
    startedAt: Date,
    textSelectable: Bool,
    annotationsEditable: Bool,
    linksFunctional: Bool,
    formsFunctional: Bool,
    visualQualityNotes: String,
    warning: String
  ) throws -> PdfCompressionResult {
    let inputBytes = try fileSize(at: workingURL)
    let outputBytes = try fileSize(at: outputURL)
    let ratio = inputBytes > 0 ? Double(outputBytes) / Double(inputBytes) : 0
    return PdfCompressionResult(
      outputPath: outputURL.path,
      inputBytes: inputBytes,
      outputBytes: outputBytes,
      compressionRatio: ratio,
      durationMilliseconds: Int64(Date().timeIntervalSince(startedAt) * 1000),
      textSelectable: textSelectable,
      annotationsEditable: annotationsEditable,
      linksFunctional: linksFunctional,
      formsFunctional: formsFunctional,
      visualQualityNotes: visualQualityNotes,
      warning: warning
    )
  }

  private func fileSize(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
  }

  private func clampedDpi(_ dpi: Int64) -> Int {
    Int(min(max(dpi, 72), 300))
  }

  private func clampedJpegQuality(_ quality: Double) -> CGFloat {
    CGFloat(min(max(quality, 0.1), 0.95))
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

  private func finish(operationId: String, result: PdfCompressionResult?, cancelled: Bool) {
    stateLock.lock()
    guard cancelled || activeOperationId == operationId else {
      stateLock.unlock()
      return
    }
    if activeOperationId == operationId {
      activeOperationId = nil
    }
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
    logPdfEvent("compression_completed", "operationId=\(operationId) cancelled=\(cancelled)")
    onCompleted?(operationId, result, cancelled)
  }

  private func fail(operationId: String, error: PdfPocError) {
    stateLock.lock()
    if activeOperationId == operationId {
      activeOperationId = nil
    }
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
    logPdfEvent(
      "compression_failed",
      "operationId=\(operationId) code=\(error.code) message=\(error.message)"
    )
    DispatchQueue.main.async {
      self.onError?(operationId, error)
    }
  }

  private func cleanup(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
  }

  static let rasterizedWarning =
    "Rasterized compression may destroy selectable text, links, forms, vector quality, and editable annotations."
}
