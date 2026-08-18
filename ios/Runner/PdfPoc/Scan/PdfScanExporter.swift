import Foundation
import PDFKit
import UIKit

private struct PdfScanExportProfile {
  let maxLongEdgePixels: CGFloat
  let jpegQuality: CGFloat

  static func profile(for quality: PdfScanExportQuality) -> PdfScanExportProfile {
    switch quality {
    case .standard:
      return PdfScanExportProfile(maxLongEdgePixels: 1600, jpegQuality: 0.80)
    case .high:
      return PdfScanExportProfile(maxLongEdgePixels: 2400, jpegQuality: 0.92)
    }
  }
}

/// Renders a reviewed session into a PDF. Writes to a temporary file first and
/// only publishes the final path after the result reopens cleanly, so a partial
/// or corrupt file is never handed to the viewer.
final class PdfScanExporter {
  private let validator = PdfScanValidator()

  func export(
    session: PdfScanSessionRecord,
    quality: PdfScanExportQuality,
    outputURL: URL,
    operationId: String,
    isCancelled: () -> Bool,
    onProgress: (Int64, Int64) -> Void
  ) throws -> PdfScanExportResult {
    let startedAt = Date()
    let pages = session.pages
    guard !pages.isEmpty else {
      throw PdfPocError(
        code: "scan_export_failed",
        message: "There are no pages to export.",
        details: "sessionId=\(session.id)"
      )
    }

    let profile = PdfScanExportProfile.profile(for: quality)
    let tempURL = outputURL.deletingLastPathComponent()
      .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).tmp.pdf")

    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: tempURL)
    try? FileManager.default.removeItem(at: outputURL)

    logPdfEvent(
      "scan_export_start",
      "operationId=\(operationId) sessionId=\(session.id) pages=\(pages.count) quality=\(quality)"
    )

    var renderError: PdfPocError?
    let renderer = UIGraphicsPDFRenderer(bounds: .zero)
    try renderer.writePDF(to: tempURL) { context in
      for (pageIndex, page) in pages.enumerated() {
        if isCancelled() { return }
        autoreleasepool {
          guard let image = loadRenderImage(for: page, profile: profile) else {
            renderError = PdfPocError(
              code: "scan_export_failed",
              message: "Could not read a page image while exporting.",
              details: "pageId=\(page.id)"
            )
            return
          }
          let bounds = CGRect(origin: .zero, size: image.size)
          context.beginPage(withBounds: bounds, pageInfo: [:])
          UIColor.white.setFill()
          UIRectFill(bounds)
          image.draw(in: bounds)
        }
        if renderError != nil { return }
        onProgress(Int64(pageIndex + 1), Int64(pages.count))
      }
    }

    if let renderError {
      try? FileManager.default.removeItem(at: tempURL)
      throw renderError
    }
    if isCancelled() {
      try? FileManager.default.removeItem(at: tempURL)
      throw PdfPocError(code: "scan_cancelled", message: "The export was cancelled.", details: nil)
    }

    try FileManager.default.moveItem(at: tempURL, to: outputURL)
    let fileSize = try validator.validate(url: outputURL, expectedPageCount: pages.count)

    let duration = Int64(Date().timeIntervalSince(startedAt) * 1000)
    logPdfEvent(
      "scan_export_completed",
      "operationId=\(operationId) output=\(outputURL.path) bytes=\(fileSize) ms=\(duration)"
    )

    return PdfScanExportResult(
      outputPath: outputURL.path,
      pageCount: Int64(pages.count),
      fileSizeBytes: fileSize,
      durationMilliseconds: duration,
      presetSummary: session.presetSummary
    )
  }

  /// Reads whichever image the page's preset selected, applies the stored
  /// rotation, and caps the long edge. Rotation lives as metadata precisely so
  /// it can be resolved here instead of invalidating the processed cache.
  private func loadRenderImage(
    for page: PdfScanPageRecord,
    profile: PdfScanExportProfile
  ) -> UIImage? {
    guard let source = UIImage(contentsOfFile: page.renderURL.path) else { return nil }
    let rotated = source.rotated(byDegrees: page.rotationDegrees)

    let longEdge = max(rotated.size.width, rotated.size.height)
    let scale = min(profile.maxLongEdgePixels / max(longEdge, 1), 1)
    let targetSize = CGSize(
      width: max((rotated.size.width * scale).rounded(), 1),
      height: max((rotated.size.height * scale).rounded(), 1)
    )

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    let normalized = renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: targetSize))
      rotated.draw(in: CGRect(origin: .zero, size: targetSize))
    }

    guard let data = normalized.jpegData(compressionQuality: profile.jpegQuality),
          let compressed = UIImage(data: data) else {
      return normalized
    }
    return compressed
  }
}

/// Reopens the written file before it is published. Catches the failure mode
/// where rendering "succeeds" but produces a file no reader accepts.
final class PdfScanValidator {
  @discardableResult
  func validate(url: URL, expectedPageCount: Int) throws -> Int64 {
    guard let document = PDFDocument(url: url) else {
      try? FileManager.default.removeItem(at: url)
      throw PdfPocError(
        code: "scan_export_failed",
        message: "The exported PDF could not be reopened.",
        details: url.path
      )
    }
    guard document.pageCount == expectedPageCount else {
      try? FileManager.default.removeItem(at: url)
      throw PdfPocError(
        code: "scan_export_failed",
        message: "The exported PDF has the wrong number of pages.",
        details: "expected=\(expectedPageCount) actual=\(document.pageCount)"
      )
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard size > 0 else {
      try? FileManager.default.removeItem(at: url)
      throw PdfPocError(
        code: "scan_export_failed",
        message: "The exported PDF is empty.",
        details: url.path
      )
    }
    return size
  }
}

extension UIImage {
  /// Rotation is stored per page and resolved at draw time. Normalises to a
  /// multiple of 90 so a caller cannot produce a non-rectangular page.
  func rotated(byDegrees degrees: Int) -> UIImage {
    let normalized = ((degrees % 360) + 360) % 360
    guard normalized != 0 else { return self }

    let radians = CGFloat(normalized) * .pi / 180
    let swapsAxes = normalized == 90 || normalized == 270
    let targetSize = swapsAxes
      ? CGSize(width: size.height, height: size.width)
      : size

    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    return renderer.image { context in
      context.cgContext.translateBy(x: targetSize.width / 2, y: targetSize.height / 2)
      context.cgContext.rotate(by: radians)
      draw(in: CGRect(
        x: -size.width / 2,
        y: -size.height / 2,
        width: size.width,
        height: size.height
      ))
    }
  }
}
