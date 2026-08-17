import Foundation
import PDFKit
import UIKit

/// Renders a loaded `UIPrintFormatter` (a WebKit-rendered source document) into
/// a paginated PDF. It writes a temporary file first and reopens the result with
/// PDFKit before publishing the final path, mirroring the scanned-PDF writer.
final class PdfConvertedDocumentWriter {
  /// Matches the default margins the system print stack uses for documents.
  private let pageMarginPoints: CGFloat = 36

  func write(
    printFormatter: UIPrintFormatter,
    pageSize: PdfConvertPageSize,
    outputURL: URL,
    operationId: String,
    isCancelled: () -> Bool,
    onProgress: (Int64, Int64) -> Void
  ) throws -> Int {
    let pageRect = CGRect(origin: .zero, size: paperSize(for: pageSize))
    let printableRect = pageRect.insetBy(dx: pageMarginPoints, dy: pageMarginPoints)

    let pageRenderer = UIPrintPageRenderer()
    pageRenderer.addPrintFormatter(printFormatter, startingAtPageAt: 0)
    pageRenderer.setValue(NSValue(cgRect: pageRect), forKey: "paperRect")
    pageRenderer.setValue(NSValue(cgRect: printableRect), forKey: "printableRect")

    let pageCount = pageRenderer.numberOfPages
    guard pageCount > 0 else {
      throw PdfPocError(
        code: "conversion_failed",
        message: "The source document produced no printable pages.",
        details: "operationId=\(operationId)"
      )
    }

    let tempURL = temporaryURL(for: outputURL)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: tempURL)
    try? FileManager.default.removeItem(at: outputURL)

    logPdfEvent(
      "convert_pdf_write_start",
      "operationId=\(operationId) pages=\(pageCount) pageSize=\(pageSize) paper=\(pageRect.size)"
    )

    pageRenderer.prepare(forDrawingPages: NSRange(location: 0, length: pageCount))
    let pdfRenderer = UIGraphicsPDFRenderer(bounds: pageRect)
    try pdfRenderer.writePDF(to: tempURL) { context in
      for pageIndex in 0..<pageCount {
        if isCancelled() {
          return
        }
        autoreleasepool {
          context.beginPage()
          pageRenderer.drawPage(at: pageIndex, in: pageRect)
        }
        onProgress(Int64(pageIndex + 1), Int64(pageCount))
      }
    }

    if isCancelled() {
      try? FileManager.default.removeItem(at: tempURL)
      throw PdfPocError(
        code: "conversion_cancelled",
        message: "PDF conversion was cancelled.",
        details: nil
      )
    }

    guard let reopened = PDFDocument(url: tempURL), reopened.pageCount == pageCount else {
      try? FileManager.default.removeItem(at: tempURL)
      throw PdfPocError(
        code: "pdf_generation_failed",
        message: "PDFKit could not reopen the converted PDF.",
        details: tempURL.path
      )
    }

    try FileManager.default.moveItem(at: tempURL, to: outputURL)
    logPdfEvent(
      "convert_pdf_write_success",
      "operationId=\(operationId) path=\(outputURL.path) pages=\(pageCount)"
    )
    return pageCount
  }

  private func paperSize(for pageSize: PdfConvertPageSize) -> CGSize {
    switch pageSize {
    case .a4:
      return CGSize(width: 595.2, height: 841.8)
    case .letter:
      return CGSize(width: 612, height: 792)
    }
  }

  private func temporaryURL(for outputURL: URL) -> URL {
    outputURL.deletingLastPathComponent()
      .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).tmp.pdf")
  }
}
