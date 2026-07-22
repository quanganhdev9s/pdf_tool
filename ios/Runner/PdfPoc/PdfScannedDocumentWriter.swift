import Foundation
import PDFKit
import UIKit
import VisionKit

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

/// Owns POC 7 scanned-PDF generation. It keeps `VNDocumentCameraScan` page
/// images native, processes one page at a time, writes a temporary PDF first,
/// and reopens the result with PDFKit before publishing the final path.
final class PdfScannedDocumentWriter {
  func write(
    scan: VNDocumentCameraScan,
    request: PdfDocumentScanRequest,
    outputURL: URL,
    operationId: String,
    isCancelled: () -> Bool,
    onProgress: (Int64, Int64) -> Void
  ) throws -> PdfDocumentScanResult {
    try writePages(
      pageCount: scan.pageCount,
      sourceLabel: "scanner",
      request: request,
      outputURL: outputURL,
      operationId: operationId,
      isCancelled: isCancelled,
      onProgress: onProgress,
      imageAt: { pageIndex in
        scan.imageOfPage(at: pageIndex)
      }
    )
  }

  func write(
    imageFileURLs: [URL],
    request: PdfDocumentScanRequest,
    outputURL: URL,
    operationId: String,
    isCancelled: () -> Bool,
    onProgress: (Int64, Int64) -> Void
  ) throws -> PdfDocumentScanResult {
    try writePages(
      pageCount: imageFileURLs.count,
      sourceLabel: "picked_images",
      request: request,
      outputURL: outputURL,
      operationId: operationId,
      isCancelled: isCancelled,
      onProgress: onProgress,
      imageAt: { pageIndex in
        UIImage(contentsOfFile: imageFileURLs[pageIndex].path)
      }
    )
  }

  private func writePages(
    pageCount: Int,
    sourceLabel: String,
    request: PdfDocumentScanRequest,
    outputURL: URL,
    operationId: String,
    isCancelled: () -> Bool,
    onProgress: (Int64, Int64) -> Void,
    imageAt: (Int) -> UIImage?
  ) throws -> PdfDocumentScanResult {
    let startedAt = Date()
    guard pageCount > 0 else {
      throw PdfPocError(
        code: sourceLabel == "picked_images" ? "image_pick_cancelled" : "scan_failed",
        message: sourceLabel == "picked_images"
          ? "No images were selected."
          : "The document scanner returned no pages.",
        details: nil
      )
    }

    let profile = PdfScanQualityProfile.profile(for: request.quality)
    let tempURL = temporaryURL(for: outputURL)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: tempURL)
    try? FileManager.default.removeItem(at: outputURL)

    logPdfEvent(
      "scan_pdf_write_start",
      "operationId=\(operationId) source=\(sourceLabel) pages=\(pageCount) quality=\(request.quality) maxLongEdge=\(profile.maxLongEdgePixels) jpeg=\(profile.jpegQuality)"
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
              code: sourceLabel == "picked_images" ? "image_pick_failed" : "scan_failed",
              message: sourceLabel == "picked_images"
                ? "Could not decode a picked image."
                : "Could not decode a scanner page image.",
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
        code: "scan_cancelled",
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
      "scan_pdf_write_success",
      "operationId=\(operationId) path=\(outputURL.path) pages=\(pageCount) bytes=\(fileSize) durationMs=\(duration)"
    )
    return PdfDocumentScanResult(
      outputPath: outputURL.path,
      pageCount: Int64(pageCount),
      fileSizeBytes: fileSize,
      durationMilliseconds: duration
    )
  }

  /// Applies the POC quality preset by limiting the long edge and round-tripping
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
