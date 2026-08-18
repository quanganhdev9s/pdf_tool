import Foundation
import PDFKit
import UIKit

private struct PdfScanQualityProfile {
  let maxLongEdgePixels: CGFloat
  let jpegQuality: CGFloat

  static func profile(for quality: PdfScanQuality) -> PdfScanQualityProfile {
    switch quality {
    case .standard:
      return PdfScanQualityProfile(maxLongEdgePixels: 1600, jpegQuality: 0.70)
    case .high:
      return PdfScanQualityProfile(maxLongEdgePixels: 2400, jpegQuality: 0.90)
    }
  }
}

/// Renders image files into a PDF, one page at a time, writing to a temporary
/// file first and reopening the result with PDFKit before publishing the path.
///
/// Used by image-to-PDF conversion. It once also served the in-viewer document
/// scanner, which is why it is written around a page-at-a-time loop rather than
/// a single image — scanning now lives in its own session-based flow with its
/// own exporter.
final class PdfImageDocumentWriter {
  func write(
    imageFileURLs: [URL],
    quality: PdfScanQuality,
    outputURL: URL,
    operationId: String,
    isCancelled: () -> Bool,
    onProgress: (Int64, Int64) -> Void
  ) throws -> Int {
    let startedAt = Date()
    let pageCount = imageFileURLs.count
    guard pageCount > 0 else {
      throw PdfPocError(
        code: "image_pick_cancelled",
        message: "No images were selected.",
        details: nil
      )
    }
    let imageAt: (Int) -> UIImage? = { UIImage(contentsOfFile: imageFileURLs[$0].path) }

    let profile = PdfScanQualityProfile.profile(for: quality)
    let tempURL = temporaryURL(for: outputURL)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: tempURL)
    try? FileManager.default.removeItem(at: outputURL)

    logPdfEvent(
      "image_pdf_write_start",
      "operationId=\(operationId) pages=\(pageCount) quality=\(quality) maxLongEdge=\(profile.maxLongEdgePixels) jpeg=\(profile.jpegQuality)"
    )

    let renderer = UIGraphicsPDFRenderer(bounds: .zero)
    var renderError: PdfPocError?
    try renderer.writePDF(to: tempURL) { context in
      for pageIndex in 0..<pageCount {
        if isCancelled() {
          return
        }
        autoreleasepool {
          guard let sourceImage = imageAt(pageIndex) else {
            renderError = PdfPocError(
              code: "image_pick_failed",
              message: "Could not decode a picked image.",
              details: "pageIndex=\(pageIndex)"
            )
            return
          }
          let image = processedImage(sourceImage, profile: profile)
          let pageSize = CGSize(
            width: max(image.size.width, 1),
            height: max(image.size.height, 1)
          )
          context.beginPage(withBounds: CGRect(origin: .zero, size: pageSize), pageInfo: [:])
          UIColor.white.setFill()
          context.cgContext.fill(CGRect(origin: .zero, size: pageSize))
          image.draw(in: CGRect(origin: .zero, size: pageSize))
        }
        if renderError != nil {
          return
        }
        onProgress(Int64(pageIndex + 1), Int64(pageCount))
      }
    }

    if let renderError {
      try? FileManager.default.removeItem(at: tempURL)
      throw renderError
    }

    if isCancelled() {
      try? FileManager.default.removeItem(at: tempURL)
      throw PdfPocError(
        code: "image_pdf_cancelled",
        message: "Document scan PDF generation was cancelled.",
        details: nil
      )
    }

    guard let reopened = PDFDocument(url: tempURL), reopened.pageCount == pageCount else {
      try? FileManager.default.removeItem(at: tempURL)
      throw PdfPocError(
        code: "pdf_generation_failed",
        message: "PDFKit could not reopen the generated scan PDF.",
        details: tempURL.path
      )
    }

    try FileManager.default.moveItem(at: tempURL, to: outputURL)
    let fileSize = try fileSize(at: outputURL)
    let duration = Int64(Date().timeIntervalSince(startedAt) * 1000)
    logPdfEvent(
      "image_pdf_write_success",
      "operationId=\(operationId) path=\(outputURL.path) pages=\(pageCount) bytes=\(fileSize) durationMs=\(duration)"
    )
    return pageCount
  }

  /// Applies the quality preset by limiting the long edge and round-tripping
  /// through JPEG. Drawing onto a white renderer also prevents transparent/black
  /// backgrounds on devices with different default image context behavior.
  private func processedImage(_ image: UIImage, profile: PdfScanQualityProfile) -> UIImage {
    let sourceSize = CGSize(
      width: max(image.size.width, 1),
      height: max(image.size.height, 1)
    )
    let longEdge = max(sourceSize.width, sourceSize.height)
    let scale = min(profile.maxLongEdgePixels / longEdge, 1)
    let targetSize = CGSize(
      width: max((sourceSize.width * scale).rounded(), 1),
      height: max((sourceSize.height * scale).rounded(), 1)
    )

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    let normalized = renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: targetSize))
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }
    guard let jpegData = normalized.jpegData(compressionQuality: profile.jpegQuality),
          let jpegImage = UIImage(data: jpegData) else {
      return normalized
    }
    return jpegImage
  }

  private func temporaryURL(for outputURL: URL) -> URL {
    outputURL.deletingLastPathComponent()
      .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).tmp.pdf")
  }

  private func fileSize(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
  }
}
