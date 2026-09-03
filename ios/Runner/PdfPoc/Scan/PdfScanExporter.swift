import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

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

  /// A4 tính bằng point, đơn vị thật của PDF. Trước đây khổ trang lấy thẳng số
  /// pixel của ảnh, nên một ảnh cao 2400px thành trang cao 33 inch và mọi trình
  /// đọc đều hiển thị sai tỉ lệ.
  private static let a4Portrait = CGSize(width: 595.28, height: 841.89)

  /// Ảnh ngang thì trang xoay ngang theo, để không phải thu nhỏ tờ giấy vào
  /// giữa một trang dọc.
  private static func pageBounds(for imageSize: CGSize) -> CGRect {
    let isLandscape = imageSize.width > imageSize.height
    let size = isLandscape
      ? CGSize(width: a4Portrait.height, height: a4Portrait.width)
      : a4Portrait
    return CGRect(origin: .zero, size: size)
  }

  /// Vừa khung và căn giữa, giữ nguyên tỉ lệ.
  private static func imageFrame(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
    let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
      x: bounds.midX - size.width / 2,
      y: bounds.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

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
          var timer = StepTimer()
          guard let image = loadRenderImage(for: page, profile: profile) else {
            renderError = PdfPocError(
              code: "scan_export_failed",
              message: "Could not read a page image while exporting.",
              details: "pageId=\(page.id)"
            )
            return
          }
          let loadMs = timer.lap()
          let bounds = Self.pageBounds(for: image.size)
          context.beginPage(withBounds: bounds, pageInfo: [:])
          UIColor.white.setFill()
          UIRectFill(bounds)
          image.draw(in: Self.imageFrame(for: image.size, in: bounds))
          logPdfEvent(
            "scan_export_page",
            "page=\(pageIndex + 1)/\(pages.count)"
              + " size=\(Int(image.size.width))x\(Int(image.size.height))"
              + " page=\(Int(bounds.width))x\(Int(bounds.height))pt"
              + " load=\(loadMs)ms draw=\(timer.lap())ms"
          )
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
  ///
  /// Giải mã thẳng ở cỡ đích và chỉ raster khi phải xoay. Bước nén JPEG phải
  /// giữ: nó là thứ khiến PDF nhúng ảnh đã nén thay vì bitmap thô.
  private func loadRenderImage(
    for page: PdfScanPageRecord,
    profile: PdfScanExportProfile
  ) -> UIImage? {
    guard let decoded = decodedImage(at: page.renderURL, maxLongEdge: profile.maxLongEdgePixels)
    else { return nil }

    let oriented = rotatedImage(decoded, byDegrees: page.rotationDegrees)
    guard let data = jpegData(from: oriented, quality: profile.jpegQuality) else {
      return UIImage(cgImage: oriented)
    }
    return UIImage(data: data) ?? UIImage(cgImage: oriented)
  }

  /// Bung thẳng ở cỡ cần dùng thay vì bung đủ độ phân giải rồi thu nhỏ sau.
  private func decodedImage(at url: URL, maxLongEdge: CGFloat) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// Xoay 0 độ, trường hợp phổ biến nhất, không tốn lượt raster nào.
  private func rotatedImage(_ image: CGImage, byDegrees degrees: Int) -> CGImage {
    guard ((degrees % 360) + 360) % 360 != 0 else { return image }
    let rotated = UIImage(cgImage: image).rotated(byDegrees: degrees)
    return rotated.cgImage ?? image
  }

  private func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output, UTType.jpeg.identifier as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
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
