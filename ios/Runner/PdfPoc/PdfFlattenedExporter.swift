import Foundation
import PDFKit
import UIKit

struct PdfFlattenedExporter {
  func export(document: PDFDocument, to outputURL: URL) throws -> PdfExportResult {
    let pageCount = document.pageCount
    guard pageCount > 0 else {
      throw PdfPocError(
        code: "invalid_pdf",
        message: "The open PDF has no pages to export.",
        details: nil
      )
    }

    do {
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let renderer = UIGraphicsPDFRenderer(bounds: .zero)
      try renderer.writePDF(to: outputURL) { context in
        for pageIndex in 0..<pageCount {
          guard let page = document.page(at: pageIndex) else { continue }
          let pageBounds = page.bounds(for: .cropBox)
          context.beginPage(withBounds: CGRect(origin: .zero, size: pageBounds.size), pageInfo: [:])
          let cgContext = context.cgContext
          cgContext.saveGState()
          cgContext.translateBy(x: -pageBounds.origin.x, y: pageBounds.height + pageBounds.origin.y)
          cgContext.scaleBy(x: 1, y: -1)
          page.draw(with: .cropBox, to: cgContext)
          cgContext.restoreGState()
        }
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
      let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
      return PdfExportResult(
        outputPath: outputURL.path,
        pageCount: Int64(pageCount),
        fileSizeBytes: fileSize
      )
    } catch let error as PdfPocError {
      throw error
    } catch {
      throw PdfPocError(
        code: "export_failed",
        message: "Could not export a flattened PDF copy.",
        details: error.localizedDescription
      )
    }
  }
}
